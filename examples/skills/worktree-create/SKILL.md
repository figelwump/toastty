---
name: worktree-create
description: Use this skill when the user asks for /worktree-create or wants to spin the current Toastty thread into a new git worktree and Toastty workspace, optionally run explicit repo setup, persist a handoff or plan file, and launch a new session that preserves the current Codex or Claude Code agent by default.
---

# Worktree Create

This example personal skill continues the current thread in a fresh Git worktree and Toastty workspace. Customize its branch naming, goal, review, and human-testing workflow for your own projects. It uses Toastty’s built-in app-control and Scratchpad skills. PRs carry the shared handoff; a project coordinator or a later finishing session can take over without keeping the original parent alive.

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
3. Resolve this personal skill's helper directory and confirm the managed environment.
   - Resolve `scripts/` relative to the path of this loaded `SKILL.md`, not the current repository or shell directory. Set `WORKTREE_CREATE_SKILL_DIR` to that absolute skill directory for the examples below. This is a shell variable you set, not an environment value injected by Toastty.
   - Use the scripts from this package, including when the skill is loaded from a copied user-plugin snapshot. Do not look for them under `TOASTTY_SKILLS_ROOT`, which belongs to the shipped Toastty skills, or guess a versioned plugin cache path.
   - `TOASTTY_CLI_PATH` must be set and executable. If the managed environment is missing, stop with `error: worktree-create must run inside a Toastty-managed agent session`.

```bash
if [[ -z "${TOASTTY_CLI_PATH:-}" || ! -x "$TOASTTY_CLI_PATH" ]]; then
  echo "error: worktree-create must run inside a Toastty-managed agent session" >&2
  exit 1
fi
```

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
"$WORKTREE_CREATE_SKILL_DIR/scripts/create-worktree.sh" \
  --slug browser-link-routing \
  --branch-prefix feat \
  --json
```

6. Parse the helper output to get `branch_name`, `worktree_path`, and `handoff_path`.
7. Run any explicit setup selected in step 4 from the new worktree root.
   - If there are no explicit setup commands, skip this step.
   - If setup came from repo instructions, mention the source path in the handoff.
   - If setup came from the user, preserve the user-specified command text in the handoff.
8. Detect and export any Scratchpad linked to the current managed agent session before writing the handoff.
   - Use detection first; do not use export failure as the signal for absence.
   - If `TOASTTY_SESSION_ID` is present, run the session-scoped lookup query:

```bash
"$TOASTTY_CLI_PATH" --json query run panel.scratchpad.lookup \
  "sessionID=${TOASTTY_SESSION_ID}"
```

   - Parse the lookup result's `linked` boolean.
   - If `linked` is `false`, treat that as "no linked Scratchpad" and continue without adding a Scratchpad section.
   - If `linked` is `true`, run the export action for the same session and use the returned absolute `filePath` in `WORKTREE_HANDOFF.md`:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export \
  "sessionID=${TOASTTY_SESSION_ID}"
```

   - Do not scan the workspace or guess from focused/right-panel state when the session lookup finds no linked Scratchpad.
   - If lookup fails, surface the failure instead of silently omitting Scratchpad context.
   - If lookup succeeds but export fails, retry once. If export still fails, do not pretend there was no Scratchpad; include the lookup metadata and export failure in the handoff and final status. Continue unless the Scratchpad was the explicit source of truth for the delegated task.
9. Persist the handoff inside the new worktree before launching the next session.
   - Write `WORKTREE_HANDOFF.md` in the new worktree root.
   - Assign a local status-note path, such as `WORKTREE_STATUS.md` beside the handoff, for the child to use if there is no PR. Include that path in the handoff and the launch record. Keep these task artifacts out of product commits.
   - Record the canonical parent checkout path, parent workspace/session IDs, task branch/path, base commit, and intended landing branch when known. Resolve paths through symlinks. Do not assume the landing branch is `main` or that the starting branch is the landing branch.
   - For implementation tasks, record whether the repository uses PR delivery and the intended remote/repository and base branch. Carry forward any local-only or publishing restrictions and required approvals; do not guess a publication destination.
   - Include the child workflow below and identify an assigned project coordinator when one exists. The child maintains its PR handoff or a durable local task note; its own Scratchpad is optional. Keep machine paths, session metadata, and this launch handoff out of public PRs and product commits.
   - If a linked Scratchpad was exported, include a `Linked Scratchpad` section with the exported HTML path, title, panel ID, document ID, and revision.
   - If the current thread already has a concrete plan/design file in the repo, reference that file explicitly in the handoff.
   - If the current thread already produced a detailed implementation plan in-chat but that plan is not yet persisted in the repo, copy that plan into `WORKTREE_HANDOFF.md` with enough detail for the next session to execute directly.
   - Do not compress an already-settled implementation plan into a lightweight summary just because it is being handed off.
   - If there is no durable plan file yet and no detailed plan exists in-thread, put a concise task-specific plan directly in `WORKTREE_HANDOFF.md`.
