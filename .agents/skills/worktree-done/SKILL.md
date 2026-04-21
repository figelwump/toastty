---
name: worktree-done
description: Use this skill when the user wants to land the current Toastty worktree branch onto `main`, validate the merged result, report the outcome, and then optionally delete the worktree after explicit user approval.
---

# Worktree Done

Use this workflow when a task is complete in a Toastty worktree and the next step is to land it on `main` and clean up safely.

## Core flow

1. Resolve the current worktree context.
   - Identify the current worktree path and current branch.
   - Resolve the checkout that owns `main`.
   - Do not repurpose the task worktree into `main` just to perform the merge.
2. Preflight before landing anything.
   - Confirm the current task changes are committed.
   - Confirm the task worktree is clean.
   - Confirm the `main` checkout is clean enough to accept a merge.
   - If `main` has unrelated local changes, stop and ask the user before mixing work.
3. Update `main` safely.
   - Bring the `main` checkout up to date when that can be done without discarding local user work.
   - Never use destructive resets or overwrite uncommitted work in the `main` checkout.
4. Merge the worktree branch into `main`.
   - Perform the merge from the `main` checkout, not from inside the feature worktree.
   - Keep the feature worktree intact until validation passes.
   - If the merge conflicts, resolve them deliberately and continue only once `main` is coherent again.
5. Validate the merged result on `main`.
   - Use the repo’s normal full validation gate.
   - In Toastty, the default baseline is `./scripts/automation/check.sh`.
   - If the change touched UI or runtime behavior, also run the smoke validation expected by the repo instructions instead of relying on unit tests alone.
   - In Toastty, that usually means the local smoke flows documented in `AGENTS.md`, including the fallback no-Ghostty pass before the Ghostty-enabled pass when the surface is covered there.
6. Report the landing result.
   - If validation fails, tell the user exactly what failed, keep the worktree intact, and stop.
   - If validation passes, summarize that `main` now contains the merged work and what validation succeeded.
7. Ask before cleanup.
   - After a clean merge and validation, ask the user if they are ready to delete the worktree.
   - Do not delete the worktree until the user explicitly says yes.
8. Delete on approval.
   - Remove the feature worktree safely.
   - If the feature branch is fully merged and no longer needed, delete the local branch too.
   - Keep the `main` checkout intact and report what was removed.

## Important invariants

- Keep the task worktree as the recovery point until `main` has been merged and validated.
- Do not claim success based only on a merge; validation must pass on the merged `main` checkout.
- Do not delete the worktree automatically after a successful merge. The user must opt in.
- If validation fails, leave both the worktree and branch in place so the user can continue from the same context.
- Prefer a clean `main` landing path over clever shortcuts.

## Toastty-specific validation

- Read the repo `AGENTS.md` before choosing the final validation set.
- `./scripts/automation/check.sh` is the default full gate.
- For UI or runtime changes, prefer the smoke automation paths documented there.
- In handoff or completion messages, say whether validation ran locally, remotely, or via a wrapper with fallback.

## When to stop and ask the user

- The `main` checkout has unrelated local changes.
- The merge requires a behavior change the user did not approve.
- Validation fails and the fix is no longer a straightforward continuation of the landed task.
- The user has not yet said whether the worktree should be deleted.
