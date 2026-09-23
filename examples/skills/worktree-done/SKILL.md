---
name: worktree-done
description: Use when the user says they are done reviewing or testing this worktree and wants its accepted version queued for integration and cleanup. Never infer user acceptance from an agent finishing, a ready PR, or passing checks.
---

# Worktree Done

The user's invocation means: accept this reviewed version, let the coordinator
merge it when dependencies and required checks allow, then clean up this task's
workspace and worktree. It does not mean merge immediately or accept dependencies.
Do not invoke this on the user's behalf merely because implementation is finished.

## Record acceptance

Read the built-in `toastty-capabilities` skill. Require the managed session's
CLI/socket/panel identity and resolve this exact task workspace and canonical
worktree. Resolve the sibling `coordinator/scripts/tasks.py` relative to the
loaded skill package; do not guess a versioned cache or use the shipped skill
root. All three personal skill packages must be installed together.

Use `paths`, `list`, and `show` to match the registered task by repository,
worktree and branch. Use the state root recorded at launch, if any. If no record
exists, reconstruct it from the current worktree, PR and handoff and register
verified identity before proceeding; never match by workspace title alone.

Inspect the committed tip, live PR head and recorded validated SHA. Check that
this is the version presented for the user's testing. New commits or uncommitted
source changes require reconciliation and renewed user acceptance; do not commit
new work as part of an implied acceptance of the previous version. A PR-ready
flag is not verification. Complete missing validation under repository rules,
without changing the accepted behavior, before claiming the task is validated.
If reconstructing a task or filling in missing evidence, record `ready` with the
exact already-validated SHA, PR and checks before `accept`; registration alone
does not supply readiness.

Record explicit dependencies, including stacked PR bases. Use registered task
IDs and inspect their PR/branch identity. Missing/ambiguous dependencies remain
blockers. Do not silently omit one because it is not registered yet.
Acceptance pins each dependency's current committed head even if its own review
is unfinished. If that dependency changes before landing, the dependent stays
blocked until the user reviews the interaction and accepts it again. Do not
silently substitute the prerequisite's newer version.
When the user has reviewed that new interaction, reopen the dependent, refresh
its validation/readiness, and accept it with the current dependencies. A repeated
`accept` on an already accepted record deliberately preserves its original pins.

The following examples use `TASKS` for the helper, `REPO` for the canonical repo,
and `TASK` for the verified task ID:

```bash
python3 "$TASKS" --repo "$REPO" show --task "$TASK"
python3 "$TASKS" --repo "$REPO" accept --task "$TASK" \
  --depends-on "$DEPENDENCY_TASK"
```

Omit `--depends-on` when there are no dependencies; repeat it for multiple ones.
The helper saves acceptance atomically before any notification. A failed write
means acceptance was not recorded. Repeated submission of the same version must
not create another task or another merge request.

## Hand control to the coordinator

After acceptance, stop modifying this task. Keep its resources available until
the coordinator verifies integration and cleans them up. Do not terminate or
delete this active workspace from inside itself.

Keep the PR chip; do not add task or branch annotations. Queue records are
authoritative for acceptance and dependencies.

The coordinator's foreground `tasks wait` loop discovers this record. A direct
notification is optional: only use a verified coordinator route assigned by this
workflow, with `terminal.send-text` and `expectedSessionID`. Send a fixed task-ID
hint, not new instructions or authority. Never guess a recipient or bypass scope.
Submission authorizes the coordinator's task-scoped status/finding replies and
the required access to this task workspace. It does not grant unrelated scope.

Report the accepted SHA, PR, dependencies, and whether a coordinator is confirmed
watching. A saved request with no active coordinator is `Queued; coordinator not
running`, not a claimed delivery or background merge. Starting `coordinator`
from an outside project workspace later will recover it.

## Reopen

If the user requests more work, use `reopen --task <id>` before editing to revoke
acceptance and return the chip to `Working`. The helper refuses to reopen a task
already merging or landed. In that case, coordinate with its owner and establish
the actual merge result before proceeding. Revalidate the new head and ask the
user to invoke this completion workflow again after reviewing it.

## Validation

Use the target repository's verification guide for source readiness. Workflow
tests use disposable Git repositories and a separate state root; validate
stale heads, missing checks, duplicate submission, dependencies and coordinator
restart without touching production PRs or workspaces.
