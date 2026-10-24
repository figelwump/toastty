# Review packets for tasks

Status: implemented. First of five coordinator PRs into `feat/task-system`.

## Goal

When a task's work is ready, its agent publishes a review packet: what changed,
the one thing to look at, the checks it ran, what it did not verify, and
screenshots. The coordinator's chat and the sidebar's Needs you items (later
PRs) show these packets. Toastty stores them apart from the worktree, so they
survive cleanup.

## Behavior

- `toastty task packet publish [<task-id>] --file packet.json [--screenshot <path> ...]`
  checks the packet, copies the screenshots, and stores the next version. It
  sets `packetVersion` and `packetHeadCommit` on the task record and
  `readyForReviewAt`, so the task waits in Needs you as after
  `task ready-for-review`. The packet adds no stage.
- `toastty task packet get [<task-id>] [--version <n>]` returns a stored packet
  with each screenshot's path, and `stale` when the worktree's `HEAD` moved
  past the newest packet's commit.
- Without a task ID, both act on the calling agent's own task.
- Refused, storing nothing: no `summary` or `look_at`; no `not_verified` (`[]`
  must be written out); an unknown key; a wrong type; a screenshot without its
  file, or a file the packet does not name.
- The shipped `toastty-task-verify` skill tells an agent how to write a good
  packet. `verify_skill` in `[defaults]` or a `[workspace."…"]` table names a
  project's own skill; `task get` reports the result as `verifySkill`, and the
  `toastty-task-start` skill points agents to it. Toastty sends no message for
  it.

## Data

- `TaskPacket` (`Sources/Core/Tasks/TaskPacket.swift`): the agent's fields in
  snake case, plus `task_id`, `version`, `created_at`, `head_commit`.
  `TaskPacket.parseDraft` validates the agent's JSON; `matchScreenshots` pairs
  names with files.
- `TaskPacketStore` writes `~/.toastty/task-packets/<task-id>/v<N>/packet.json`
  with the screenshots beside it. The version directory is made without
  intermediate directories, so two publishes at once never share a number.
  Versions never repeat, even when the record knows a version the disk lost.
- `TaskRecord.packetVersion` and `packetHeadCommit` are optional, so older
  records decode unchanged.
- Packets follow attachment retention: removed when the task is deleted, and a
  week after the task is Done or Archived with its task space closed.

## Decisions

- `task.packet.get` is an action, not a query, because it reads git for
  staleness and queries run synchronously. It reports `didMutateState: false`.
- Staleness is computed on read from the worktree's `HEAD`, not stored. A task
  without a worktree, or whose worktree was removed, is never stale.
- `pair` is `before`, `after` or `null`; a before and an after with the same
  `width` form a pair. This keeps pairing implicit and avoids cross-references
  between screenshot names.
- The CLI sends the packet file's text; the app parses it, so socket callers
  get the same checks. An object is accepted too.

## Validation

- Core: `Tests/Core/TaskPacketTests.swift` (validation, matching, storage and
  versioning, staleness), `Tests/Core/TasksConfigFileTests.swift`.
- App: `Tests/App/TaskPacketAppControlTests.swift` (publish, versions, Needs
  you, refusals, staleness against a real git worktree, retention, delete).
- CLI: `Tests/CLI/ToasttyCLITaskTests.swift`.
- Live: `scripts/automation/remote-task-packet-check.py`, through
  `sv exec -- scripts/remote/validate.sh --require-remote --validation-command 'python3 scripts/automation/remote-task-packet-check.py'`.
