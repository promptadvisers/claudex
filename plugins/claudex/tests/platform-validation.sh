#!/usr/bin/env bash
# Phase 0 -- Platform Validation
#
# Run this after installing claudex to confirm the platform behaviors that
# claudex depends on actually work on your machine.
#
#   bash tests/platform-validation.sh
#
# What it checks:
#   1. Hook script exists and is executable
#   2. Hook returns valid JSON when invoked manually
#   3. Hook fails open on bad input
#   4. Hook handles missing state directory gracefully
#   5. State helpers source cleanly
#   6. review_id generation + validation
#   7. Atomic state write
#   8. CAS phase transition
#   9. Stale loop sweeper
#  10. Lockfile + PID-alive checks
#
# These do NOT exercise Claude Code's actual hook execution (that requires
# running a real Claude session). Run the smoke test for that.

set +e

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"

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

printf '\033[1m=== Claudex Phase 0 Platform Validation ===\033[0m\n'
printf 'Plugin root: %s\n' "$PLUGIN_ROOT"

section "1. Hook script"
check "hook file exists" test -f "$HOOK"
check "hook is executable" test -x "$HOOK"

section "2. Hook responds to empty input"
output=$(echo '{}' | bash "$HOOK" 2>/dev/null)
check "hook outputs something" test -n "$output"
check "hook output is JSON-ish" bash -c "echo '$output' | grep -q '{' && echo '$output' | grep -q '}'"
check "hook output has decision field" bash -c "echo '$output' | grep -q decision"

section "3. Hook fail-opens on bad input"
output=$(echo 'not json at all' | bash "$HOOK" 2>/dev/null)
check "hook fail-opens on bad input" bash -c "echo '$output' | grep -q approve"

section "4. Hook handles missing state dir"
TMP=$(mktemp -d)
cd "$TMP"
output=$(echo '{}' | bash "$HOOK" 2>/dev/null)
check "hook handles missing state" bash -c "echo '$output' | grep -q approve"
cd - >/dev/null
rm -rf "$TMP"

section "5. state-helpers.sh"
check "state-helpers exists" test -f "$PLUGIN_ROOT/scripts/state-helpers.sh"
check "state-helpers sources cleanly" bash -c "source '$PLUGIN_ROOT/scripts/state-helpers.sh'"

# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/state-helpers.sh"

section "6. review_id generation + validation"
test_id=$(claudex_new_review_id)
check "generates id" test -n "$test_id"
check "id matches format" claudex_validate_review_id "$test_id"
check "rejects empty id" bash -c "! claudex_validate_review_id ''"
check "rejects bad id" bash -c "! claudex_validate_review_id 'bad-id'"
check "rejects path traversal" bash -c "! claudex_validate_review_id '../../../etc/passwd'"

section "7. Atomic state write"
TMP=$(mktemp -d)
cd "$TMP"
mkdir -p .claude/claudex
content="phase: drafting
round: 1
last_updated_at: 2026-04-26T00:00:00Z"
claudex_state_write ".claude/claudex/test.state" "$content"
check "state file created" test -f ".claude/claudex/test.state"
phase_val=$(claudex_state_read_field ".claude/claudex/test.state" phase)
check "phase field readable" test "$phase_val" = "drafting"
round_val=$(claudex_state_read_field ".claude/claudex/test.state" round)
check "round field readable" test "$round_val" = "1"
cd - >/dev/null
rm -rf "$TMP"

section "8. CAS phase transition"
TMP=$(mktemp -d)
cd "$TMP"
mkdir -p .claude/claudex
content="phase: drafting
last_updated_at: 2026-04-26T00:00:00Z"
claudex_state_write ".claude/claudex/test.state" "$content"
check "valid CAS succeeds" claudex_phase_transition ".claude/claudex/test.state" drafting reviewing
new_phase=$(claudex_state_read_field ".claude/claudex/test.state" phase)
check "phase actually changed" test "$new_phase" = "reviewing"
# After transition, phase is "reviewing", so CAS from "drafting" should fail
if claudex_phase_transition ".claude/claudex/test.state" drafting reviewing; then
  check "stale CAS fails" false
else
  check "stale CAS fails" true
fi
cd - >/dev/null
rm -rf "$TMP"

section "9. Stale sweeper"
TMP=$(mktemp -d)
cd "$TMP"
mkdir -p .claude/claudex
touch -t 200001010000 ".claude/claudex/old.state"  # year 2000, definitely stale
claudex_state_write ".claude/claudex/fresh.state" "phase: drafting"
CLAUDEX_STALE_MINUTES=15 claudex_sweep_stale
check "stale state removed" bash -c '! test -f .claude/claudex/old.state'
check "fresh state kept" test -f ".claude/claudex/fresh.state"
cd - >/dev/null
rm -rf "$TMP"

section "10. Lockfile + PID-alive"
TMP=$(mktemp -d)
cd "$TMP"
mkdir -p .claude/claudex
claudex_lock_write ".claude/claudex/test.lock"
check "lock file written" test -f ".claude/claudex/test.lock"
check "self PID is alive" claudex_lock_is_active ".claude/claudex/test.lock"
echo "999999" > ".claude/claudex/dead.lock"  # impossibly high PID
check "dead PID detected" bash -c "! claudex_lock_is_active .claude/claudex/dead.lock"
cd - >/dev/null
rm -rf "$TMP"

