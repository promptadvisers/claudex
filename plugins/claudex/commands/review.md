---
description: Run a Codex review against the current diff. Writes findings + proposed fixes to reviews/. Read-only in v1.
allowed-tools: Bash
---

# /claudex:review

You are running claudex review mode. The Stop hook will fire when you end your turn and run a Codex adversarial review against the current diff. Findings + proposed fixes get written to `reviews/`.

## Procedure

1. Run start-loop.sh in review mode:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" review
```

2. The script sets up state. Read the printed instructions.

3. End your turn immediately. Do NOT write any code or analysis in this turn. The Stop hook fires and runs the Codex review automatically.

## v1 limitations

- Single-shot. The review runs once. There is no auto-iteration in v1.
- Read-only. Codex produces findings + proposed-fix patches. Claudex does NOT auto-apply them. Apply manually after the review.

v2 will add auto-apply with branch isolation. See `docs/V2_DESIGN.md`.

## Important

- Concurrent loops are refused. If a `/claudex:plan` loop is active, finish it before starting a review.
- To abort: `/claudex:cancel`
- To force-clean stale state: `/claudex:rollback`
