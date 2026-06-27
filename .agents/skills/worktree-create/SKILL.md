---
name: worktree-create
description: Use this skill when the user asks for /worktree-create or wants to spin the current Toastty thread into a new git worktree and Toastty workspace, optionally run explicit repo setup, persist a handoff or plan file, and launch a new agent session (codex by default) in the new workspace.
---

# Worktree Create

Use this workflow when the current thread should continue in a fresh git worktree and Toastty workspace.

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
   - `TOASTTY_PANEL_ID` must be set for the default structured launch because parent `set-current` needs the current panel. It may be omitted only when using `--startup-command`, or when combining `--window-id` with `--no-scope-parent`.
   - `TOASTTY_SESSION_ID` must be set for the default structured launch because the helper scopes the current parent session before it creates the child workspace.
   - The skill is designed for a Toastty-managed agent session, not an arbitrary shell.
4. Resolve the current repository root and identify any explicit setup requirement.
   - Run `git rev-parse --show-toplevel` from the current task repo; this repo, not the Toastty repo that owns the skill source, is the worktree target.
   - Look for clear project instructions about new worktrees, bootstrap, or local setup in `AGENTS.md`, `CLAUDE.md`, `.agents/**`, `README*`, and `docs/**`.
   - Clear setup instructions are imperative repo-local commands, such as "for a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`" or "after cloning, run `pnpm install`". Prefer instructions that mention worktrees directly.
   - Use only explicit setup commands from the user or from repo instructions. Do not infer bootstrap from vague first-time install notes, dependency lists, tool names, or examples unrelated to local setup.
   - If no clear setup instruction exists, assume no bootstrap is required.
   - If setup commands are needed, run them from the new worktree root after creating the worktree and before launching the next session. Stop on the first setup failure and report it.
   - Do not add trust-changing commands such as `direnv allow` unless the user requested or approved them for that worktree.
5. Create the new worktree with the bundled helper, passing the selected branch prefix explicitly:

```bash
.agents/skills/worktree-create/scripts/create-worktree.sh \
  --slug browser-link-routing \
  --branch-prefix feat \
  --json
```

6. Parse the helper output to get `branch_name`, `worktree_path`, and `handoff_path`.
7. Run any explicit setup selected in step 4 from the new worktree root.
   - If there are no explicit setup commands, skip this step.
   - If setup came from repo instructions, mention the source path in the handoff.
   - If setup came from the user, preserve the user-specified command text in the handoff.
8. Persist the handoff inside the new worktree before launching the next session.
   - Write `WORKTREE_HANDOFF.md` in the new worktree root.
   - If the current thread already has a concrete plan/design file in the repo, reference that file explicitly in the handoff.
   - If the current thread already produced a detailed implementation plan in-chat but that plan is not yet persisted in the repo, copy that plan into `WORKTREE_HANDOFF.md` with enough detail for the next session to execute directly.
   - Do not compress an already-settled implementation plan into a lightweight summary just because it is being handed off.
   - If there is no durable plan file yet and no detailed plan exists in-thread, put a concise task-specific plan directly in `WORKTREE_HANDOFF.md`.
9. Open a new Toastty workspace for that worktree and launch the new terminal session with the bundled helper:
   - The helper creates the workspace in the background without selecting it, opens `WORKTREE_HANDOFF.md` as a local-document panel using Toastty's default markdown placement, and starts the new terminal command in the left terminal pane.
   - For the structured `agent.launch` path, the helper first inspects the current parent session with `session scope show --session "$TOASTTY_SESSION_ID"`. If the parent is unscoped, it runs `session scope set-current --session "$TOASTTY_SESSION_ID"` before workspace creation so the newly created workspace is auto-bound into the parent's effective scope. If the parent is already scoped, the helper preserves that scope and relies on workspace creation to add the new workspace. If the helper scoped an unscoped parent and later fails, it attempts to restore the parent to unrestricted automation before exiting.
   - For the structured `agent.launch` path, the helper immediately scopes the launched child session to the newly created workspace with `session scope set --session <child-session-id> --workspace <new-workspace-id>`. This is a cooperative post-launch scope; treat a scope failure as a launch failure, but report that the workspace/session may already exist.
   - Background-created workspaces stay marked as new in the sidebar until the user visits them once.
   - The startup command launches `codex` by default. If the user explicitly requested a different agent for the new session, pass it with `--agent-command <name>` (for example `--agent-command claude`); otherwise omit the flag.
   - If the user explicitly requested commands that must run inside the launched terminal immediately before the agent starts, pass each command with `--initial-command <command>` so the helper keeps the structured `agent.launch` path. For example, `--initial-command "direnv allow"` runs after `cd <worktree>` and before the agent prompt. If an initial command fails, the agent command is stopped in the terminal, but the workspace creation helper may already have reported launch success.
   - If you intentionally need to leave the parent session unrestricted, pass `--no-scope-parent` and mention that exception in the handoff.

