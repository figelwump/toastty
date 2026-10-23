# Toastty Workflow Guide

This guide is for an agent helping a user turn how they work into a Toastty workflow: a skill that tells agents which Toastty building blocks to use, and when. Follow the user's lead. Suggest ideas, but build only what they ask for.

## What a workflow skill is

A workflow skill is a folder in the user skills directory, `$TOASTTY_USER_SKILLS_ROOT` (normally `~/.toastty/skills`), with a `SKILL.md` file. Its YAML frontmatter has a `name` that matches the folder name and a `description` that says when an agent should use it. The folder can also hold `scripts/` and `references/`.

Toastty delivers every accepted skill in that folder to each new managed Codex, Claude Code, Cursor, Grok Build, OpenCode, MiMo Code, and Pi session. Running sessions keep the skills they launched with, so test a new or edited skill in a fresh session.

Write the skill as intended behavior and constraints, not as a fixed script of commands. The agent that runs it discovers exact parameters from the live app.

## Building blocks

- **Workspaces and task spaces**: `workspace.create` makes a workspace for a project or task. `workspace.set-parent` nests it under the workspace that started it, so it shows as a task space in the sidebar. `workspace.set-done` marks finished work.
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

- **Finishing tasks** ("merge it", "clean up"): accepts a task's reviewed PR, turns on auto-merge, and removes merged worktrees. Starting a task in its own worktree is built in. Toastty bundles these; see below.
- **Issue to PR** ("start ENG-412"): reads a Linear or GitHub issue, names a workspace after it with a chip linking back, drafts the plan in a Scratchpad, and links the PR on the issue when it is up.
- **Review queue** ("review my PRs"): opens a task space per requested review with the diff in the browser, writes notes into a Scratchpad, and notifies the user as each one is ready.
- **Spec to tasks** ("build from this spec"): opens a spec from Google Docs, Notion, or a Markdown file beside the terminal, splits it into tasks, starts a task space for each, and keeps a progress page current.
- **Crash to fix** ("fix this crash"): reproduces a Sentry report or log error in a worktree with the dev server in a split the agent can read, then shows before and after screenshots.
- **Second opinion** ("ask another model"): runs two agents side by side on the same question and compares their answers in a Scratchpad.

## Worked example: the task lifecycle

Starting and finishing a task needs no personal skill. The shipped `toastty-task-start` skill runs `toastty task start-work`, and Toastty makes the worktree and continues the conversation there. When the user presses Merge on a task, or says "merge it", the shipped `toastty-task-merge` skill checks the pull request: unresolved review threads, merge prerequisites in its description, tasks that must land first, and CI. If nothing blocks, it runs `toastty task merge`; otherwise it reports the blockers and stops. Toastty then merges at the commit the skill checked, waits for checks that still run, and after the agent's turn ends closes the task space and removes its worktree. The checks need an authenticated `gh` CLI.

To change how a project merges, set its `merge_skill` in `~/.toastty/tasks.toml` to the user's own skill, or set `merge = "direct"` to merge without an agent. A custom merge skill decides, then calls `toastty task merge`; it does not merge with `gh` itself, so Toastty stays the one place that merges and cleans up. In the same way, `start_skill` names the skill every new task's first message starts with, and `release_skill` the one a release task starts with; Toastty does not check that the agent has the skill.

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
