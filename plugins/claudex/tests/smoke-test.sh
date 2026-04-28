#!/usr/bin/env bash
# Smoke test - simulates the full plan-mode lifecycle without invoking Codex.
#
# This test stubs out the actual Codex call and just exercises the state
# machine + hook lifecycle. Run it after platform-validation.sh passes.
#
# What it tests:
#   1. start-loop.sh creates state and prints initial instructions
#   2. Hook fires with phase=drafting + missing PLAN.md  -> BLOCK
#   3. Hook fires with phase=drafting + present PLAN.md  -> BLOCK with run-script + transition to reviewing
#   4. Hook fires with phase=reviewing + no signal       -> BLOCK + round increment
#   5. Hook fires with phase=reviewing + done signal     -> ALLOW + cleanup
#   6. Concurrent loops are refused
#   7. cancel-loop.sh marks state cancelled
#   8. rollback-loop.sh wipes state

set +e

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"
START="$PLUGIN_ROOT/scripts/start-loop.sh"
MARK_DONE="$PLUGIN_ROOT/scripts/mark-done.sh"
CANCEL="$PLUGIN_ROOT/scripts/cancel-loop.sh"
ROLLBACK="$PLUGIN_ROOT/scripts/rollback-loop.sh"

pass=0
fail=0
fail_msgs=()

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
    pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    fail=$((fail+1))
    fail_msgs+=("$name")
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

printf '\033[1m=== Claudex Smoke Test ===\033[0m\n'
printf 'Plugin root: %s\n' "$PLUGIN_ROOT"

# Set up an isolated test repo.
TMP=$(mktemp -d)
cd "$TMP"
git init -q

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

section "1. start-loop.sh plan mode"
output=$(bash "$START" plan "test feature: a small URL shortener with expiry" 2>&1)
echo "$output" > /tmp/claudex-smoke-output.txt
check "start-loop produces output" test -n "$output"
check "output mentions plan mode" bash -c "echo \"$output\" | grep -q 'plan mode'"
check "state file created" bash -c "ls .claude/claudex/*.state 2>/dev/null | grep -q ."
REVIEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
check "review_id extracted" test -n "$REVIEW_ID"

# Read state.
STATE_FILE=".claude/claudex/$REVIEW_ID.state"
phase=$(grep '^phase:' "$STATE_FILE" | sed 's/^phase: //')
check "initial phase is drafting" test "$phase" = "drafting"

section "2. Concurrent loops refused"
output=$(bash "$START" plan "another loop" 2>&1)
check "second start-loop refuses" bash -c "echo \"$output\" | grep -qi 'already active'"

section "3. Hook with phase=drafting and missing PLAN.md"
hook_out=$(echo '{}' | bash "$HOOK" 2>/dev/null)
check "hook returns block (no PLAN.md)" bash -c "echo '$hook_out' | grep -q block"

section "4. Hook with phase=drafting and present PLAN.md"
echo "# Test plan
1. step one
2. step two" > PLAN.md
HOOK_OUT_FILE=$(mktemp)
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"
check "hook returns block (run runner)" grep -q block "$HOOK_OUT_FILE"
check "phase transitioned to reviewing" bash -c '[ "$(grep ^phase: '"$STATE_FILE"' | sed s/^phase:.*//)" != "drafting" ]'
new_phase=$(grep '^phase:' "$STATE_FILE" | sed 's/^phase: //')
check "phase is now reviewing" test "$new_phase" = "reviewing"
check "runner script written" test -f ".claude/claudex/$REVIEW_ID-runner.sh"

section "5. Hook with phase=reviewing and no done signal (round increment)"
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"
check "hook returns block (round 2)" grep -q block "$HOOK_OUT_FILE"
new_round=$(grep '^round:' "$STATE_FILE" | sed 's/^round: //')
check "round incremented to 2" test "$new_round" = "2"

