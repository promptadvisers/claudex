# Claudex Architecture

This document explains how claudex works under the hood. Read it once and you understand the entire plugin. Use it as the script for the loop video.

## The core insight

Claude Code has a feature called **Stop hooks**. These are shell scripts that fire whenever Claude tries to finish a turn. They can return one of two decisions:

- `{"decision":"approve"}`. Let Claude exit normally
- `{"decision":"block","reason":"..."}`. Refuse to let Claude finish, force it to keep working with the reason text as the next instruction

Stop hooks are the **only** mechanism in Claude Code that can drive an autonomous loop. A slash command alone can't loop because slash commands are one-shot. They execute once, return their output, and Claude is done.

Claudex is a thin orchestrator built on top of Stop hooks. The hook is the brain. Everything else is plumbing.

## The lifecycle (plan mode)

```
USER: /claudex:plan add expiry dates
              │
              ▼
  ┌─────────────────────┐
  │ commands/claudex.md │ Slash command tells Claude to:
  └─────────────────────┘   1. Run start-loop.sh
              │             2. Read its instructions
              │             3. Draft PLAN.md
              ▼
  ┌─────────────────────┐
  │ start-loop.sh       │ - Sweeps stale loops
  └─────────────────────┘ - Refuses if another loop active
              │           - Generates review_id
              │           - Writes state file
              │           - Writes lockfile
              ▼           - Prints initial instructions
  CLAUDE drafts PLAN.md
  CLAUDE tries to finish turn
              │
              ▼
  ┌─────────────────────┐
  │ stop-hook.sh        │ Reads state file
  └─────────────────────┘ phase=drafting + PLAN.md exists
              │           → CAS transition to reviewing
              │           → Write runner script with Codex prompt
              │           → Return BLOCK with "run the script"
              ▼
  CLAUDE: bash <runner-script>
  CLAUDE reads Codex findings
  CLAUDE decides: material? (revise + end turn)
                  no?       (mark-done + end turn)
              │
              ▼
  ┌─────────────────────┐
  │ stop-hook.sh        │ Reads state file
  └─────────────────────┘ phase=reviewing
              │           → If signal=no-material-findings: ALLOW + cleanup
              │           → If round >= max: ALLOW + "stopped at max"
              │           → Else: increment round, BLOCK with new round
              ▼
  CLAUDE either revises PLAN.md (loops back) OR exits cleanly
```

## The state file

State lives at `.claude/claudex/<review_id>.state`. YAML frontmatter format:

```yaml
mode: plan
phase: reviewing
topic: "add expiry dates to my links"
round: 2
max_rounds: 5
review_id: 20260426-094523-a3f7c2
repo_root: /Users/me/projects/linkboard
session_id: abc123
started_at: 2026-04-26T09:45:23Z
last_updated_at: 2026-04-26T09:48:01Z
decision_signal: none
```

### Why per-loop state files (not one shared file)

If the entire plugin used one shared `.claude/claudex.state` file, two things break:

1. **Stale state survives across sessions.** Crash mid-loop, the next Claude session sees a half-finished loop and gets confused.
2. **Concurrent invocations clobber each other.** Open two terminals, run `/claudex` in both, and the second one overwrites the first's state.

Per-loop files (`<review_id>.state`) plus an active-loop sweeper solves both.

### Atomic writes

Every state mutation goes through `claudex_state_write`, which writes to a `.tmp` file then renames. Rename is atomic on the same filesystem. So a hook reading the state never sees a half-written file.

### Compare-and-swap (CAS) phase transitions

`claudex_phase_transition` reads the current phase, only writes the new phase if it matches the expected `from` phase, and updates `last_updated_at` in the same write. This prevents race conditions where two concurrent code paths both try to advance the phase.

## The Stop hook

`hooks/stop-hook.sh` is the brain. ~250 lines of bash. The only thing in claudex that the user never directly invokes.

### Fail-open everywhere

The first thing the hook does is install an ERR trap that returns `{"decision":"approve"}` on any unhandled error. The user can NEVER get trapped in a broken loop. Other fail-open points:

- Missing state directory → approve
- No active loop → approve
- Invalid review_id → remove the bad state file, approve
- cwd doesn't match the loop's repo_root → approve
- Unknown mode or phase → approve
- python3 missing for JSON escape → fall back to sed

Every error path leads to approve. The plugin is not allowed to break the user's workflow.

### Mode-specific lifecycles

The hook branches on `mode` (plan or review) and then on `phase`. Plan mode has the most states:

- `drafting` → check PLAN.md, transition to reviewing, write runner, BLOCK
- `reviewing` → check decision_signal, either ALLOW (done/max) or increment round + BLOCK
- `done` → cleanup + ALLOW
- `cancelled` → cleanup + ALLOW

Review mode is simpler in v1:

- `reviewing` → write runner script that produces findings file, transition to done, BLOCK
- `done` → cleanup + ALLOW

## The runner script

When the hook decides BLOCK, it writes a runner script to `.claude/claudex/<review_id>-runner.sh`. The script is a self-contained shell command that invokes the Codex CLI with a prompt embedded inline.

The hook tells Claude in its BLOCK reason to run that runner script. Claude executes via the Bash tool. Codex output streams to the user's terminal in real time.

The runner script includes:

- A check for `codex` in PATH (clear error if missing)
- The full prompt as a heredoc (so the Codex review focus is exactly what claudex specified)
- A clear log line so the user knows what's happening

## How Claude communicates "done" back to the hook

The challenge: hooks fire AFTER Claude finishes a turn. So how does Claude tell the hook "the loop should end now"?

Answer: Claude updates the state file before ending its turn. Specifically, Claude runs `mark-done.sh` which sets `phase=done` and `decision_signal=no-material-findings`. The hook reads those fields on its next fire and ALLOWs exit.

This is just a state machine using the file system as a synchronization channel. Simple. Robust. Survives crashes.

## What the hook does NOT do

To keep the plugin safe and predictable, the hook explicitly does not:

- Edit any user code outside of `.claude/claudex/`
- Auto-apply Codex findings (review mode is read-only in v1)
- Time out without allowing exit
- Trap on missing dependencies
- Call slash commands directly (it writes runner scripts that Claude executes)

## What you would change in a fork

If you want to extend claudex, the natural seams are:

- **Add a new mode**: branch in `commands/claudex.md` to detect a new keyword, add a new lifecycle in `stop-hook.sh`, write new prompt templates.
- **Change the Codex invocation**: edit the `write_runner_script` function in `stop-hook.sh`. Default uses `codex --dangerously-bypass-approvals-and-sandbox`. You can swap in any other agent.
- **Change round limits**: set `CLAUDEX_MAX_PLAN_ROUNDS` and `CLAUDEX_MAX_REVIEW_ROUNDS` env vars before invoking `/claudex`.
- **Change the stale threshold**: set `CLAUDEX_STALE_MINUTES` (default 15).
- **Add multi-agent mode**: see `docs/V2_DESIGN.md` for sketched approach.

## What you would change for v2 auto-apply review

Read `docs/V2_DESIGN.md` for the full plan. Short version:

- Detect dirty worktree at start. Refuse if dirty.
- Create isolated `claudex/review-<id>` branch.
- Apply each fix on the branch.
- Snapshot every patch separately.
- Add `/claudex:apply <id>` to merge or discard the branch.
- Add `/claudex:rollback <id>` to nuke the branch entirely.
