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

# Parse optional flags before the topic. Recognized flags:
#   --rounds N         override default max rounds (positive integer)
#   --from-draft       use existing PLAN.md instead of drafting from scratch (plan mode only)
FROM_DRAFT=false
CUSTOM_ROUNDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds)
      shift
      CUSTOM_ROUNDS="$1"
      shift || true
      ;;
    --rounds=*)
      CUSTOM_ROUNDS="${1#--rounds=}"
      shift
      ;;
    --from-draft)
      FROM_DRAFT=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

TOPIC="$*"

if [ -z "$MODE" ]; then
  echo "Usage: start-loop.sh plan [--rounds N] [--from-draft] <topic> | start-loop.sh review [--rounds N]" >&2
  exit 2
fi

# Validate --rounds.
if [ -n "$CUSTOM_ROUNDS" ]; then
  if ! echo "$CUSTOM_ROUNDS" | grep -qE '^[1-9][0-9]*$'; then
    echo "--rounds must be a positive integer (got: $CUSTOM_ROUNDS)" >&2
    exit 2
  fi
fi

# Validate --from-draft (plan mode only, requires PLAN.md to exist).
if [ "$FROM_DRAFT" = "true" ]; then
  if [ "$MODE" != "plan" ]; then
    echo "--from-draft only applies to plan mode, not $MODE" >&2
    exit 2
  fi
  if [ ! -f "PLAN.md" ] || [ ! -s "PLAN.md" ]; then
    echo "--from-draft requires PLAN.md to exist in the project root and be non-empty." >&2
    echo "Either remove --from-draft (let Claude draft from scratch) or create PLAN.md first." >&2
    exit 2
  fi
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
MAX_PLAN_ROUNDS="${CLAUDEX_MAX_PLAN_ROUNDS:-3}"
MAX_REVIEW_ROUNDS="${CLAUDEX_MAX_REVIEW_ROUNDS:-3}"

if [ "$MODE" = "plan" ]; then
  MAX_ROUNDS="$MAX_PLAN_ROUNDS"
  PHASE="drafting"
else
  MAX_ROUNDS="$MAX_REVIEW_ROUNDS"
  PHASE="reviewing"
fi

# --rounds flag overrides default max.
if [ -n "$CUSTOM_ROUNDS" ]; then
  MAX_ROUNDS="$CUSTOM_ROUNDS"
fi

# Escape topic for YAML (basic; topic is user-provided).
ESCAPED_TOPIC="$(printf '%s' "$TOPIC" | sed 's/"/\\"/g')"

STATE_CONTENT="mode: $MODE
phase: $PHASE
topic: \"$ESCAPED_TOPIC\"
round: 1
max_rounds: $MAX_ROUNDS
from_draft: $FROM_DRAFT
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
    if [ "$FROM_DRAFT" = "true" ]; then
      echo "Source: existing PLAN.md (--from-draft)"
      echo ""
      cat "$CLAUDE_PLUGIN_ROOT/scripts/prompts/plan-mode-from-draft.md" 2>/dev/null \
        | sed -e "s|{{TOPIC}}|$TOPIC|g" -e "s|{{REVIEW_ID}}|$REVIEW_ID|g" -e "s|{{MAX_ROUNDS}}|$MAX_ROUNDS|g"
    else
      echo ""
      echo "Round 1 - drafting plan."
      echo ""
      cat "$CLAUDE_PLUGIN_ROOT/scripts/prompts/plan-mode-init.md" 2>/dev/null \
        | sed -e "s|{{TOPIC}}|$TOPIC|g" -e "s|{{REVIEW_ID}}|$REVIEW_ID|g"
    fi
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
