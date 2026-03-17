# toastty socket protocol (v1)

Date: 2026-03-13

This document describes the current socket protocol implemented by
`Sources/App/Automation/AutomationSocketServer.swift`.

Important scope note:

- The socket server is currently created only when Toastty launches in automation mode.
- The same server accepts both automation requests and event-style envelopes
  (`session.*`, `notification.emit`).
- This is a narrow implementation doc, not an aspirational protocol design.

## 1) transport and lifecycle

- Transport: Unix domain socket only.
- The server creates the parent directory with mode `0700` and the socket file with
  mode `0600`.
- The server is available only when automation mode is enabled through either:
  - `--automation`
  - a truthy `TOASTTY_AUTOMATION` environment value

Default socket path resolution:

1. `--socket-path <path>`
2. `TOASTTY_SOCKET_PATH`
3. a temp socket path derived from `TOASTTY_RUNTIME_HOME` when runtime isolation is enabled
4. `<TMPDIR-or-system-temp>/toastty-$UID/events-v1.sock`

Automation config defaults:

- `runID` defaults to `"default"`
- `fixture` is optional
- `artifactsDirectory` defaults to
  `<system-temp>/toastty-automation-<runID>`

Ready file:

- When the app reaches its ready signal, it writes
  `<artifactsDirectory>/automation-ready-<sanitized-runID>.json`
- The payload includes:
  - `protocolVersion`
  - `ready`
  - `runID`
  - `fixture`
  - `socketPath`
  - `status`
  - `error`
  - `timestamp`

## 2) framing and compatibility

- Messages are UTF-8 JSON objects delimited by a single newline.
- The server buffers at most 256 KiB per connection.
- The server handles one envelope per connection, writes one response, then closes
  that connection.
- Unknown JSON fields are ignored by decoding.
- Supported `protocolVersion` values must start with `"1."`.

## 3) envelope shapes

### request envelope

Required top-level fields:

- `protocolVersion: String`
- `kind: "request"`
- `requestID: String`
- `command: String`

Optional top-level fields:

- `payload: Object`
  - omitted payloads are treated as `{}`

### event envelope

Required top-level fields:

- `protocolVersion: String`
- `kind: "event"`
- `eventType: String`
- `payload: Object`

Optional top-level fields:

- `requestID: String`
- `sessionID: String`
- `panelID: UUID string`
- `timestamp: ISO-8601 string`

Event timestamp behavior:

- If `timestamp` is present and parseable, the server uses it.
- Otherwise it falls back to the current server time.

### response envelope

Every processed envelope returns a response:

- `protocolVersion: "1.0"`
- `kind: "response"`
- `requestID: String`
- `ok: Bool`
- `result?: Object`
- `error?: { code: String, message: String }`

If an incoming event omits `requestID`, the server generates a response ID.
If parsing fails before a request ID can be recovered, the response uses
`requestID: "unknown"`.

## 4) workspace and terminal target resolution

Several commands and events accept `workspaceID`, `windowID`, or `panelID`.

Workspace resolution rules:

- If `workspaceID` is supplied, it must be a UUID and refer to a live workspace.
- If both `workspaceID` and `windowID` are supplied, the workspace must belong to that
  window.
- If only `windowID` is supplied, the window's selected workspace is used.
- If neither is supplied:
  - the call succeeds only when exactly one window exists
  - zero windows or multiple windows return `INVALID_PAYLOAD`

Terminal target resolution rules:

- If `panelID` is supplied, it must be a UUID for a live terminal panel.
- Otherwise the server resolves a workspace first, then uses:
  - the focused panel if it is terminal-backed
  - otherwise the first terminal panel in slot order
- If the resolved workspace has no terminal panels, the server returns
  `INVALID_PAYLOAD`.

## 5) implemented automation commands

### `automation.ping`

Request payload: empty

Result:

- `status: "ok"`
- `automationEnabled: true`
- `appUptimeMs: Int`
- `protocolVersion: "1.0"`

