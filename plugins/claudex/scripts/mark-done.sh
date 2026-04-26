#!/usr/bin/env bash
# mark-done.sh - Claude calls this to signal the loop is complete.
#
# Usage: bash mark-done.sh <review_id>
#
# Sets phase=done in the state file. The Stop hook will see this on the next
# fire and ALLOW exit with the final summary.

set +e

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh"

REVIEW_ID="$1"

if [ -z "$REVIEW_ID" ]; then
  echo "Usage: mark-done.sh <review_id>" >&2
  exit 1
fi

if ! claudex_validate_review_id "$REVIEW_ID"; then
  echo "Invalid review_id format: $REVIEW_ID" >&2
  exit 1
fi

STATE_FILE="$CLAUDEX_STATE_DIR/$REVIEW_ID.state"

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file for $REVIEW_ID" >&2
  exit 1
fi

claudex_state_set_field "$STATE_FILE" "decision_signal" "no-material-findings" || exit 1
claudex_state_set_field "$STATE_FILE" "phase" "done" || exit 1
claudex_state_set_field "$STATE_FILE" "last_updated_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 1

echo "Loop $REVIEW_ID marked as done."
exit 0
