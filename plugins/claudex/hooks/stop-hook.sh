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
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/personas.sh" 2>/dev/null || approve "personas missing"

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
STARTED_AT_EPOCH=$(claudex_state_read_field "$ACTIVE_STATE" "started_at_epoch")

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
REVIEW_DIR="$STATE_DIR/$REVIEW_ID"
mkdir -p "$REVIEW_DIR" 2>/dev/null

# Format elapsed seconds for human-readable summary lines.
# Empty input prints empty string so callers can guard easily.
format_elapsed() {
  local started="$1"
  [ -n "$started" ] || return 0
  case "$started" in ''|*[!0-9]*) return 0 ;; esac
  local now=$(date -u +%s)
  local delta=$((now - started))
  if [ "$delta" -lt 60 ]; then
    printf '%ds' "$delta"
  elif [ "$delta" -lt 3600 ]; then
    printf '%dm %ds' $((delta / 60)) $((delta % 60))
  else
    printf '%dh %dm' $((delta / 3600)) $(((delta % 3600) / 60))
  fi
}

# Build the per-round findings table for the final summary BLOCK.
# Iterates 1..final_round, reads each findings file, counts severities,
# pairs with the persona label. Empty if no rounds completed.
build_rounds_table() {
  local final_round="$1"
  local i
  local table=""
  for i in $(seq 1 "$final_round"); do
    local ff="$REVIEW_DIR/findings-round-$i.md"
    local label
    label=$(claudex_persona_label_for_round "$i")
    local counts
    if [ -f "$ff" ]; then
      counts=$(claudex_findings_severity_counts "$ff")
    else
      counts="no findings file"
    fi
    table="${table}- Round $i ($label): $counts"$'\n'
  done
  printf '%s' "$table"
}