section "6. mark-done signals loop end (sets signal, leaves phase=reviewing)"
bash "$MARK_DONE" "$REVIEW_ID" >/dev/null 2>&1
post_phase=$(grep '^phase:' "$STATE_FILE" | sed 's/^phase: //')
post_signal=$(grep '^decision_signal:' "$STATE_FILE" | sed 's/^decision_signal: //')
check "mark-done leaves phase=reviewing" test "$post_phase" = "reviewing"
check "mark-done set signal=no-material-findings" test "$post_signal" = "no-material-findings"

section "7. Hook with phase=reviewing + signal=no-material-findings -> BLOCK with summary"
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"
check "summary fire returns block" grep -q block "$HOOK_OUT_FILE"
check "summary mentions 'plan loop complete'" grep -qi 'plan loop complete' "$HOOK_OUT_FILE"
check "summary mentions 'Findings by round'" grep -q 'Findings by round' "$HOOK_OUT_FILE"
summarizing_phase=$(grep '^phase:' "$STATE_FILE" | sed 's/^phase: //')
check "phase transitioned to summarizing" test "$summarizing_phase" = "summarizing"

section "7b. Next hook fire: summarizing -> done -> approve"
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"
check "post-summary fire returns approve" grep -q approve "$HOOK_OUT_FILE"
final_phase=$(grep '^phase:' "$STATE_FILE" | sed 's/^phase: //')
check "phase is now done" test "$final_phase" = "done"

section "8. Cancel-loop"
bash "$ROLLBACK" >/dev/null 2>&1
bash "$START" plan "another test" >/dev/null 2>&1
bash "$CANCEL" >/dev/null 2>&1
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
cancelled_phase=$(grep '^phase:' "$NEW_STATE" 2>/dev/null | sed 's/^phase: //')
check "cancel set phase=cancelled" test "$cancelled_phase" = "cancelled"