```bash
.agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh \
  --workspace-name browser-link-routing \
  --worktree-path /abs/path/to/repo-browser-link-routing \
  --handoff-file /abs/path/to/repo-browser-link-routing/WORKTREE_HANDOFF.md \
  --json
```

10. Parse the launch helper output to get `workspace_id`, `panel_id`, `session_id`, `scope_set`, and `parent_scope_status`.
    - `session_id` is present and `scope_set` is `true` for structured managed launches.
    - `parent_scope_status` is `set_current` when the helper scoped an unscoped parent, `already_scoped` when it preserved an existing parent scope, `disabled` when `--no-scope-parent` was used, and `startup_command` for explicit startup-command launches.
    - `session_id` is absent and `scope_set` is `false` only for `--startup-command` or fallback `terminal.send-text` launches; use those paths only for explicit validation or fully custom shell setup.
11. Tell the user the new branch, worktree path, workspace name, workspace ID, panel ID, child session ID when present, parent scope status, child scope status, handoff file path, and whether setup was skipped or which explicit setup commands ran.

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
- The filesystem naming convention is a sibling repo path like `../<repo-name>-<slug>`.
- Setup/bootstrap is not assumed. Run setup only when the user specified it or when the current repo's instructions clearly say to run it for new worktrees or local development.
- When setup is required by repo instructions, treat it as a local worktree requirement, not just a remote-build requirement.
- Remote wrappers that bootstrap or generate in disposable remote worktrees do not satisfy a setup requirement for the local worktree.
- In the Toastty repo, the repo instructions explicitly require `./scripts/dev/bootstrap-worktree.sh` for a fresh worktree; that is discovered from Toastty's `AGENTS.md`, not hard-coded into this skill.
- The handoff file must exist before launching the new agent session.
- The default workspace layout is terminal on the left and the handoff markdown file in the right panel.
- The default launch should use `agent.launch` with structured `cwd`, `initialCommands`, environment, and `initialPrompt` arguments so the new background workspace starts without a separate `terminal.send-text` injection. The launched command still `cd`s into the new worktree, runs any `--initial-command` single-line shell snippets in order with `&&`, and starts the agent CLI with a short prompt that points at `WORKTREE_HANDOFF.md`. The agent CLI is `codex` unless the user explicitly requested a different agent; honor an explicit request with `--agent-command`.
- Before the default structured launch creates the workspace, scope the parent if needed with `session scope set-current --session "$TOASTTY_SESSION_ID"`. Do not reset an already scoped parent; preserving the existing scope lets `workspace.create` auto-bind the new workspace without dropping prior explicit workspace assignments.
- After a structured `agent.launch` succeeds, scope the child session to the created workspace by calling `session scope set --session <sessionID> --workspace <workspaceID>` from the parent. Do not use `session scope set-current` for the child handoff; that command can only target the current parent session and panel. The helper performs this scope call automatically and reports `scope_set`. Because the scope API runs after launch returns the child `sessionID`, this is cooperative workspace isolation, not a hard pre-exec sandbox.
- `--startup-command` is the explicit escape hatch for validation or fully custom shell setup. It replaces the structured agent launch path and uses `terminal.send-text` after resolving the terminal panel. Do not combine it with `--agent-command` or `--initial-command`.
- `--no-scope-parent` is the explicit escape hatch for leaving the parent session unrestricted during a structured launch. Use it only when unrestricted parent automation is intentional.
- Prefer the helper scripts over ad-hoc `git worktree add` and `toastty action run ...` sequences.

## Window targeting

- `open-toastty-worktree-session.sh` accepts `--window-id` when you know the target Toastty window.
- If `--window-id` is omitted, the helper resolves the current window by querying `terminal.state` for `TOASTTY_PANEL_ID`, then creates the new workspace in that window.
- Use the explicit override only when you intentionally want to create the worktree workspace in a different Toastty window from the current thread.
- For non-Toastty-managed shells, keep passing `--window-id` explicitly instead of relying on `TOASTTY_PANEL_ID`, and pass `--no-scope-parent` unless you are intentionally providing valid current-session context.

## Validation

- After launch, confirm the helper returned the new workspace ID, terminal panel ID, child session ID, `parent_scope_status` of `set_current` or `already_scoped`, and `scope_set=true` for the default structured launch.
- If debugging lower-level calls, verify scope directly:

```bash
"$TOASTTY_CLI_PATH" --json session scope show --session "$SESSION_ID"
```

- Confirm the original workspace stayed visible while the new workspace was provisioned.
- Confirm the handoff document opened in the right panel of the new workspace.
- Confirm setup was handled according to the current repo's instructions: either explicit setup commands ran successfully, or no clear setup requirement was found and setup was skipped.
- For validation or debugging, you can override the startup command:

```bash
.agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh \
  --workspace-name smoke-slug \
  --worktree-path /abs/path/to/repo-smoke-slug \
  --handoff-file /abs/path/to/repo-smoke-slug/WORKTREE_HANDOFF.md \
  --startup-command "printf 'WORKTREE_CREATE_SMOKE\\n'" \
  --json
```
