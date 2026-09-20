# Integration and cleanup

This procedure runs in the coordinator, outside the task workspace and checkout.
The accepted task record supplies scope and exact source identity. Reuse current
review and verification evidence; perform missing checks under the repository's
instructions. Do not take over implementation just to satisfy cosmetic preferences.

## Assess the candidate

Match the record to the live PR repository/base/head and to the canonical local
worktree, branch and Toastty resource IDs. Read the PR's intent, constraints,
design, checks and `ValidatedCommit`, plus the user's accepted SHA. All source
identities must agree. A new commit invalidates acceptance, even if an agent says
the change is harmless. Reopen, revalidate and ask the user to accept the updated
version. Do not silently carry approval across a rebase or conflict resolution.

Review the diff in context: ownership, existing capabilities, contracts, failure
handling, data preservation, tests and documentation. Inspect related pending
tasks for missing dependencies, incompatible assumptions and required ordering.
Record the source SHA, destination SHA and relevant peer heads actually examined.
Git mergeability alone does not establish semantic compatibility. State access
limits and concrete risks; optional refactors do not become new merge gates.

Inspect browser evidence using `panel.browser.state` with the recorded panel
ID and a bounded polling deadline, following `toastty-capabilities`. The query
can start loading a background panel without selecting it. A detached host
can finish navigation, and a ready host only establishes window attachment.
Navigation completion does not prove visual correctness or video playback.
If the running app lacks navigation status or the deadline expires, record
the verification limit rather than changing the user's selection or focus.

For a particular interaction that inspection cannot resolve, use a disposable
integration checkout with the candidate and the changes expected to land first.
Run focused checks and record the exact commits and order. Do not mutate task
branches or test every possible combination. Preserve useful results and remove
only the disposable check's resources afterward.

Keep fixes with the task owner. The user's completion handoff allows a status or
blocking-finding reply to that exact managed session. Before `terminal.send-text`,
verify the recorded instance/panel/session and use `expectedSessionID` with
`submit=true`. Supply the coordinator's verified return route for requested
task-scoped replies directly in the request: instance, workspace, panel, session,
supported messaging action and any authorized scope addition. Keep instructions
model-neutral and defer review mechanics to the recipient's own instructions.
Require a completion or blocked reply naming the task, final commit, checks and
remaining blockers; a PR update alone is not that reply. If delivery fails,
inspect durable task state read-only and report the blocker, without redirecting
or bypassing a denial.
Any source change returns the task to the user for renewed acceptance.

## Merge and verify

Acquire queue ownership before beginning integration. Confirm the task owner has
stopped writing and capture source tip, dirty/untracked status, and fingerprints
of temporary task artifacts. Preserve unrelated edits and unpublished work.
Use a clean landing checkout or a separate integration checkout; never stash or
reset user changes to make room. Refresh the destination without discarding local
commits. Read the repository's required review, build, tests and merge policy.

Validate the candidate against the current destination before merging whenever
practical. The repository's required checks still apply to the landed result.
Immediately before merging, recheck source and destination and persist intent:

```bash
python3 "$TASKS" --repo "$REPO" begin --task "$TASK" \
  --owner "$TOASTTY_SESSION_ID" --expected-base "$DESTINATION_SHA"
```

Follow the repository's integration method. For GitHub, use its expected-head
guard (`gh pr merge --match-head-commit <accepted-sha>`) and required branch
protections. Reassess if the destination moved; the head guard alone does not pin
the base. Do not bypass required reviews or CI. A queued auto-merge is not a
completed merge. Reobserve the actual PR result and exact landed commit.

On restart, inspect every `integrating` record before issuing a merge again. A prior
request may already have succeeded. Confirm ordinary ancestry or, for squash/
rebase, PR merge correspondence and that the intended changes landed. Record
the actual result before cleaning anything:

```bash
python3 "$TASKS" --repo "$REPO" landed --task "$TASK" \
  --owner "$TOASTTY_SESSION_ID" --landing-sha "$LANDED_SHA"
```

Inspect the landed diff for accidental task artifacts. Run required generation,
build and affected tests/runtime checks against the actual result. Record exact
commands, targets, results and limitations, then mark integration verified:

```bash
python3 "$TASKS" --repo "$REPO" verified --task "$TASK" \
  --owner "$TOASTTY_SESSION_ID" --evidence "$VERIFICATION"
```

If verification fails, pause further merges and retain the task's workspace,
worktree and branch while arranging scoped corrections. Do not claim completion
or release dependents merely because GitHub reports merged. Integration is not
deployment; this workflow does not publish releases.

After verified integration, reassess eligible dependents against the new target.
A stacked dependent may need retargeting; resolve that before removing any branch
it uses as a base. If updating the dependent changes its head, require renewed
acceptance. Keep this limitation explicit instead of claiming automatic rebase
preserves human testing.

## Clean up this task now

Cleanup authority covers only resources owned by this accepted task. Assess
services, agent processes, documents, workspace, worktree and branch separately.
Inspect other tabs/sessions and unsaved documents before closing a workspace.
Do not remove shared environments, user data, or resources needed by another
task. A blocked resource need not prevent independent safe cleanup.

1. Recheck source/status/artifact contents against the captured values. Reconcile
   new edits before stopping the owner. Stop task-owned dev services and runtime
   instances through their recorded identities and supported shutdown paths.
2. Terminate task-owned agents through supported terminal controls and verify
   their processes exited. A session bookkeeping status is not proof of exit.
3. Close the task workspace using `toastty-capabilities` closing rules. Never
   override unsaved documents or close the coordinator's own workspace. If safe
   closure is unavailable, retain the worktree and report the specific blocker.
4. Inspect ignored as well as untracked content. Remove unchanged, confirmed
   disposable handoffs, scratch work and test artifacts. Preserve durable release
   records and user data. Do not classify files as disposable just because Git
   ignores them, and do not archive temporary task output by default.
5. Recheck exact paths and content immediately before removal. Use
   `git worktree remove <exact-path>` without `--force`, then `git branch -d`
   for a branch Git recognizes as merged. Never use force deletion. A branch
   retained after a squash merge does not require retaining the workspace or
   worktree; record that specific retained branch.

Move any required durable information out of temporary task files into the PR
or task record before deleting them. Preserve the small record of accepted and
landed SHAs and verification so a restart can distinguish completed integration
from pending cleanup. Record completed cleanup with:

```bash
python3 "$TASKS" --repo "$REPO" cleaned --task "$TASK" \
  --owner "$TOASTTY_SESSION_ID" --workspace-closed --branch-removed \
  --evidence "$CLEANUP_RESULT"
```

Use `--branch-retained "reason"` instead of `--branch-removed` when the branch
was deliberately retained. The helper verifies worktree/path and branch state;
the caller must verify workspace closure. On partial failure, report what completed and retry only
the remaining cleanup; do not merge again.
