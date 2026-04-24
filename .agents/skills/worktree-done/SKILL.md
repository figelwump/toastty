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
   - Inspect the landed diff for worktree-only artifacts before validation.
   - In Toastty, `WORKTREE_HANDOFF.md` is a handoff artifact and should not stay on `main` unless the user explicitly wants it committed there.
5. Validate the merged result on `main`.
   - Choose validation from the current repo instructions, not from this skill alone.
   - Prefer the repo’s remote/wrapper validation paths for agent-driven test and smoke runs when they cover the change.
   - If the change touched UI or runtime behavior, include the relevant smoke validation instead of relying on unit tests alone.
   - Use local-only validation only when the repo instructions call for it, the check cannot run remotely, or a remote wrapper has failed and you are intentionally continuing with a local fallback.
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
- Do not leave `WORKTREE_HANDOFF.md` on `main` as part of routine worktree cleanup.

## Toastty-specific validation

- Read the repo `AGENTS.md` before choosing the final validation set.
- For agent-driven smoke validation, start with `sv exec -- scripts/remote/validate.sh --smoke-test ...` unless the current repo instructions make a narrower local check more appropriate.
- For agent-driven `xcodebuild test` validation, prefer `sv exec -- scripts/remote/test.sh -- ...` when test coverage is needed and the wrapper applies.
- Use `./scripts/automation/check.sh` only when it is explicitly the right validation for the situation, not as a default substitute for remote wrappers.
- In handoff or completion messages, say whether each validation ran remotely, locally, or via a wrapper with fallback.

## When to stop and ask the user

- The `main` checkout has unrelated local changes.
- The merge requires a behavior change the user did not approve.
- Validation fails and the fix is no longer a straightforward continuation of the landed task.
- The user has not yet said whether the worktree should be deleted.
