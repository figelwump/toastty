# toastty socket protocol (v1)

Date: 2026-02-27

This document defines the local unix-socket protocol used by:

- agent adapters/wrappers (session lifecycle + attribution events)
- local CLI notifications (`toastty notify`)
- automation commands (`--automation` mode)

## 1) transport

- Type: unix domain socket
- Scope: per-user, local machine only
- Permissions: socket and parent directory are `0700`/`0600`
- TCP is not supported in v1

Default path resolution:

1. `TOASTTY_SOCKET_PATH` if set
2. `$TMPDIR/toastty-$UID/events-v1.sock`
3. `/tmp/toastty-$UID/events-v1.sock`

## 2) message framing

- UTF-8 JSON, newline-delimited (one JSON object per line)
- Maximum message size: 256 KiB
- Unknown fields must be ignored
- Unknown message kinds must return an error response when a `requestID` is present

## 3) versioning and compatibility

- `protocolVersion` format: `"major.minor"` (example: `"1.0"`)
- Different major version: reject request/event as incompatible
- Different minor version: accept when current-version required fields are present
- v1.0 required top-level fields by envelope:
  - event: `protocolVersion`, `kind`, `eventType`, `timestamp`, `payload`
  - request: `protocolVersion`, `kind`, `requestID`, `command`, `payload`
  - response: `protocolVersion`, `kind`, `requestID`, `ok`

## 4) envelope types

### event envelope (adapter/cli -> app)

```json
{
  "protocolVersion": "1.0",
  "kind": "event",
  "eventType": "session.update_files",
  "sessionID": "sess_123",
  "panelID": "26E78311-470E-4E62-8F6A-2F87F949D318",
  "timestamp": "2026-02-27T08:30:00Z",
  "payload": {}
}
```

### request envelope (automation client -> app)

```json
{
  "protocolVersion": "1.0",
  "kind": "request",
  "requestID": "D0FCA65E-6B36-4F00-AEAF-C5298C0E3E56",
  "command": "automation.capture_screenshot",
  "payload": {}
}
```

### response envelope (app -> automation client)

```json
{
  "protocolVersion": "1.0",
  "kind": "response",
  "requestID": "D0FCA65E-6B36-4F00-AEAF-C5298C0E3E56",
  "ok": true,
  "result": {}
}
```

Error response:

```json
{
  "protocolVersion": "1.0",
  "kind": "response",
  "requestID": "D0FCA65E-6B36-4F00-AEAF-C5298C0E3E56",
  "ok": false,
  "error": {
    "code": "INVALID_PAYLOAD",
    "message": "cwd is required when files are relative"
  }
}
```

## 5) event types and payloads

### `session.start`

Required top-level fields:

- `sessionID: String`
- `panelID: UUID`

Payload:

- `agent: "claude" | "codex"` (required)
- `cwd?: String` (absolute path)
- `repoRoot?: String` (absolute path)

Validation:

- Missing `agent` must return `INVALID_PAYLOAD`.

### `session.update_files`

Required top-level fields:

- `sessionID: String`
- `panelID: UUID`

Payload:

- `files: [String]` (absolute paths preferred)
- `cwd?: String` (absolute path, required when any file path is relative)
- `repoRoot?: String` (absolute path)

Normalization:

- If `files` are absolute, they are used as-is.
- If any `files` are relative, `cwd` is required and used for normalization.
- If normalized file is outside `repoRoot`, mark file as out-of-scope for diff rendering.
- If later `session.update_files` events send a conflicting `repoRoot`, preserve the first accepted root and emit a warning state (`conflicting repo roots`) in app state.
- If payload exceeds max frame size, sender must split files across multiple `session.update_files` events.

### `session.needs_input`

Required top-level fields:

- `sessionID: String`
- `panelID: UUID`

Payload:

- `title: String`
- `body: String`

### `session.progress`

Required top-level fields:

- `sessionID: String`
- `panelID: UUID`

Payload:

- `message: String`

### `session.error`

Required top-level fields:

- `sessionID: String`
- `panelID: UUID`

Payload:

- `message: String`

### `session.stop`

Required top-level fields:

- `sessionID: String`
- `panelID: UUID`

