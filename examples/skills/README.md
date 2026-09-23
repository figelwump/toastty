# Personal task workflow

Install these three packages together:

- [worktree-create](worktree-create/SKILL.md) creates a named task workspace and
  Git worktree. Start a fresh conversation for planning, or fork an existing
  Codex/Claude discussion into the worktree for continuation.
- [worktree-done](worktree-done/SKILL.md) records the user's acceptance of an exact
  reviewed version and queues it for integration and cleanup.
- [coordinator](coordinator/SKILL.md) watches registered tasks, checks dependencies,
  assesses accepted changes and merges, verifies and cleans each eligible task.

These are opt-in personal skills, not automatically loaded repository instructions.
The coordinator contains the integration/cleanup procedure formerly provided by
`finisher`; the separate `project-orchestrator` workflow is no longer needed.
Release and deployment management are outside this workflow.

## Typical use

Keep one coordinator workspace per repository. Invoke `worktree-create` there
with a brief task description, do detailed design in the task workspace, and tell
that same agent when to implement. After testing/reviewing the result, invoke
`worktree-done`. The coordinator processes accepted tasks in dependency order
and closes each task workspace/removes its worktree after verified integration.

When detailed planning already happened in another conversation, use the
launcher's `--fork-from-session` option. This requires updated Toastty
`agent.launch` capabilities, a verified native source session, and the same
Codex/Claude provider. It creates an independent child conversation with an
explicit worktree cwd; it does not move the parent or transfer future messages.
No summary-only fallback silently replaces a requested fork. Provider context
limits and compaction still apply.

New tasks default to planning. Explicit implementation requests retain their
authorization and use implementation mode. Session rows show live agent status;
workspaces show a PR annotation when one exists. The launcher adds no task or
branch chip.

## Local queue and waiting

The coordinator's `scripts/tasks.py` helper keeps private records under
`~/.toastty/task-state/<repository-id>/queue.json`. Repository identity comes from the
canonical shared Git directory, so worktrees in one clone share the queue.
It is local to this machine, not a remote queue. Use `--state-root` consistently
for disposable tests or isolated app instances.

The helper records task identity, readiness, explicit acceptance, dependencies,
integration intent and landed/verified/cleanup results. Atomic writes and locks
protect records; a durable coordinator owner prevents cooperating sessions from
starting competing integrations. GitHub and Git remain authoritative for PR
heads, checks and actual merges. A new source head requires renewed acceptance.

`tasks.py wait` is a bounded foreground command. It observes record and relevant
PR/check changes and returns control to the coordinator; it never merges or
deletes anything. Lost messages do not lose requests. An exited coordinator does
not keep processing; restarting it reconciles unfinished records. No daemon,
scheduler or deployment engine is installed.

## Install or migrate

Copy `worktree-create/`, `worktree-done/`, and `coordinator/` from this directory
to `~/.toastty/skills/`. Preserve any personal model preferences or repository
customizations when replacing an existing package. Retire the old personal
`finisher` and `project-orchestrator` packages from that discovery directory once
their relevant custom rules have been carried into the coordinator reference.

Use real directories; Toastty rejects symlinked user skill packages. Scripts
resolve relative to their loaded package snapshot. The three packages must remain
siblings because worktree skills use the coordinator's shared helper.
`TOASTTY_SKILLS_ROOT` refers to the shipped plugin, not these personal skills.

Check discovery with `"$TOASTTY_CLI_PATH" setup skills list`. Updated packages load
in newly launched managed sessions. Codex exposes them as
`toastty-user:worktree-create`, `toastty-user:worktree-done`, and
`toastty-user:coordinator`. Fork and additional-directory launch options require
an app build that exposes those capabilities; skill installation does not update
the running app.

## Verification

Run `python3 examples/skills/coordinator/scripts/test_tasks.py` locally against
disposable Git repositories and mocked GitHub responses. Launcher and structured
fork coverage lives in the app test suite. Follow the repository's verification
guide for those checks. Validate all three skills with the skill validator.

See [User-created skills](../../docs/running-agents.md#user-created-skills) for
discovery, immutable snapshots and management controls.
