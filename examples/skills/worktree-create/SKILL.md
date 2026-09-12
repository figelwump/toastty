---
name: worktree-create
description: Use this skill when the user asks for /worktree-create or wants to spin the current Toastty thread into a new git worktree and Toastty workspace, optionally run explicit repo setup, persist a handoff or plan file, and launch a new session that preserves the current Codex or Claude Code agent by default.
---

# Worktree Create

This example personal skill continues the current thread in a fresh Git worktree and Toastty workspace. Customize its branch naming, goal, review, and human-testing workflow for your own projects. It uses Toastty’s built-in app-control and Scratchpad skills. PRs carry the shared handoff so a later finishing session can take over without keeping the original parent alive.

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
5. Select the base following **Base selection** below, then create the new worktree with the bundled helper. Pass both the selected branch prefix and the resolved base commit explicitly:

```bash
"$WORKTREE_CREATE_SKILL_DIR/scripts/create-worktree.sh" \
  --slug browser-link-routing \
  --branch-prefix feat \
  --base-ref "$WORKTREE_BASE_COMMIT" \
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
   - If the optional `toastty-watcher` command is installed (`command -v toastty-watcher` succeeds), record the child's bind command in the handoff: `toastty-watcher bind . <slug> --self`, run from the worktree root. The child runs it first. Do not pass `--pr`; the watcher attaches the PR by its head branch once it exists.
   - Assign a local status-note path, such as `WORKTREE_STATUS.md` beside the handoff, for the child to use if there is no PR. Include that path in the handoff and the launch record. Keep these task artifacts out of product commits.
   - Record the canonical parent checkout path, parent workspace/session IDs, task branch/path, base commit, and intended landing branch when known. Resolve paths through symlinks. Do not assume the landing branch is `main` or that the starting branch is the landing branch.
   - For implementation tasks, record whether the repository uses PR delivery and the intended remote/repository and base branch. Carry forward any local-only or publishing restrictions and required approvals; do not guess a publication destination.
   - Include the child workflow and workspace-visibility requirements below in the handoff, and identify an assigned project coordinator when one exists. Preserve the full PR lifecycle: create one PR initially as a draft, mark it ready before handing back once repository-required agent review and automated validation cover the current PR head, and do not merge. Human review, approval, and testing are not prerequisites for marking it ready. The child maintains its PR handoff or a durable local task note; its own Scratchpad is optional. Keep machine paths, session metadata, and this launch handoff out of public PRs and product commits.
   - If a linked Scratchpad was exported, include a `Linked Scratchpad` section with the exported HTML path, title, panel ID, document ID, and revision.
   - If the current thread already has a concrete plan/design file in the repo, reference that file explicitly in the handoff.
   - If the current thread already produced a detailed implementation plan in-chat but that plan is not yet persisted in the repo, copy that plan into `WORKTREE_HANDOFF.md` with enough detail for the next session to execute directly.
   - Do not compress an already-settled implementation plan into a lightweight summary just because it is being handed off.
   - If there is no durable plan file yet and no detailed plan exists in-thread, put a concise task-specific plan directly in `WORKTREE_HANDOFF.md`.
10. Open a new Toastty workspace for that worktree and launch the new terminal session with the bundled helper:
   - The helper creates the workspace in the background without selecting it, opens `WORKTREE_HANDOFF.md` as a local-document panel using Toastty's default markdown placement, and starts the new terminal command in the left terminal pane.
   - Before starting a structured child, the helper sets `git-branch` to the actual branch (or a detached-HEAD revision) and `task-status` to `Working`. Missing Git metadata leaves only the status chip and a warning. It preserves existing color claims. Branch labels longer than 80 characters are shortened for the chip; the handoff keeps the full branch name. If annotation setup fails, it reports the created workspace and stops before launching a child. A later failure before launch marks an initialized status `Needs attention`; after the child starts, failures are reported without overwriting its status. Explicit `--startup-command` smoke/custom launches do not manage task annotations.
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

## Base selection

Choose the base before creating the task branch or worktree. The parent checkout is the worktree this workflow was invoked from; the landing branch may be checked out elsewhere. Uncommitted parent changes are not included in a Git base, regardless of how it is selected. Do not automatically stash, commit, or transfer those changes.

- Honor an explicit base or an agreed continuation of an existing feature branch. Do not replace that choice with the landing branch just because it is newer.
- Otherwise, identify the intended landing branch and its remote from the user's instructions, repository guidance, and Git tracking/default-branch metadata. Do not hardcode `main` or `origin`, or assume the current feature branch's upstream is the landing branch. Ask if the intended branch or remote remains ambiguous.
- Fetch the identified remote branch before selecting its tip. Use the commit obtained by that successful fetch, for example by reading `FETCH_HEAD` immediately after fetching that single branch. Do not rely on a remote-tracking ref that the fetch may not update, or require its SHA to change to prove success. Do not use a fetch refspec that writes to a local branch. Fetching may update local remote-tracking refs, but base selection must leave the parent checkout's branch, files, and local landing branch unchanged.
- Compare the fetched tip with the local landing branch using commit ancestry. If the local branch is absent, equal to, or behind the fetched branch, select the fetched tip without pulling into or updating the local landing branch.
- If the local landing branch has unpublished commits or has diverged, explain the relationship and relevant commits. Use the agreed task intent to determine whether those commits belong in the new task; if intent does not settle that choice, ask before creating the worktree. Do not automatically merge, rebase, reset, or discard commits to reconcile the branches.
- For a local-only repository with no remote base, select the identified local base and record that remote freshness does not apply. If fetching fails, report that freshness could not be verified. Use a cached or local fallback only when the user has explicitly allowed that fallback in the task or accepts it now. If the remote reports that the branch does not exist, resolve the intended branch before continuing; offline permission does not settle a missing or renamed branch.
- Verify that the selected ref resolves to a locally available commit, then resolve its full SHA and assign it to `WORKTREE_BASE_COMMIT` for the helper invocation. Record in `WORKTREE_HANDOFF.md` the source ref, intended landing branch and remote when applicable, selected SHA, local/remote relationship, selection reason, and whether fetching succeeded, failed, or was skipped. An explicit base or continuation that skips fetching must not be described as the latest remote state.

## Child workflow

Include these expectations in the handoff so the launched agent can execute them:

- If the handoff carries a watcher bind command, run it before other work so coordinator wake-ups reach this session. Rerun it after resuming in a new session.
- Use the agent runtime's native persistent goal, when available and permitted, to implement the agreed task, complete repository-required review and automated verification, and prepare it for coordinator assessment and post-deployment human testing. A goal is the runtime's own continued-work mechanism; writing a literal `/goal` in a startup prompt is not proof that one was created. If unavailable, continue through the normal agent workflow and report that limitation. Bounded waits for this task's CI are permitted; do not add a permanent watcher, supervisor, or background runner.
- Maintain the child workspace annotations as described in **Workspace visibility** below. Carry these requirements in the handoff so they apply even when the child does not load this launcher skill.
- Read the target repository's instructions and use its setup, review, and verification workflows. Continue through routine fixes within the approved scope; preserve real approval and input requirements.
- Use subagents as needed when delegation improves progress or independent scrutiny. Suitable work includes codebase research, external research, implementation, testing, design, architecture reviews, and code reviews. Give each subagent a bounded task and clear ownership; integrate its results and remain responsible for the overall outcome.
- Choose models and reasoning levels appropriate to the task for yourself and each subagent where the runtime supports selection, while honoring explicit user choices and repository requirements. Use faster models or lower reasoning effort for straightforward, well-scoped work, and more capable models or higher reasoning effort for complex, ambiguous, or risky work. Choose from the runtime's available options rather than assuming fixed model names or capabilities.
- For implementation tasks in repositories that use PRs, create one PR for this worktree's task, initially as a draft, once the change is coherent enough to review. Reuse an existing PR for the same task branch. Follow the authorized remote and base branch; if publication requires missing authorization or access, continue useful local work and report the PR step as pending. Local-only tasks do not require a PR. Propose independently landable splits to the parent/user for separate child tasks/worktrees; do not create sibling tasks or a stack of dependent PRs by default.
- Own the PR's implementation and fixes. Describe the resulting behavior, scope, validation, and known limitations in the PR, following the repository's template. Complete repository-required agent review and check CI for the actual PR head before declaring automated readiness. Address failures within scope. If required automated checks cannot run while the PR is a draft, report them as pending draft status, not failures or completed verification. Once repository-required agent review and automated validation are complete for the current PR head and the PR carries the handoff, mark it ready for review before handing back. Do not wait for human review, approval, or testing to mark it ready. Ready status is the handoff signal to the coordinator and to any repository review automation; it does not authorize merging. Convert it back to draft before rework, then mark it ready again with a new `ValidatedCommit`. Hand back any other approval, access, or scope question using the runtime's blocked/input behavior; do not claim the goal is complete. External reviewer approvals remain separate merge gates: record them as pending without making the child wait for coordinator review or human testing before handing back its work. This is part of the active task, not a permanent background monitor.
- Keep the PR as the shared task record, following the repository's template. Include the agreed intent and constraints, resulting behavior, important design decisions, validation results and limitations, human testing steps, dependencies or known overlaps, and deployment implications. Name affected targets, migrations, compatibility/order requirements, or why no deployment appears needed. The coordinator verifies these claims against the diff and release rules. Do not depend on the original conversation or a Scratchpad to explain the task.
- Add a concise coordinator handoff to the PR when it is ready for assessment. Explicitly distinguish working, ready for assessment, pending checks/approvals, and validated work. Commit task changes as required by the repository. Once repository-required agent review and automated checks cover the committed task tip, record `ValidatedCommit: <full SHA>` with the evidence. The live PR head and local task tip must match it before integration. Use the PR's native repository/base/head metadata rather than duplicating it throughout the prose. External approvals remain separately identified merge gates. Human testing steps describe what the user checks after deployment, under a heading that says so; they are never a merge gate. Do not name a pre-merge manual check unless the user asked for one in this task. When you do, put it under an explicit `Pre-merge manual check` heading with the reason, because the coordinator treats it as a gate only the user can clear. A draft or an idle agent alone is not a readiness signal.
- If there is no PR or publishing is blocked, maintain the same handoff at the status-note path assigned in `WORKTREE_HANDOFF.md` and report that path in the handback. The launcher has already recorded it; do not require the child to edit the launcher's private note. Label the missing publication/checks explicitly; do not claim remote delivery. Optional session-linked Scratchpads can show progress, previews, and visual explanations through `toastty-scratchpad`, but the task record must contain all required handoff evidence.
- Any subsequent change to the local tip or live PR head invalidates prior readiness, regardless of author. Before editing, mark the handoff as working when possible; otherwise mark the local record and report the stale remote handoff. Update the PR and affected review/checks for the new head before declaring it validated. Never assert that human testing or coordinator review happened without evidence.
- Before handing back, open each screenshot, video, or other visual artifact used as verification evidence directly in a browser panel in the child's own Toastty workspace. Opening a Markdown evidence document containing image links does not satisfy this requirement. Use the built-in `toastty-capabilities` skill to resolve that workspace and open the artifacts; make remote captures accessible locally when needed.
- Confirm that each evidence panel shows the intended image or playable video; a successful panel-creation response alone is insufficient. If an artifact is renamed or regenerated, refresh or reopen it and verify the current version. In the final handback, identify the evidence panels opened and any artifacts that could not be displayed or whose display could not be verified.
- When the changes can be tested locally, start the relevant development services or app from the task worktree before handing back, using the repository's documented commands (for example, `npm run dev`, `dev:www`, or `dev -- up`). Keep services available after the agent turn ends, using workspace terminals or the repository's supported service lifecycle. Confirm they are ready, then open the relevant pages in the in-Toastty browser in the child's workspace, such as www, computer home, or control, according to the changes. Use the actual URLs and ports for this worktree. Record the commands, URLs, how to stop the services, and brief testing steps in the local task note and handback; report any startup or browser blocker. This local testing opportunity does not add a human approval or merge gate.
- End the implementation goal at readiness for coordinator assessment, subject to the pending-check behavior above. Leave the workspace, optional Scratchpad, worktree, branch, and PR available. Do not merge or clean up as part of this goal. An assigned `project-orchestrator` can discover the handoff during its watch; without one, report it to the user for later `worktree-done`. The original parent need not remain active, and no coordinator is launched implicitly. Handoff or review does not authorize integration, publication, or cleanup.
- Coordinator findings arrive as PR comments or as a project watcher message. Reply on the PR with the outcome and push; for a task without a PR, commit and update the status note. Then end the turn.
- When resumed, first verify the task still exists and has not already landed; report removed or integrated work instead of recreating it. For accepted coordinator findings or user feedback, keep ownership of fixes and update the same PR/task record. Record the new head and rerun affected review and verification before setting a new `ValidatedCommit`. Update human testing steps and identify which previous human checks need repeating. New behavior outside the agreed scope still needs the user.

## Workspace visibility

Include these requirements in the child handoff. Annotations summarize the task;
the PR or status note remains the evidence and handoff record.

- Resolve the child's current workspace through its managed session/panel context,
  not the parent IDs in the handoff. Use the built-in `toastty-capabilities` skill
  to inspect the annotation catalog and target workspace before setting chips.
  If that context cannot be resolved, report the missing update rather than
  guessing a workspace or using the parent’s identity.
- Own the stable keys `git-branch`, `task-status`, and `github-pr` in that workspace.
  Update the same keys rather than adding a new key for every status or PR number.
  Preserve unrelated annotations and omit `color` to retain the runtime's claim.
- Keep `git-branch` aligned with the actual worktree branch. The launcher sets it
  initially; update it if an authorized branch change occurs. Keep the chip at
  most 80 characters (use a shortened label ending in `...` if needed), while
  retaining the full branch in the task record. A detached checkout names its
  revision; do not invent a branch for it.
- Update `task-status` on meaningful transitions, not on every command:
  `Working` during implementation or rework; `Validating` during review and checks;
  `Needs attention` when approval, access, a failed required check, or user input
  prevents progress; and `Ready for your testing` when repository-required agent
  review and automated checks cover the current committed tip. Set that chip and
  mark the PR ready for review together; converting the PR back to draft for
  rework returns the chip to `Working`. Pending human checks and external merge
  approvals remain explicit in the task record. A draft PR, idle process, or
  passing subset of checks does not establish readiness.
- As soon as a PR is created or adopted for the task, set `github-pr` with text
  such as `PR #42` and its verified canonical GitHub URL. Use the PR metadata or
  creation result; never infer a URL from a number alone. Keep the chip current
  if the task's PR changes; clear only this key if the association is removed.
  Local-only work has no PR chip.
