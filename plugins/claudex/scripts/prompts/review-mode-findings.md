## Review complete

Codex has finished its review. Two files were written for you:

1. **`reviews/review-{{REVIEW_ID}}.md`** - the raw findings from Codex
2. **`reviews/proposed-fixes-{{REVIEW_ID}}.md`** - patches Claude is suggesting based on those findings (in unified diff format)

## What to do

Read both files. The findings file is what Codex actually said. The proposed-fixes file is Claude's interpretation of which fixes to apply and how.

**v1 of claudex is read-only.** Claudex will NOT auto-apply any of these patches. That is by design. Auto-apply with branch isolation lands in v2.

## To apply a fix manually

Pick the patches you want from `proposed-fixes-{{REVIEW_ID}}.md` and apply them yourself. Either:

```
git apply reviews/proposed-fixes-{{REVIEW_ID}}.md
```

Or copy the patches into your editor and adapt them. Or ask Claude to apply specific ones.

## End the loop

End your turn. The Stop hook will allow exit cleanly.
