# claudex

> **Autonomous Claude + Codex review loop for Claude Code.**
> Plan a feature with adversarial pushback. Audit code with a fresh pair of eyes.
> All in one Claude Code session, hands off the keyboard.

```
$ /claudex:plan add expiry dates to my links

  Round 1 — drafting plan...
  Round 2 — adversarial review starting...
        Codex: 5 findings (2 high, 3 medium)
  Round 3 — revising based on findings...
  Round 4 — adversarial review starting...
        Codex: no substantive findings
  Round 4 — LGTM. Plan locked.

  Plan: PLAN.md
  Log:  .claude/claudex/<id>.log
```

You typed one command. You watched Codex grill Claude's plan three times until there was nothing left to grill. You walked away with a vetted plan. You did not touch the keyboard between the first command and the final output.

That's claudex.

---

## What it actually is

Two slash commands wired through a Claude Code Stop hook. The Stop hook is the only mechanism in Claude Code that can force an autonomous loop. Claudex uses it to drive Claude and Codex back and forth until the work is done.

| Command | Mode | Behavior |
|---|---|---|
| `/claudex:plan [flags] <feature>` | Plan mode | Claude drafts `PLAN.md`. Codex pressure-tests it. Claude revises. Repeat until LGTM or N rounds. |
| `/claudex:review` | Review mode | Codex reviews the diff. Findings + proposed fixes written to `reviews/`. **Read-only in v1.** |
| `/claudex:cancel` | — | Graceful cancel of the active loop. |
| `/claudex:rollback` | — | Nuclear cleanup of all state files. |

### Plan-mode flags

| Flag | Effect |
|---|---|
| `--rounds N` | Override the default max rounds (5). Useful for tighter or looser loops. |
| `--from-draft` | Use the existing `PLAN.md` in the project root instead of drafting from scratch. PLAN.md must exist and be non-empty. |

Examples:
```
/claudex:plan add expiry dates                        # default 5 rounds, fresh draft
/claudex:plan --rounds 3 add expiry dates             # 3 rounds max, fresh draft
/claudex:plan --from-draft add expiry dates           # use existing PLAN.md
/claudex:plan --rounds 3 --from-draft add expiry      # combined
```

## Why this is different from solo Claude or solo Codex

Most "AI loop" plugins for Claude Code only do code review. Plan mode is the bigger unlock — having Codex pressure-test a *design* before you write a line of code is the move that compounds the most over time. Two rounds and your plan is bulletproof. You haven't written any code. That's the magic.

## Prerequisites

Before installing claudex, you need:

| Requirement | Why | How to get it |
|---|---|---|
| **Claude Code** | Where claudex runs | https://docs.claude.com/en/docs/claude-code |
| **Node.js 18.18+** | Codex CLI is a Node app | https://nodejs.org/ or use `nvm` |
| **Codex CLI** | claudex calls `codex exec` directly | `npm install -g @openai/codex` |
| **ChatGPT Plus or higher** | Codex authenticates against your ChatGPT account | https://chatgpt.com/ |
| **Bash** | Hooks and scripts are bash | Built into macOS and Linux. Windows needs WSL. |
| **`codex login`** | Authenticates the Codex CLI | Run `codex login` after install (opens a browser) |

### Recommended companion (not required)

[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) — the official Codex plugin for Claude Code. Adds `/codex:review`, `/codex:adversarial-review`, `/codex:rescue`, and `/codex:setup` slash commands. Most people who watched the Dynamic Duo video have this installed already.

To install it:

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

claudex works without it (we invoke `codex` CLI directly), but pairing them is the full experience.

## Install

### Quick path (one command checks everything)

```bash
git clone git@github.com:promptadvisers/claudex.git ~/claudex
cd ~/claudex
bash install.sh
```

`install.sh` walks through every prerequisite, installs the Codex CLI if it's missing, points you at `codex login` if needed, and runs the platform validation tests at the end. Re-runnable any time you want to recheck the setup.

After it reports green, drop the plugin into your project:

```bash
# inside your project root, in a Claude Code session:
cp -r ~/claudex .claude/plugins/claudex
/reload-plugins
```

Or symlink it instead so updates stay in sync:

```bash
mkdir -p .claude/plugins
ln -s ~/claudex .claude/plugins/claudex
/reload-plugins
```

### Verify

```bash
bash .claude/plugins/claudex/tests/platform-validation.sh
bash .claude/plugins/claudex/tests/smoke-test.sh
```

Both should pass. If either fails, see the Troubleshooting section below.

## Try it

In a Claude Code session inside any git project:

```
/claudex:plan add a feature flag system to this app
```

Claude drafts `PLAN.md`. The Stop hook fires when Claude tries to finish the turn. The hook writes a runner script that calls Codex with an adversarial review prompt. Claude executes the script, reads Codex's findings, and either revises `PLAN.md` (if there are material findings) or marks the loop done.

You watch all of it happen in one Claude Code window.

## How it works (the 60-second version)

```
USER /claudex:plan <topic>
   ↓
Slash command writes state file, tells Claude to draft PLAN.md
   ↓
Claude drafts PLAN.md, tries to finish turn
   ↓
Stop hook fires → BLOCK with "run the runner script"
   ↓
Claude runs the runner → Codex returns adversarial findings
   ↓
Claude reads findings: revise PLAN.md OR call mark-done
   ↓
Try to finish turn again
   ↓
Stop hook fires → check signal:
   - no-material-findings  → ALLOW, print final summary
   - max rounds hit        → ALLOW, print remaining concerns
   - else                  → increment round, BLOCK with new round
```

