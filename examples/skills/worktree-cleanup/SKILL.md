---
name: worktree-cleanup
description: Use when the user asks which pull requests or task worktrees are ready to merge, asks to merge specific ready PRs, or asks to clean up merged worktrees, branches, and their Toastty workspaces or task spaces. Run it from outside the task workspaces.
---

# Worktree Cleanup

Report which task PRs are ready, merge the ones the user names, and clean up task
worktrees whose PR has merged. Run it from a workspace other than the tasks being
cleaned up, usually the repository's main checkout.

Resolve `scripts/worktree-status.py` relative to this loaded package. Run it with
`--repo <any checkout of the repository>`; it needs `git`, an authenticated `gh`,
and, for cleanup, `TOASTTY_CLI_PATH` pointing at a Toastty with `workspace.list`.
Cleanup refuses to run from a workspace-scoped session, because that session sees
only some workspaces. A project session that launched tasks with `worktree-create`
is scoped. Ask the user whether to clear this session's scope with
`"$TOASTTY_CLI_PATH" session scope clear`, or to run cleanup from a new session;
do not clear it without their answer.

## Report status

Run `worktree-status.py` and summarize its verdicts:

- **ready**: open, not draft, GitHub reports it mergeable with required checks
  met, no check failing or still running, the worktree is clean at exactly
  the PR head, and the description lists no merge prerequisites.
- **cleanup**: merged, and the worktree is clean at exactly the PR head. A
  detached worktree may instead be at the PR merge commit, when its workspace
  has one unambiguous PR URL chip for this repository.
- **blocked**: anything else. Give the reason it prints. A description with an
  "Activation order", "Merge order", "Rollout", or "Depends on" section, or a
  link to a PR in another repository, blocks the PR even when CI is green.

A ready verdict is not acceptance. Name the ready PRs and ask which to merge
unless the user already named them.

## Merge

Merge only PRs the user names in this request, or that the user accepted with
`worktree-done`. For each:

1. Rerun the status and confirm the PR is still ready at the head you report.
   If its only blocked reason is merge prerequisites in its description, name
   them and treat it as ready once the user confirms each one is done. Do not
   infer completion from green CI or from a linked PR having merged; any other
   blocked reason still stops the merge.
2. Run `gh pr merge <number> --auto --merge --match-head-commit <head>`. Use the
   repository's documented merge method instead of `--merge` when it has one.
   Auto-merge lands the PR when required checks pass, or at once if they have.
   If it fails with `Pull request is in clean status`, GitHub refused to queue a
   PR that is already mergeable. Recheck with
   `gh pr view <number> --json state,mergeable,mergeStateStatus,headRefOid,baseRefName`.
   If the PR is still open, `MERGEABLE`, `CLEAN`, and at the same head and base,
   merge it directly with `gh pr merge <number> --merge --match-head-commit <head>`, using
   the same merge method. Otherwise report its state and skip it.
3. If a named PR is stacked on another unmerged PR, stop and ask whether to merge
   that base PR too. Merge nothing the user did not name. After the base merges
   and its branch is deleted, GitHub retargets the dependent PR.

After merging, confirm that the default branch's CI ran and passed for the final
merged commit. A green run that skipped jobs does not test the merged code.

## Clean up

Run `worktree-status.py --cleanup-merged`. For each cleanup row it closes the
matching Toastty workspace, removes the worktree, and deletes the local and remote
branch. Closing the workspace ends any agent sessions and running terminal
commands in it; the row's cleanup report names what was ended. It skips a row,
leaving everything in place, when the workspace match is ambiguous; when the
workspace is this session's own, holds another worktree or another PR's chip, or
has unsaved documents; or when the worktree is locked. It rereads the workspaces
just before closing each one, rechecks the worktree just before removing it, and
deletes each branch only while it still points at the PR head and is not checked
out in another worktree. Detached cleanup keeps the default branch and branches
used by another open PR. Detached worktrees require the same PR URL chip on each
workspace recheck. Their exact HEAD is checked again before removal. It never touches blocked rows or worktrees without a PR, and
repeated runs are harmless.

Report what was cleaned up, including any sessions or busy terminals that closing
a workspace ended, and every skipped row with its reason. Do not work around a
skip with manual `workspace.close`, `git worktree remove --force`, or branch
deletion.

## Clean up or close one task from Toastty

A task space created by `worktree-create` carries a cleanup hook that runs
`scripts/worktree-status.py --cleanup-workspace` for that one workspace, with
`TOASTTY_WORKSPACE_ID` set. The Clean Up button in the workspace header and on
the task space row, the Task Spaces header's clean-up icon, and
`workspace.task.cleanup` all run it. It applies the same guards as
`--cleanup-merged` and reports through its exit status: 0 cleaned, 3 skipped
with the reason as the last line printed, anything else failed. A PR that has
not merged yet is a skip, so Clean Up on a task that `worktree-done` just
accepted waits for the merge; run it again later.

The close hook runs `scripts/worktree-status.py --close-workspace` the same way,
from the Close Task… menu item or `workspace.task.close`, to abandon a task: it
closes an open PR on GitHub, then removes the worktree and closes the workspace
with the same guards, and keeps the branch on GitHub so the PR can be reopened.
It refuses a merged PR (use Clean Up) and a branch whose commits exist only
locally.

## Changes to this workflow

Run `python3 scripts/test_worktree_status.py`. It uses disposable Git
repositories with fake `gh` and Toastty commands, and covers each cleanup guard.