- Before the final handback, reconcile these chips with the task record and actual
  PR. On resume or any new task commit, clear stale readiness by setting `Working`
  before further edits, then repeat the affected checks. Do not overwrite your
  own newer status with a delayed launch update.
- If a chip update fails, report the missing update in the handback and durable
  task record. Preserve the task's actual progress; do not claim a chip was set or
  broaden workspace scope to work around a denial.

A child Scratchpad remains optional for previews or visual explanations. It is
not required to mirror these chips or the PR, and it does not replace the
parent's exported design or the durable handoff.

## Handoff file contents

Keep `WORKTREE_HANDOFF.md` task-specific. The length should match the state of the thread:

- If the thread only has a rough direction, a concise handoff is fine.
- If the thread already has a concrete implementation plan, preserve that plan in enough detail for the next session to continue without reconstructing architecture decisions from scratch.
- “Concise” does not mean dropping agreed design decisions, sequencing, file targets, validation, or accepted review corrections.

Include:

- the task goal
- relevant user constraints or preferences from the current thread
- current status
- selected base commit, source ref, landing branch/remote, selection reason, and fetch status from **Base selection**
- linked Scratchpad exported HTML path and metadata when the current session has one
- any existing plan/design file paths
- any settled implementation decisions from the current thread
- affected files or code areas when known
- the next 2-5 concrete actions for the new session
- the `toastty-watcher bind . <slug> --self` command when `toastty-watcher` is installed
- any risks, open questions, or validation notes
- the explicit child requirements to open verification media directly in browser panels, verify their display and refresh changed artifacts, and identify opened panels or display limitations in the final handback; include these requirements even when linking to a separate evidence document
- the child requirements to prepare locally testable changes in its own Toastty workspace before handing back, including relevant development commands and pages when known

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
- For a structured managed launch, confirm the new workspace has the actual branch and `Working` status chips before the child starts, and that the handoff includes the later status/PR update requirements.
- Confirm the handoff document opened in the right panel of the new workspace.
- If the parent session had a linked Scratchpad, confirm `WORKTREE_HANDOFF.md` includes the exported Scratchpad path and metadata. If lookup found no linked Scratchpad, confirm the workflow did not scan or guess from other Scratchpad panels.
- Confirm the new branch started at `WORKTREE_BASE_COMMIT`, the handoff records its source and fetch status, and base selection left the parent checkout unchanged.
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
