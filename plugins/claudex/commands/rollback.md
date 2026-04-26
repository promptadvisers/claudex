---
description: Force-clean all claudex state. Use when the loop is stuck and /claudex:cancel did not work.
allowed-tools: Bash
---

# /claudex:rollback

Nuclear option. Removes all claudex state files in the current project.

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/rollback-loop.sh"
```

This removes:
- Every `.state` file under `.claude/claudex/`
- Every `.lock` file
- Every `-runner.sh` and `-prompt.txt`

The log file (`.claude/claudex/log`) is preserved so you can debug what happened.

Use this if `/claudex:cancel` did not work, or if claudex is reporting a stale concurrent loop that you cannot find.

The Stop hook fail-opens on missing state, so after rollback, your next turn ends cleanly.
