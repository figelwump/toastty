---
name: toastty-task-merge
description: Use in a Toastty-managed task session when Toastty asks you to merge the task's pull request (its Merge button sends "Use the toastty-task-merge skill."), when the user says "merge it", or when a coordinating task merges its child tasks. Checks review threads, merge prerequisites, tasks that must land first, and CI, then merges with `toastty task merge`, or reports what blocks the merge.
---

# Toastty Task Merge

Toastty's Merge button, or the user saying "merge it", is the user's acceptance
of the pull request as it is now. Do not ask the user again. Your job is to check
what the user cannot see at a glance, resolve routine Git merge conflicts, then
either merge or report what blocks the merge. Toastty does the merge itself:
`toastty task merge` merges at the commit you checked, waits for GitHub's checks
if they still run, never turns on
auto-merge, and closes the task space and removes its worktree after your turn
ends. Do not merge with `gh`, close this workspace, or remove the worktree.

Run the commands below with `"$TOASTTY_CLI_PATH"`. If it is not set, report that
this skill must run inside a Toastty-managed agent session, and stop.

## Check the pull request

Work in this task's checkout (`git rev-parse --show-toplevel`). Read the pull
request with
`gh pr view --json number,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,statusCheckRollup,reviewDecision,body`.
Stop and report, without merging, when:

- there is no pull request, or it is closed or already merged;
- `git status --porcelain` shows uncommitted or untracked changes;
- after `git fetch`, local `HEAD` differs from `headRefOid` before you start
  conflict resolution. Do not include unseen work or overwrite another push.
  Commits you create under the conflict-resolution steps below are authorized
  by this merge request;
- a required check failed. Checks that are still running do not block: Toastty
  waits for them;
- `reviewDecision` is `REVIEW_REQUIRED` or `CHANGES_REQUESTED`. An empty value
  alone is not a missing approval;
- the description says something must happen before this pull request
  merges, such as another pull request merging first or an artifact being
  rebuilt. Read the whole description and judge what each step means: a
  rollout or deploy plan for after the merge does not block it. Name each
  prerequisite. Green CI or a merged linked pull request does not confirm
  them; the user does;
- a review thread is unresolved. Query `reviewThreads` (`id`, `isResolved`, the
  first comment's `url`) with `gh api graphql`, fetch every page, and require the
  last page to have `hasNextPage: false`. A failed or partial query blocks the
  merge. Report each unresolved thread's link, including outdated ones. Do not
  mark threads resolved, dismiss reviews, or implement new review requests
  just to pass these gates.
  This review-thread rule does not prohibit Git merge conflict resolution.

Merge into the pull request's current `baseRefName`, including a feature
branch. The base branch does not need to merge into the default branch first.
Do not retarget the pull request as part of this check.

## Check tasks that must land first

Read this task with `"$TOASTTY_CLI_PATH" task get`. Check tasks or pull requests
that its description names as merge prerequisites with
`"$TOASTTY_CLI_PATH" task get <task-id>` and `gh pr view`. A prerequisite that
has not merged blocks this merge. Check that where it merged satisfies what
the description requires.

`parentTaskID` records which task created this one; it does not by itself
require that task to merge first. A child may merge into its parent's feature
branch while the parent's pull request stays open. Read the parent task and
its pull request when present. If the child includes the parent's unmerged
work but targets another branch, stop and report that dependency. Do not land
that work outside the parent's branch before its prerequisite merge.

## Resolve Git merge conflicts

After the other merge checks pass, resolve Git conflicts or satisfy a required
up-to-date rule that prevents merging. A base branch advancing alone does not
require integration. Recheck an unknown merge state before changing the branch.
The merge request authorizes this routine resolution without another approval.
Fetch the intended base branch,
record the fetched commit and the PR head you checked, and merge the fetched
base into this task branch. Preserve both changes' intended behavior and inspect
overlapping changes even when Git merges them automatically. Do not force-push
or retarget the PR.

Resolve the conflicts, follow the repository's review and verification rules,
and commit the scoped resolution. Before pushing, confirm that the remote PR
head still equals the head you recorded; stop if someone else changed it. Push
without force to the verified PR head remote and `headRefName`, then confirm
that the PR head equals your local commit. Recheck
CI, required approvals, every review-thread page, and merge prerequisites for
that new head. Continue with `task merge --head <new-head>` without asking the
user to accept the routine resolution again.
If the push invalidates a required approval, report that blocker and stop.

Ask only when the resolution needs a material scope or behavior decision that
the existing task does not answer. Report failed checks or other blockers;
do not bypass them to complete a merge.

## Merge or report

If nothing blocks, run:

```bash
"$TOASTTY_CLI_PATH" task merge --head <headRefOid>
```

It returns at once. Report the pull request, the commit, and whether Toastty
merges it now or after the checks that are still running. Then end your turn
and run nothing else: Toastty cleans up after this turn ends.

If something blocks, report each blocker with its link and end your turn. Do
not run `task merge`. The task then waits for the user in the Tasks view, who can
fix the blocker and press Merge again, or choose Merge Without Checks.

If `task merge` refuses because the user cancelled the merge, do not retry it.

## Coordinating tasks

A task that coordinates child tasks merges them in dependency order. List them
with `"$TOASTTY_CLI_PATH" task list --parent <this-task-id>`. For each child,
check it as above from its own pull request and worktree, then run
`"$TOASTTY_CLI_PATH" task merge <child-task-id> --head <sha>`. Wait for one
child's merge before you merge a child that builds on it, for example with
`"$TOASTTY_CLI_PATH" task watch <child-task-id> --until merged` where that
command exists.
