---
description: Run an autonomous Claude+Codex loop. Plan a feature with adversarial pushback, or audit code (read-only).
argument-hint: 'plan [--rounds N] [--from-draft] <feature> | review'
allowed-tools: Bash, Read, Write, Edit
---

# /claudex

User argument: $ARGUMENTS

You are running the claudex autonomous loop. Mode is detected from the first word of $ARGUMENTS. Optional flags can follow the mode and precede the topic.

## Mode detection

- If $ARGUMENTS starts with `plan ` (case insensitive), strip the prefix. Parse any flags. Treat the rest as the topic. Run PLAN MODE.
- If $ARGUMENTS equals `review` or starts with `review `, run REVIEW MODE.
- If $ARGUMENTS is empty or unclear, print:
  `Usage: /claudex plan [--rounds N] [--from-draft] <feature> | /claudex review`

## Optional flags (plan mode)

- `--rounds N` — override the default max rounds (5). Useful for tighter or looser loops.
- `--from-draft` — use the existing `PLAN.md` in the project root instead of drafting from scratch. PLAN.md must exist and be non-empty. If you want a different file, copy it to PLAN.md first.

Pass flags through to start-loop.sh as-is. The script handles parsing.

## PLAN MODE

1. Run the start-loop script with `plan`, any flags, and the topic:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" plan [--rounds N] [--from-draft] "<topic>"
```

Examples:
- `/claudex plan add expiry dates to my links` (default: 5 rounds, fresh draft)
- `/claudex plan --rounds 3 add expiry dates to my links`
- `/claudex plan --from-draft add expiry dates to my links` (uses existing PLAN.md)
- `/claudex plan --rounds 3 --from-draft add expiry dates to my links`

2. The script sets up state and prints initial instructions for you. Read them carefully.

3. Follow the instructions:
   - Without `--from-draft`: draft `PLAN.md` in the project root with a detailed numbered plan covering edge cases, time zones, concurrent use, data integrity, unhappy paths.
   - With `--from-draft`: read the existing PLAN.md so you have context for upcoming review rounds. Do not modify it yet.

4. End your turn. The Stop hook fires automatically and starts the adversarial review loop.

## REVIEW MODE

1. Run the start-loop script with `review`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" review
```

2. The script sets up state. Read the printed instructions.

3. End your turn immediately. Do NOT write any code or analysis in this turn. The Stop hook fires and runs the Codex review automatically.

Note: review mode is read-only and single-shot in v1. The `--rounds` flag is accepted but currently has no effect.

## Important

- Once the loop starts, do not invoke `/claudex` again until the current loop finishes. The system will refuse a second concurrent loop.
- To abort an active loop: `/claudex:cancel`
- To force-clean stale state: `/claudex:rollback`
