## Round {{ROUND}} - adversarial review

Run the runner script below. It will execute Codex in adversarial mode against PLAN.md and stream findings to your terminal.

```
bash {{RUNNER_SCRIPT}}
```

Wait for Codex to finish. Read the findings carefully.

## Then decide

After reading Codex's findings, decide whether they are MATERIAL.

**Material findings:**
- Real bugs or design flaws that would break under stress
- Edge cases that would cause data loss, security issues, or user-facing failures
- Genuine architectural concerns

**NOT material:**
- Style preferences
- Naming nits
- Speculative concerns without specific evidence

## Two paths

**Path A: Material findings exist.** Revise `PLAN.md` to address them. In a brief changelog comment at the top of `PLAN.md` (under a "## Changelog" section), note what you took and what you rejected (with reasoning). Then end your turn. The Stop hook will fire and run another round.

**Path B: No material findings (or only style nits).** Update the state file to mark the loop done:

```
bash {{CLAUDE_PLUGIN_ROOT}}/scripts/mark-done.sh {{REVIEW_ID}}
```

Then end your turn. The Stop hook will allow your exit and print the final summary.

## Hard stop

If this is round {{MAX_ROUNDS}} and Codex still has substantive findings, end your turn anyway. The hook will detect max-rounds-reached and exit cleanly with a list of remaining concerns.