# write_runner_script <mode> <focus> <round>
# The third arg is the round number to print in headers and use in the
# findings file path. Pass it explicitly so the caller controls parity
# between the hook BLOCK message and the runner output.
write_runner_script() {
  local mode="$1"
  local focus="$2"
  local round_num="$3"

  # Plan mode rotates personas per round. Review mode is single-shot, so we
  # use only the round-1 senior-engineer stanza to keep the prompt stable.
  local persona=""
  local persona_label=""
  if [ "$mode" = "plan" ]; then
    persona=$(claudex_persona_for_round "$round_num")
    persona_label=$(claudex_persona_label_for_round "$round_num")
  else
    persona=$(claudex_persona_for_round 1)
    persona_label=$(claudex_persona_label_for_round 1)
  fi

  local full_focus="$persona

$focus"

  cat > "$RUNNER" <<RUNNEREOF
#!/usr/bin/env bash
# Claudex runner script for $REVIEW_ID, mode=$mode, round=$round_num
# Persona: $persona_label
# Runs Codex against the current state. Output streams to user's terminal.

set +e

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex CLI not found in PATH. Install with: npm install -g @openai/codex" >&2
  exit 1
fi

PROMPT_FILE="$STATE_DIR/$REVIEW_ID-prompt.txt"

cat > "\$PROMPT_FILE" <<'PROMPTEOF'
$full_focus
PROMPTEOF

echo "[claudex] Running Codex (mode=$mode, round=$round_num, persona: $persona_label)..."
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

      FINDINGS_FILE="$REVIEW_DIR/findings-round-$ROUND.md"

      FOCUS="You are doing an adversarial review of a plan document at PLAN.md in the current working directory.

Topic: $TOPIC

Round: $ROUND of $MAX_ROUNDS

Pressure-test this plan. Find real failure modes, design flaws, and edge cases that would break under stress. Be specific.

For each material finding:
- Severity: high, medium, or low
- One-sentence description of what could go wrong
- Specific recommendation

If you find no material concerns (only style nits), say exactly: 'No substantive findings.'

Read PLAN.md, then review.

CRITICAL OUTPUT REQUIREMENT: After your full analysis, write a clean summary of just the findings (severity + one-line description + recommendation) to the file:

  $FINDINGS_FILE

Use this exact format:

# Round $ROUND findings

## High
- <one-line description> (<recommendation>)
- ...

## Medium
- ...

## Low
- ...

If no material findings, the file should contain exactly:

# Round $ROUND findings

No substantive findings.

Write that file before exiting. The next reviewer reads only that file, not your full transcript."

      write_runner_script "plan" "$FOCUS" "$ROUND"

      PERSONA_LABEL=$(claudex_persona_label_for_round "$ROUND")

      MSG="### Claudex round $ROUND of $MAX_ROUNDS, $PERSONA_LABEL

**Run the runner:**

\`\`\`
bash $RUNNER
\`\`\`

When Codex finishes, read the clean findings summary from:

\`$FINDINGS_FILE\`

(That file is a short bullet list. Skip the full transcript unless you need extra context.)

**Then decide:**

- **Material findings exist** → revise PLAN.md to address them. Append (or update) a '## Changelog' section at the bottom of PLAN.md noting what you took and what you rejected with reasoning. Then end your turn.
- **No material findings (or only style nits)** → mark the loop done:
  \`\`\`
  bash \${CLAUDE_PLUGIN_ROOT}/scripts/mark-done.sh $REVIEW_ID
  \`\`\`
  Then end your turn.

**Hard stop:** if this is round $MAX_ROUNDS and Codex still has substantive findings, end your turn anyway. The hook will detect max-rounds-reached and exit cleanly with a summary of what's left."

      block "$MSG"
      ;;

    reviewing)
      # Claude has run review and either revised PLAN.md or marked done.
      if [ "$DECISION_SIGNAL" = "no-material-findings" ]; then
        # Loop complete. Transition to summarizing and BLOCK with the final
        # summary so the user actually sees the loop landed.
        if ! claudex_phase_transition "$ACTIVE_STATE" "reviewing" "summarizing"; then
          log "CAS reviewing->summarizing failed (already done?)"
          approve "CAS failed"
        fi
        ELAPSED=$(format_elapsed "$STARTED_AT_EPOCH")
        [ -z "$ELAPSED" ] && ELAPSED="unknown"
        ROUNDS_TABLE=$(build_rounds_table "$ROUND")

        SUMMARY="### Claudex plan loop complete ✓

The plan at \`PLAN.md\` is locked. Codex had no substantive findings on the final round.

**Rounds run:** $ROUND of $MAX_ROUNDS
**Total time:** $ELAPSED

**Findings by round:**

$ROUNDS_TABLE

**Print this summary to the user so they see the loop landed.** Then end your turn. The Stop hook will allow exit cleanly."
        log "Plan loop $REVIEW_ID complete after $ROUND round(s) in $ELAPSED"
        block "$SUMMARY"
      fi

      # No done signal. Claude must have revised. Increment round.
      NEW_ROUND=$((ROUND + 1))
      claudex_state_set_field "$ACTIVE_STATE" "round" "$NEW_ROUND"

      if [ "$NEW_ROUND" -gt "$MAX_ROUNDS" ]; then
        # Max rounds hit. Transition to summarizing and BLOCK with a
        # summary that points the user at the final round's findings.
        claudex_state_set_field "$ACTIVE_STATE" "decision_signal" "max-reached"
        claudex_state_set_field "$ACTIVE_STATE" "phase" "summarizing"
        ELAPSED=$(format_elapsed "$STARTED_AT_EPOCH")
        [ -z "$ELAPSED" ] && ELAPSED="unknown"
        ROUNDS_TABLE=$(build_rounds_table "$ROUND")
        FINAL_FINDINGS="$REVIEW_DIR/findings-round-$ROUND.md"

        SUMMARY="### Claudex plan loop stopped at max rounds (round $ROUND of $MAX_ROUNDS)

The plan at \`PLAN.md\` was revised through every available round. The final round still had material findings.

**Total time:** $ELAPSED

**Findings by round:**

$ROUNDS_TABLE

The user should look at the last round's findings file:

\`$FINAL_FINDINGS\`

Then decide:

- Apply more revisions manually, or
- Re-run with a higher round budget (e.g. \`/claudex:plan --rounds 5 ...\`), or
- Accept the current plan as a known-incomplete artifact and document the open concerns.

**Print this summary to the user.** Then end your turn. The Stop hook will allow exit cleanly."
        log "Plan loop $REVIEW_ID stopped at max rounds after $ELAPSED"
        block "$SUMMARY"
      fi

      # Run another round. Promote local ROUND to NEW_ROUND so the runner
      # script header, the findings filename, and the BLOCK message all
      # agree on the round number.
      ROUND="$NEW_ROUND"
      FINDINGS_FILE="$REVIEW_DIR/findings-round-$ROUND.md"
      PREV_FINDINGS_FILE="$REVIEW_DIR/findings-round-$((ROUND - 1)).md"

      PREV_REF=""
      if [ -f "$PREV_FINDINGS_FILE" ]; then
        PREV_REF="

The previous round's findings are at $PREV_FINDINGS_FILE. PLAN.md should already address them; flag any that were dismissed without good reason. Focus your fresh attention on what is still wrong, what got introduced by the revisions, and what still has not been considered."
      fi

      FOCUS="You are doing an adversarial review of a plan document at PLAN.md in the current working directory.

Topic: $TOPIC

Round: $ROUND of $MAX_ROUNDS$PREV_REF

Pressure-test this plan. Find real failure modes, design flaws, and edge cases that would break under stress. Be specific.

For each material finding:
- Severity: high, medium, or low
- One-sentence description of what could go wrong
- Specific recommendation

If you find no material concerns (only style nits), say exactly: 'No substantive findings.'

Read PLAN.md, then review.

CRITICAL OUTPUT REQUIREMENT: After your full analysis, write a clean summary of just the findings (severity + one-line description + recommendation) to the file:

  $FINDINGS_FILE

Use this exact format:

# Round $ROUND findings

## High
- <one-line description> (<recommendation>)
- ...

## Medium
- ...

## Low
- ...

If no material findings, the file should contain exactly:

# Round $ROUND findings

No substantive findings.

Write that file before exiting."

      write_runner_script "plan" "$FOCUS" "$ROUND"

      PERSONA_LABEL=$(claudex_persona_label_for_round "$ROUND")

      # Severity tally from the previous round so Claude (and the viewer)
      # see the trajectory. Helper prints "high=N medium=N low=N" or zeroes.
      PREV_TALLY=""
      if [ -f "$PREV_FINDINGS_FILE" ]; then
        PREV_TALLY=$(claudex_findings_severity_counts "$PREV_FINDINGS_FILE")
      fi

      TRAJECTORY_LINE=""
      if [ -n "$PREV_TALLY" ]; then
        TRAJECTORY_LINE="**Previous round:** $PREV_TALLY

"
      fi

      MSG="### Claudex round $ROUND of $MAX_ROUNDS, $PERSONA_LABEL

${TRAJECTORY_LINE}**Run the runner:**

\`\`\`
bash $RUNNER
\`\`\`

Findings summary will be written to:

\`$FINDINGS_FILE\`

**Then decide:**

- **Material findings** → revise PLAN.md (update the Changelog) and end your turn. Round will auto-increment.
- **No material findings** → mark done:
  \`\`\`
  bash \${CLAUDE_PLUGIN_ROOT}/scripts/mark-done.sh $REVIEW_ID
  \`\`\`
  Then end your turn."

      block "$MSG"
      ;;

    summarizing)
      # Summary BLOCK was delivered on the previous fire and Claude has
      # printed it to the user. Final cleanup and approve.
      claudex_phase_transition "$ACTIVE_STATE" "summarizing" "done" 2>/dev/null
      rm -f "$RUNNER" "$STATE_DIR/$REVIEW_ID-prompt.txt" "$STATE_DIR/$REVIEW_ID.lock" 2>/dev/null
      ELAPSED=$(format_elapsed "$STARTED_AT_EPOCH")
      if [ -n "$ELAPSED" ]; then
        log "Plan loop $REVIEW_ID summary delivered; total elapsed $ELAPSED"
      fi
      approve "summary delivered"
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
      # First fire after /claudex:review. Run codex review on diff.
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

      write_runner_script "review" "$FOCUS" "1"

      claudex_phase_transition "$ACTIVE_STATE" "reviewing" "done"

      MSG="### Claudex review starting

**Run the runner:**

\`\`\`
bash $RUNNER
\`\`\`

Codex will write:
- Findings → \`reviews/review-$REVIEW_ID.md\`
- Proposed fixes → \`reviews/proposed-fixes-$REVIEW_ID.md\`

**Note:** claudex v1 review mode is READ-ONLY. It will NOT auto-apply patches. Review the findings yourself, then apply fixes manually.

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