### `automation.reset`

Request payload: empty

Result:

- `stateVersion: Int`

Behavior:

- Replaces app state with `AppState.bootstrap()`
- Resets current fixture name to `"default"`
- Clears session registry, notification store, coalesced updates, progress, and errors

### `automation.load_fixture`

Request payload:

- `name: String`

Current fixture names:

- `default`
- `single-workspace`
- `two-workspaces`
- `split-workspace`

Result:

- `fixture: String`
- `stateVersion: Int`

### `automation.perform_action`

Request payload:

- `action: String`
- `args?: Object`

Result:

- `stateVersion: Int`

Supported action IDs:

- `workspace.split.horizontal`
- `workspace.split.vertical`
- `workspace.split.right`
- `workspace.split.down`
- `workspace.split.left`
- `workspace.split.up`
- `workspace.close-focused-panel`
- `workspace.focus-slot.previous`
- `workspace.focus-slot.next`
- `workspace.focus-slot.left`
- `workspace.focus-slot.right`
- `workspace.focus-slot.up`
- `workspace.focus-slot.down`
- `workspace.focus-panel`
  - requires `args.panelID`
- `workspace.resize-split.left`
- `workspace.resize-split.right`
- `workspace.resize-split.up`
- `workspace.resize-split.down`
  - `args.amount` is optional and clamps to at least `1`
- `workspace.equalize-splits`
- `topbar.toggle.diff`
- `topbar.toggle.markdown`
- `topbar.toggle.scratchpad`
- `topbar.toggle.focused-panel`
- `app.font.increase`
- `app.font.decrease`
- `app.font.reset`
- `sidebar.workspaces.new`
  - `args.title` is optional
  - `args.windowID` is required when multiple windows exist

### `automation.terminal_send_text`

Request payload:

- `text: String`
- `submit?: Bool`
- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`
- `allowUnavailable?: Bool`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `submitted: Bool`
- `available: Bool`

Behavior:

- `waitForSurfaceMs` is explicitly rejected as deprecated.
- When the terminal surface is unavailable:
  - return `available: false` if `allowUnavailable=true`
  - otherwise return `INVALID_PAYLOAD`

### `automation.terminal_drop_image_files`

Request payload:

- `files: [String]`
- `cwd?: String`
- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`
- `allowUnavailable?: Bool`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `requestedFileCount: Int`
- `acceptedImageCount: Int`
- `available: Bool`

Behavior:

- Relative file paths require `cwd`.
- Paths are normalized with Foundation path standardization.
- If no usable image paths remain, return `INVALID_PAYLOAD`.
- When the terminal surface is unavailable:
  - return `available: false` if `allowUnavailable=true`
  - otherwise return `INVALID_PAYLOAD`

### `automation.terminal_visible_text`

Request payload:

- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`
- `contains?: String`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `text: String`
- `contains?: Bool`

### `automation.terminal_state`

Request payload:

- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `title: String`
- `cwd: String`
- `shell: String`

### `automation.workspace_snapshot`

Request payload:

- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `slotCount: Int`
- `panelCount: Int`
- `focusedPanelID: UUID string | null`
- `rootSplitRatio: Double | null`
- `slotIDs: [UUID string]`
- `slotPanelIDs: [UUID string]`
- `slotMappings: [{ slotID, panelID }]`
- `layoutSignature: String`

### `automation.workspace_render_snapshot`

Request payload:

- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `terminalPanelCount: Int`
- `allRenderable: Bool`
- `panels: [Object]`
  - each panel object currently includes:
    - `panelID`
    - `controllerExists`
    - `hostHasSuperview`
    - `hostAttachedToWindow`
    - `sourceContainerExists`
    - `sourceContainerAttachedToWindow`
    - `hostSuperviewMatchesSourceContainer`
    - `hostLifecycleState`
    - `hostAttachmentID`
    - `ghosttySurfaceAvailable`
    - `isRenderable`

### `automation.capture_screenshot`

Request payload:

- `step: String`
- `fixture?: String`

Result:

- `path: String`

Behavior:

- If `fixture` is omitted, the current fixture name is used.
- If `fixture` is provided and does not match the current fixture, return
  `INVALID_PAYLOAD`.
- Output path is:
  `<artifactsDirectory>/ui/<sanitized-runID>/<sanitized-fixture>/<sanitized-step>.png`

### `automation.dump_state`

Request payload:

- `includeRuntime?: Bool`

Result:

- `path: String`
- `hash: String`

Behavior:

- Default output path is under
  `<artifactsDirectory>/ui/<sanitized-runID>/state/state-<stateVersion>.json`
- With `includeRuntime=false`, the dump contains serialized `AppState`
- With `includeRuntime=true`, the dump contains:
  - `appState`
  - `sessionRegistry`
  - `notifications`
  - `progressBySessionID`
  - `errorsBySessionID`

## 6) implemented event types

### `session.start`

Required:

- top-level `sessionID`
- top-level `panelID`
- payload `agent`

Accepted payload keys:

- `agent: "claude" | "codex"`
- `cwd?: String`
- `repoRoot?: String`

Validation:

- `panelID` must refer to a live panel
- `agent` must be one of the supported values

Result:

- `eventType`
- `stateVersion`

### `session.update_files`

Required:

- top-level `sessionID`
- top-level `panelID`
- payload `files`

Accepted payload keys:

- `files: [String]`
- `cwd?: String`
- `repoRoot?: String`

Behavior:

- `panelID` must refer to a live panel
- `files` must be a non-empty string array
- Relative file paths require `cwd`
- Updates are coalesced per session before being written into `SessionRegistry`

Result:

- `eventType`
- `queuedFiles`
- `stateVersion`

### `session.needs_input`

Required:

- top-level `sessionID`
- top-level `panelID`
- payload `title`
- payload `body`

Behavior:

- `panelID` must refer to a live panel
- Records a notification decision and may trigger a system notification

Result:

- `eventType`
- `notificationStored: Bool`
- `sendSystemNotification: Bool`
- `stateVersion`

### `session.progress`

Required:

- top-level `sessionID`
- top-level `panelID`
- payload `message`

Result:

- `eventType`
- `stateVersion`

### `session.error`

Required:

- top-level `sessionID`
- top-level `panelID`
- payload `message`

Result:

- `eventType`
- `stateVersion`

### `session.stop`

Required:

- top-level `sessionID`
- top-level `panelID`

Behavior:

- Flushes all coalesced file updates before stopping the session
- Clears stored progress and error state for that session

Result:

- `eventType`
- `stateVersion`

### `notification.emit`

Required payload:

- `title: String`
- `body: String`

Optional payload:

- `workspaceID?: UUID string`
- `panelID?: UUID string`
- `windowID?: UUID string`

Routing:

- If `workspaceID` is present, use that workspace
- Else if `panelID` is present, resolve its workspace
- Else resolve workspace selection from the remaining payload
  - `windowID` is used when present
  - otherwise the event succeeds only when exactly one window exists

Result:

- `eventType`
- `notificationStored: Bool`
- `sendSystemNotification: Bool`
- `stateVersion`

## 7) error codes

Current response error codes:

- `INVALID_JSON`
- `INVALID_ENVELOPE`
- `INCOMPATIBLE_PROTOCOL`
- `UNKNOWN_EVENT_TYPE`
- `UNKNOWN_COMMAND`
- `INVALID_PAYLOAD`
- `INTERNAL_ERROR`

## 8) implementation notes that are not separate protocol guarantees

- `session.update_files` coalescing currently uses a 0.5 second window per session.
- The protocol does not currently expose a standalone schema version beyond
  `protocolVersion`.
- This repo does not currently include a `toastty notify` CLI implementation; the
  live behavior for `notification.emit` is the socket event handler described above.
