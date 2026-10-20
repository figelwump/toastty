# Personal task workflow

Starting a task in its own Git worktree is built into Toastty: the shipped
`toastty-task-start` skill moves a task into a worktree with
`toastty task start-work`, as [Tasks](../../docs/tasks.md#work-in-a-git-worktree)
describes. These two packages finish the work. Install them together:

- [worktree-done](worktree-done/SKILL.md) accepts the version the user reviewed
  and turns on auto-merge for its PR, so GitHub merges it when required checks pass.
- [worktree-cleanup](worktree-cleanup/SKILL.md) reports which task PRs are ready,
  merges the ones the user names, and cleans up worktrees whose PR has merged.

These are opt-in personal skills, not automatically loaded repository instructions.
Release and deployment management are outside this workflow.

## Typical use

A task's agent designs, implements, verifies, and publishes a PR in its own
worktree and task space. After testing or reviewing the result there, invoke `worktree-done` in
that workspace. It checks that the worktree matches the PR, enables auto-merge,
and marks the workspace done, which its task space row shows as a check; it never
closes its own workspace.

Later, from the project workspace, invoke `worktree-cleanup`. It lists ready,
merged, and blocked PRs, merges any you name, and for merged PRs closes the task
workspace, removes the worktree, and deletes the branches. Closing the workspace
ends any agent sessions and running commands in it, and cleanup reports what it
ended. It skips a workspace with unsaved documents and reports it instead. A
workspace-scoped session sees only some workspaces, so cleanup refuses to run
there. Clear that session's scope when asked, or run cleanup from a new session.

Workspaces show a PR chip. `worktree-done` marks the workspace done once the
user accepts the PR.

## Repository settings

`worktree-done` relies on GitHub auto-merge. Turn on auto-merge for the repository
and make the checks that must pass before merging required on the default branch;
without a required check, auto-merge lands a PR as soon as it has no conflicts.
Turning on automatic branch deletion lets GitHub retarget stacked PRs when their
base merges.

## Install or migrate

Toastty bundles these packages with the app. Ask an agent in a Toastty pane to
set up the task finishing workflow, during the onboarding's "Pick a workflow"
step or any time later. It reads `"$TOASTTY_CLI_PATH" setup guide --topic
workflows`, which prints where the bundled copies are, asks what to adapt (base
branch, PR flow, verification commands, models), and copies the adapted packages
into `~/.toastty/skills/` after you approve. It does not overwrite an existing
copy without asking.

You can also copy `worktree-done/` and `worktree-cleanup/` from this directory to `~/.toastty/skills/` by hand, for example to pick up
changes newer than your installed app. Preserve any personal model preferences or
repository customizations when replacing an existing package. The earlier
`worktree-create` and `coordinator` packages are retired; a personal copy of
`worktree-create` still works, but tasks no longer need it.

Use real directories; Toastty rejects symlinked user skill packages. Scripts
resolve relative to their loaded package snapshot. `TOASTTY_SKILLS_ROOT` refers to
the shipped plugin, not these personal skills.

Check discovery with `"$TOASTTY_CLI_PATH" setup skills list`. Updated packages load
in newly launched managed sessions. Codex exposes them as
`toastty-user:worktree-done` and `toastty-user:worktree-cleanup`. The
`workspace.list` query that cleanup uses requires an app build that exposes it;
skill installation does not update the running app.

## Verification

Run `python3 examples/skills/worktree-cleanup/scripts/test_worktree_status.py`
locally. It uses disposable Git repositories with fake `gh` and Toastty commands.
Validate both skills with the skill validator.

See [User-created skills](../../docs/running-agents.md#user-created-skills) for
discovery, immutable snapshots and management controls.
