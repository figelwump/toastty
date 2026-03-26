# Toastty CLI Reference

Toastty bundles a `toastty` CLI that communicates with the running app over its automation Unix socket. The CLI is primarily used by agents and wrapper scripts to report session status, file changes, and notifications back to the sidebar.

When Toastty launches an agent it injects `TOASTTY_CLI_PATH` into the environment, pointing at the bundled executable. All examples below assume you invoke the CLI through that path.

## Global options

| Option | Description |
|---|---|
| `--json` | Return structured JSON instead of human-readable text |
| `--socket-path <path>` | Override the automation socket path |
| `-h`, `--help` | Print usage information |

**Socket resolution order:** `--socket-path` flag > `TOASTTY_SOCKET_PATH` env var > app-resolved default socket path. For runtime-isolated launches, that default starts from the stable runtime-home-derived socket path and can resolve to a per-process sibling such as `events-v1-<pid>.sock` if the stable path is already owned by a live listener.

## Commands

### `notify`

Emit a macOS desktop notification.

```
toastty notify <title> <body> [--workspace <id>] [--panel <id>]
```

| Argument / Option | Required | Description |
|---|---|---|
| `<title>` | yes | Notification title |
| `<body>` | yes | Notification body |
| `--workspace <id>` | no | Target workspace UUID |
| `--panel <id>` | no | Target panel UUID |

```bash
"$TOASTTY_CLI_PATH" notify "Build Complete" "All tests passed"
```

### `session start`

Create a new agent session for a terminal panel.

```
toastty session start --agent <id> --panel <id> [--session <id>] [--cwd <path>] [--repo-root <path>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--agent <id>` | yes | `TOASTTY_AGENT` | Agent profile ID |
| `--panel <id>` | yes | `TOASTTY_PANEL_ID` | Terminal panel UUID |
| `--session <id>` | no | `TOASTTY_SESSION_ID` | Session ID (auto-generated if omitted) |
| `--cwd <path>` | no | `TOASTTY_CWD` | Panel working directory |
| `--repo-root <path>` | no | `TOASTTY_REPO_ROOT` | Git repository root |

Returns the resolved session ID.

### `session status`

Update the status of an active session. This drives the sidebar indicator and can trigger unread badges and desktop notifications.

```
toastty session status --session <id> --kind <kind> --summary <text> [--panel <id>] [--detail <text>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--kind <kind>` | yes | — | One of `idle`, `working`, `needs_approval`, `ready`, `error` |
| `--summary <text>` | yes | — | Short status line (non-empty) |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--detail <text>` | no | — | Additional detail text |

**Kind values:**

| Kind | Meaning | Triggers notification? |
|---|---|---|
| `idle` | Waiting for input | no |
| `working` | Actively processing | no |
| `needs_approval` | Awaiting user approval | yes |
| `ready` | Finished, ready for review | yes |
| `error` | Error state | yes |

```bash
"$TOASTTY_CLI_PATH" session status \
  --session "$TOASTTY_SESSION_ID" \
  --kind working \
  --summary "Analyzing code"
```

### `session update-files`

Report files changed during a session.

```
toastty session update-files --session <id> --file <path> [--file <path> ...] [--panel <id>] [--cwd <path>] [--repo-root <path>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--file <path>` | yes | — | Changed file path (repeatable) |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--cwd <path>` | no | `TOASTTY_CWD` | Base directory for relative paths |
| `--repo-root <path>` | no | `TOASTTY_REPO_ROOT` | Git repository root |

Multiple `--file` arguments can be provided. Relative paths are resolved against `--cwd`. File updates are coalesced server-side with a 0.5-second window per session.

```bash
"$TOASTTY_CLI_PATH" session update-files \
  --session "$TOASTTY_SESSION_ID" \
  --file src/main.rs \
  --file Cargo.toml
```

### `session stop`

End an active session.

```
toastty session stop --session <id> [--panel <id>] [--reason <text>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--reason <text>` | no | — | Reason for stopping |

```bash
"$TOASTTY_CLI_PATH" session stop \
  --session "$TOASTTY_SESSION_ID" \
  --reason "User cancelled"
```

### `session ingest-agent-event`

Process agent lifecycle events from stdin. This is a CLI-local command used by the built-in Claude and Codex instrumentation — it reads structured event JSON from stdin and translates it into `session status` and `session stop` calls over the socket.

```
toastty session ingest-agent-event --source <source> [--session <id>] [--panel <id>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--source <source>` | yes | — | `claude-hooks` or `codex-notify` |
| `--session <id>` | no | `TOASTTY_SESSION_ID` | Session ID |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |

This command is not intended for third-party integrations. Custom agents should use `session status` and `session stop` directly.

Toastty's built-in Claude and Codex launch helpers invoke this command with an explicit `TOASTTY_SOCKET_PATH` injected at launch time. That injected value is the authoritative resolved socket path for the target app instance, including runtime-isolated fallback cases. If the helper cannot reach the app, it keeps the agent process alive but appends the CLI failure details to `telemetry-failures.log` in that session's temporary launch artifacts directory while the session remains active.

## Environment variables

When Toastty launches an agent, these variables are injected into the agent's environment:

| Variable | Description |
|---|---|
| `TOASTTY_CLI_PATH` | Absolute path to the bundled `toastty` CLI |
| `TOASTTY_SESSION_ID` | Session ID for the current agent run |
| `TOASTTY_PANEL_ID` | Terminal panel UUID |
| `TOASTTY_SOCKET_PATH` | Resolved automation socket path for the target app instance |
| `TOASTTY_CWD` | Panel working directory (if available) |
| `TOASTTY_REPO_ROOT` | Git repository root (if available) |

Most CLI flags fall back to their corresponding environment variable when not provided explicitly, so agents launched by Toastty can often omit flags like `--session` and `--panel`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime error (socket failure, validation error, bad response) |
| `64` | Usage error (invalid arguments, missing required flags) |

## Agent ID format

Agent IDs must be lowercase, start with a letter (`a-z`), and contain only letters, digits, hyphens, and underscores. Examples: `claude`, `codex`, `my-agent`, `custom_agent_2`.

## JSON output

When `--json` is passed, responses follow the automation protocol envelope:

```json
{
  "protocolVersion": "1.0",
  "kind": "response",
  "requestID": "...",
  "ok": true,
  "result": { ... }
}
```

Error responses set `ok: false` and include an `error` object with `code` and `message` fields.

## Custom agent integration example

A minimal wrapper script that reports status back to Toastty:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Toastty injects TOASTTY_CLI_PATH, TOASTTY_SESSION_ID, etc.
cli="$TOASTTY_CLI_PATH"
session="$TOASTTY_SESSION_ID"

"$cli" session status --session "$session" --kind working --summary "Starting"

# ... do work ...

"$cli" session update-files --session "$session" --file output.txt
"$cli" session status --session "$session" --kind ready --summary "Done"
"$cli" session stop --session "$session"
"$cli" notify "Agent finished" "Check the results"
```

See [running-agents.md](running-agents.md#custom-and-third-party-agents) for the full integration guide.
