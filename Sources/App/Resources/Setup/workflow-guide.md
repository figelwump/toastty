# Toastty Workflow Guide

This guide is for an agent helping a user turn how they work into a Toastty workflow: a skill that tells agents which Toastty building blocks to use, and when. Follow the user's lead. Suggest ideas, but build only what they ask for.

## What a workflow skill is

A workflow skill is a folder in the user skills directory, `$TOASTTY_USER_SKILLS_ROOT` (normally `~/.toastty/skills`), with a `SKILL.md` file. Its YAML frontmatter has a `name` that matches the folder name and a `description` that says when an agent should use it. The folder can also hold `scripts/` and `references/`.

Toastty delivers every accepted skill in that folder to each new managed Codex, Claude Code, Cursor, OpenCode, MiMo Code, and Pi session. Running sessions keep the skills they launched with, so test a new or edited skill in a fresh session.

Write the skill as intended behavior and constraints, not as a fixed script of commands. The agent that runs it discovers exact parameters from the live app.

## Building blocks

- **Workspaces and subspaces**: `workspace.create` makes a workspace for a project or task. `workspace.set-parent` nests it under the workspace that started it, so it shows as a subspace in the sidebar. `workspace.set-done` marks finished work.
- **Tabs and splits**: `workspace.tab.create` and `workspace.split.right` arrange terminals.
- **Agents**: `agent.launch` starts a managed agent in a pane. It can pick a model and reasoning effort, and for Codex and Claude it can fork the current conversation with `forkFromSessionID`.
- **Right panel**: `panel.create.local-document` opens Markdown, code, and logs beside the terminal. `panel.create.browser` opens previews, PRs, and dashboards. Scratchpad pages for plans, mockups, and reports come from the shipped `toastty-scratchpad` skill.
- **Chips**: `workspace.set-annotation` pins a keyed chip with an optional link to a workspace, such as `PR #128` or `ENG-412`.
- **Terminals**: `terminal.visible-text` reads another pane, and `terminal.send-text` types into one.
- **Notifications**: `"$TOASTTY_CLI_PATH" notify <title> <body>` posts a macOS notification.

List the exact parameters before composing commands:

```bash
"$TOASTTY_CLI_PATH" --json action list
"$TOASTTY_CLI_PATH" --json query list
```

The shipped `toastty-capabilities` skill covers these actions in more depth, including workspace scope.

## Ideas to suggest

Match these to what the user works on and which tools they use. Issue trackers, documents, and monitoring are reached through the agent's own tools, such as MCP servers or the `gh` CLI; Toastty provides the workspace around them. If a workflow needs a tool the user's agent lacks, say so.

- **Worktree handoff** ("hand this off"): packages the conversation into a handoff, opens a Git worktree in a new subspace, and comes back with a screenshot report and a PR chip. Installable; see below.
- **Issue to PR** ("start ENG-412"): reads a Linear or GitHub issue, names a workspace after it with a chip linking back, drafts the plan in a Scratchpad, and links the PR on the issue when it is up.
- **Review queue** ("review my PRs"): opens a subspace per requested review with the diff in the browser, writes notes into a Scratchpad, and notifies the user as each one is ready.
- **Spec to tasks** ("build from this spec"): opens a spec from Google Docs, Notion, or a Markdown file beside the terminal, splits it into tasks, starts a subspace for each, and keeps a progress page current.
- **Crash to fix** ("fix this crash"): reproduces a Sentry report or log error in a worktree with the dev server in a split the agent can read, then shows before and after screenshots.
- **Second opinion** ("ask another model"): runs two agents side by side on the same question and compares their answers in a Scratchpad.

## Worked example: worktree handoff

Toastty bundles the worktree handoff workflow. Preview the install, show the user the planned packages, and apply only after an explicit OK:

```bash
"$TOASTTY_CLI_PATH" setup install-workflow worktree-handoff --dry-run
"$TOASTTY_CLI_PATH" setup install-workflow worktree-handoff --apply
```

It installs three packages. `worktree-create` hands a task to its own worktree and subspace, forking the conversation when the task was already discussed. `worktree-done` accepts the reviewed PR and turns on auto-merge. `worktree-cleanup` reports which task PRs are ready and removes merged worktrees. The PR steps need an authenticated `gh` CLI, and `worktree-done` relies on the repository's auto-merge setting.

The installer never overwrites an existing package. If one differs from the bundled version, it changes nothing and reports the conflict; ask the user whether to keep their copy or move it aside first.

After installing, read `worktree-create/SKILL.md` in the user skills directory as a model for a custom workflow. It checks its inputs, creates the worktree with a bundled script, launches the child agent with `agent.launch`, opens the related documents in the new workspace's right panel, and records every ID it creates. The installed copies belong to the user to edit.

## Rules for workflow skills

- Start narrow: one trigger and a few steps. Add more once the first version works.
- Call the injected `"$TOASTTY_CLI_PATH"` with `--json`. Check `ok` in every `action run` and `query run` response, check the exit status of other commands, and report failures instead of guessing.
- Respect workspace scope. Treat `scope_denied` as a reason to stop and ask, not an error to work around.
- Ask before merging, deploying, deleting, or sending anything outside the machine. Preparing that step is fine.
- Resolve IDs and paths at run time; do not hardcode them. Scripts should find their own files relative to the skill folder.
- Keep personal choices such as models, branch prefixes, and repositories in the skill where the user can edit them.

## Writing a skill with the user

1. Ask what they repeat, which tools are involved, and what the result should look like.
2. Draft `SKILL.md`, plus any script, and show it before writing anything.
3. After an explicit OK, write it to `<name>/` in the user skills directory as real files, not symlinks. The name uses lowercase letters, digits, and hyphens.
4. Run `"$TOASTTY_CLI_PATH" setup skills list` and fix any exclusion it reports.
5. Offer to try it in a new agent session on a small task.