10. Open a new Toastty workspace for that worktree and launch the new terminal session with the bundled helper:
   - The helper creates the workspace in the background without selecting it, opens `WORKTREE_HANDOFF.md` as a local-document panel using Toastty's default markdown placement, and starts the new terminal command in the left terminal pane.
   - For the structured `agent.launch` path, the helper first inspects the current parent session with `session scope show --session "$TOASTTY_SESSION_ID"`. If the parent is unscoped, it runs `session scope set-current --session "$TOASTTY_SESSION_ID"` before workspace creation so the newly created workspace is auto-bound into the parent's effective scope. If the parent is already scoped, the helper preserves that scope and relies on workspace creation to add the new workspace. If the helper scoped an unscoped parent and later fails, it attempts to restore the parent to unrestricted automation before exiting.
   - For the structured `agent.launch` path, the helper immediately scopes the launched child session to the newly created workspace with `session scope set --session <child-session-id> --workspace <new-workspace-id>`. This is a cooperative post-launch scope; treat a scope failure as a launch failure, but report that the workspace/session may already exist.
   - Background-created workspaces stay marked as new in the sidebar until the user visits them once.
   - The helper preserves `TOASTTY_AGENT=codex` or `TOASTTY_AGENT=claude` by default. Missing or unknown values fall back to `codex`. If the user explicitly requested a different agent for the new session, pass it with `--agent-command <name>`; otherwise omit the flag.
   - If the user explicitly requested commands that must run inside the launched terminal immediately before the agent starts, pass each command with `--initial-command <command>` so the helper keeps the structured `agent.launch` path. For example, `--initial-command "direnv allow"` runs after `cd <worktree>` and before the agent prompt. If an initial command fails, the agent command is stopped in the terminal, but the workspace creation helper may already have reported launch success.
   - If you intentionally need to leave the parent session unrestricted, pass `--no-scope-parent` and mention that exception in the handoff.

```bash
"$WORKTREE_CREATE_SKILL_DIR/scripts/open-toastty-worktree-session.sh" \
  --workspace-name browser-link-routing \
  --worktree-path /abs/path/to/repo-browser-link-routing \
  --handoff-file /abs/path/to/repo-browser-link-routing/WORKTREE_HANDOFF.md \
  --json
```

11. Parse the launch helper output to get `workspace_id`, `panel_id`, `session_id`, `scope_set`, and `parent_scope_status`.
    - Retain these IDs with the repository, task name, branch, canonical worktree path, handoff path, and assigned status-note path in a durable local launch note outside the child worktree, using an ignored artifact location or a directory outside Git. When a project coordinator is assigned, make the note location available in its local coordination record. This lets a later session discover the task without the original parent or its Scratchpad. Do not rewrite the child's handoff after launch to add IDs. Workspace assignment and control scope must still be established before that session acts on the child.
    - `session_id` is present and `scope_set` is `true` for structured managed launches.
    - `parent_scope_status` is `set_current` when the helper scoped an unscoped parent, `already_scoped` when it preserved an existing parent scope, `disabled` when `--no-scope-parent` was used, and `startup_command` for explicit startup-command launches.
    - `session_id` is absent and `scope_set` is `false` only for `--startup-command` or fallback `terminal.send-text` launches; use those paths only for explicit validation or fully custom shell setup.
12. Tell the user the new branch, worktree path, workspace name, workspace ID, panel ID, child session ID when present, parent scope status, child scope status, handoff file path, Scratchpad export path/status, and whether setup was skipped or which explicit setup commands ran.

## Child workflow

Include these expectations in the handoff so the launched agent can execute them:

