---
description: Run an autonomous plan-and-review loop. Claude drafts PLAN.md, Codex grills it adversarially, Claude revises until LGTM or N rounds.
argument-hint: '[--rounds N] [--from-draft] <feature description>'
allowed-tools: Bash, Read, Write, Edit
---

# /claudex:plan

User argument: $ARGUMENTS

You are running the claudex plan-mode autonomous loop. The user wants you to draft a plan, hand it to Codex for adversarial review, revise based on findings, and loop until Codex has nothing material left to flag (or until the round budget is exhausted).

## Optional flags

Parse these flags from the start of $ARGUMENTS:

- `--rounds N` — override the default max rounds (5). Useful for tighter or looser loops.
- `--from-draft` — use the existing `PLAN.md` in the project root instead of drafting from scratch. PLAN.md must exist and be non-empty.

Pass flags through to start-loop.sh as-is. The script handles parsing.

## Procedure

1. Run start-loop.sh with the full $ARGUMENTS:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" plan $ARGUMENTS
```

2. The script sets up state and prints initial instructions for you. Read them carefully.

3. Follow the instructions:
   - Without `--from-draft`: draft `PLAN.md` in the project root with a detailed numbered plan covering edge cases, time zones, concurrent use, data integrity, unhappy paths.
   - With `--from-draft`: read the existing PLAN.md so you have context for upcoming review rounds. Do not modify it yet.

4. End your turn. The Stop hook fires automatically and starts the adversarial review loop.

## Examples

```
/claudex:plan add expiry dates to my links
/claudex:plan --rounds 3 add expiry dates to my links
/claudex:plan --from-draft add expiry dates to my links
/claudex:plan --rounds 3 --from-draft add expiry dates
```

## Important

- Once the loop starts, do not invoke `/claudex:plan` or `/claudex:review` again until the current loop finishes. The system will refuse a second concurrent loop.
- To abort an active loop: `/claudex:cancel`
- To force-clean stale state: `/claudex:rollback`
