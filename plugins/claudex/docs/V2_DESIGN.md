# Claudex V2 Design — Auto-Apply Review Mode

This document describes the design for v2 of claudex review mode. v2 adds the ability to auto-apply Codex's recommended fixes safely. v1 is read-only and produces a proposed-fixes file that the user applies manually.

The reason auto-apply was deferred: a Codex adversarial review of the v1 plan flagged that auto-applying patches without branch isolation is dangerous. Bad findings, retries, partial failures, or a user's dirty worktree can mix automated edits with unrelated user changes irreversibly. v2 fixes this by making auto-apply only operate on an isolated branch that the user explicitly merges or discards.

## v2 lifecycle

```
USER: /claudex:review --apply
              │
              ▼
  start-loop.sh checks for dirty worktree
              │
              ├─ DIRTY  → refuse, instruct user to commit or stash
              │
              └─ CLEAN  → continue
              │
              ▼
  Create branch: claudex/review-<review_id>
              │
              ▼
  Codex reviews HEAD diff (unchanged from v1)
              │
              ▼
  Findings + proposed-fixes files written
              │
              ▼
  For each fix Claude applies:
    │
    ├─ snapshot the file before editing → .claude/claudex/<id>-snapshots/<file>
    ├─ apply the fix
    ├─ git commit on the isolated branch with a clear message
    └─ record the commit SHA in a manifest
              │
              ▼
  Loop continues until done (no material findings) or max rounds
              │
              ▼
  Write a summary file: reviews/applied-<id>.md
    - List of changes
    - File paths and commit SHAs
    - How to apply, how to discard
              │
              ▼
  Hook ALLOWs exit
              │
              ▼
  USER: /claudex:apply <id>      OR      /claudex:rollback <id>
              │                                    │
              ▼                                    ▼
   Merge claudex/review-<id>            Delete the isolated branch
   into the user's current branch      Restore working tree to pre-loop state
   with a single squash commit
```

## v2 state file additions

```yaml
mode: review
phase: applying        # NEW: "applying" phase between reviewing and done
isolated_branch: claudex/review-20260426-094523-a3f7c2
commits_applied:       # NEW: array of SHA + file path pairs
  - sha: abc1234
    path: src/api/transactions.ts
    rationale: "fix timezone parsing"
snapshot_dir: .claude/claudex/20260426-094523-a3f7c2-snapshots
```

## New commands in v2

- `/claudex:review --apply <feature description>` — opt-in auto-apply mode (default review mode stays read-only)
- `/claudex:apply <review_id>` — merge the isolated branch into the user's current branch
- `/claudex:rollback <review_id>` — delete the isolated branch and restore pre-loop state

## v2 safety guarantees (added on top of v1)

- Auto-apply mode REFUSES to start if the worktree is dirty
- All edits happen on `claudex/review-<id>`, never on the user's current branch
- Every applied fix is a separate git commit on the isolated branch with rationale in the message
- Pre-edit snapshots are saved so even individual edits can be reverted
- The user must explicitly merge via `/claudex:apply` — nothing happens to their branch by default
- `/claudex:rollback` is irreversible from the plugin's perspective but git keeps the branch reflog for ~30 days

## Implementation phases (v2)

- **Phase v2.1** — branch isolation and commit-per-fix on the isolated branch (no merge support yet)
- **Phase v2.2** — `/claudex:apply` and `/claudex:rollback` commands
- **Phase v2.3** — multi-agent Codex (parallel reviewers) opt-in
- **Phase v2.4** — interactive apply (let the user pick which fixes to apply)

## What v2 does NOT add

- A web UI
- Cloud sync
- Multi-user state coordination
- Windows native support (still bash-only)

## When v2 lands

After v1 ships and Mark builds the loop video. v1 is the teachable artifact for the video. v2 is the production-ready next iteration.
