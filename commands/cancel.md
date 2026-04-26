---
description: Cancel the active claudex loop. Cleans state files so the Stop hook will allow exit on the next turn.
allowed-tools: Bash
---

# /claudex:cancel

Cancel the currently active claudex loop in this project.

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cancel-loop.sh"
```

The script will:
1. Find the active loop state file
2. Mark its phase as `cancelled`
3. Remove the runner script and lockfile
4. Print confirmation

The Stop hook will see the cancelled phase on its next fire and ALLOW exit cleanly.

If no active loop exists, the script reports that and exits cleanly.
