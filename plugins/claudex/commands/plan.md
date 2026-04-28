---
description: Run an autonomous plan-and-review loop. Claude drafts PLAN.md, Codex grills it adversarially, Claude revises until LGTM or N rounds.
argument-hint: '[--rounds N] [--from-draft] [--skip-interview] <feature description>'
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# /claudex:plan

User argument: $ARGUMENTS

You are running the claudex plan-mode autonomous loop. The user wants you to draft a plan, hand it to Codex for adversarial review, revise based on findings, and loop until Codex has nothing material left to flag (or until the round budget is exhausted).

## Optional flags

Parse these flags from the start of $ARGUMENTS (the script handles them; you mainly need to detect `--skip-interview`):

- `--rounds N`. Override the default max rounds (3). Common picks: 3 (default, fast), 5 (deeper grilling), 7+ (very high stakes).
- `--from-draft`. Use the existing `PLAN.md` in the project root instead of drafting from scratch. PLAN.md must exist and be non-empty.
- `--skip-interview`. Bypass the topic-sharpening interview offer in step 2 below. Useful when you've already nailed the topic or you're in a rush.

## Procedure

### 1. Empty arguments → ask for a topic

If $ARGUMENTS is empty (no topic, no flags), do NOT run start-loop.sh. Instead, ask the user a single question:

> What feature or change should I plan? (e.g. "add expiry dates to my links", "migrate auth to Clerk")
>
> Optional: prefix with `--rounds N` to override the default of 3 grilling rounds, `--from-draft` to use an existing PLAN.md, or `--skip-interview` to skip the interview offer.

Wait for their reply, then re-invoke `/claudex:plan <their answer>`. Do not proceed past this step until you have a topic.

### 2. Offer the topic-sharpening interview

If $ARGUMENTS does NOT contain `--skip-interview`, use the AskUserQuestion tool to offer the user a quick interview before launching the loop. The interview lets the user front-load constraints and worries that would otherwise come out only when Codex flags them on round 2 or 3, a much cheaper signal capture.

Use this exact AskUserQuestion call:

- **Question:** "Want me to interview you to sharpen the topic before launching the adversarial loop, or just go?"
- **Header:** "Interview"
- **Options:**
  1. Label: "Interview me first (Recommended)", Description: "I'll ask 3 quick questions about scope, constraints, and edge cases you're worried about. Then I launch the loop with a sharper topic. Costs ~30 seconds, saves a round of grilling."
  2. Label: "Just launch the loop", Description: "Skip the interview and start drafting PLAN.md from the topic as written. Faster, but Codex may surface basic gaps you could have answered up front."

If the user picks "Just launch the loop", skip to step 4.

If the user picks "Interview me first", continue with step 3.

### 3. Run the interview

Use a SECOND AskUserQuestion call with all three questions in one tool call (so the user fills them out together):

1. **Question:** "What's in scope and what's explicitly OUT of scope for this work?"
   - **Header:** "Scope"
   - **Options:** Provide 2 plausible defaults inferred from the topic (e.g. for "add expiry dates": "Just expiry on shortlinks, nothing else" / "Expiry on all link types including custom domains") plus a clear "Other" path. Keep options short and specific. multiSelect: false.
2. **Question:** "Any hard constraints? Deadlines, dependencies, or things in the codebase that must NOT change?"
   - **Header:** "Constraints"
   - **Options:** 2 plausible defaults like "No constraints, design freely" / "Must ship within X days" / "Existing API surface must not change". multiSelect: false.
3. **Question:** "What edge cases or failure modes worry you most?"
   - **Header:** "Worry list"
   - **Options:** 2-3 topic-specific options like "Concurrent edits / race conditions" / "Data loss on partial failure" / "Backwards compatibility for existing users". multiSelect: true (let the user pick several).

After the user answers, compose an enriched topic string as a SINGLE LINE using `; ` separators (the state file collapses newlines, so a one-line topic survives the round trip cleanly):

```
<original topic>; Scope: <answer 1>; Constraints: <answer 2>; Worries: <answer 3 joined by ', '>
```

Pass this enriched topic to start-loop.sh (still using --interviewed so it gets recorded in state). Do NOT show the user the enriched topic before launching, they don't need to re-confirm. Just go.

### 4. Launch the loop

Run start-loop.sh. Use $ARGUMENTS verbatim if no interview happened, or the enriched topic plus original flags if it did:

```bash
# Without interview:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" plan $ARGUMENTS

# With interview (substitute <flags> with any --rounds/--from-draft from $ARGUMENTS,
# and <enriched_topic> with the composed string):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-loop.sh" plan <flags> --interviewed "<enriched_topic>"
```

The script sets up state and prints initial instructions for you. Read them carefully.

### 5. Follow the printed instructions

- Without `--from-draft`: draft `PLAN.md` in the project root with a detailed numbered plan covering edge cases, time zones, concurrent use, data integrity, unhappy paths.
- With `--from-draft`: read the existing PLAN.md so you have context for upcoming review rounds. Do not modify it yet.

### 6. End your turn

The Stop hook fires automatically and starts the adversarial review loop.

## Examples

```
/claudex:plan add expiry dates to my links
/claudex:plan --rounds 5 add expiry dates to my links
/claudex:plan --from-draft add expiry dates
/claudex:plan --skip-interview --rounds 3 quick fix for the auth bug
```

## Important

- Once the loop starts, do not invoke `/claudex:plan` or `/claudex:review` again until the current loop finishes. The system will refuse a second concurrent loop.
- To watch state mid-loop: `/claudex:status`
- To abort an active loop: `/claudex:cancel`
- To force-clean stale state: `/claudex:rollback`