Payload:

- `reason?: String`

### `notification.emit`

Used by CLI wrappers such as `toastty notify`.

Payload:

- `title: String`
- `body: String`
- `workspaceID?: UUID`
- `panelID?: UUID`

Routing rules:

- If `workspaceID` is present, use it.
- Else if `panelID` is present, resolve workspace from panel location.
- Else route to focused workspace when one exists.
- If no workspace can be resolved, return `INVALID_PAYLOAD`.

## 6) automation mode contract

Automation commands are accepted only when the app is launched with:

- args: `--automation --run-id <id> --fixture <name> --artifacts-dir <path>`
- env: `TOASTTY_AUTOMATION=1`

If automation mode is disabled:

- return `AUTOMATION_DISABLED` for all `automation.*` requests

Enablement rule:

- Both launch args and env marker are required. If either is missing, automation commands are rejected.

### readiness handshake

After fixture load and socket bind, app writes:

- `artifacts/ui/<run-id>/ready.json`

`run-id` is provided by required launch arg `--run-id`.

`ready.json` example:

```json
{
  "protocolVersion": "1.0",
  "ready": true,
  "socketPath": "/tmp/toastty-501/events-v1.sock",
  "fixture": "baseline-main",
  "timestamp": "2026-02-27T08:31:00Z"
}
```

Smoke script must wait for this file (with timeout) before sending commands.

## 7) automation commands

### `automation.ping`

Request payload: empty  
Result:

- `status: "ok"`
- `automationEnabled: Bool`
- `appUptimeMs: Int`
- `protocolVersion: String`

### `automation.reset`

Resets transient runtime state to baseline for deterministic test run.

Request payload:

- `clearNotifications?: Bool` (default `true`)
- `clearSessions?: Bool` (default `true`)

Result:

- `stateVersion: Int`

Semantics:

- `clearSessions=true`: clear `SessionRegistry` and session-linked transient metadata.
- `clearSessions=true` does not remove panel layout objects by itself.
- use `automation.load_fixture` after reset to reach deterministic full-state baseline.

### `automation.load_fixture`

Request payload:

- `name: String` (fixture name from `Automation/Fixtures/`)

Result:

- `fixture: String`
- `stateVersion: Int`

### `automation.perform_action`

Request payload:

- `action: String` (typed app action id)
- `args?: Object`

Result:

- `stateVersion: Int`
- `warnings?: [String]`

### `automation.terminal_send_text`

Sends raw terminal input text to a resolved terminal panel.

Request payload:

- `text: String` (required; empty string allowed)
- `submit?: Bool` (default `false`; sends a Return key event after the text when `true`)
- `panelID?: UUID` (optional explicit terminal panel target)
- `workspaceID?: UUID` (optional; used when `panelID` is omitted)
- `allowUnavailable?: Bool` (default `false`)

Result:

- `workspaceID: UUID`
- `panelID: UUID`
- `submitted: Bool`
- `available: Bool`

Validation:

- rejects deprecated `waitForSurfaceMs` payload key.
- only reports `available=true` when the resolved terminal host is render-attached and ready to accept focused input.
- when `allowUnavailable=false`, unavailable terminal surfaces return `INVALID_PAYLOAD`.

### `automation.terminal_drop_image_files`

Simulates dropping image files into a resolved terminal panel.

Request payload:

- `files: [String]` (required; absolute paths preferred)
- `cwd?: String` (required when any file path is relative)
- `panelID?: UUID` (optional explicit terminal panel target)
- `workspaceID?: UUID` (optional; used when `panelID` is omitted)
- `allowUnavailable?: Bool` (default `false`)

Result:

- `workspaceID: UUID`
- `panelID: UUID`
- `requestedFileCount: Int`
- `acceptedImageCount: Int`
- `available: Bool`

Validation:

- normalizes paths using `cwd` for relative inputs.
- returns `INVALID_PAYLOAD` when no image file paths remain after normalization/filtering.
- when `allowUnavailable=false`, unavailable terminal surfaces return `INVALID_PAYLOAD`.

### `automation.terminal_visible_text`

Reads visible text from a resolved terminal panel.

Request payload:

