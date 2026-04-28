#!/usr/bin/env bash
# doctor.sh - claudex preflight diagnostic.
#
# Verifies that everything claudex needs is wired up correctly:
#   - bash version
#   - python3 (for JSON escape; sed fallback exists but python3 is preferred)
#   - codex CLI installed and responding
#   - .claude/claudex writable
#   - plugin file integrity (every expected script + prompt template present)
#   - hook fail-open sanity check
#   - stale loops report (informational, not fatal)
#
# Exits 0 if every required check passes, 1 if any required check fails.
# Optional checks (e.g. python3) only print warnings.

set +e

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=/dev/null
source "$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh" 2>/dev/null

# No ERR trap: the check/warn_check helpers consume exit codes via `if`,
# and helper functions like claudex_find_active_loop return non-zero on
# benign "nothing to find" paths. set +e above keeps the script running.

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

pass=0
fail=0
warn=0
fail_msgs=()

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$name"
    pass=$((pass+1))
  else
    printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$name"
    fail=$((fail+1))
    fail_msgs+=("$name")
  fi
}

warn_check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$name"
    pass=$((pass+1))
  else
    printf '  %s!%s %s%s%s\n' "$C_YELLOW" "$C_RESET" "$C_DIM" "$name (optional)" "$C_RESET"
    warn=$((warn+1))
  fi
}

section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

printf '%s=== claudex doctor ===%s\n' "$C_BOLD" "$C_RESET"
printf 'Plugin root: %s\n' "$CLAUDE_PLUGIN_ROOT"

section "Shell"
check "bash present" command -v bash
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
warn_check "bash 4+ (got $BASH_VERSION; bash 3.x works but 4+ recommended)" \
  test "$BASH_MAJOR" -ge 4

section "Codex CLI"
check "codex in PATH" command -v codex
if command -v codex >/dev/null 2>&1; then
  CODEX_VER=$(codex --version 2>/dev/null | head -1)
  if [ -n "$CODEX_VER" ]; then
    printf '  %s•%s codex version: %s\n' "$C_DIM" "$C_RESET" "$CODEX_VER"
  fi
fi

section "Optional dependencies"
warn_check "python3 (used for JSON escape; sed fallback works)" command -v python3

section "State directory"
mkdir -p "$CLAUDEX_STATE_DIR" 2>/dev/null
check "$CLAUDEX_STATE_DIR exists" test -d "$CLAUDEX_STATE_DIR"
check "$CLAUDEX_STATE_DIR writable" test -w "$CLAUDEX_STATE_DIR"

section "Plugin files"
PLUGIN_FILES=(
  "hooks/stop-hook.sh"
  "hooks/hooks.json"
  "scripts/state-helpers.sh"
  "scripts/personas.sh"
  "scripts/start-loop.sh"
  "scripts/cancel-loop.sh"
  "scripts/rollback-loop.sh"
  "scripts/mark-done.sh"
  "scripts/status.sh"
  "scripts/doctor.sh"
  "scripts/prompts/plan-mode-init.md"
  "scripts/prompts/plan-mode-from-draft.md"
  "scripts/prompts/plan-mode-review.md"
  "scripts/prompts/review-mode-init.md"
  "scripts/prompts/review-mode-findings.md"
)
missing_files=()
for f in "${PLUGIN_FILES[@]}"; do
  [ -f "$CLAUDE_PLUGIN_ROOT/$f" ] || missing_files+=("$f")
done
if [ ${#missing_files[@]} -eq 0 ]; then
  printf '  %s✓%s all %d plugin files present\n' "$C_GREEN" "$C_RESET" "${#PLUGIN_FILES[@]}"
  pass=$((pass+1))
else
  printf '  %s✗%s %d of %d plugin files missing:\n' "$C_RED" "$C_RESET" "${#missing_files[@]}" "${#PLUGIN_FILES[@]}"
  for f in "${missing_files[@]}"; do
    printf '      - %s\n' "$f"
  done
  fail=$((fail+1))
  fail_msgs+=("plugin files missing")
fi

section "Hook fail-open sanity"
HOOK="$CLAUDE_PLUGIN_ROOT/hooks/stop-hook.sh"
check "hook is executable" test -x "$HOOK"
TMP=$(mktemp -d 2>/dev/null)
if [ -n "$TMP" ] && [ -d "$TMP" ]; then
  output=$(cd "$TMP" && echo '{}' | bash "$HOOK" 2>/dev/null)
  check "hook returns approve on empty state" \
    bash -c "echo '$output' | grep -q 'approve'"
  rm -rf "$TMP"
fi

section "Helpers smoke"
check "state-helpers source cleanly" \
  bash -c "source '$CLAUDE_PLUGIN_ROOT/scripts/state-helpers.sh'"
check "personas source cleanly" \
  bash -c "source '$CLAUDE_PLUGIN_ROOT/scripts/personas.sh'"
if source "$CLAUDE_PLUGIN_ROOT/scripts/personas.sh" 2>/dev/null; then
  R1=$(claudex_persona_for_round 1)
  R2=$(claudex_persona_for_round 2)
  R3=$(claudex_persona_for_round 3)
  check "round 1 persona non-empty"  test -n "$R1"
  check "round 2 persona non-empty"  test -n "$R2"
  check "round 3 persona non-empty"  test -n "$R3"
  check "round 1 differs from round 2" test "$R1" != "$R2"
  check "round 2 differs from round 3" test "$R2" != "$R3"
fi

section "Loop hygiene"
ACTIVE=$(claudex_find_active_loop 2>/dev/null)
if [ -z "$ACTIVE" ]; then
  printf '  %s•%s no loops on disk\n' "$C_DIM" "$C_RESET"
else
  ACTIVE_ID=$(basename "$ACTIVE" .state)
  ACTIVE_PHASE=$(claudex_state_read_field "$ACTIVE" "phase")
  printf '  %s•%s most recent loop: %s (%s)\n' "$C_DIM" "$C_RESET" "$ACTIVE_ID" "$ACTIVE_PHASE"
fi

# Summary.
printf '\n%s=== Results ===%s\n' "$C_BOLD" "$C_RESET"
printf '  %s%d passed%s' "$C_GREEN" "$pass" "$C_RESET"
[ "$warn" -gt 0 ] && printf '  %s%d warnings%s' "$C_YELLOW" "$warn" "$C_RESET"
[ "$fail" -gt 0 ] && printf '  %s%d failed%s' "$C_RED" "$fail" "$C_RESET"
printf '\n'

if [ "$fail" -gt 0 ]; then
  printf '\nFailed checks:\n'
  for m in "${fail_msgs[@]}"; do
    printf '  - %s\n' "$m"
  done
  printf '\nFix the failures above before running claudex.\n'
  exit 1
fi

printf '\nclaudex looks healthy. You can run /claudex:plan or /claudex:review.\n'
exit 0
