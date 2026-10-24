---
name: toastty-task-merge
description: Use in a Toastty-managed task session when Toastty asks you to merge the task's pull request (its Merge button sends "Use the toastty-task-merge skill."), when the user says "merge it", or when a coordinating task merges its child tasks. Checks review threads, merge prerequisites, tasks that must land first, and CI, then merges with `toastty task merge`, or reports what blocks the merge.
---

# Toastty Task Merge

Toastty's Merge button, or the user saying "merge it", is the user's acceptance
of the pull request as it is now. Do not ask the user again. Your job is to check
what the user cannot see at a glance, then either merge or report what blocks
the merge. Toastty does the merge itself: `toastty task merge` merges at the
commit you checked, waits for GitHub's checks if they still run, never turns on
auto-merge, and closes the task space and removes its worktree after your turn
ends. Do not merge with `gh`, close this workspace, or remove the worktree.

Run the commands below with `"$TOASTTY_CLI_PATH"`. If it is not set, report that
this skill must run inside a Toastty-managed agent session, and stop.

When the request includes a review ID, intent ID and approved commit/destination, keep that
exact change throughout the procedure. Follow the repository's own merge
guidance and additional skills. A different head or destination needs a new review; do not update
or push the branch as part of this approval. Pass the intent with the final
command as `--review-intent <intent-id>`. The app refuses a missing or mismatched intent for a saved review approval.

## Check the pull request

Work in this task's checkout (`git rev-parse --show-toplevel`). Read the pull
request with
`gh pr view --json number,url,state,isDraft,headRefOid,baseRefName,mergeStateStatus,statusCheckRollup,body`.
Stop and report, without merging, when:

- there is no pull request, or it is closed or already merged;
- `git status --porcelain` shows uncommitted or untracked changes;
- after `git fetch`, local `HEAD` differs from `headRefOid`. Commits the user
  has not seen need their review first; do not commit or push as part of a merge;
- a required check failed. Checks that are still running do not block: Toastty
  waits for them;
- the base is not the repository's default branch. The base pull request merges
  first, and GitHub then retargets this one;
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
  resolve threads or change code here.

## Check tasks that must land first

Read this task with `"$TOASTTY_CLI_PATH" task get`. When it has a
`parentTaskID`, or the description names other tasks or pull requests this one
builds on, check them with `"$TOASTTY_CLI_PATH" task get <task-id>` and
`gh pr view`. A dependency that has not merged blocks this merge.

## Merge or report

If nothing blocks, run:

```bash
"$TOASTTY_CLI_PATH" task merge --head <headRefOid>
```

For a review request, require `headRefOid` to equal its approved commit, and add
`--review-intent <intent-id>`. It returns at once. Report the pull request and
commit as an accepted merge request; delivery is not proof that it merged.
For a review request, report it before ending the turn:

```bash
"$TOASTTY_CLI_PATH" coordinator review report <review-id> --intent <intent-id> \
  --outcome queued --detail "Toastty accepted the merge request for the approved commit."
```

Toastty confirms the PR state separately. Then end your turn and run nothing
else: Toastty cleans up after this turn ends.

If something blocks, report each blocker with its link and end your turn. Do
not run `task merge`. The task then waits for the user in the Tasks view, who can
fix the blocker and press Merge again, or choose Merge Without Checks.
For a review request, also use `coordinator review report` with its intent ID,
`--outcome blocked` and the concrete reason before ending the turn. Use
`--outcome headChanged` when the approved version changed. Do not report a
merge as confirmed merely because its command returned.

If `task merge` refuses because the user cancelled the merge, do not retry it.

## Coordinating tasks

A task that coordinates child tasks merges them in dependency order. List them
with `"$TOASTTY_CLI_PATH" task list --parent <this-task-id>`. For each child,
check it as above from its own pull request and worktree, then run
`"$TOASTTY_CLI_PATH" task merge <child-task-id> --head <sha>`. Wait for one
child's merge before you merge a child that builds on it, for example with
`"$TOASTTY_CLI_PATH" task watch <child-task-id> --until merged` where that
command exists.
