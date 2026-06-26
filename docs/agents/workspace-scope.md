# Workspace Scope

Toastty supports opt-in cooperative workspace scoping for orchestration automation. It is meant to help agent sessions stay inside user-assigned workspaces. It is not a hard security sandbox and does not isolate terminal processes, filesystems, credentials, or every legacy/debug automation command.

## Semantics

- Unscoped sessions are unrestricted.
- Scoped sessions are scoped at workspace granularity.
- A scoped session can automate its current workspace and every workspace explicitly assigned to it.
- The current-workspace allowance is live. If the session moves to another workspace, that implicit allowance follows the session.
- An empty explicit scope means the session is scoped to its current workspace only.
- Sessions in the same workspace share automation access to that workspace.
- Requests without a caller session ID are unrestricted.
- Requests from an unknown or stopped caller session are unrestricted in v1, and Toastty logs a warning once for that caller.

Managed sessions stamp caller identity from their own `TOASTTY_SESSION_ID` environment. A session that clears or forges that value can bypass this cooperative scope, so workspace scope must not be treated as an authorization or security boundary.

## Child Launches

When a scoped parent launches a child session, the child inherits a snapshot of the parent's effective workspace scope at launch time. Later scope changes on the parent do not update the child automatically. Unscoped parents launch unscoped children.

If a scoped session creates a workspace through `workspace.create`, Toastty binds the new workspace into that session's explicit scope before returning success. Agent launches into existing workspaces require access to the target workspace.

## CLI

Use the bundled CLI from a managed session or pass `--session` explicitly:

```bash
toastty session scope show [--session <id>]
toastty session scope set-current [--session <id>]
toastty session scope set [--session <id>] --workspace <id> [--workspace <id> ...]
toastty session scope add [--session <id>] --workspace <id> [--workspace <id> ...]
toastty session scope clear [--session <id>]
```

When `--session` is omitted, the CLI uses `TOASTTY_SESSION_ID`. If neither is available, the command fails with a usage error.

Use `set-current` from inside a managed session to fence that session to its current workspace. It requires `TOASTTY_PANEL_ID`, verifies that panel still belongs to a Toastty workspace, and stores an empty explicit scope so future own-workspace access remains live. Use `add --workspace` only for additional pre-existing workspaces the user explicitly assigned, and `clear` to return to unrestricted automation.

## Enforcement Coverage

V1 enforcement focuses on orchestration-relevant app-control paths, including workspace and terminal targeting, reading terminal state or visible text, sending terminal text, browser/local-document/Scratchpad panel targets, workspace creation, and agent launch.

Legacy and debug automation-mode commands such as `automation.reset`, `automation.load_fixture`, `automation.dump_state`, `automation.capture_screenshot`, and session/status events are outside v1 scope enforcement unless they delegate through app-control. Treat workspace scope as cooperative guidance, not complete automation isolation.

When a scoped request targets an unassigned workspace, Toastty returns:

```json
{
  "code": "scope_denied",
  "message": "This workspace is outside your assigned scope. If the user explicitly assigned it, run toastty session scope add; otherwise stop and report."
}
```