- `panelID?: UUID`
- `workspaceID?: UUID`
- `contains?: String`

Result:

- `workspaceID: UUID`
- `panelID: UUID`
- `text: String`
- `contains?: Bool` (present when `contains` was requested)

### `automation.workspace_snapshot`

Returns deterministic workspace layout metrics for assertions.

Request payload:

- `workspaceID?: UUID` (defaults to selected workspace)

Result:

- `workspaceID: UUID`
- `slotCount: Int`
- `panelCount: Int`
- `focusedPanelID: UUID | null`
- `rootSplitRatio: Double | null`
- `slotIDs: [UUID]`
- `slotPanelIDs: [UUID]`

### `automation.capture_screenshot`

Request payload:

- `fixture?: String`
- `step: String`

Result:

- `path: String` (absolute output path)

Path contract:

- runtime output: `artifacts/ui/<run-id>/<fixture>/<step>.png`

Validation:

- if `fixture` is omitted, use currently loaded fixture name.
- if `fixture` is provided and differs from loaded fixture, return `INVALID_PAYLOAD`.

### `automation.dump_state`

Request payload:

- `includeRuntime?: Bool` (default `false`)

Result:

- `path: String` (JSON dump file path)
- `hash: String` (content hash for deterministic comparisons)

## 8) error codes

- `INVALID_JSON`
- `INVALID_ENVELOPE`
- `INCOMPATIBLE_PROTOCOL`
- `UNKNOWN_EVENT_TYPE`
- `UNKNOWN_COMMAND`
- `INVALID_PAYLOAD`
- `AUTOMATION_DISABLED`
- `TIMEOUT`
- `INTERNAL_ERROR`

## 9) security requirements

- Reject non-local transports.
- Reject symlinked socket paths outside owned directory.
- Enforce maximum message size.
- Sanitize all file paths used for fixtures/artifacts; no path traversal.
- Never execute shell commands from socket payloads.
- `panelID` is stable for the lifetime of a session; panel/window/workspace moves do not rewrite it in protocol messages.

## 10) event coalescing guidance

Agents may emit `session.update_files` at high frequency. The app is responsible for coalescing these events to avoid downstream thrashing (e.g., rapid diff recomputes):

- **Recommended coalesce window**: 500ms per session. Merge file lists from events within the window. Keep latest `cwd` and `repoRoot`.
- **Diff recompute**: trigger once after the coalesce window closes. If new events arrive during computation, cancel and restart after the next window.
- **Other event types**: `session.progress` and `session.needs_input` are not coalesced (they update lightweight UI elements).

This coalescing happens in the app's event processing layer, not in the protocol itself. The protocol delivers events as-is.

## 11) observability

Every processed message should emit structured logs with:

- `timestamp`
- `kind`
- `eventType` or `command`
- `requestID` (when present)
- `ok`
- `error.code` (when failed)
- `latencyMs`

## 12) examples

### adapter file update event

```json
{
  "protocolVersion": "1.0",
  "kind": "event",
  "eventType": "session.update_files",
  "sessionID": "sess_abc123",
  "panelID": "26E78311-470E-4E62-8F6A-2F87F949D318",
  "timestamp": "2026-02-27T08:32:00Z",
  "payload": {
    "files": ["Sources/UI/TopBar/TopBarView.swift", "docs/implementation-plan.md"],
    "cwd": "/Users/vishal/GiantThings/repos/toastty",
    "repoRoot": "/Users/vishal/GiantThings/repos/toastty"
  }
}
```

### screenshot request/response

```json
{
  "protocolVersion": "1.0",
  "kind": "request",
  "requestID": "5C88E8A8-E5F8-487A-908A-D4467CB45E0F",
  "command": "automation.capture_screenshot",
  "payload": {
    "fixture": "workspace-two-panes",
    "step": "after-move-panel"
  }
}
```

```json
{
  "protocolVersion": "1.0",
  "kind": "response",
  "requestID": "5C88E8A8-E5F8-487A-908A-D4467CB45E0F",
  "ok": true,
  "result": {
    "path": "/Users/vishal/GiantThings/repos/toastty/artifacts/ui/run-20260227-083200/workspace-two-panes/after-move-panel.png"
  }
}
```
