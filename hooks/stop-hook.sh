#!/usr/bin/env bash
# Claudex Stop Hook (full lifecycle)
#
# Fires every time Claude tries to finish a turn. Drives the autonomous loop
# by deciding whether to ALLOW the exit or BLOCK it with instructions for
# the next step.
#
# Modes:
#   plan   - draft PLAN.md, adversarial-review it, revise, repeat
#   review - run code review, write findings + proposed-fixes (read-only v1)
#
# Safety: every error path returns {"decision":"approve"} so the user can
# never be trapped. ERR trap installed at the top.

set +e

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR=".claude/claudex"
LOG_FILE="$STATE_DIR/log"

mkdir -p "$STATE_DIR" 2>/dev/null

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null
}

approve() {
  local reason="$1"
  [ -n "$reason" ] && log "APPROVE: $reason"
  printf '{"decision":"approve"}\n'
  exit 0
}

block() {
  local reason="$1"
  log "BLOCK: $(printf '%s' "$reason" | head -c 80)..."
  # Escape the reason for JSON: replace newlines, quotes, backslashes.
  local escaped
  escaped=$(printf '%s' "$reason" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))' 2>/dev/null)
  if [ -z "$escaped" ]; then
    # Fallback: simple sed-based escaping
    escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g')
    escaped="\"$escaped\""
  fi
  printf '{"decision":"block","reason":%s}\n' "$escaped"
  exit 0
}

trap 'log "ERR trap at line $LINENO; failing open"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh" 2>/dev/null || approve "state-helpers missing"

# Read hook input from stdin (Claude Code sends JSON).
HOOK_INPUT=""
if [ -t 0 ]; then
  HOOK_INPUT='{}'
else
  HOOK_INPUT="$(cat 2>/dev/null || echo '{}')"
fi
log "Hook fired. Input bytes: ${#HOOK_INPUT}"

# Find active loop.
ACTIVE_STATE=""
ACTIVE_STATE=$(claudex_find_active_loop 2>/dev/null)
if [ -z "$ACTIVE_STATE" ] || [ ! -f "$ACTIVE_STATE" ]; then
  approve "no active loop"
fi

REVIEW_ID=$(basename "$ACTIVE_STATE" .state)
log "Active loop: $REVIEW_ID"

if ! claudex_validate_review_id "$REVIEW_ID"; then
  log "Invalid review_id, removing state"
  rm -f "$ACTIVE_STATE" 2>/dev/null
  approve "invalid review_id, cleaned"
fi

# Read state fields.
MODE=$(claudex_state_read_field "$ACTIVE_STATE" "mode")
PHASE=$(claudex_state_read_field "$ACTIVE_STATE" "phase")
ROUND=$(claudex_state_read_field "$ACTIVE_STATE" "round")
MAX_ROUNDS=$(claudex_state_read_field "$ACTIVE_STATE" "max_rounds")
DECISION_SIGNAL=$(claudex_state_read_field "$ACTIVE_STATE" "decision_signal")
TOPIC=$(claudex_state_read_field "$ACTIVE_STATE" "topic")
REPO_ROOT_STATE=$(claudex_state_read_field "$ACTIVE_STATE" "repo_root")

log "State: mode=$MODE phase=$PHASE round=$ROUND/$MAX_ROUNDS signal=$DECISION_SIGNAL"

# Sanity: if cwd doesn't match the repo where the loop started, fail-open.
if [ -n "$REPO_ROOT_STATE" ] && [ "$REPO_ROOT_STATE" != "$(pwd)" ]; then
  log "cwd mismatch (state=$REPO_ROOT_STATE, here=$(pwd)); fail-open"
  approve "cwd mismatch"
fi

# Validate numerics.
case "$ROUND" in
  ''|*[!0-9]*) ROUND=1 ;;
esac
case "$MAX_ROUNDS" in
  ''|*[!0-9]*) MAX_ROUNDS=5 ;;
esac

RUNNER="$STATE_DIR/$REVIEW_ID-runner.sh"

