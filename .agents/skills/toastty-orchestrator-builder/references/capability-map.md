# Toastty Orchestration Capability Map

Use this map when designing a workflow-specific orchestrator skill. Prefer live discovery over stale lists.

## Instance Targeting

Use the exact running Toastty instance. In a Toastty-managed session, first probe the injected CLI and current panel:

```bash
"$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID"
```

Managed sessions usually receive:

- `TOASTTY_CLI_PATH`
- `TOASTTY_SOCKET_PATH`
- `TOASTTY_SESSION_ID`
- `TOASTTY_PANEL_ID`
- `TOASTTY_CWD`
- `TOASTTY_REPO_ROOT`

Treat live capability discovery as available only when `TOASTTY_CLI_PATH` is executable and a probe such as `terminal.state` succeeds. If the probe fails, do not guess which app to target.

If multiple Toastty instances may be running, prefer an explicit `instance.json` from the intended runtime or a user-provided socket path. Runtime-isolated `instance.json` files live under that run's `runtime-home/` and record the authoritative `socketPath`, PID, runtime label, and log paths. Pass the recorded socket with `--socket-path`.

## Live Discovery

Discover the current app-control surface:

```bash
"$TOASTTY_CLI_PATH" --json action list
"$TOASTTY_CLI_PATH" --json query list
```

Use returned descriptors for canonical IDs, selectors, parameters, aliases, and summaries.

For CLI JSON responses, check `.ok == true` before using `.result`. If `.ok` is false, branch on `.error.code` and preserve the error in the report. Treat `scope_denied` as a boundary signal; do not retry with a broader target unless the workflow already authorizes scope expansion.

## Capability Families

### Workspaces, Tabs, And Windows

Common actions:

- `window.create`
- `window.sidebar.toggle`
- `workspace.create`
- `workspace.select`
- `workspace.move`
- `workspace.rename`
- `workspace.close`
- `workspace.tab.create`
- `workspace.tab.select`
- `workspace.tab.move`
- `workspace.tab.rename`
- `workspace.tab.close`

Useful for orchestrators that create one workspace per role, keep review/work/test areas separate, or route agents into background workspaces.

### Panels

Common actions:

- `panel.close`
- `panel.create.browser`
- `panel.create.local-document`
- `panel.focus-mode.toggle`

Common queries:

- `panel.local-document.state`
- `panel.browser.state`
- `panel.scratchpad.state`

Useful for opening handoff docs, browser references, local markdown plans, or inspecting panel state.

### Terminal Control

Common actions:

- `terminal.send-text`
- `terminal.drop-image-files`

Common queries:

- `terminal.state`
- `terminal.visible-text`

`terminal.send-text` does not move AppKit keyboard focus. Select or focus separately when the user needs the target panel to become interactive.

### Managed Agents

Common action:

- `agent.launch`

Use it to start built-in profiles such as `codex`, `claude`, `opencode`, `mimocode`, or `pi`, or configured custom profiles. Include explicit `cwd`, optional `initialCommands`, optional `env.NAME=value`, and optional `initialPrompt` when the workflow requires them.

When `agent.launch` returns a child `sessionID`, record that ID with the target `workspaceID` and `panelID`. Apply any post-launch scope policy to the returned child session, not to the parent by accident.

### Session Lifecycle

Common commands:

```bash
"$TOASTTY_CLI_PATH" session start --agent <id> --panel <panel-id>
"$TOASTTY_CLI_PATH" session status --session <id> --kind working --summary "..."
"$TOASTTY_CLI_PATH" session update-files --session <id> --file <path>
"$TOASTTY_CLI_PATH" session stop --session <id> --reason "..."
```

Use these for custom agents, wrappers, or orchestration status reporting. Built-in managed agents may already emit these through Toastty instrumentation.

### Scratchpad Artifacts

Common actions:

- `panel.scratchpad.set-content`
- `panel.scratchpad.patch-content`
- `panel.scratchpad.rebind`
- `panel.scratchpad.export`

Use Scratchpad for structured summaries, comparison matrices, QA packets, release notes drafts, review dashboards, or live workflow artifacts linked to a managed session.

### Notifications

Command:

```bash
"$TOASTTY_CLI_PATH" notify "Title" "Body" --workspace <workspace-id> --panel <panel-id>
```

Use notifications for `needs_approval`, `ready`, or `error` states when the user should return to the workflow.

### Automation-Only Or Debug Surfaces

Automation-mode commands such as screenshot capture, fixture loading, state dumps, and render snapshots are useful for validation and demos, but they are not the live orchestration API.

Use app-control actions and queries for normal orchestrators. Reach for automation-only commands only when the generated workflow explicitly targets validation, visual capture, or disposable automation runs.

Important scope note: legacy/debug automation commands may sit outside v1 workspace-scope enforcement unless they delegate through app-control. Do not use them to prove a scoped workflow boundary, and do not use them as a way around `scope_denied`.

## Scope Contract

Default scope setup:

```bash
"$TOASTTY_CLI_PATH" --json session scope set-current
```

Scope management:

```bash
"$TOASTTY_CLI_PATH" --json session scope show
"$TOASTTY_CLI_PATH" --json session scope add --workspace <workspace-id>
"$TOASTTY_CLI_PATH" --json session scope clear
```

Rules for generated orchestrators:

- Start scoped unless the user explicitly wants unrestricted automation.
- Use an empty explicit scope for current-workspace-only operation.
- Add only user-assigned workspaces.
- Treat `scope_denied` as a boundary signal, not a failure to bypass.
- Explain that scoping is cooperative and not a security boundary.

## Source References

Use these repo docs for current details:

- `docs/cli-reference.md`
- `docs/socket-protocol.md`
- `docs/agents/workspace-scope.md`
- `docs/agents/automation.md`
