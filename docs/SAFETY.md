# Claudex Safety Document

Read this before installing claudex. Be especially clear about what claudex DOES and does NOT do.

## What claudex DOES

### Plan mode

- Creates a state file at `.claude/claudex/<review_id>.state`
- Creates a lockfile at `.claude/claudex/<review_id>.lock`
- Writes a runner script at `.claude/claudex/<review_id>-runner.sh`
- Writes a prompt file at `.claude/claudex/<review_id>-prompt.txt`
- **Creates and modifies `PLAN.md` in the project root.** This is the only file outside of `.claude/claudex/` that plan mode writes to.
- Logs to `.claude/claudex/log`

### Review mode (v1, read-only)

- Same state file artifacts as plan mode
- **Creates and writes to `reviews/review-<id>.md`** (Codex findings)
- **Creates and writes to `reviews/proposed-fixes-<id>.md`** (Claude's interpretation, in unified diff format)
- Does NOT apply any patches. Does NOT edit any other code in your project.

### Both modes

- Sweeps stale loops (older than 15 minutes by default) on every new invocation
- Refuses to start if another loop is already active in the project
- Fails open on every error path (any hook failure returns "approve" so you can exit)

## What claudex DOES NOT do

- Does NOT edit any user code in review mode (v1)
- Does NOT delete any of your files
- Does NOT push to git, branch, commit, or revert any of your work
- Does NOT call out to any external service except the Codex CLI (which uses your existing ChatGPT auth)
- Does NOT collect telemetry or send any data anywhere

## Files claudex touches (complete list)

```
.claude/claudex/                    (created if missing)
.claude/claudex/<review_id>.state   (per-loop state)
.claude/claudex/<review_id>.lock    (per-loop lockfile)
.claude/claudex/<review_id>-runner.sh    (per-loop runner)
.claude/claudex/<review_id>-prompt.txt   (per-loop Codex prompt)
.claude/claudex/log                 (append-only log)
PLAN.md                             (plan mode only, in project root)
reviews/review-<id>.md              (review mode only)
reviews/proposed-fixes-<id>.md      (review mode only)
```

That's it. Every other file in your project is untouched.

## Add to .gitignore?

Yes, recommended:

```
# Claudex per-loop state
.claude/claudex/

# Plan mode output (decide for yourself if you want PLAN.md tracked)
# PLAN.md

# Review mode output
reviews/review-*.md
reviews/proposed-fixes-*.md
```

## Token cost

Claudex uses Codex via the Codex CLI, which runs against your ChatGPT subscription. Costs are billed by ChatGPT, not by claudex.

Each plan mode round = one Codex review. Default max 5 rounds = up to 5 reviews per loop.
Each review mode invocation = one Codex review.

If your ChatGPT plan has usage limits, monitor them. Claudex cannot enforce limits or stop on cost — that's between you and OpenAI.

## What happens if it breaks

The plugin is designed to fail open. Specifically:

- If the Stop hook crashes for any reason → Claude's exit is allowed → you are not trapped
- If a state file is corrupted → hook removes it on next fire and allows exit
- If two `/claudex` are launched at once → the second is refused with a clear message
- If you Ctrl-C mid-loop → the lockfile becomes stale → next `/claudex` invocation cleans it up
- If `codex` CLI is missing → the runner script reports an error, the hook still allows exit

Worst case: you might end up with a stale state file under `.claude/claudex/` that doesn't get auto-swept. To clean: run `/claudex:rollback`.

## What claudex CANNOT recover from

- An incomplete plan mode edit (PLAN.md half-written) if Claude is killed mid-edit. Manual recovery needed: revert PLAN.md from git or rewrite it.
- A user who has the review gate from the official Codex plugin enabled while running claudex. The two will fight. Disable one or the other.

## What v2 will add

Auto-apply for review mode, with safety guarantees:

- Detect dirty worktree at start. Refuse if dirty.
- All edits land on an isolated `claudex/review-<id>` branch. Your main branch is never touched directly.
- Per-edit patch snapshots so any change is individually revertable.
- `/claudex:apply <id>` to merge the isolated branch into main, after explicit confirmation.
- `/claudex:rollback <id>` to discard the entire branch.

See `docs/V2_DESIGN.md` for the full design.
