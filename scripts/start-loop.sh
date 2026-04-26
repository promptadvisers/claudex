#!/usr/bin/env bash
# Claudex start-loop.sh
#
# Called by the /claudex slash command. Sets up state for a fresh loop and
# prints initial instructions for Claude to read.
#
# Usage:
#   bash start-loop.sh plan "<topic>"
#   bash start-loop.sh review
#
# Exit codes:
#   0  ok, instructions printed to stdout
#   1  another loop is already active in this project
#   2  invalid mode argument
#   3  internal error (state write failed)

set +e

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh"

MODE="$1"
shift || true
TOPIC="$*"

if [ -z "$MODE" ]; then
  echo "Usage: start-loop.sh plan <topic> | start-loop.sh review" >&2
  exit 2
fi

case "$MODE" in
  plan)
    if [ -z "$TOPIC" ]; then
      echo "Plan mode requires a topic. Usage: start-loop.sh plan <topic>" >&2
      exit 2
    fi
    ;;
  review)
    ;;
  *)
    echo "Unknown mode: $MODE. Use plan or review." >&2
    exit 2
    ;;
esac

mkdir -p "$CLAUDEX_STATE_DIR" || exit 3

# Sweep stale loops first (anything older than 15 min by default).
claudex_sweep_stale

# Refuse to start if another loop is genuinely active.
# State files are kept on disk for audit even after a loop completes or is
# cancelled, so we check the phase to decide if a loop is still running.
# Active phases: drafting, reviewing, revising. Terminal: done, cancelled, errored.
for state in "$CLAUDEX_STATE_DIR"/*.state; do
  [ -f "$state" ] || continue
  state_phase=$(claudex_state_read_field "$state" "phase")
  case "$state_phase" in
    done|cancelled|errored|"")
      # Terminal phase or unparseable; not an active loop.
      ;;
    *)
      active_id=$(basename "$state" .state)
      echo "Another claudex loop is already active: $active_id (phase: $state_phase)" >&2
      echo "Run /claudex:cancel to abort it, or /claudex:rollback to force-clean." >&2
      exit 1
      ;;
  esac
done

# Generate review_id.
REVIEW_ID="$(claudex_new_review_id)"
if ! claudex_validate_review_id "$REVIEW_ID"; then
  echo "Failed to generate valid review_id." >&2
  exit 3
fi

STATE_FILE="$CLAUDEX_STATE_DIR/$REVIEW_ID.state"
LOCK_FILE="$CLAUDEX_STATE_DIR/$REVIEW_ID.lock"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPO_ROOT="$(pwd)"
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
MAX_PLAN_ROUNDS="${CLAUDEX_MAX_PLAN_ROUNDS:-5}"
MAX_REVIEW_ROUNDS="${CLAUDEX_MAX_REVIEW_ROUNDS:-3}"

if [ "$MODE" = "plan" ]; then
  MAX_ROUNDS="$MAX_PLAN_ROUNDS"
  PHASE="drafting"
else
  MAX_ROUNDS="$MAX_REVIEW_ROUNDS"
  PHASE="reviewing"
fi

# Escape topic for YAML (basic; topic is user-provided).
ESCAPED_TOPIC="$(printf '%s' "$TOPIC" | sed 's/"/\\"/g')"

STATE_CONTENT="mode: $MODE
phase: $PHASE
topic: \"$ESCAPED_TOPIC\"
round: 1
max_rounds: $MAX_ROUNDS
review_id: $REVIEW_ID
repo_root: $REPO_ROOT
session_id: $SESSION_ID
started_at: $NOW
last_updated_at: $NOW
decision_signal: none"

claudex_state_write "$STATE_FILE" "$STATE_CONTENT" || exit 3
claudex_lock_write "$LOCK_FILE" || exit 3

# Print initial instructions to stdout. Claude will read these.
case "$MODE" in
  plan)
    echo "Claudex plan mode initialized."
    echo "Review ID: $REVIEW_ID"
    echo "Topic: $TOPIC"
    echo "Max rounds: $MAX_ROUNDS"
    echo ""
    echo "Round 1 - drafting plan."
    echo ""
    cat "$CLAUDE_PLUGIN_ROOT/scripts/prompts/plan-mode-init.md" 2>/dev/null \
      | sed -e "s|{{TOPIC}}|$TOPIC|g" -e "s|{{REVIEW_ID}}|$REVIEW_ID|g"
    ;;
  review)
    echo "Claudex review mode initialized."
    echo "Review ID: $REVIEW_ID"
    echo "Max rounds: $MAX_ROUNDS"
    echo ""
    cat "$CLAUDE_PLUGIN_ROOT/scripts/prompts/review-mode-init.md" 2>/dev/null \
      | sed -e "s|{{REVIEW_ID}}|$REVIEW_ID|g"
    ;;
esac

exit 0
