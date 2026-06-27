---
name: <generated-skill-name>
description: Use this skill when <specific workflow trigger>. It coordinates Toastty <workspaces/panels/agents/artifacts> for <workflow> and applies cooperative workspace scoping by default.
---

# <Generated Skill Title>

Use this workflow to <one-sentence outcome>.

## Preconditions

- Confirm a Toastty-managed environment when the workflow needs the live app:
  - `TOASTTY_CLI_PATH`
  - `TOASTTY_SOCKET_PATH` or an explicit `--socket-path`
  - `TOASTTY_SESSION_ID`
  - `TOASTTY_PANEL_ID`
- If not running inside Toastty, ask for the target `instance.json` or socket path.
- If more than one Toastty instance may be running, do not guess. Use the intended `instance.json` or explicit socket path.

## Capability Discovery

Run live discovery before relying on app-control IDs:

```bash
"$TOASTTY_CLI_PATH" --json action list
"$TOASTTY_CLI_PATH" --json query list
```

Record only the workflow-relevant actions and queries in the handoff or final report.

Check `.ok == true` before using JSON response results. On `.ok == false`, branch on `.error.code` and preserve the error in the report.

## Scope Policy

- Start by scoping the current managed session:

```bash
"$TOASTTY_CLI_PATH" --json session scope set-current
```

- Use `session scope add --workspace <id>` only for workspaces explicitly assigned by the user or created by this workflow.
- On `scope_denied`, stop that operation and report the workspace boundary unless the workflow already authorizes adding that workspace.
- Treat scope as cooperative orchestration guidance, not a security sandbox.
- Do not use automation-only/debug commands as a workaround for scoped app-control denial.
- Clear scope only during explicit cleanup:

```bash
"$TOASTTY_CLI_PATH" --json session scope clear
```

## Workflow

1. Snapshot current state:
   - `query run terminal.state`
   - `query run workspace.snapshot`
2. Prepare the workspace/panel layout:
   - <workspace creation or selection steps>
   - <panel setup steps>
3. Launch or coordinate agents:
   - <agent.launch or existing-session steps>
4. Exchange artifacts:
   - <Scratchpad, local-document, notification, or file-update steps>
5. Track status:
   - `session status --kind working|needs_approval|ready|error`
   - `session update-files` when files change
6. Finish:
   - <summary/reporting>
   - <scope cleanup policy>
   - <child-session stop policy>

## Reporting

Report:

- Workspace IDs and panel IDs used.
- Session IDs launched or coordinated.
- Scope state and any `scope_denied` events.
- Actions/queries used.
- Artifacts created or updated.
- Remaining manual checks or user approvals.

## Validation

Validate the generated workflow with the narrowest practical check:

- Dry-run discovery commands when no live mutation is needed.
- Use a disposable throwaway workspace for mutation tests, and run those tests only after the user approves a live Toastty mutation check.
- Confirm generated skill frontmatter and `agents/openai.yaml` with the active skill validator.
