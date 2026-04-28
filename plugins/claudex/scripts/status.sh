#!/usr/bin/env bash
# status.sh - print a compact summary of the most recent claudex loop.
#
# Reads the most recent state file (active OR last-completed) and prints:
#   mode, phase, round/max_rounds, topic, started_at, elapsed, decision_signal,
#   lock-file PID + alive check, runner-script presence, per-round findings
#   files with severity tallies.
#
# Always exits 0; fails open on any unexpected error so the user is never blocked.

set +e

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh" 2>/dev/null || {
  echo "claudex: state-helpers missing; cannot read status."
  exit 0
}

# No ERR trap: helper functions legitimately return non-zero (e.g. no loops on
# disk) and we don't want those benign returns to print scary messages. set +e
# above already prevents the script from aborting on a failed command.

# Color helpers (degrade gracefully if not a tty).
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m';   C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

ACTIVE=$(claudex_find_active_loop 2>/dev/null)
if [ -z "$ACTIVE" ] || [ ! -f "$ACTIVE" ]; then
  echo "${C_DIM}No claudex loops in $CLAUDEX_STATE_DIR.${C_RESET}"
  exit 0
fi

REVIEW_ID=$(basename "$ACTIVE" .state)

MODE=$(claudex_state_read_field        "$ACTIVE" "mode")
PHASE=$(claudex_state_read_field       "$ACTIVE" "phase")
ROUND=$(claudex_state_read_field       "$ACTIVE" "round")
MAX_ROUNDS=$(claudex_state_read_field  "$ACTIVE" "max_rounds")
TOPIC=$(claudex_state_read_field       "$ACTIVE" "topic")
DECISION=$(claudex_state_read_field    "$ACTIVE" "decision_signal")
STARTED=$(claudex_state_read_field     "$ACTIVE" "started_at")
STARTED_EPOCH=$(claudex_state_read_field "$ACTIVE" "started_at_epoch")
INTERVIEW=$(claudex_state_read_field   "$ACTIVE" "interview_used")
FROM_DRAFT=$(claudex_state_read_field  "$ACTIVE" "from_draft")

# Phase color.
case "$PHASE" in
  drafting|reviewing) PHASE_COLOR="$C_YELLOW" ;;
  done)               PHASE_COLOR="$C_GREEN"  ;;
  cancelled|errored)  PHASE_COLOR="$C_RED"    ;;
  *)                  PHASE_COLOR="$C_DIM"    ;;
esac

# Elapsed.
ELAPSED="-"
if [ -n "$STARTED_EPOCH" ]; then
  case "$STARTED_EPOCH" in
    ''|*[!0-9]*) : ;;
    *)
      now=$(date -u +%s)
      delta=$((now - STARTED_EPOCH))
      if   [ "$delta" -lt 60 ];   then ELAPSED="${delta}s"
      elif [ "$delta" -lt 3600 ]; then ELAPSED="$((delta / 60))m $((delta % 60))s"
      else                              ELAPSED="$((delta / 3600))h $(((delta % 3600) / 60))m"
      fi
      ;;
  esac
fi

# Activity inferred from phase. The lock file's PID belongs to the start-loop
# script that has long since exited, so a lock-PID-alive check is never useful
# in claudex's between-turns architecture. Phase is the real liveness signal.
case "$PHASE" in
  drafting|reviewing) ACTIVITY_LINE="${C_GREEN}active${C_RESET} (loop in progress between turns)" ;;
  done)               ACTIVITY_LINE="${C_DIM}complete${C_RESET}" ;;
  cancelled)          ACTIVITY_LINE="${C_RED}cancelled${C_RESET}" ;;
  errored)            ACTIVITY_LINE="${C_RED}errored${C_RESET}" ;;
  *)                  ACTIVITY_LINE="${C_DIM}unknown${C_RESET}" ;;
esac

# Runner script.
RUNNER_FILE="$CLAUDEX_STATE_DIR/$REVIEW_ID-runner.sh"
RUNNER_LINE="${C_DIM}none${C_RESET}"
[ -f "$RUNNER_FILE" ] && RUNNER_LINE="${C_GREEN}present${C_RESET}"

# Header.
printf '%s%s claudex %s%s\n' "$C_BOLD" "─────" "─────" "$C_RESET"
printf '  %-13s %s\n' "review_id"  "$REVIEW_ID"
printf '  %-13s %s\n' "mode"       "$MODE"
printf '  %-13s %s%s%s\n' "phase"  "$PHASE_COLOR" "$PHASE" "$C_RESET"
if [ -n "$ROUND" ] && [ -n "$MAX_ROUNDS" ]; then
  printf '  %-13s %s of %s\n' "round" "$ROUND" "$MAX_ROUNDS"
fi
[ -n "$TOPIC" ]      && printf '  %-13s %s\n' "topic"      "$TOPIC"
[ -n "$STARTED" ]    && printf '  %-13s %s\n' "started_at" "$STARTED"
printf '  %-13s %s\n' "elapsed"    "$ELAPSED"
[ -n "$DECISION" ]   && printf '  %-13s %s\n' "decision"   "$DECISION"
[ -n "$INTERVIEW" ]  && printf '  %-13s %s\n' "interview"  "$INTERVIEW"
[ -n "$FROM_DRAFT" ] && printf '  %-13s %s\n' "from_draft" "$FROM_DRAFT"
printf '  %-13s %b\n' "activity"   "$ACTIVITY_LINE"
printf '  %-13s %b\n' "runner"     "$RUNNER_LINE"

# Per-round findings tally.
FINDINGS_DIR="$CLAUDEX_STATE_DIR/$REVIEW_ID"
if [ -d "$FINDINGS_DIR" ]; then
  shopt -s nullglob 2>/dev/null
  FOUND=0
  for f in "$FINDINGS_DIR"/findings-round-*.md; do
    [ -f "$f" ] || continue
    if [ "$FOUND" -eq 0 ]; then
      printf '\n%sFindings by round:%s\n' "$C_BOLD" "$C_RESET"
      FOUND=1
    fi
    rnum=$(basename "$f" .md | sed 's/^findings-round-//')
    counts=$(claudex_findings_severity_counts "$f")
    printf '  round %-2s  %s\n' "$rnum" "$counts"
  done
fi

exit 0
