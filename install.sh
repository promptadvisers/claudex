#!/usr/bin/env bash
# claudex install.sh
#
# Walks through every prerequisite you need to actually run /claudex inside
# Claude Code. Safe to re-run; it just re-checks each step.
#
#   1. Node.js 18+
#   2. Codex CLI (npm install -g @openai/codex)
#   3. Codex auth (codex login)
#   4. The official Codex plugin for Claude Code (recommended companion)
#   5. claudex itself (this plugin)
#   6. Run platform-validation tests
#
# Usage:
#   bash install.sh

set +e

PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

ok()    { printf '  %b✓%b %s\n' "$GREEN" "$RESET" "$1"; }
fail()  { printf '  %b✗%b %s\n' "$RED" "$RESET" "$1"; }
warn()  { printf '  %b!%b %s\n' "$YELLOW" "$RESET" "$1"; }
hdr()   { printf '\n%b%s%b\n' "$BOLD" "$1" "$RESET"; }
note()  { printf '    %s\n' "$1"; }

failures=0

# ─────────────────────────────────────────────
hdr "1. Node.js (>= 18.18)"
# ─────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  fail "Node.js not found"
  note "Install from https://nodejs.org/ or use a version manager like nvm."
  failures=$((failures+1))
else
  NODE_VER=$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)
  if [ -z "$NODE_VER" ] || [ "$NODE_VER" -lt 18 ]; then
    fail "Node.js $(node --version) too old; need 18.18 or later"
    failures=$((failures+1))
  else
    ok "Node.js $(node --version)"
  fi
fi

# ─────────────────────────────────────────────
hdr "2. Codex CLI"
# ─────────────────────────────────────────────
if ! command -v codex >/dev/null 2>&1; then
  warn "codex CLI not found"
  note "Installing @openai/codex via npm..."
  if npm install -g @openai/codex 2>&1 | tail -5; then
    if command -v codex >/dev/null 2>&1; then
      ok "codex CLI installed: $(codex --version 2>/dev/null | head -1)"
    else
      fail "npm install ran but codex still not on PATH"
      failures=$((failures+1))
    fi
  else
    fail "npm install -g @openai/codex failed"
    failures=$((failures+1))
  fi
else
  ok "codex CLI: $(codex --version 2>/dev/null | head -1)"
fi

# ─────────────────────────────────────────────
hdr "3. Codex authentication"
# ─────────────────────────────────────────────
# We can't reliably check auth without invoking a real codex command which
# costs tokens. Just print a hint.
if command -v codex >/dev/null 2>&1; then
  note "Run this if you see auth errors during a /claudex loop:"
  note "  codex login"
  note "(Opens a browser. Sign in with your ChatGPT account. ChatGPT Plus or higher required.)"
  ok "codex CLI is callable; auth not verified by this script"
fi

# ─────────────────────────────────────────────
hdr "4. Claude Code"
# ─────────────────────────────────────────────
if ! command -v claude >/dev/null 2>&1; then
  fail "claude (Claude Code CLI) not found"
  note "Install from https://docs.claude.com/en/docs/claude-code"
  failures=$((failures+1))
else
  ok "Claude Code: $(claude --version 2>/dev/null | head -1)"
fi

# ─────────────────────────────────────────────
hdr "5. Recommended companion: openai/codex-plugin-cc"
# ─────────────────────────────────────────────
note "The official Codex plugin for Claude Code adds /codex:review,"
note "/codex:adversarial-review, /codex:rescue, and /codex:setup."
note "It is recommended (not strictly required) alongside claudex."
note ""
note "To install it, open a Claude Code session and run:"
note ""
note "  /plugin marketplace add openai/codex-plugin-cc"
note "  /plugin install codex@openai-codex"
note "  /reload-plugins"
note "  /codex:setup"
note ""
note "claudex will work without it (we call codex CLI directly), but the"
note "official plugin is what most viewers of the Dynamic Duo video have."

# ─────────────────────────────────────────────
hdr "6. claudex plugin install"
# ─────────────────────────────────────────────
note "claudex itself isn't auto-installed by this script (yet)."
note "Inside a Claude Code session, choose ONE of these:"
note ""
note "  Option A (folder-drop, simplest):"
note "    cp -r '$PLUGIN_ROOT' .claude/plugins/claudex"
note "    /reload-plugins"
note ""
note "  Option B (project-local symlink):"
note "    mkdir -p .claude/plugins"
note "    ln -s '$PLUGIN_ROOT' .claude/plugins/claudex"
note "    /reload-plugins"
note ""
note "After /reload-plugins, /claudex should appear in your slash command list."

# ─────────────────────────────────────────────
hdr "7. Platform validation"
# ─────────────────────────────────────────────
if [ -x "$PLUGIN_ROOT/tests/platform-validation.sh" ]; then
  echo "Running platform-validation.sh..."
  echo ""
  if bash "$PLUGIN_ROOT/tests/platform-validation.sh" 2>&1 | tail -5; then
    :
  else
    failures=$((failures+1))
  fi
else
  warn "platform-validation.sh not found or not executable"
  failures=$((failures+1))
fi

# ─────────────────────────────────────────────
echo ""
hdr "Summary"
# ─────────────────────────────────────────────
if [ "$failures" -eq 0 ]; then
  printf "  %bAll prerequisites look good.%b\n" "$GREEN" "$RESET"
  echo ""
  echo "Next: open a Claude Code session in any git project, install the plugin"
  echo "(see step 6 above), and try:"
  echo ""
  echo "  /claudex:plan add a feature flag system to my app"
  echo ""
  exit 0
else
  printf "  %b%d issue(s) above.%b Fix them and re-run: bash install.sh\n" "$RED" "$failures" "$RESET"
  exit 1
fi
