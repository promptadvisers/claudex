#!/usr/bin/env bash
# rollback-loop.sh - force-clean all claudex state.

set +e

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh"

if [ ! -d "$CLAUDEX_STATE_DIR" ]; then
  echo "No claudex state directory. Nothing to roll back."
  exit 0
fi

count=0
for f in "$CLAUDEX_STATE_DIR"/*.state "$CLAUDEX_STATE_DIR"/*.lock "$CLAUDEX_STATE_DIR"/*-runner.sh "$CLAUDEX_STATE_DIR"/*-prompt.txt; do
  if [ -f "$f" ]; then
    rm -f "$f"
    count=$((count+1))
  fi
done

echo "Rolled back. Removed $count file(s) from $CLAUDEX_STATE_DIR."
echo "(Log file preserved.)"
exit 0
