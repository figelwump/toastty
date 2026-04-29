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
2. Pick a branch prefix that describes the work, not the agent.
   - Use `feat` for new behavior, UI, workflows, or user-visible capability.
   - Use `debug` for bug investigation, repro work, flaky behavior, crashes, or targeted fixes where the root cause is not yet settled.
   - Use `fix` for a known, narrow bug fix with a clear intended correction.
   - Use `refactor` for internal restructuring without intended behavior changes.
   - Use `test`, `docs`, or `chore` when the branch is primarily test-only, documentation-only, or maintenance work.
   - If the user explicitly provides a prefix or branch name, honor it when it fits the repo's branch naming style.
3. Confirm the Toastty-managed environment is present before using the launch helper.
   - `TOASTTY_CLI_PATH` must be set.
   - `TOASTTY_PANEL_ID` should be set unless you are explicitly overriding `--window-id`.
   - The skill is designed for a Toastty-managed agent session, not an arbitrary shell.
4. Create and bootstrap the new worktree with the bundled helper, passing the selected branch prefix explicitly:

```bash
.agents/skills/worktree-create/scripts/create-toastty-worktree.sh \
  --slug browser-link-routing \
  --branch-prefix feat \
  --json
```

5. Parse the helper output to get `branch_name`, `worktree_path`, and `handoff_path`.
6. Persist the handoff inside the new worktree before launching the next session.
   - Write `WORKTREE_HANDOFF.md` in the new worktree root.
   - If the current thread already has a concrete plan/design file in the repo, reference that file explicitly in the handoff.
   - If the current thread already produced a detailed implementation plan in-chat but that plan is not yet persisted in the repo, copy that plan into `WORKTREE_HANDOFF.md` with enough detail for the next session to execute directly.
   - Do not compress an already-settled implementation plan into a lightweight summary just because it is being handed off.
   - If there is no durable plan file yet and no detailed plan exists in-thread, put a concise task-specific plan directly in `WORKTREE_HANDOFF.md`.
7. Open a new Toastty workspace for that worktree and launch the new terminal session with the bundled helper:
   - The helper creates the workspace in the background without selecting it, opens `WORKTREE_HANDOFF.md` in a right-hand local-document split, and starts the new terminal command in the left terminal pane.
   - Background-created workspaces stay marked as new in the sidebar until the user visits them once.

```bash
.agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh \
  --workspace-name browser-link-routing \
  --worktree-path /abs/path/to/toastty-browser-link-routing \
  --handoff-file /abs/path/to/toastty-browser-link-routing/WORKTREE_HANDOFF.md \
  --json
```

8. Tell the user the new branch, worktree path, workspace name, workspace ID, panel ID, and handoff file path.

## Handoff file contents

Keep `WORKTREE_HANDOFF.md` task-specific. The length should match the state of the thread:

- If the thread only has a rough direction, a concise handoff is fine.
- If the thread already has a concrete implementation plan, preserve that plan in enough detail for the next session to continue without reconstructing architecture decisions from scratch.
- “Concise” does not mean dropping agreed design decisions, sequencing, file targets, validation, or accepted review corrections.

Include:

- the task goal
- relevant user constraints or preferences from the current thread
- current status
- any existing plan/design file paths
- any settled implementation decisions from the current thread
- affected files or code areas when known
- the next 2-5 concrete actions for the new session
- any risks, open questions, or validation notes

When the parent thread already has a full implementation plan, prefer the following extra detail in the handoff:

- architecture and state-shape decisions that were already made
- explicit sequencing when order matters
- file-by-file implementation targets
- validation and test expectations
- review feedback that was accepted or intentionally rejected

## Important invariants

- The worktree branch naming convention is `<semantic-prefix>/<slug>` such as `feat/<slug>`, `debug/<slug>`, `fix/<slug>`, `refactor/<slug>`, `test/<slug>`, `docs/<slug>`, or `chore/<slug>`.
- Do not use an agent-specific prefix such as `codex/` unless the user explicitly requests it.
- The filesystem naming convention is a sibling repo path like `../toastty-<slug>`.
- Always run `scripts/dev/bootstrap-worktree.sh` in the new worktree before handing it off.
- Treat bootstrap as a local worktree requirement, not just a remote-build requirement.
- Before handing off, the new worktree itself should contain the generated Xcode artifacts such as `toastty.xcworkspace` / `*.xcodeproj` from `tuist generate`.
- Remote wrappers that bootstrap or generate in disposable remote worktrees do not satisfy this handoff requirement for the local worktree.
- The handoff file must exist before launching the new `cdx` session.
- The default workspace layout is terminal on the left and the handoff markdown panel in a right split.
- The default startup command should `cd` into the new worktree, export `TOASTTY_DEV_WORKTREE_ROOT`, and start `cdx` with a short prompt that points at `WORKTREE_HANDOFF.md`.
- Prefer the helper scripts over ad-hoc `git worktree add` and `toastty action run ...` sequences.

## Window targeting

- `open-toastty-worktree-session.sh` accepts `--window-id` when you know the target Toastty window.
- If `--window-id` is omitted, the helper resolves the current window by querying `terminal.state` for `TOASTTY_PANEL_ID`, then creates the new workspace in that window.
- Use the explicit override only when you intentionally want to create the worktree workspace in a different Toastty window from the current thread.
- For non-Toastty-managed shells, keep passing `--window-id` explicitly instead of relying on `TOASTTY_PANEL_ID`.

## Validation

- After launch, confirm the helper returned the new `workspaceID` and terminal `panelID`.
- Confirm the original workspace stayed visible while the new workspace was provisioned.
- Confirm the handoff document opened in a right split of the new workspace.
- Confirm the new local worktree has been bootstrapped successfully, including locally generated Xcode files such as `toastty.xcworkspace`.
- When picking up a handoff in a worktree, if those generated files are missing locally, rerun `scripts/dev/bootstrap-worktree.sh` before continuing.
- For validation or debugging, you can override the startup command:

```bash
.agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh \
  --workspace-name smoke-slug \
  --worktree-path /abs/path/to/toastty-smoke-slug \
  --handoff-file /abs/path/to/toastty-smoke-slug/WORKTREE_HANDOFF.md \
  --startup-command "printf 'WORKTREE_CREATE_SMOKE\\n'" \
  --json
```