write_runner_script() {
  local mode="$1"
  local focus="$2"
  cat > "$RUNNER" <<RUNNEREOF
#!/usr/bin/env bash
# Claudex runner script for $REVIEW_ID, mode=$mode, round=$ROUND
# Runs Codex against the current state. Output streams to user's terminal.

set +e

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex CLI not found in PATH. Install with: npm install -g @openai/codex" >&2
  exit 1
fi

PROMPT_FILE="$STATE_DIR/$REVIEW_ID-prompt.txt"

cat > "\$PROMPT_FILE" <<'PROMPTEOF'
$focus
PROMPTEOF

echo "[claudex] Running Codex (mode=$mode, round=$ROUND)..."
codex exec --dangerously-bypass-approvals-and-sandbox < "\$PROMPT_FILE"
RC=\$?
echo "[claudex] Codex exit code: \$RC"
exit \$RC
RUNNEREOF
  chmod +x "$RUNNER"
}

# === PLAN MODE LIFECYCLE ===

if [ "$MODE" = "plan" ]; then
  case "$PHASE" in
    drafting)
      # Claude was supposed to draft PLAN.md. Verify.
      if [ ! -f "PLAN.md" ] || [ ! -s "PLAN.md" ]; then
        block "Claudex plan mode: PLAN.md does not exist or is empty.

You need to draft PLAN.md in the project root before ending your turn.

Topic: $TOPIC

Use a numbered list covering edge cases, time zones, concurrent use, data integrity, and unhappy paths. Then end your turn."
      fi

      # PLAN.md exists. Transition to reviewing and run round 1.
      if ! claudex_phase_transition "$ACTIVE_STATE" "drafting" "reviewing"; then
        log "CAS drafting->reviewing failed"
        approve "CAS failed"
      fi

      FOCUS="You are doing an adversarial review of a plan document at PLAN.md in the current working directory.

Topic: $TOPIC

Pressure-test this plan. Find real failure modes, design flaws, and edge cases that would break under stress. Be specific.

For each material finding:
- Severity: high, medium, or low
- One-sentence description of what could go wrong
- Specific recommendation

If you find no material concerns (only style nits), say exactly: 'No substantive findings.'

Read PLAN.md now and review."

      write_runner_script "plan" "$FOCUS"

      MSG="Round $ROUND - adversarial review starting.

Run the runner script:
  bash $RUNNER

Wait for Codex to finish. Read the findings.

Then decide:

**If material findings exist:** Revise PLAN.md to address them. Add a '## Changelog' section at the bottom of PLAN.md noting what you took (and what you rejected with reasoning). Then end your turn.

**If no material findings (or only style nits):** Mark the loop done by running:
  bash $CLAUDE_PLUGIN_ROOT/scripts/mark-done.sh $REVIEW_ID
Then end your turn.

Hard stop: if this is round $MAX_ROUNDS and Codex still has substantive findings, end your turn anyway. The hook will detect max-rounds-reached and exit cleanly."

      block "$MSG"
      ;;

    reviewing)
      # Claude has run review and either revised PLAN.md or marked done.
      if [ "$DECISION_SIGNAL" = "no-material-findings" ]; then
        # Loop complete.
        if ! claudex_phase_transition "$ACTIVE_STATE" "reviewing" "done"; then
          log "CAS reviewing->done failed (already done?)"
        fi
        # Read changelog if it exists.
        CHANGELOG=""
        if [ -f "PLAN.md" ]; then
          CHANGELOG=$(awk '/^## Changelog/,/^## /' PLAN.md 2>/dev/null | tail -n +2 | head -20)
        fi
        rm -f "$RUNNER" "$STATE_DIR/$REVIEW_ID-prompt.txt" 2>/dev/null
        rm -f "$STATE_DIR/$REVIEW_ID.lock" 2>/dev/null
        log "Plan loop $REVIEW_ID complete after $ROUND round(s)"
        approve "plan loop complete"
      fi

      # No done signal. Claude must have revised. Increment round.
      NEW_ROUND=$((ROUND + 1))
      claudex_state_set_field "$ACTIVE_STATE" "round" "$NEW_ROUND"

      if [ "$NEW_ROUND" -gt "$MAX_ROUNDS" ]; then
        # Max rounds hit.
        claudex_state_set_field "$ACTIVE_STATE" "decision_signal" "max-reached"
        claudex_state_set_field "$ACTIVE_STATE" "phase" "done"
        rm -f "$RUNNER" "$STATE_DIR/$REVIEW_ID-prompt.txt" 2>/dev/null
        rm -f "$STATE_DIR/$REVIEW_ID.lock" 2>/dev/null
        log "Plan loop $REVIEW_ID stopped at max rounds"
        approve "max rounds reached"
      fi

      # Run another round.
      FOCUS="You are doing an adversarial review of a plan document at PLAN.md in the current working directory.

