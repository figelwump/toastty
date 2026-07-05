---
name: toastty-capabilities
description: Use this skill when a user asks an agent to orchestrate, inspect, automate, control, coordinate, or present work inside Toastty, including creating workspaces or panels, launching agents, opening browser or local-document panels, using Scratchpad, checking terminal state, managing workspace scope, or notifying the user.
---

# Toastty Capabilities

Use this skill to drive Toastty from an agent session. Toastty provides a bundled CLI that talks to the running app over its automation socket. Prefer live discovery and typed descriptors over copied command catalogs.

## Environment Contract

In a Toastty-launched agent terminal, expect:

- `TOASTTY_CLI_PATH`: absolute path to the bundled `toastty` CLI.
- `TOASTTY_PANEL_ID`: current terminal panel ID.
- `TOASTTY_SESSION_ID`: current managed session ID when the agent was launched by Toastty.
- `TOASTTY_SOCKET_PATH`: resolved socket path for the owning app instance.
- `TOASTTY_CWD`: launch working directory when Toastty knows it.
- `TOASTTY_REPO_ROOT`: repository root when Toastty inferred one.

Always invoke the injected CLI:

```bash
"$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID"
```

If `TOASTTY_CLI_PATH` is missing, not executable, or the probe fails, do not guess which Toastty instance to target. Ask the user to run you from a Toastty pane or provide an explicit socket path.

## Discovery Loop

Discover the live app-control surface before composing a workflow:

```bash
"$TOASTTY_CLI_PATH" --json action list
"$TOASTTY_CLI_PATH" --json query list
```

Use the returned descriptors for canonical IDs, selectors, parameters, aliases, summaries, repeatability, and allowed values. Do not duplicate the whole catalog in your prompt or skill output. For every JSON response, check `.ok == true` before reading `.result`; if `.ok` is false, branch on `.error.code` and preserve the message in your report.

## Workspace, Panel, And Session Model

Toastty has windows, workspaces, workspace tabs, and panels. A terminal panel can host a managed agent session. App-control selectors target `windowID`, `workspaceID`, and `panelID`; many commands can infer a target, but robust workflows should pass explicit IDs from `terminal.state`, `workspace.snapshot`, or action results.

Common workflow families:

- Workspaces and tabs: `workspace.create`, `workspace.select`, `workspace.rename`, `workspace.tab.create`, `workspace.tab.select`.
- Panels: `panel.create.browser`, `panel.create.local-document`, `panel.close`, `panel.focus-mode.toggle`.
- Terminal control: `terminal.send-text`, `terminal.visible-text`, `terminal.state`.
- Agents: `agent.launch`.
- Scratchpad: `panel.scratchpad.set-content`, `panel.scratchpad.patch-content`, `panel.scratchpad.export`, `panel.scratchpad.state`.
- Notifications: `toastty notify`.

## Scope Semantics

Workspace scope is cooperative guidance, not a security sandbox. A scoped session may automate its current workspace and explicitly assigned workspaces. Requests from a managed session carry caller identity from `TOASTTY_SESSION_ID`.

Use scope intentionally:

```bash
"$TOASTTY_CLI_PATH" --json session scope set-current
"$TOASTTY_CLI_PATH" --json session scope show
"$TOASTTY_CLI_PATH" --json session scope add --workspace "<workspace-id>"
"$TOASTTY_CLI_PATH" --json session scope clear
```

Treat `scope_denied` as a boundary signal. Do not retry with broader targets unless the user explicitly assigned that workspace or the workflow already authorized scope expansion. Explain what was denied and ask before expanding.

## Worked Examples

### Launch An Agent In A New Workspace

```bash
window_id="$(
  "$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["windowID"])'
)"

workspace_id="$(
  "$TOASTTY_CLI_PATH" --json action run workspace.create \
    --window "$window_id" \
    title="Review" \
    activate=false \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["workspaceID"])'
)"

"$TOASTTY_CLI_PATH" --json action run agent.launch \
  --workspace "$workspace_id" \
  profileID=codex \
  cwd="$PWD" \
  initialPrompt="Review this change and report findings only."
```

Record the returned `sessionID`, `workspaceID`, and `panelID`. If you need to scope the child, apply scope to the returned child session, not the parent by accident.

### Open Browser And Local Document Panels

```bash
"$TOASTTY_CLI_PATH" --json action run panel.create.browser \
  --workspace "$workspace_id" \
  url="https://example.com"

"$TOASTTY_CLI_PATH" --json action run panel.create.local-document \
  --workspace "$workspace_id" \
  filePath="$PWD/docs/plan.md"
```

Omit `placement` unless the workflow has a reason to override Toastty's default placement.

### Publish To Scratchpad

Use Scratchpad for visual summaries, diagrams, QA packets, comparisons, or dashboards. Prefer a complete HTML document for first publish or major rewrites:

```bash
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.set-content \
  --stdin content \
  "sessionID=$TOASTTY_SESSION_ID" \
  title="Review Summary" < /tmp/review-summary.html
```

For small exact updates, export or query state first and then use `panel.scratchpad.patch-content` with the current revision.

### Notify The User

Use notifications for ready, needs-approval, or error states:

```bash
"$TOASTTY_CLI_PATH" notify "Review ready" "The background review is complete." \
  --workspace "$workspace_id" \
  --panel "$panel_id"
```

## When To Create Another Skill

If the user asks for a recurring Toastty workflow, write a dedicated skill for that workflow instead of embedding a long orchestration plan in every response. A good dedicated skill should describe the workflow intent, required Toastty context, scope policy, live discovery steps, actions and queries to use, validation, and failure handling.
