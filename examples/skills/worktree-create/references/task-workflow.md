# Task session workflow

This session owns the task from planning through implementation, testing and
user acceptance. The coordinator owns integration and cleanup. Read repository
instructions and use its required review and verification workflows.

## Planning and context

Check the actual working directory and branch against the task record before
making changes. For a fork, use the inherited discussion and existing artifacts;
do not recreate settled design from a shortened summary. Current launch paths
and ownership supersede historical paths in that discussion. Only carry prior
authorization within the assigned task's scope.

In planning mode, investigate and propose a design, preserving decisions in the
task's plan as they are made. Wait for implementation authorization. An explicit
implementation request already supplies that authorization; do not ask again.
Use subagents only where permitted and useful, with bounded ownership and an
explicit return route. Select model/effort for their actual task independently.

## Implementation and readiness

For repositories using PRs, create or reuse one draft PR on the authorized remote
and base. Own its implementation and subsequent fixes. Commit only task changes;
keep local handoffs, queue state and machine/session metadata out of product
commits and public PRs. Local-only work can be planned and implemented normally,
but the current automatic completion queue requires a PR; report that limit.

Describe the resulting behavior, decisions, tests, limitations, dependencies and
human testing steps in the PR. Complete repository-required independent review
and automated validation for the actual source tip, then record
`ValidatedCommit: <full SHA>` and mark the PR ready for review. External approvals
remain merge gates. A ready PR is available for the user's testing; it is not
user acceptance or merge authorization.

Use the registered helper to record readiness and attach the PR:

```bash
python3 "$TASKS" --repo "$REPO" ready --task "$TASK" --pr "$PR" \
  --validated-sha "$VALIDATED_SHA" --evidence "$CHECKS"
```

The user reviews/tests this version in the task workspace. Where practical,
prepare the documented local development environment and open relevant pages
or verification media there. Record exact service identities and shutdown steps
so the coordinator can safely clean up later. Do not launch a forbidden local
GUI or production environment merely to make a preview available.

When visual artifacts support verification, open them in the task workspace's
browser panels and verify they display the intended image or playable video.
A Markdown link or successful panel creation is not display verification.
Refresh regenerated artifacts and report unavailable media honestly.

The user's `worktree-done` request submits acceptance of this exact version.
Never submit it automatically because a test passed or your implementation ended.
After acceptance stop writing. If the user requests further changes, reopen the
record before editing; merging or landed tasks must be reconciled first. Changed
heads need new checks/review and renewed user acceptance. On any resume, check
whether the task already landed or was removed before continuing. If the managed
session ID changed, verify live workspace/panel identity and update the record
using `rebind --task <id> --previous-session <old> --session <new>
--workspace <same-workspace> --panel <new-panel> --socket <same-socket>`.
Reopen an accepted task before rebinding for further work. Never redirect a
record to a different workspace or app instance based only on its title.

## Workspace status

Maintain only `task-status` and `github-pr` annotations. Use `Planning`, `Working`,
`Validating`, `Needs attention`, and `Ready for your testing` as appropriate.
Reuse existing keys/colors and verified PR URLs. Do not create or maintain a
`git-branch` annotation; the workspace name already identifies the task.
Annotations are displays, not readiness evidence. Report failed annotation writes
without broadening scope. A Scratchpad is optional and does not replace records.

## Coordinator replies

The coordinator may send task-scoped findings to the exact managed session.
Keep fixes within the user's approved behavior. Before replying, verify the
recorded coordinator instance/panel/session and use `terminal.send-text` with
`expectedSessionID` and `submit=true`. Include the task, exact commit, checks and
blockers. Do not grant new authority in a status message. If delivery fails,
preserve the task record and report it rather than redirecting the reply.
