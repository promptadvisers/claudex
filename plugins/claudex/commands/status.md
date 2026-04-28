---
description: Print a compact summary of the most recent claudex loop -- mode, phase, round, elapsed, lock state, and per-round findings tally.
allowed-tools: Bash
---

# /claudex:status

Print the current state of the most recent claudex loop in this project. Useful while a loop is running (to see which round you're on and how long it's been going) and after one finishes (to see the final phase and severity trajectory).

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

The output is read-only. It never mutates state and always exits 0.

If no loops have run in this project, it prints a one-line "no loops" message.