- Use the agent runtime's native persistent goal, when available and permitted, to implement the agreed task, complete repository-required review and automated verification, and prepare it for human testing. A goal is the runtime's own continued-work mechanism; writing a literal `/goal` in a startup prompt is not proof that one was created. If unavailable, continue through the normal agent workflow and report that limitation. Bounded waits for this task's CI are permitted; do not add a permanent watcher, supervisor, or background runner.
- Read the target repository's instructions and use its setup, review, and verification workflows. Continue through routine fixes within the approved scope; preserve real approval and input requirements.
- For implementation tasks in repositories that use PRs, deliver one draft PR for this worktree's task once the change is coherent enough to review. Reuse an existing PR for the same task branch. Follow the authorized remote and base branch; if publication requires missing authorization or access, continue useful local work and report the PR step as pending. Local-only tasks do not require a PR. Propose independently landable splits to the parent/user for separate child tasks/worktrees; do not create sibling tasks or a stack of dependent PRs by default.
- Own the PR's implementation and fixes. Describe the resulting behavior, scope, validation, and known limitations in the PR, following the repository's template. Complete repository-required agent review and check CI for the actual PR head before declaring automated readiness. Address failures within scope. If required automated checks cannot run while the PR is a draft, report them as pending draft status, not failures or completed verification. Hand back any needed approval, access, or PR-state transition using the runtime's blocked/input behavior; do not silently promote the PR or claim the goal is complete. External reviewer approvals remain separate merge gates: record them as pending without making the child wait for coordinator review or human testing before handing back its work. This is part of the active task, not a permanent background monitor.
- Keep the PR as the shared task record, following the repository's template. Include the agreed intent and constraints, resulting behavior, important design decisions, validation results and limitations, human testing steps, dependencies or known overlaps, and deployment implications. Name affected targets, migrations, compatibility/order requirements, or why no deployment appears needed. The coordinator verifies these claims against the diff and release rules. Do not depend on the original conversation or a Scratchpad to explain the task.
- Add a concise coordinator handoff to the PR when it is ready for assessment. Explicitly distinguish working, ready for assessment, pending checks/approvals, and validated work. Commit task changes as required by the repository. Once repository-required agent review and automated checks cover the committed task tip, record `ValidatedCommit: <full SHA>` with the evidence. The live PR head and local task tip must match it before integration. Use the PR's native repository/base/head metadata rather than duplicating it throughout the prose. Human testing and external approvals remain separately identified gates. A draft or an idle agent alone is not a readiness signal.
- If there is no PR or publishing is blocked, maintain the same handoff at the status-note path assigned in `WORKTREE_HANDOFF.md` and report that path in the handback. The launcher has already recorded it; do not require the child to edit the launcher's private note. Label the missing publication/checks explicitly; do not claim remote delivery. Optional session-linked Scratchpads can show progress, previews, and visual explanations through `toastty-scratchpad`, but the task record must contain all required handoff evidence.
- Any subsequent change to the local tip or live PR head invalidates prior readiness, regardless of author. Before editing, mark the handoff as working when possible; otherwise mark the local record and report the stale remote handoff. Update the PR and affected review/checks for the new head before declaring it validated. Never assert that human testing or coordinator review happened without evidence.
- End the implementation goal at readiness for coordinator assessment and human testing, subject to the pending-check behavior above. Leave the workspace, optional Scratchpad, worktree, branch, and PR available. Do not merge or clean up as part of this goal. An assigned `project-orchestrator` can discover the handoff during its watch; without one, report it to the user for later `worktree-done`. The original parent need not remain active, and no coordinator is launched implicitly. Handoff or review does not authorize integration, publication, or cleanup.
- When resumed, first verify the task still exists and has not already landed; report removed or integrated work instead of recreating it. For accepted coordinator findings or user feedback, keep ownership of fixes and update the same PR/task record. Record the new head and rerun affected review and verification before setting a new `ValidatedCommit`. Update human testing steps and identify which previous human checks need repeating. New behavior outside the agreed scope still needs the user.

## Handoff file contents

Keep `WORKTREE_HANDOFF.md` task-specific. The length should match the state of the thread:

- If the thread only has a rough direction, a concise handoff is fine.
- If the thread already has a concrete implementation plan, preserve that plan in enough detail for the next session to continue without reconstructing architecture decisions from scratch.
- “Concise” does not mean dropping agreed design decisions, sequencing, file targets, validation, or accepted review corrections.

Include:

- the task goal
- relevant user constraints or preferences from the current thread
- current status
- linked Scratchpad exported HTML path and metadata when the current session has one
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
- The handoff file must exist before launching the new agent session.
- Scratchpad detection must use `panel.scratchpad.lookup` with `sessionID=$TOASTTY_SESSION_ID` before export, and absence is represented by a successful lookup response with `linked=false`. Export is only for creating the durable readable HTML file path for the next session; it is not the absence check.
- A session-linked Scratchpad should be represented in `WORKTREE_HANDOFF.md` by the exported absolute HTML file path plus title, panel ID, document ID, and revision. A panel ID or document ID alone is not enough for the child session, because the child will be scoped to the new workspace and should not depend on parent workspace panel access.
- The default workspace layout is terminal on the left and the handoff markdown file in the right panel.
- The default launch should use `agent.launch` with structured `cwd`, `initialCommands`, environment, and `initialPrompt` arguments so the new background workspace starts without a separate `terminal.send-text` injection. The launched command still `cd`s into the new worktree, runs any `--initial-command` single-line shell snippets in order with `&&`, and starts the agent CLI with a short prompt that points at `WORKTREE_HANDOFF.md`. Preserve a recognized `TOASTTY_AGENT` value unless the user explicitly requested a different agent with `--agent-command`; otherwise fall back to `codex`.
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
- If the parent session had a linked Scratchpad, confirm `WORKTREE_HANDOFF.md` includes the exported Scratchpad path and metadata. If lookup found no linked Scratchpad, confirm the workflow did not scan or guess from other Scratchpad panels.
- Confirm setup was handled according to the current repo's instructions: either explicit setup commands ran successfully, or no clear setup requirement was found and setup was skipped.
- For validation or debugging, you can override the startup command:

```bash
"$WORKTREE_CREATE_SKILL_DIR/scripts/open-toastty-worktree-session.sh" \
  --workspace-name smoke-slug \
  --worktree-path /abs/path/to/repo-smoke-slug \
  --handoff-file /abs/path/to/repo-smoke-slug/WORKTREE_HANDOFF.md \
  --startup-command "printf 'WORKTREE_CREATE_SMOKE\\n'" \
  --json
```
