# Toastty Agent Hooks

Toastty can invoke one user-configured executable for normalized managed-session
lifecycle and actionable status events. The hook is global: every managed agent
session (Codex, Claude Code, OpenCode, MiMo Code, Pi, and process watch) reports
through the same script with the same normalized contract. There is no
per-agent hook configuration and no raw provider-event passthrough.

## Configuration

Set `agent-hook` in the Toastty config file (see
[Configuration](configuration.md)):

```toml
agent-hook = "~/.toastty/hooks/agent-hook"
```

The configured path must exist, be a regular file, be executable, and start
with a valid shebang — Toastty executes it directly, not through a shell. A
leading `~` expands to your home directory. A missing or unusable path never
breaks session handling; Toastty logs a deduplicated warning and continues.
`Toastty > Reload Configuration` applies path changes and reports a warning
when the configured path is currently missing or non-executable.

On launch, Toastty creates a commented starter template at
`~/.toastty/hooks/agent-hook` (write-once; an existing file is never
overwritten). It is executable but inert — every event is stubbed with
commented example actions and the contract summarized inline — so enabling it
is just uncommenting what you need and setting `agent-hook` as above.
Runtime-isolated dev instances materialize the template under their runtime
home instead of the real `~/.toastty`.

## Events

Event names are stable public strings:

| Event | Fired when |
|---|---|
| `session-start` | A managed session starts. `launchReason` distinguishes `managed`, `restore`, and `process-watch` starts. |
| `turn-complete` | The session's accepted status becomes `ready` after previously being another kind, once any waiting-on-children or resuming projection clears. |
| `needs-approval` | The accepted status becomes `needs_approval` from another kind. |
| `session-error` | The accepted status becomes `error` from another kind. |
| `session-stop` | The session ends, from any teardown path (explicit stop, panel close, workspace/window close, layout-profile replacement, terminal command exit, replacement launch, or process-watch completion). Generated exactly once per session before queueing; delivery remains subject to the overload policy below. |

For process-watch sessions, command completion emits the final ready/error
status followed by `session-stop`. The completed row remains visible until it
is replaced or its panel is torn down; the stop ends hook delivery, not the
row's UI lifetime.

`idle` and `working` statuses update transition state but do not invoke the
script. Deduplication is by accepted status kind, not event name:
`needs_approval -> ready` and `error -> ready` each emit `turn-complete`, while
a repeated identical status kind emits nothing.

Hook delivery is automation behavior, not notification behavior. Events fire
for focused panels even when desktop notifications would be suppressed, and the
UI-only focused `ready -> idle` collapse never hides a hook event.

When a `ready` status arrives while the session still shows background
children (child agents or subagents) or a resuming projection, the
`turn-complete` event is held and emitted once the session becomes actionable.
A later non-ready status or session teardown cancels the held event; a
long-running child keeps it pending rather than forcing a false completion.

## Execution model

- Invocations are enqueued without blocking Toastty. Events for one session run
  strictly in order; different sessions run concurrently, with at most four
  hook processes running globally.
- Each invocation gets a 10-second execution window, then SIGTERM, then SIGKILL
  after a one-second grace period. Signals target the direct hook process only;
  descendant/background process lifetime is the script's responsibility.
- Per session, at most 8 events wait in the queue, including an event waiting
  for a global process slot. Lifecycle events take priority: when the queue is
  full, a new start or stop first removes the oldest queued status event. In a
  lifecycle-only overload, the oldest queued lifecycle event is evicted so the
  queue remains bounded and the newest lifecycle state is retained. Every drop
  is logged. A running invocation is never cancelled.
- The event JSON is written to stdin, then stdin is closed. stdout and stderr
  are redirected to `/dev/null`, so the script can write freely without
  deadlocking. Toastty logs invocations, nonzero exits, timeouts, and launch
  failures.
- Config reload affects only newly enqueued events; queued and running events
  keep the script path captured when they were enqueued. Clearing `agent-hook`
  drains already-queued work but prevents new events.
- App termination is best-effort: pending or running hook invocations are not a
  shutdown barrier, and events around quit may be lost. Restored managed
  sessions emit a fresh `session-start` with `launchReason = "restore"` after
  relaunch.

