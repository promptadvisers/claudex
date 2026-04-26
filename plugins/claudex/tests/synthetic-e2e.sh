#!/usr/bin/env bash
# Synthetic end-to-end test with REAL Codex calls.
#
# This is more expensive than smoke-test.sh because it actually invokes the
# Codex CLI through the runner scripts. Use it to confirm the entire pipeline
# works against a live Codex install before shipping.
#
# What it does:
#   1. Spins up a throwaway project at /tmp/claudex_synthetic with its own .git
#   2. Runs start-loop.sh plan with a real topic
#   3. Writes a realistic PLAN.md
#   4. Invokes the Stop hook directly (simulates Claude finishing a turn)
#   5. Executes the generated runner script (real Codex call)
#   6. Reads Codex output, decides material/not material
#   7. Either revises PLAN.md and loops, or calls mark-done
#   8. Verifies final state
#
# Cost: 1-3 Codex review calls. Depends on how many rounds the loop runs.
#
# Usage:
#   bash tests/synthetic-e2e.sh

set +e

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOOK="$PLUGIN_ROOT/hooks/stop-hook.sh"
START="$PLUGIN_ROOT/scripts/start-loop.sh"
MARK_DONE="$PLUGIN_ROOT/scripts/mark-done.sh"

SYNTH_DIR="/tmp/claudex_synthetic"
TOPIC="add expiry dates to short links so they auto-die after a configured time"

# Track results.
pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
    pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    fail=$((fail+1))
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

printf '\033[1m=== Claudex Synthetic E2E (with real Codex) ===\033[0m\n'

# Pre-flight: codex CLI must be available.
if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI not found in PATH. Install with: npm install -g @openai/codex"
  exit 2
fi
echo "codex CLI found: $(command -v codex) ($(codex --version 2>/dev/null | head -1))"

# Set up synthetic project.
section "Setup"
rm -rf "$SYNTH_DIR"
mkdir -p "$SYNTH_DIR"
cd "$SYNTH_DIR" || exit 1
git init -q
git commit --allow-empty -q -m "baseline"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
echo "Synthetic project at: $SYNTH_DIR"
echo "Plugin root:          $PLUGIN_ROOT"

# Round 0 — initialize loop.
section "Round 0: start-loop"
START_OUTPUT=$(bash "$START" plan "$TOPIC" 2>&1)
echo "$START_OUTPUT" | head -8
check "start-loop produced output" test -n "$START_OUTPUT"
check "state file created" bash -c "ls .claude/claudex/*.state >/dev/null"
REVIEW_ID=$(ls .claude/claudex/*.state 2>/dev/null | head -1 | xargs basename | sed 's/.state$//')
echo "Review ID: $REVIEW_ID"
check "review_id format valid" bash -c "[[ '$REVIEW_ID' =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]]"

# Write a realistic PLAN.md with at least one obvious gap so Codex has material to find.
section "Round 1: write initial PLAN.md (with deliberate gaps)"
cat > PLAN.md <<'EOF'
# Plan: Link Expiry

## Scope

Add an expiry date field to short links so they auto-die after a user-set time.

## Steps

1. Add an `expires_at` column to the `links` table.
2. When a user creates a short link, accept an optional expiry date in the form input.
3. When a short link is clicked, check if `expires_at` is in the past. If so, redirect to a 410 Gone page.
4. Add a daily cron job that hard-deletes expired links.
EOF
echo "PLAN.md written ($(wc -l < PLAN.md) lines)."
check "PLAN.md exists" test -f PLAN.md

# Fire hook for round 1 — should BLOCK with runner script.
section "Round 1: fire hook (drafting -> reviewing)"
HOOK_OUT=$(echo '{}' | bash "$HOOK" 2>/dev/null)
echo "Hook output: $(printf '%s' "$HOOK_OUT" | head -c 80)..."
check "hook returned block" bash -c "echo '$HOOK_OUT' | grep -q block"
RUNNER=".claude/claudex/$REVIEW_ID-runner.sh"
check "runner script created" test -f "$RUNNER"
check "runner has quoted PROMPTEOF (P1 fix)" grep -q "<<'PROMPTEOF'" "$RUNNER"

# Execute the runner script for real.
section "Round 1: execute runner (real Codex call)"
echo "Calling Codex... this may take 30-90 seconds."
CODEX_OUTPUT=$(bash "$RUNNER" 2>&1)
RUNNER_RC=$?
echo "Runner exit code: $RUNNER_RC"
echo "$CODEX_OUTPUT" | tail -30 | head -20
check "runner exited with code 0" test "$RUNNER_RC" = "0"
check "Codex output is non-empty" test -n "$CODEX_OUTPUT"
check "Codex did not hit stdin terminal error" bash -c "! echo '$CODEX_OUTPUT' | grep -q 'stdin is not a terminal'"
check "Codex did not hit auth error" bash -c "! echo '$CODEX_OUTPUT' | grep -qi 'not logged in\\|auth.*fail'"
check "Codex output mentions plan/review topic" bash -c "echo '$CODEX_OUTPUT' | grep -qiE 'plan|review|expir|finding'"

# Round 1 done. Now simulate Claude deciding the loop is complete and calling mark-done.
# (We don't try to parse Codex output to decide -- that's Claude's job in production.
#  The point here is to verify the lifecycle ends cleanly when mark-done is called.)
section "Mark loop done (Claude's signal in production)"
bash "$MARK_DONE" "$REVIEW_ID" >/dev/null
PHASE=$(grep '^phase:' ".claude/claudex/$REVIEW_ID.state" | sed 's/^phase: //')
SIGNAL=$(grep '^decision_signal:' ".claude/claudex/$REVIEW_ID.state" | sed 's/^decision_signal: //')
check "phase marked done" test "$PHASE" = "done"
check "signal set to no-material-findings" test "$SIGNAL" = "no-material-findings"

# Final hook fire — should ALLOW.
section "Final hook fire"
HOOK_OUT=$(echo '{}' | bash "$HOOK" 2>/dev/null)
echo "Final hook output: $HOOK_OUT"
check "final hook returned approve" bash -c "echo '$HOOK_OUT' | grep -q approve"
check "lockfile cleaned up" bash -c "! test -f .claude/claudex/$REVIEW_ID.lock"
check "state file preserved for audit" test -f ".claude/claudex/$REVIEW_ID.state"
check "runner script cleaned up" bash -c "! test -f $RUNNER"

# Verify back-to-back: another /claudex should accept.
section "Back-to-back check (P2 fix in real conditions)"
NEXT_OUTPUT=$(bash "$START" plan "another small feature" 2>&1)
check "second loop accepted after first complete" bash -c "echo '$NEXT_OUTPUT' | grep -qi 'plan mode initialized'"

# Cleanup.
section "Cleanup"
rm -rf "$SYNTH_DIR"
echo "Synthetic project removed."

# Summary.
printf '\n\033[1m=== Synthetic E2E Results ===\033[0m\n'
printf '  \033[32m%d passed\033[0m\n' "$pass"
if [ $fail -gt 0 ]; then
  printf '  \033[31m%d failed\033[0m\n' "$fail"
  exit 1
fi
printf '\n  Synthetic E2E passed. Real Codex pipeline works end-to-end.\n'
exit 0
