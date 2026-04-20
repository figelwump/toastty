---
name: worktree-create
description: Use this skill when the user asks for /worktree-create or wants to spin the current Toastty thread into a new git worktree and Toastty workspace, bootstrap that worktree for builds, persist a handoff or plan file, and launch a new cdx session in the new workspace.
---

# Worktree Create

Use this workflow when the current thread should continue in a fresh Toastty worktree and workspace.

## Core flow

1. Pick a short slug for the task.
   - Prefer an explicit user-provided name.
   - Otherwise derive a hyphen-case slug from the task, such as `browser-link-routing`.
2. Confirm the Toastty-managed environment is present before using the launch helper.
   - `TOASTTY_CLI_PATH` must be set.
   - The skill is designed for a Toastty-managed agent session, not an arbitrary shell.
3. Create and bootstrap the new worktree with the bundled helper:

```bash
.agents/skills/worktree-create/scripts/create-toastty-worktree.sh --slug browser-link-routing --json
```

4. Parse the helper output to get `worktree_path` and `handoff_path`.
5. Persist the handoff inside the new worktree before launching the next session.
   - Write `WORKTREE_HANDOFF.md` in the new worktree root.
   - If the current thread already has a concrete plan/design file in the repo, reference that file explicitly in the handoff.
   - If there is no durable plan file yet, put a concise plan directly in `WORKTREE_HANDOFF.md`.
6. Open a new Toastty workspace for that worktree and launch the new terminal session with the bundled helper:

```bash
.agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh \
  --workspace-name browser-link-routing \
  --worktree-path /abs/path/to/toastty-browser-link-routing \
  --handoff-file /abs/path/to/toastty-browser-link-routing/WORKTREE_HANDOFF.md \
  --json
```

7. Tell the user the new branch, worktree path, workspace name, workspace ID, panel ID, and handoff file path.

## Handoff file contents

Keep `WORKTREE_HANDOFF.md` concise and task-specific. Include:

- the task goal
- relevant user constraints or preferences from the current thread
- current status
- any existing plan/design file paths
- the next 2-5 concrete actions for the new session
- any risks, open questions, or validation notes

## Important invariants

- The worktree branch naming convention is `codex/<slug>`.
- The filesystem naming convention is a sibling repo path like `../toastty-<slug>`.
- Always run `scripts/dev/bootstrap-worktree.sh` in the new worktree before handing it off.
- The handoff file must exist before launching the new `cdx` session.
- The default startup command should `cd` into the new worktree, export `TOASTTY_DEV_WORKTREE_ROOT`, and start `cdx` with a short prompt that points at `WORKTREE_HANDOFF.md`.
- Prefer the helper scripts over ad-hoc `git worktree add` and `toastty action run ...` sequences.

## Window targeting caveat

- `open-toastty-worktree-session.sh` accepts `--window-id` when you know the target Toastty window.
- If `--window-id` is omitted, Toastty must be able to resolve the target window implicitly. Today that means this helper works best in single-window sessions.
- If workspace creation fails because multiple windows are open, stop and tell the user instead of guessing.

## Validation

- After launch, confirm the helper returned the new `workspaceID` and `panelID`.
- For validation or debugging, you can override the startup command:

```bash
.agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh \
  --workspace-name smoke-slug \
  --worktree-path /abs/path/to/toastty-smoke-slug \
  --handoff-file /abs/path/to/toastty-smoke-slug/WORKTREE_HANDOFF.md \
  --startup-command "printf 'WORKTREE_CREATE_SMOKE\\n'" \
  --json
```