Topic: $TOPIC

Pressure-test this plan. Find real failure modes, design flaws, and edge cases that would break under stress. Be specific.

For each material finding:
- Severity: high, medium, or low
- One-sentence description of what could go wrong
- Specific recommendation

If you find no material concerns (only style nits), say exactly: 'No substantive findings.'

Read PLAN.md now and review."

      write_runner_script "plan" "$FOCUS"

      MSG="Round $NEW_ROUND - adversarial review starting.

Run the runner script:
  bash $RUNNER

Wait for Codex to finish. Read the findings.

If material findings exist, revise PLAN.md and end your turn (round will increment).
If no material findings, run: bash $CLAUDE_PLUGIN_ROOT/scripts/mark-done.sh $REVIEW_ID
Then end your turn."

      block "$MSG"
      ;;

    done)
      rm -f "$RUNNER" "$STATE_DIR/$REVIEW_ID-prompt.txt" "$STATE_DIR/$REVIEW_ID.lock" 2>/dev/null
      approve "plan loop already done"
      ;;

    *)
      log "Unknown plan phase: $PHASE"
      approve "unknown phase, fail-open"
      ;;
  esac
fi

# === REVIEW MODE LIFECYCLE ===

if [ "$MODE" = "review" ]; then
  case "$PHASE" in
    reviewing)
      # First fire after /claudex review. Run codex review on diff.
      mkdir -p reviews 2>/dev/null

      FOCUS="You are doing a code review of the current git diff (uncommitted changes plus the diff against the base branch if one is configured).

Run a thorough adversarial review. Find:
- Real bugs and design flaws
- Security issues (OWASP top ten, injection, validation gaps)
- Race conditions and concurrency problems
- Edge cases that fail silently
- Performance landmines (unbounded queries, N+1, etc.)

For each material finding:
- Severity: high, medium, or low
- File path and line numbers if known
- Description of what could go wrong
- Specific recommendation, ideally with a unified-diff style fix

Skip style nits. Material findings only.

Output as a markdown document. Save the findings to reviews/review-$REVIEW_ID.md and proposed fixes (unified diff format) to reviews/proposed-fixes-$REVIEW_ID.md."

      write_runner_script "review" "$FOCUS"

      claudex_phase_transition "$ACTIVE_STATE" "reviewing" "done"

      MSG="Claudex review starting.

Run the runner script:
  bash $RUNNER

Codex will write findings to reviews/review-$REVIEW_ID.md and proposed fixes to reviews/proposed-fixes-$REVIEW_ID.md.

Note: claudex v1 is READ-ONLY. It will NOT auto-apply patches. Review the findings yourself, then apply fixes manually.

After Codex finishes, end your turn. The hook will allow exit."

      block "$MSG"
      ;;

    done)
      rm -f "$RUNNER" "$STATE_DIR/$REVIEW_ID-prompt.txt" "$STATE_DIR/$REVIEW_ID.lock" 2>/dev/null
      approve "review loop done"
      ;;

    *)
      log "Unknown review phase: $PHASE"
      approve "unknown review phase"
      ;;
  esac
fi

# Unknown mode.
log "Unknown mode: $MODE"
approve "unknown mode, fail-open"
