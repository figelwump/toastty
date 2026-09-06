# Personal skill examples

These complete packages show how to build your own development workflows on
Toastty's built-in app-control, Scratchpad, and document capabilities. They are
opt-in examples, not shipped skills or automatically loaded repository skills.

- [worktree-create](worktree-create/SKILL.md) creates a worktree, preserves a
  handoff, launches a scoped child workspace, and guides the child through a
  native goal, review, automated checks, and readiness for human testing.
- [worktree-done](worktree-done/SKILL.md) lets the parent resolve the tested
  commit, integrate it using the repository's rules, verify the landed result,
  and perform authorized cleanup.

## Copy and customize

From the repository root, copy whichever packages you want. This writes only
the named personal skill folders and refuses to overwrite existing copies:

```bash
python3 - <<'PY'
from pathlib import Path
import shutil

source = Path("examples/skills")
destination = Path.home() / ".toastty/skills"
names = ["worktree-create", "worktree-done"]
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
Codex exposes them as `toastty-user:worktree-create` and
`toastty-user:worktree-done`. An older Toastty build may still expose its shipped
`toastty:worktree-create`; choose the personal version until the app is updated.

## Build your own version

The package's `SKILL.md` describes the workflow; `scripts/` contains deterministic
helpers. Reference helpers relative to the loaded skill file so a copied plugin
snapshot remains self-contained. `TOASTTY_SKILLS_ROOT` points to the built-in
plugin, not your personal package. Use the built-in `toastty-capabilities` skill
to discover the running app's commands instead of duplicating its API catalog.

Adjust the workflow to your projects: branch naming, setup, when to use persistent
goals, how to present progress, review and testing requirements, and when to hand
control back to the user. Keep explicit merge/cleanup authorization and preserve
uncommitted work when customizing these examples. Repository instructions still
apply. Native goals depend on the selected agent runtime; the examples do not
provide a separate supervisor.

See [User-created skills](../../docs/running-agents.md#user-created-skills) for
package limits, discovery, snapshots, and management controls.
