---
name: delete-comment
description: Audit and remove InkFlow code comments in batches, move decisions to project docs, and file issues for shortcuts. Use for /delete-comment or requests to continue the repository's comment cleanup.
---

# Delete InkFlow code comments

Use [the comment inventory and lint](../../../docs/comment-cleanup.md) from the active worktree. Take the requested
scope. For a repo-wide pass, inventory the whole repo and select a coherent batch small enough to review in context.
Identify reviewed paths and the outstanding inventory.

Read the code and nearby docs before assigning a category to each comment in the batch.

- **Redundant.** The code already gives the same information. Delete the comment.
- **Excuse.** The comment justifies a brittle shortcut that leaves a concrete implementation problem.
  Find or file a GitHub issue describing the problem, affected entry point and acceptance checks, then delete the
  comment. Group several comments into one issue when they describe the same defect. Record any issue filing
  blocker before removing the only record of that problem.
- **Stale.** The comment refers to superseded behavior, tools or paths. Confirm the current implementation and delete it.
- **Decision record.** The comment preserves a non-obvious contract, reason, rejected trade-off or invariant.
  Move the applicable details to the nearest maintained README or design document, then delete the comment.

Keep compiler and tooling directives and preserved legal material. Check shell heredocs, quoted values and
generated payloads before editing. Preserve executable behavior and test expectations. Use the repository's normal
issue, branch, PR and focused verification workflow.

Run the lint against the PR base and refresh the inventory. Report the four category counts for the batch,
decision docs, issue links, remaining inventory and physical comment-only lines removed. Inline comments
count as zero physical lines when code still occupies the line.