section "9. Rollback wipes state"
bash "$ROLLBACK" >/dev/null 2>&1
remaining=$(ls .claude/claudex/*.state 2>/dev/null | wc -l | tr -d ' ')
check "rollback removed all state files" test "$remaining" = "0"
check "log file preserved" test -f ".claude/claudex/log"

section "10. Review mode E2E"
bash "$START" review >/dev/null 2>&1
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
review_phase=$(grep '^phase:' "$NEW_STATE" | sed 's/^phase: //')
check "review mode initial phase=reviewing" test "$review_phase" = "reviewing"
hook_out=$(echo '{}' | bash "$HOOK" 2>/dev/null)
check "review mode hook returns block" bash -c "echo '$hook_out' | grep -q block"
check "review mode runner created" test -f ".claude/claudex/$NEW_ID-runner.sh"

bash "$ROLLBACK" >/dev/null 2>&1

section "11. P1 fix - runner script uses quoted PROMPTEOF"
bash "$START" plan "topic with safe metachars" >/dev/null 2>&1
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" >/dev/null 2>&1
RUNNER_FILE=$(ls .claude/claudex/*-runner.sh 2>/dev/null | head -1)
check "runner file exists" test -f "$RUNNER_FILE"
check "PROMPTEOF is single-quoted" grep -q "<<'PROMPTEOF'" "$RUNNER_FILE"
check "no unquoted PROMPTEOF" bash -c "! grep -E '<<PROMPTEOF\$' '$RUNNER_FILE'"

bash "$ROLLBACK" >/dev/null 2>&1

section "12. P2 fix - back-to-back loops after completion"
bash "$START" plan "first loop" >/dev/null 2>&1
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" >/dev/null 2>&1   # drafting -> reviewing, writes runner
FIRST_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
bash "$MARK_DONE" "$FIRST_ID" >/dev/null 2>&1
echo '{}' | bash "$HOOK" >/dev/null 2>&1   # reviewing -> summarizing, BLOCK with summary
echo '{}' | bash "$HOOK" >/dev/null 2>&1   # summarizing -> done, cleans up lockfile + runner
# Lockfile should now be gone, state file remains
check "lockfile removed after completion" bash -c "! test -f .claude/claudex/$FIRST_ID.lock"
check "state file kept for audit" test -f ".claude/claudex/$FIRST_ID.state"
# Now try a second loop
output=$(bash "$START" plan "second loop" 2>&1)
check "second loop accepted (not refused)" bash -c "echo '$output' | grep -qi 'plan mode initialized'"
check "second loop NOT marked as concurrent" bash -c "! echo '$output' | grep -qi 'already active'"

bash "$ROLLBACK" >/dev/null 2>&1

section "13. P2 fix - back-to-back loops after cancellation"
bash "$START" plan "first loop" >/dev/null 2>&1
bash "$CANCEL" >/dev/null 2>&1
output=$(bash "$START" plan "second loop after cancel" 2>&1)
check "second loop after cancel accepted" bash -c "echo '$output' | grep -qi 'plan mode initialized'"

bash "$ROLLBACK" >/dev/null 2>&1

section "14. P2 fix - terminal-phase state files do not block new loops"
mkdir -p .claude/claudex
# Plant a state file in terminal phase (mimics a completed loop preserved for audit)
cat > .claude/claudex/20200101-000000-aaaaaa.state <<'STATEEOF'
mode: plan
phase: done
topic: "old completed loop"
round: 3
max_rounds: 5
STATEEOF
output=$(bash "$START" plan "fresh loop past terminal" 2>&1)
check "fresh loop accepted past done state" bash -c "echo '$output' | grep -qi 'plan mode initialized'"
check "old state file preserved for audit" test -f .claude/claudex/20200101-000000-aaaaaa.state

bash "$ROLLBACK" >/dev/null 2>&1

section "15. --rounds N flag overrides default"
output=$(bash "$START" plan --rounds 3 "tight loop" 2>&1)
check "--rounds accepted" bash -c "echo '$output' | grep -qi 'plan mode initialized'"
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
state_max=$(grep '^max_rounds:' "$NEW_STATE" | sed 's/^max_rounds: //')
check "max_rounds set to 3 in state" test "$state_max" = "3"

bash "$ROLLBACK" >/dev/null 2>&1

section "16. --rounds with =N syntax also works"
output=$(bash "$START" plan --rounds=2 "even tighter loop" 2>&1)
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
state_max=$(grep '^max_rounds:' "$NEW_STATE" | sed 's/^max_rounds: //')
check "max_rounds=2 set via equals syntax" test "$state_max" = "2"

bash "$ROLLBACK" >/dev/null 2>&1

section "17. --rounds rejects non-positive values"
output=$(bash "$START" plan --rounds 0 "invalid" 2>&1)
check "--rounds 0 rejected" bash -c "echo '$output' | grep -qi 'positive integer'"
output=$(bash "$START" plan --rounds abc "invalid" 2>&1)
check "--rounds abc rejected" bash -c "echo '$output' | grep -qi 'positive integer'"

bash "$ROLLBACK" >/dev/null 2>&1

section "18. --from-draft requires existing PLAN.md"
rm -f PLAN.md
output=$(bash "$START" plan --from-draft "draft topic" 2>&1)
check "--from-draft errors when PLAN.md missing" bash -c "echo '$output' | grep -qi 'PLAN.md to exist'"
check "no state file created on --from-draft error" bash -c "[ -z \"$(ls .claude/claudex/*.state 2>/dev/null)\" ]"

section "19. --from-draft works when PLAN.md exists"
echo "# existing plan
1. step one
2. step two" > PLAN.md
output=$(bash "$START" plan --from-draft "topic for from-draft" 2>&1)
check "--from-draft accepted" bash -c "echo '$output' | grep -qi 'plan mode initialized'"
check "output mentions from-draft source" bash -c "echo '$output' | grep -qi 'existing PLAN.md'"
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
fd_field=$(grep '^from_draft:' "$NEW_STATE" | sed 's/^from_draft: //')
check "from_draft=true in state" test "$fd_field" = "true"

bash "$ROLLBACK" >/dev/null 2>&1
rm -f PLAN.md

section "20. --from-draft rejected on review mode"
echo "# plan" > PLAN.md
output=$(bash "$START" review --from-draft 2>&1)
check "--from-draft on review mode rejected" bash -c "echo '$output' | grep -qi 'only applies to plan mode'"
rm -f PLAN.md

bash "$ROLLBACK" >/dev/null 2>&1

section "21. Combined --rounds and --from-draft"
echo "# plan" > PLAN.md
output=$(bash "$START" plan --rounds 4 --from-draft "combined flags" 2>&1)
check "combined flags accepted" bash -c "echo '$output' | grep -qi 'plan mode initialized'"
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
state_max=$(grep '^max_rounds:' "$NEW_STATE" | sed 's/^max_rounds: //')
fd_field=$(grep '^from_draft:' "$NEW_STATE" | sed 's/^from_draft: //')
check "max_rounds=4 set" test "$state_max" = "4"
check "from_draft=true set" test "$fd_field" = "true"
rm -f PLAN.md

bash "$ROLLBACK" >/dev/null 2>&1

section "22. New state fields: started_at_epoch and interview_used"
bash "$START" plan "epoch test" >/dev/null 2>&1
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
check "started_at_epoch field present" grep -qE '^started_at_epoch:' "$NEW_STATE"
epoch_val=$(grep '^started_at_epoch:' "$NEW_STATE" | sed 's/^started_at_epoch: //')
check "started_at_epoch is numeric" bash -c "echo '$epoch_val' | grep -qE '^[0-9]+$'"
check "interview_used field present" grep -qE '^interview_used:' "$NEW_STATE"
iu_val=$(grep '^interview_used:' "$NEW_STATE" | sed 's/^interview_used: //')
check "interview_used defaults to false" test "$iu_val" = "false"

bash "$ROLLBACK" >/dev/null 2>&1

section "23. --skip-interview flag accepted (no-op in start-loop)"
output=$(bash "$START" plan --skip-interview "no-interview topic" 2>&1)
check "--skip-interview accepted" bash -c "echo '$output' | grep -qi 'plan mode initialized'"

bash "$ROLLBACK" >/dev/null 2>&1

section "24. --interviewed flag records interview_used=true"
bash "$START" plan --interviewed "interviewed topic with details" >/dev/null 2>&1
NEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
NEW_STATE=".claude/claudex/$NEW_ID.state"
iu_val=$(grep '^interview_used:' "$NEW_STATE" | sed 's/^interview_used: //')
check "interview_used=true recorded" test "$iu_val" = "true"

bash "$ROLLBACK" >/dev/null 2>&1

section "25. Persona rotates per round in runner script"
bash "$START" plan "persona test topic" >/dev/null 2>&1
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" >/dev/null 2>&1   # round 1: senior engineer
RUNNER_FILE=$(ls .claude/claudex/*-runner.sh 2>/dev/null | head -1)
check "round 1 runner mentions senior engineer" grep -qi 'senior' "$RUNNER_FILE"
check "round 1 runner does NOT mention security persona" bash -c "! grep -qi 'security and data-integrity' '$RUNNER_FILE'"

# Force round 2 by re-firing with no done signal.
echo '{}' | bash "$HOOK" >/dev/null 2>&1
RUNNER_FILE=$(ls .claude/claudex/*-runner.sh 2>/dev/null | head -1)
check "round 2 runner mentions security" grep -qi 'security' "$RUNNER_FILE"

# Round 3.
echo '{}' | bash "$HOOK" >/dev/null 2>&1
RUNNER_FILE=$(ls .claude/claudex/*-runner.sh 2>/dev/null | head -1)
check "round 3 runner mentions ops or SRE" bash -c "grep -qiE 'ops|SRE' '$RUNNER_FILE'"
rm -f PLAN.md

bash "$ROLLBACK" >/dev/null 2>&1

section "26. /claudex:status output on a fresh loop"
bash "$START" plan "status test" >/dev/null 2>&1
status_out=$(bash "$PLUGIN_ROOT/scripts/status.sh" 2>&1)
check "status prints review_id" bash -c "echo '$status_out' | grep -q 'review_id'"
check "status prints phase" bash -c "echo '$status_out' | grep -q 'phase'"
check "status prints elapsed" bash -c "echo '$status_out' | grep -q 'elapsed'"

bash "$ROLLBACK" >/dev/null 2>&1

section "27. /claudex:status on empty state directory"
status_out=$(bash "$PLUGIN_ROOT/scripts/status.sh" 2>&1)
check "status reports no loops cleanly" bash -c "echo '$status_out' | grep -qi 'no.*loops'"

bash "$ROLLBACK" >/dev/null 2>&1

section "28. Max-rounds termination delivers a summary BLOCK (not silent approve)"
bash "$START" plan --rounds 1 "max-rounds test" >/dev/null 2>&1
ID28=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
ST28=".claude/claudex/$ID28.state"
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" >/dev/null 2>&1   # drafting -> reviewing
# Without mark-done and without a fresh PLAN, the next fire increments round past max
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"   # round 1 -> would be round 2 > max=1
check "max-rounds fire returns block (with summary)" grep -q block "$HOOK_OUT_FILE"
check "summary mentions 'stopped at max rounds'" grep -qi 'stopped at max rounds' "$HOOK_OUT_FILE"
phase28=$(grep '^phase:' "$ST28" | sed 's/^phase: //')
check "phase=summarizing after max-rounds BLOCK" test "$phase28" = "summarizing"
signal28=$(grep '^decision_signal:' "$ST28" | sed 's/^decision_signal: //')
check "signal=max-reached" test "$signal28" = "max-reached"
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"   # summarizing -> done -> approve
check "next fire returns approve" grep -q approve "$HOOK_OUT_FILE"
phase28b=$(grep '^phase:' "$ST28" | sed 's/^phase: //')
check "phase=done after summary delivered" test "$phase28b" = "done"
rm -f PLAN.md

bash "$ROLLBACK" >/dev/null 2>&1

section "29. mark-done.sh BLOCK uses literal \${CLAUDE_PLUGIN_ROOT}"
bash "$START" plan "literal pluginroot test" >/dev/null 2>&1
echo "# plan" > PLAN.md
echo '{}' | bash "$HOOK" 2>/dev/null > "$HOOK_OUT_FILE"
check "BLOCK contains literal \${CLAUDE_PLUGIN_ROOT} placeholder" \
  grep -q '\${CLAUDE_PLUGIN_ROOT}/scripts/mark-done.sh' "$HOOK_OUT_FILE"
check "BLOCK does NOT contain a leaked absolute path" \
  bash -c "! grep -q '$PLUGIN_ROOT/scripts/mark-done.sh' '$HOOK_OUT_FILE'"
rm -f PLAN.md

bash "$ROLLBACK" >/dev/null 2>&1

section "30. last_updated_at refreshes on every state mutation"
bash "$START" plan "last_updated test" >/dev/null 2>&1
ID30=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.state$//')
ST30=".claude/claudex/$ID30.state"
ts_initial=$(grep '^last_updated_at:' "$ST30" | sed 's/^last_updated_at: //')
sleep 1
source "$PLUGIN_ROOT/scripts/state-helpers.sh"
claudex_state_set_field "$ST30" "round" "2"
ts_after_set=$(grep '^last_updated_at:' "$ST30" | sed 's/^last_updated_at: //')
check "last_updated_at refreshed by set_field" test "$ts_initial" != "$ts_after_set"

# Cleanup
cd - >/dev/null
rm -rf "$TMP"

# Summary
printf '\n\033[1m=== Smoke Test Results ===\033[0m\n'
printf '  \033[32m%d passed\033[0m\n' "$pass"
if [ $fail -gt 0 ]; then
  printf '  \033[31m%d failed\033[0m\n' "$fail"
  printf '\nFailed:\n'
  for m in "${fail_msgs[@]}"; do
    printf '  - %s\n' "$m"
  done
  exit 1
fi
printf '\n  Smoke test passed. Plan mode and review mode lifecycles work.\n'
exit 0
