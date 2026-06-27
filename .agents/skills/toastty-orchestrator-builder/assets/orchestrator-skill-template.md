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
- If using an `instance.json`, read its recorded socket path and pass that exact socket path to every live Toastty CLI command that targets the app.
- If more than one Toastty instance may be running, do not guess. Use the intended `instance.json` or explicit socket path, and stop when the target remains ambiguous.
- Use a single socket argument convention in examples and generated commands:

```bash
SOCKET_ARGS=()
# If targeting an explicit socket, use:
# SOCKET_ARGS=(--socket-path "$SOCKET_PATH")
```

## Workflow Contracts

- Target environment: <app, repo, domain, or workflow environment>.
- Local instructions and validation sources: <repo instructions, docs, skill files, commands, acceptance checks, or "ask when unclear">.
- Required agent profile, model, reasoning level, and role capabilities: <hard requirements and how each can be verified>.
- Preferred agent profile, model, reasoning level, and role capabilities: <preferences that may fall back with approval>.
- Fallback behavior when a required or preferred agent profile or validation source is unavailable: <stop, ask, or approved fallback>.
- Profile verification source: <live `agent.launch` discovery, known profile config, user-provided profile ID, documented command, or "ask when unverifiable">.

## Capability Discovery

Run live discovery before relying on app-control IDs:

```bash
"$TOASTTY_CLI_PATH" "${SOCKET_ARGS[@]}" --json action list
"$TOASTTY_CLI_PATH" "${SOCKET_ARGS[@]}" --json query list
```

Record only the workflow-relevant actions and queries in the handoff or final report.

Check `.ok == true` before using JSON response results. On `.ok == false`, branch on `.error.code` and preserve the error in the report.

## Scope Policy

- Start by scoping the current managed session:

```bash
"$TOASTTY_CLI_PATH" "${SOCKET_ARGS[@]}" --json session scope set-current
```

- Use `session scope add --workspace <id>` only for workspaces explicitly assigned by the user or for workflow-created child workspaces that this orchestrator is explicitly authorized to manage.
- After creating or adding a workspace, record its workspace ID, verify the resulting scope with `session scope show`, and stop if the expected workspace is not in scope.
- On `scope_denied`, stop that operation and report the workspace boundary unless the workflow already authorizes adding that workspace.
- Treat scope as cooperative orchestration guidance, not a security sandbox.
- Do not use automation-only/debug commands as a workaround for scoped app-control denial.
- Apply the same `SOCKET_ARGS` to every live scope command:

```bash
"$TOASTTY_CLI_PATH" "${SOCKET_ARGS[@]}" --json session scope add --workspace "$WORKSPACE_ID"
"$TOASTTY_CLI_PATH" "${SOCKET_ARGS[@]}" --json session scope show
```

- Clear scope only during explicit cleanup:

```bash
"$TOASTTY_CLI_PATH" "${SOCKET_ARGS[@]}" --json session scope clear
```

## Workflow

1. Snapshot current state:
   - `query run terminal.state`
   - `query run workspace.snapshot`
2. Prepare the workspace/panel layout:
   - <workspace creation or selection steps>
   - <panel setup steps>
   - <scope verification after created or assigned workspaces>
3. Launch or coordinate agents:
   - <agent.launch or existing-session steps>
   - <required agent profile/model verification before launch; stop or ask when the required capability cannot be verified from the agreed source>
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
- Agent profile/model used, required capabilities verified, and fallback or stop decisions.
- Artifacts created or updated.
- Remaining manual checks or user approvals.

## Validation

Validate the generated workflow with the narrowest practical check:

- Use the target workflow's own validation source when known, such as repo-local instructions, repo-local verify skills, documented commands, or user-provided acceptance checks. If the validation source is unknown, ask instead of substituting unrelated repo-specific validation.
- Dry-run discovery commands when no live mutation is needed.
- Use a disposable throwaway workspace for mutation tests, and run those tests only after the user approves a live Toastty mutation check.
- Confirm generated skill frontmatter with the active skill validator, and check `agents/openai.yaml` only when that file exists and the target repo uses it.