## JSON payload (schema v1)

```json
{
  "schemaVersion": 1,
  "event": "turn-complete",
  "timestamp": "2026-08-06T20:15:30.123Z",
  "sessionID": "6BB93A4C-6E4E-4F0F-9E3F-58F4E5D9A210",
  "agent": "codex",
  "workspaceID": "F2C7B9B4-8A5C-45B9-9350-2C5E9DDA5A88",
  "panelID": "7D1B429E-3A62-4E11-BE41-1A315E1E7ACD",
  "cwd": "/repo",
  "previousStatus": "working",
  "newStatus": "ready",
  "launchReason": null
}
```

- `timestamp` is ISO-8601 UTC with millisecond precision.
- `agent` is the lowercase agent ID; process watch reports `process-watch`.
- `cwd` is the session working directory, or `null` when unknown.
- `previousStatus` / `newStatus` are accepted status kinds (`idle`, `working`,
  `needs_approval`, `ready`, `error`). For `session-start` both are `null`;
  for `session-stop`, `previousStatus` is the last accepted kind and
  `newStatus` is `null`.
- `launchReason` is `managed`, `restore`, or `process-watch` for
  `session-start` and `null` otherwise.

Schema v1 consumers must ignore unknown JSON fields. Breaking field changes
require a schema-version increment.

## Environment

Each invocation inherits the app environment plus:

| Variable | Value |
|---|---|
| `TOASTTY_HOOK_SCHEMA_VERSION` | `1` |
| `TOASTTY_HOOK_EVENT` | The event name. |
| `TOASTTY_AGENT` | The lowercase agent ID (`codex`, `claude`, `process-watch`, …). |
| `TOASTTY_SESSION_ID` | The managed session ID. |
| `TOASTTY_WORKSPACE_ID` | The workspace UUID. |
| `TOASTTY_PANEL_ID` | The panel UUID. |
| `TOASTTY_SESSION_CWD` | The session working directory, or empty. |
| `TOASTTY_CLI_PATH` | The absolute path of this Toastty instance's staged CLI, or empty. |
| `TOASTTY_SOCKET_PATH` | This Toastty instance's automation socket path. |
| `TOASTTY_LAUNCH_REASON` | `managed`, `restore`, or `process-watch` for `session-start`; empty otherwise. |

Optional values are present as empty strings, never unset. The CLI and socket
paths always describe the exact running Toastty instance that invoked the hook,
including runtime-isolated dev instances.

## Calling back into Toastty

Hook scripts may call Toastty CLI actions; per-session serialization prevents
overlapping invocations for the same session. Example: keep a status chip
under the workspace name in sync with the latest session state using
workspace annotations, and rename the workspace on approval waits. Use a stable
semantic annotation key such as `agent` here so later calls update the same
chip and preserve its first-use global color; do not derive the key from the
current display text or try to repaint it as status changes.

```bash
#!/bin/bash
# ~/.toastty/hooks/agent-hook
set -euo pipefail

payload=$(cat)

case "$TOASTTY_HOOK_EVENT" in
turn-complete)
    "$TOASTTY_CLI_PATH" action run workspace.set-annotation \
        --workspace "$TOASTTY_WORKSPACE_ID" \
        key=agent \
        text="$TOASTTY_AGENT done"
    ;;
needs-approval)
    "$TOASTTY_CLI_PATH" action run workspace.set-annotation \
        --workspace "$TOASTTY_WORKSPACE_ID" \
        key=agent \
        text="$TOASTTY_AGENT waiting on you"
    "$TOASTTY_CLI_PATH" action run workspace.rename \
        --workspace "$TOASTTY_WORKSPACE_ID" \
        title="Waiting on approval"
    ;;
session-stop)
    "$TOASTTY_CLI_PATH" action run workspace.clear-annotation \
        --workspace "$TOASTTY_WORKSPACE_ID" \
        key=agent
    ;;
esac
```

See [CLI Reference](cli-reference.md) for the full action catalog and the
annotation validation rules.

## Related docs

- [Configuration](configuration.md)
- [Running Agents](running-agents.md)
- [CLI Reference](cli-reference.md)
- [Privacy and Local Data](privacy-and-local-data.md)
