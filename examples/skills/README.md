# Personal task workflow

Install these three packages together:

- [worktree-create](worktree-create/SKILL.md) creates a named task workspace and
  Git worktree. Start a fresh conversation for planning, or fork an existing
  Codex/Claude discussion into the worktree for continuation.
- [worktree-done](worktree-done/SKILL.md) accepts the version the user reviewed
  and turns on auto-merge for its PR, so GitHub merges it when required checks pass.
- [worktree-cleanup](worktree-cleanup/SKILL.md) reports which task PRs are ready,
  merges the ones the user names, and cleans up worktrees whose PR has merged.

These are opt-in personal skills, not automatically loaded repository instructions.
Release and deployment management are outside this workflow.

## Typical use

From a project workspace, invoke `worktree-create` with a brief task description.
The task session designs, implements, verifies, and publishes a PR in its own
workspace. After testing or reviewing the result there, invoke `worktree-done` in
that workspace. It checks that the worktree matches the PR and enables auto-merge;
it never closes its own workspace.

Later, from the project workspace, invoke `worktree-cleanup`. It lists ready,
merged, and blocked PRs, merges any you name, and for merged PRs closes the task
workspace, removes the worktree, and deletes the branches. It skips a workspace
that still has an agent session, a busy terminal, or unsaved documents and reports
it instead. A workspace-scoped session sees only some workspaces, so cleanup
refuses to run there; `worktree-create` scopes the session that launches a task.
Clear that session's scope when asked, or run cleanup from a new session.

When detailed planning already happened in another conversation, use the
launcher's `--fork-from-session` option. This requires updated Toastty
`agent.launch` capabilities, a verified native source session, and the same
Codex/Claude provider. It creates an independent child conversation with an
explicit worktree cwd; it does not move the parent or transfer future messages.
No summary-only fallback silently replaces a requested fork. Provider context
limits and compaction still apply.

New tasks start implementing unless the request limits them to planning.
Workspaces show a PR chip; the launcher does not add task-status or branch chips.

## Repository settings

`worktree-done` relies on GitHub auto-merge. Turn on auto-merge for the repository
and make the checks that must pass before merging required on the default branch;
without a required check, auto-merge lands a PR as soon as it has no conflicts.
Turning on automatic branch deletion lets GitHub retarget stacked PRs when their
base merges.

## Install or migrate

Copy `worktree-create/`, `worktree-done/`, and `worktree-cleanup/` from this
directory to `~/.toastty/skills/`. Preserve any personal model preferences or
repository customizations when replacing an existing package. The earlier
`coordinator` package and its `~/.toastty/task-state/` queue are retired; remove
them from the discovery directory.

Use real directories; Toastty rejects symlinked user skill packages. Scripts
resolve relative to their loaded package snapshot. `TOASTTY_SKILLS_ROOT` refers to
the shipped plugin, not these personal skills.

Check discovery with `"$TOASTTY_CLI_PATH" setup skills list`. Updated packages load
in newly launched managed sessions. Codex exposes them as
`toastty-user:worktree-create`, `toastty-user:worktree-done`, and
`toastty-user:worktree-cleanup`. Fork and additional-directory launch options, and
the `workspace.list` query that cleanup uses, require an app build that exposes
them; skill installation does not update the running app.

## Verification

Run `python3 examples/skills/worktree-cleanup/scripts/test_worktree_status.py`
locally. It uses disposable Git repositories with fake `gh` and Toastty commands.
Launcher and structured fork coverage lives in the app test suite. Follow the
repository's verification guide for those checks. Validate all three skills with
the skill validator.

See [User-created skills](../../docs/running-agents.md#user-created-skills) for
discovery, immutable snapshots and management controls.