section "11. Active loop finder"
TMP=$(mktemp -d)
cd "$TMP"
export CLAUDEX_STATE_DIR=".claude/claudex"
mkdir -p "$CLAUDEX_STATE_DIR"
check "no loops returns empty" bash -c "! claudex_find_active_loop"
claudex_state_write "$CLAUDEX_STATE_DIR/loop1.state" "phase: drafting"
sleep 1
claudex_state_write "$CLAUDEX_STATE_DIR/loop2.state" "phase: drafting"
active=$(claudex_find_active_loop)
check "active loop detected" test -n "$active"
check "most recent loop returned" bash -c "echo '$active' | grep -q loop2"
cd - >/dev/null
rm -rf "$TMP"
unset CLAUDEX_STATE_DIR

section "11b. Session-scoped active loop finder"
TMP=$(mktemp -d)
cd "$TMP"
export CLAUDEX_STATE_DIR=".claude/claudex"
mkdir -p "$CLAUDEX_STATE_DIR"
check "empty session arg returns non-zero" bash -c "! claudex_find_active_loop_for_session ''"
check "no loops returns non-zero" bash -c "! claudex_find_active_loop_for_session SID_X"
claudex_state_write "$CLAUDEX_STATE_DIR/loopA.state" "phase: drafting
session_id: SID_A"
sleep 1
claudex_state_write "$CLAUDEX_STATE_DIR/loopB.state" "phase: drafting
session_id: SID_B"
matchA=$(claudex_find_active_loop_for_session "SID_A")
check "scoped lookup finds SID_A loop" bash -c "echo '$matchA' | grep -q loopA"
matchB=$(claudex_find_active_loop_for_session "SID_B")
check "scoped lookup finds SID_B loop" bash -c "echo '$matchB' | grep -q loopB"
check "scoped lookup with unknown sid returns non-zero" bash -c "! claudex_find_active_loop_for_session SID_Z"
cd - >/dev/null
rm -rf "$TMP"
unset CLAUDEX_STATE_DIR

section "12. Personas helper"
check "personas.sh exists" test -f "$PLUGIN_ROOT/scripts/personas.sh"
check "personas sources cleanly" bash -c "source '$PLUGIN_ROOT/scripts/personas.sh'"

# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/personas.sh"
R1=$(claudex_persona_for_round 1)
R2=$(claudex_persona_for_round 2)
R3=$(claudex_persona_for_round 3)
R4=$(claudex_persona_for_round 4)
check "round 1 persona non-empty" test -n "$R1"
check "round 2 persona non-empty" test -n "$R2"
check "round 3 persona non-empty" test -n "$R3"
check "round 4 persona non-empty" test -n "$R4"
check "round 1 differs from round 2" test "$R1" != "$R2"
check "round 2 differs from round 3" test "$R2" != "$R3"
check "round 1 mentions senior engineer" bash -c "echo \"$R1\" | grep -qi 'senior'"
check "round 2 mentions security" bash -c "echo \"$R2\" | grep -qi 'security'"
check "round 3 mentions ops or SRE" bash -c "echo \"$R3\" | grep -qiE 'ops|SRE'"

L1=$(claudex_persona_label_for_round 1)
L2=$(claudex_persona_label_for_round 2)
L3=$(claudex_persona_label_for_round 3)
check "round 1 label non-empty" test -n "$L1"
check "round 1 label differs from round 2" test "$L1" != "$L2"
check "round 2 label differs from round 3" test "$L2" != "$L3"

section "13. Findings severity counter"
TMP=$(mktemp -d)
cat > "$TMP/sample.md" <<'EOF'
# Round 2 findings

## High
- finding one (recommendation A)
- finding two (recommendation B)
- finding three (recommendation C)

## Medium
- finding four (recommendation D)

## Low
EOF
counts=$(claudex_findings_severity_counts "$TMP/sample.md")
check "counts produced" test -n "$counts"
check "high count = 3" bash -c "echo '$counts' | grep -q 'high=3'"
check "medium count = 1" bash -c "echo '$counts' | grep -q 'medium=1'"
check "low count = 0" bash -c "echo '$counts' | grep -q 'low=0'"
empty_counts=$(claudex_findings_severity_counts "$TMP/does-not-exist.md")
check "missing file returns zeroed counts" \
  bash -c "echo '$empty_counts' | grep -q 'high=0 medium=0 low=0'"
rm -rf "$TMP"

section "14. status.sh and doctor.sh present and runnable"
check "status.sh exists" test -f "$PLUGIN_ROOT/scripts/status.sh"
check "doctor.sh exists" test -f "$PLUGIN_ROOT/scripts/doctor.sh"
check "status.sh runs without error on empty state" bash -c "
  TMP=\$(mktemp -d) && cd \"\$TMP\" && \
  CLAUDEX_STATE_DIR=.claude/claudex bash '$PLUGIN_ROOT/scripts/status.sh' >/dev/null 2>&1
  rc=\$?
  cd - >/dev/null && rm -rf \"\$TMP\"
  exit \$rc
"

# Summary
printf '\n\033[1m=== Results ===\033[0m\n'
printf '  \033[32m%d passed\033[0m\n' "$pass"
if [ $fail -gt 0 ]; then
  printf '  \033[31m%d failed\033[0m\n' "$fail"
  printf '\nFailed checks:\n'
  for m in "${fail_msgs[@]}"; do
    printf '  - %s\n' "$m"
  done
  exit 1
fi
printf '\n  All platform checks passed. Foundation is ready.\n'
exit 0