The Stop hook is fail-open everywhere. Any error returns `{"decision":"approve"}` so the user can never get trapped. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full breakdown.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `CLAUDEX_MAX_PLAN_ROUNDS` | 5 | Max plan-loop rounds before stopping |
| `CLAUDEX_MAX_REVIEW_ROUNDS` | 3 | Max review-loop rounds (v2) |
| `CLAUDEX_STALE_MINUTES` | 15 | Loops older than this are auto-swept on next invocation |
| `CLAUDEX_STATE_DIR` | `.claude/claudex` | State directory location |

## Safety

The plugin is designed to fail open everywhere. You can never get trapped in a broken loop. See [`docs/SAFETY.md`](docs/SAFETY.md) for the complete list of what claudex does and does NOT do.

Highlights:

- Hook fails open on every error (ERR trap installed at the top)
- Plan mode only writes to `PLAN.md` and `.claude/claudex/`
- **Review mode v1 is read-only** — does NOT edit your code
- Concurrent loops detected and refused (phase-based, not file-presence)
- Stale loops auto-cleaned after 15 min
- Atomic state writes (tmp + rename)
- CAS phase transitions prevent race conditions

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — full technical walkthrough. Loop lifecycle, state machine, fail-open patterns.
- [`docs/SAFETY.md`](docs/SAFETY.md) — explicit guarantees and non-guarantees. Read before installing.
- [`docs/V2_DESIGN.md`](docs/V2_DESIGN.md) — design for v2 auto-apply review mode (not built in v1).

## Tests

```bash
# Phase 0: confirm platform behaviors work on your machine (28 checks)
bash tests/platform-validation.sh

# Smoke test: simulate full lifecycle without invoking Codex (32 checks)
bash tests/smoke-test.sh

# Synthetic E2E: real Codex calls against a throwaway repo (19 checks, costs a few cents in tokens)
bash tests/synthetic-e2e.sh
```

All three should pass before trusting claudex on a real project.

## Project structure

```
claudex/
├── .claude-plugin/plugin.json    # Manifest
├── commands/
│   ├── claudex.md                # Main slash command
│   ├── claudex-cancel.md
│   └── claudex-rollback.md
├── hooks/
│   ├── hooks.json                # Stop hook registration
│   └── stop-hook.sh              # Lifecycle engine, fail-open everywhere
├── scripts/
│   ├── start-loop.sh             # Sets up state, refuses concurrent loops
│   ├── mark-done.sh              # Claude calls this to signal LGTM
│   ├── cancel-loop.sh
│   ├── rollback-loop.sh
│   ├── state-helpers.sh          # Atomic write, CAS, sweeper, lockfile
│   └── prompts/                  # Templated instructions
├── tests/
│   ├── platform-validation.sh
│   ├── smoke-test.sh
│   └── synthetic-e2e.sh
└── docs/
```

## Status

v1 ships with these phases complete:

- [x] Phase 0 — Platform validation tests
- [x] Phase 1 — Skeleton + fail-open Stop hook
- [x] Phase 2 — State machine schema
- [x] Phase 2.5 — Safety primitives (atomic writes, CAS, lockfiles, stale sweeper)
- [x] Phase 3 — Plan mode end-to-end
- [x] Phase 4 — Review mode (read-only)
- [x] Phase 4.5 — V2 design doc
- [x] Phase 5 — Polish (cancel, rollback, env-var config)
- [x] Phase 6 — Distribution + docs

v2 lands later. Highlights: auto-apply for review mode with branch isolation, multi-agent Codex, interactive apply.

## Troubleshooting

**`/claudex` doesn't show up in my slash command list.**
You either skipped `/reload-plugins` after dropping the plugin in, or the plugin folder isn't where Claude Code expects it. Confirm `.claude/plugins/claudex/.claude-plugin/plugin.json` exists. Then run `/reload-plugins`.

**`codex exec` errors out with "auth required" or similar.**
Run `codex login` in a regular terminal. It opens a browser. Sign in with your ChatGPT account (Plus or higher).

**`platform-validation.sh` fails on a state-helpers check.**
Make sure you're running with `bash`, not `sh` or `zsh`. The scripts use bash-specific syntax. Try `bash tests/platform-validation.sh` explicitly.

**The hook fires but Claude doesn't continue the loop.**
Check `.claude/claudex/log` for ERR-trap entries. Most likely cause: the runner script printed an error from the Codex CLI. Run `bash .claude/claudex/<id>-runner.sh` manually to see what Codex said.

**A loop is stuck and `/claudex:cancel` didn't help.**
Use `/claudex:rollback` to nuke all state files. Then start a fresh loop.

**I want to debug what the hook is doing.**
Set `CLAUDEX_VERBOSE=1` in your environment before invoking `/claudex`. Logs will be more detailed in `.claude/claudex/log`.

## Author

Mark Kashef. Built for the Codex + Claude Code Dynamic Duo follow-up video on the loop pattern.

## License

MIT. See [`LICENSE`](LICENSE).
