---
description: Preflight diagnostic for claudex. Verifies bash, codex CLI, state directory, plugin file integrity, and hook fail-open. Run after install or when something feels off.
allowed-tools: Bash
---

# /claudex:doctor

Run a full preflight check on the claudex install. Use this:
- Right after installing the plugin
- If `/claudex:plan` or `/claudex:review` is misbehaving
- Before going live with claudex on a new machine

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

Exit code 0 means every required check passed. Exit code 1 means at least one required check failed. Optional checks (e.g. python3) print warnings but never fail the run.
