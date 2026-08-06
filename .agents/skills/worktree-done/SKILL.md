---
name: worktree-done
description: Use this repo-local skill when the user wants to land the current Toastty worktree branch onto `main`, validate the merged result, report the outcome, and then optionally delete the worktree after explicit user approval.
---

# Worktree Done

Use this workflow only for Toastty repository worktrees whose established
landing branch is `main`.

## Core flow

1. Resolve the current worktree path and branch and the checkout that owns
   `main`. Do not repurpose the task worktree into `main`.
2. Confirm the task changes are committed and the worktree is clean.
3. Confirm the `main` checkout is clean enough to accept a merge. If it has
   unrelated local changes, stop and ask the user before mixing work.
4. Bring `main` up to date without discarding user work, then merge the
   worktree branch from the `main` checkout.
5. Keep the feature worktree intact until validation passes. Resolve conflicts
   deliberately and inspect the landed diff for worktree-only artifacts.
   `WORKTREE_HANDOFF.md` should not stay on `main` unless the user explicitly
   wants it committed.
6. Validate the merged result using this repository's `AGENTS.md` and
   `.agents/skills/toastty-verify/SKILL.md`. Include runtime/UI validation when
   the change requires it.
7. Report the landing result. If validation fails, keep the worktree intact and
   stop.
8. After a clean merge and successful validation, ask whether the user is ready
   to delete the worktree. Do not delete it without explicit approval.
9. On approval, remove the feature worktree safely and delete the fully merged
   local branch when it is no longer needed.

## Invariants

- Keep the task worktree as the recovery point until `main` is merged and
  validated.
- Never use destructive resets or overwrite uncommitted work.
- Do not claim success based only on a merge.
- Do not move work onto `main` without explicit user confirmation.
- If validation fails, leave both the worktree and branch available.
- Report whether validation ran remotely, locally, or through a wrapper with
  fallback.

## Stop and ask

- The `main` checkout has unrelated local changes.
- The merge requires a behavior change the user did not approve.
- Validation fails and the fix is no longer a straightforward continuation.
- The user has not approved worktree deletion.
