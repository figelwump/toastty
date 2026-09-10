# Personal skill examples

These complete packages show how to build your own development workflows on
Toastty's built-in app-control, Scratchpad, and document capabilities. They are
opt-in examples, not shipped skills or automatically loaded repository skills.

- [worktree-create](worktree-create/SKILL.md) creates a worktree, preserves the
  task intent and local resource identity, launches a scoped child workspace,
  and guides implementation through review, verification, and a PR handoff. The
  child uses subagents and selects models and reasoning levels as appropriate,
  and maintains workspace chips for the branch, task status, and PR.
- [project-orchestrator](project-orchestrator/SKILL.md) watches the project's PRs
  and assigned local tasks during a working session, maintains a Scratchpad
  dashboard, reviews interactions, and coordinates authorized integration,
  pushing, deployment, and cleanup through repository workflows.
- [worktree-done](worktree-done/SKILL.md) assesses tasks from a session outside
  the task, verifies authorized integration, and performs authorized cleanup.
  Without a named target, it discovers open PRs and local worktrees with open
  Toastty workspaces in the current repository. Review-only requests stop at
  the report.

Before creating a worktree, the launcher honors an explicit base or continuation.
Otherwise it fetches the intended landing branch, resolves any local-only or
divergent commits against the task intent, and selects the base. It passes a
pinned commit to the helper and records that choice in the handoff; it
does not pull into or rewrite the parent checkout. Fetch failures require an
explicitly accepted fallback.

## PR handoff and project coordination

For implementation work in repositories that use PRs, the default is one draft
PR per worktree. The child owns implementation, required agent review/CI, and
subsequent fixes. Its PR explains intent, decisions, verification, human testing,
dependencies, and deployment implications. Once required agent review and
automated checks cover the committed tip, the child records `ValidatedCommit`
and marks the PR ready for review to signal readiness for coordinator assessment.
Rework returns the PR to draft and invalidates old readiness. External approvals
remain separate merge gates. Human testing follows deployment unless the user
explicitly requested a pre-merge manual check.
Local-only work uses an equivalent durable task note. Child Scratchpads are optional.

Run one project coordinator while you work. It can assess design and interactions
across tasks, return authorized fixes to task owners, and maintain a dashboard
showing Working, Validating, Ready to merge, Merged awaiting deployment, and
Complete. The dashboard also shows blockers, partial deployments, synchronization
status, and when its evidence was last refreshed. PRs and existing release records
supply shared evidence; a small local coordination note preserves private resource
identities and pending decisions. The original parent sessions need not remain active.

The coordinator accounts for relevant local commits and remote work, including
changes already merged but not yet deployed. It follows the repository's review
and integration rules before pushing eligible local work, recognizes changes
already landed through PR merges, and uses existing release tooling to prepare a
combined plan with exact revisions, targets, and order. It does not automatically
publish every local branch or treat a partial release as completion.

Use `worktree-done` for a one-off assessment or authorized integration and cleanup,
or let the coordinator invoke it within its assigned authority. A request to watch
or review does not authorize PR comments, agent instructions, merges, pushes,
cleanup, or production changes. Existing authorization persists within its scope.
The coordinator is a skill-driven agent session, not a service installed by these
examples; monitoring ends when its session stops. On resume it reobserves state
from durable records. Repository-specific review, verification, and release rules
remain authoritative.

The worktree handoff can bind an optional `toastty-watcher` command when it is
already installed. That command is not included in these example packages.

## Copy and customize

From the repository root, copy whichever packages you want. This writes only
the named personal skill folders and refuses to overwrite existing copies:

```bash
python3 - <<'PY'
from pathlib import Path
import shutil

source = Path("examples/skills")
destination = Path.home() / ".toastty/skills"
names = ["worktree-create", "worktree-done", "project-orchestrator"]
for name in names:
    target = destination / name
    if target.exists() or target.is_symlink():
        raise SystemExit(f"Already exists; keep or compare your copy first: {target}")
destination.mkdir(parents=True, exist_ok=True)
for name in names:
    shutil.copytree(source / name, destination / name)
PY
```

Use real copies: Toastty rejects symlinks in user skill packages. Edit your copies
under `~/.toastty/skills`; repository updates do not replace your customizations.
The folder name and the frontmatter `name` must match if you rename a skill.

Run `"$TOASTTY_CLI_PATH" setup skills list` in a Toastty-managed session for a
read-only inventory, then start a new managed session to load the new packages.
Codex exposes them as `toastty-user:worktree-create`,
`toastty-user:worktree-done`, and `toastty-user:project-orchestrator`. An older
Toastty build may still expose its shipped
`toastty:worktree-create`; choose the personal version until the app is updated.

## Build your own version

The package's `SKILL.md` describes the workflow; `scripts/` contains deterministic
helpers. Reference helpers relative to the loaded skill file so a copied plugin
snapshot remains self-contained. `TOASTTY_SKILLS_ROOT` points to the built-in
plugin, not your personal package. Use the built-in `toastty-capabilities` skill
to discover the running app's commands instead of duplicating its API catalog.

Adjust the workflow to your projects: branch naming, setup, when to use persistent
goals, how to present progress, review and testing requirements, and when to hand
control back to the user. Set the coordinator's polling interval, assigned tasks,
and integration/release authority to fit your working session. Keep explicit
merge/cleanup authorization and preserve uncommitted work when customizing these examples. Repository instructions still
apply. Native goals depend on the selected agent runtime; the examples do not
provide a separate supervisor.

See [User-created skills](../../docs/running-agents.md#user-created-skills) for
package limits, discovery, snapshots, and management controls.
