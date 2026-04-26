---
description: Run an autonomous Claude+Codex loop. Plan a feature with adversarial pushback, or audit code (read-only).
argument-hint: 'plan <feature> | review'
allowed-tools: Bash, Read, Write, Edit
---

# /claudex

User argument: $ARGUMENTS

You are running the claudex autonomous loop. Mode is detected from the first word of $ARGUMENTS.

## Mode detection

- If $ARGUMENTS starts with `plan ` (case insensitive), strip the prefix and use the rest as the topic. Run PLAN MODE.
- If $ARGUMENTS equals `review` or starts with `review `, run REVIEW MODE.
- If $ARGUMENTS is empty or unclear, print: "Usage: /claudex plan <feature description> | /claudex review" and stop.

## PLAN MODE

1. Run the start-loop script with `plan` and the topic:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" plan "<topic>"
```

2. The script will set up state and print initial instructions for you. Read them.

3. Follow the instructions: draft `PLAN.md` in the project root with a detailed numbered plan. Cover edge cases, time zones, concurrent use, data integrity, unhappy paths.

4. End your turn. The Stop hook fires automatically and starts the adversarial review loop.

## REVIEW MODE

1. Run the start-loop script with `review`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" review
```

2. The script sets up state. Read the printed instructions.

3. End your turn immediately. Do NOT write any code or analysis in this turn. The Stop hook fires and runs the Codex review automatically.

## Important

- Once the loop starts, do not invoke `/claudex` again until the current loop finishes. The system will refuse a second concurrent loop.
- To abort an active loop: `/claudex:cancel`
- To force-clean stale state: `/claudex:rollback`
