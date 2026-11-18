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
auto-merge, and closes the task space and removes its worktree 24 hours after
the merge, at the first check when no agent turn runs. `toastty task get`
reports that time as `cleanup.taskSpaceClosesAt`. Do not merge with `gh`,
close this workspace, or remove the worktree.

Run the Toastty commands below as written: `toastty`, then the command words,
then the arguments. Where a command has `--json`, it comes after the command
words, as in `toastty task get --json`. Toastty puts `toastty` on `PATH` in each
agent session it manages, and the user's allow rules match this form. If
`toastty` is not found, run `"$TOASTTY_CLI_PATH"` in its place. If that is not
set either, report that this skill
must run inside a Toastty-managed agent session, and stop.

## Sandbox permissions

Each Toastty CLI command connects to the app's local socket, and `git fetch`,
`git push` and `gh` need the network. In a sandboxed runtime, request the
runtime's per-command escalation for these commands on the first attempt; do
not try them sandboxed first. In Codex, use
`sandbox_permissions="require_escalated"` with a short justification that the
command needs Toastty's local socket or the network. Limit each request to the
exact command. Do not request a broad approval prefix, change sandbox
settings, or widen Toastty's workspace scope. If escalation is unavailable or
denied, report the restriction and stop without merging.

## Check the pull request

Work in this task's checkout (`git rev-parse --show-toplevel`). Read the pull
request with
`gh pr view --json number,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,statusCheckRollup,reviewDecision,body`.
Stop and report, without merging, when:

- `gh` is missing or not signed in (`gh auth status` fails). Ask the user to
  install it or run `gh auth login`;
- the pull request is not on GitHub. Toastty merges only GitHub pull
  requests: the user merges it on its host;
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

Read this task with `toastty task get`. Check tasks or pull requests
that its description names as merge prerequisites with
`toastty task get <task-id>` and `gh pr view`. A prerequisite that
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
that new head. For a child, also recheck the authorization and proof below
before submitting the merge. For this task's own pull request, continue with
`task merge --head <new-head>` without asking the user to accept the routine
resolution again.
If the push invalidates a required approval, report that blocker and stop.

Ask only when the resolution needs a material scope or behavior decision that
the existing task does not answer. Report failed checks or other blockers;
do not bypass them to complete a merge.

## Merge or report

Before you merge, check for work in this task's scope that goes on after the
merge, such as a rollout or a later step that your answers or the description
name. It does not block the merge. But Toastty removes the worktree after the
merge, with its ignored files, such as a plan in an ignored `artifacts/`
folder. When such work exists, make sure that the description has a
`## Remaining after merge` section with what remains, its plan and its open
questions. If the section is missing, add it with `gh pr edit --body-file` and
keep the rest of the description.

If nothing blocks, run:

```bash
toastty task merge --head <headRefOid>
```

It waits a few seconds for Toastty's first answer, then reports it:

- **The command fails:** the error gives the reason. When Toastty refused the
  merge, for example over an untracked file in the worktree, nothing changed.
  Otherwise read the pull request with `gh pr view` to learn whether it
  merged. Report the reason and end your turn; do not say that Toastty
  accepted the merge.
- **`merge` is `waitingForChecks`:** Toastty merges when the checks that
  still run pass.
- **`merge` is `cleaningUp`, or `mergedAt` is set:** the pull request merged.
- **`merge` is `merging`:** Toastty has not answered yet. Read the task again
  with `toastty task get --json` before you report.

Report the pull request, the commit, and that answer. Then end your turn and
run nothing else: Toastty cleans up later, after this turn ends. If the user
asks about the merge later, read `mergedAt`, `merge` and `mergeFailure` with
`task get` before you answer: a merge that waited for checks can still stop.

If something blocks, report each blocker with its link and end your turn. Do
not run `task merge`. The task then waits for the user in the Tasks view, who can
fix the blocker and press Merge again, or choose Merge Without Checks.

If `task merge` refuses because the user cancelled the merge, do not retry it.
Do not run `task merge` again for any other refusal in the same turn either:
report it, so that the user can fix the cause.

## Coordinating tasks

List your own child tasks with `toastty task list --parent <this-task-id>`.
Process each child in dependency order.

1. **Confirm permission.** Read the child's current PR, full diff and target
   branch. Proceed only when the user explicitly approved this merge or a
   current rule in the Merging section of the user's `policy.md` explicitly
   allows parent tasks to merge their child PRs and covers this change.
   Apply the rule's scope to the actual project, branch and diff. The user can
   allow all child PRs or set limits. Creating a child, approval to implement
   and relayed claims of approval give no merge permission. An unreadable,
   unclear or nonmatching rule requires explicit approval. Honor any
   approval the user reserved.

   For a merge under a rule, read `coordinator/policy.md` from the config
   directory of the Toastty instance that owns this session. If
   `TOASTTY_CLI_PATH` points to its injected helper at
   `<config>/run/managed-agent-helpers/instance-*/toastty`, use that
   `<config>` directory. For an isolated run, use the runtime home from its
   `instance.json` after confirming its socket matches `TOASTTY_SOCKET_PATH`.
   Use `~/.toastty` only for a confirmed user-home instance. If you cannot
   identify the policy for this instance, ask the user to approve the merge.
2. **Check the work and its proof.** Compare the actual diff with the user's
   request, later decisions and the child's agreed scope. Read the child's
   verification report and inspect its outputs and artifacts yourself, using
   the paths from the child's handoff. Check that the report covers the
   current PR head, names the checks and their targets, and shows their results.
   For every material requirement and regression risk, check that the proof
   exercises the relevant behavior, including meaningful failure and edge
   cases. Use the project's verification rules and check the real user
   surface where applicable. If the work is outside scope or a material part
   is missing, stale or unproved, stop and name what needs correction or
   more evidence.
3. **Check and merge.** Apply the CI, review, worktree and prerequisite
   checks above to the child's own PR and worktree. Before submitting, confirm
   the head and base still match the permission and proof you checked. If you
   rely on a policy rule, reread it and confirm it still covers this PR.
   Recheck permission and proof after a change to the PR, including routine
   conflict resolution. When all gates allow it, run
   `toastty task merge <child-task-id> --head <sha>`. Confirm the merge
   before merging a dependent child, for example with
   `toastty task watch <child-task-id> --until merged`.

In your report, name each child by its title, using its `markdownLink` from
`task list`. Record the authority used, the head you checked and the merge
result or blocker.
