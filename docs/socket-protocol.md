# toastty socket protocol (v1)

Date: 2026-03-13

This document describes the current socket protocol implemented by
`Sources/App/Automation/AutomationSocketServer.swift`.

Important scope note:

- The socket server is created for normal launches as well as automation launches so session and notification events can still reach the app.
- The same server accepts both automation requests and event-style envelopes
  (`session.*`, `notification.emit`).
- `automation.*` commands still require automation mode.
- This is a narrow implementation doc, not an aspirational protocol design.

CLI note:

- The repo ships a thin `toastty` CLI wrapper for `notify` and the `session`
  subcommands.
- Toastty-managed Claude and Codex launches primarily use
  `session ingest-agent-event` to translate provider events into `session.status`
  updates. `session ingest-agent-event` is handled locally inside the CLI; it is
  not a socket event type.
- Manual wrappers should generally use `session start`, `session status`,
  optional `session update-files`, and `session stop` directly.

## 1) transport and lifecycle

- Transport: Unix domain socket only.
- The server creates the parent directory with mode `0700` and the socket file with
  mode `0600`.
- Event-style envelopes are available whenever the app listener is running.
- `automation.*` commands require automation mode enabled through either:
  - `--automation`
  - a truthy `TOASTTY_AUTOMATION` environment value

Default socket path resolution:

1. `--socket-path <path>`
2. `TOASTTY_SOCKET_PATH`
3. a preferred temp socket path derived from the active runtime home when runtime isolation is enabled
4. `<TMPDIR-or-system-temp>/toastty-$UID/events-v1.sock`

Runtime-isolated resolution note:

- If the preferred runtime-home-derived socket path is already owned by a live Toastty listener, the app keeps that listener in place and resolves the new launch to a per-process sibling path such as `events-v1-<pid>.sock`.
- In that case, treat the resolved `socketPath` written to `instance.json`, the automation ready file, or an injected `TOASTTY_SOCKET_PATH` as authoritative.

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
  - `socketPath` (the resolved live socket path for that launch)
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
- Clears session registry, notification store, and coalesced file updates

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
- `workspace.focus-next-unread-or-active`
  - `args.windowID` is required when multiple windows exist
  - first targets unread panels using the normal unread traversal order
  - unread traversal still wraps within the current workspace before moving on
  - if no unread panel exists, falls back to managed-session panels whose live status is `working`, `needsApproval`, or `error`
  - active fallback scans the rest of the current workspace first, then sibling workspaces later in the current window's workspace order
  - after that it scans later windows in window order, trying each window's selected workspace first and then the remaining workspaces in that window order
  - only after those passes does it wrap back to earlier panels in the current workspace
  - `workspace.focus-next-unread` was removed and is no longer accepted
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
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.font.decrease`
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.font.reset`
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
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

### `automation.launch_agent`

Launches a configured agent profile into a resolved terminal panel. Toastty
records the baseline session in-app before injecting the provider command and
passes `TOASTTY_*` launch context with the command. For first-party Claude and
Codex launches, Toastty also generates helper scripts that call
`toastty session ingest-agent-event` so provider events become `session.status`
updates automatically. If the agent does not emit `session.stop`, Toastty falls
back to stopping the session when the panel returns to an interactive shell
prompt or the panel closes.

Launch context environment:

- `TOASTTY_SESSION_ID`
- `TOASTTY_PANEL_ID`
- `TOASTTY_SOCKET_PATH` (the resolved live socket path for that launch)
- `TOASTTY_CLI_PATH`
- `TOASTTY_CWD` when the target panel has a known working directory
- `TOASTTY_REPO_ROOT` when Toastty can infer a repository root from that directory

Request payload:

- `profileID?: String`
- `agent?: String` (legacy alias for `profileID`)
- `panelID?: UUID`
- `workspaceID?: UUID`

Result:

- `profileID: String`
- `agent: String`
- `displayName: String`
- `sessionID: String`
- `windowID: UUID`
- `workspaceID: UUID`
- `panelID: UUID`
- `command: String`
- `cwd?: String`
- `repoRoot?: String`
- `stateVersion: Int`

Validation:

- requires automation mode like other `automation.*` commands.
- the resolved target must be a terminal panel.
- if both `panelID` and `workspaceID` are provided, the panel must belong to that workspace.
- if the target terminal appears busy (not at an interactive prompt), return `INVALID_PAYLOAD`.

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

## 6) implemented event types

Legacy note:

- `session.progress`, `session.needs_input`, and `session.error` are no longer
  implemented. Use `session.status` and `notification.emit` instead.

### `session.start`

Required:

- top-level `sessionID`
- top-level `panelID`
- payload `agent`

Accepted payload keys:

- `agent: lowercase agent ID`
- `cwd?: String`
- `repoRoot?: String`

Validation:

- `panelID` must refer to a live panel
- `agent` must be a valid lowercase agent ID
- Built-in examples include `claude` and `codex`

Result:

- `eventType`
- `stateVersion`

### `session.status`

Required:

- top-level `sessionID`
- payload `kind`
- payload `summary`

Optional top-level fields:

- `panelID?: UUID string`

Accepted payload keys:

- `kind: "idle" | "working" | "needs_approval" | "ready" | "error"`
- `summary: String`
- `detail?: String`

Behavior:

- `sessionID` must identify an active session
- `panelID` is optional; when present it must match the active session
- `summary` must be non-empty after trimming

Result:

- `eventType`
- `stateVersion`

### `session.update_files`

Required:

- top-level `sessionID`
- payload `files`

Optional top-level fields:

- `panelID?: UUID string`

Accepted payload keys:

- `files: [String]`
- `cwd?: String`
- `repoRoot?: String`

Behavior:

- `sessionID` must identify an active session
- `panelID` is optional; when present it must match the active session
- `files` must be a non-empty string array
- Relative file paths require `cwd`
- Updates are coalesced per session before being written into `SessionRegistry`

Result:

- `eventType`
- `queuedFiles`
- `stateVersion`

### `session.stop`

Required:

- top-level `sessionID`

Optional top-level fields:

- `panelID?: UUID string`

Accepted payload keys:

- `reason?: String`

Behavior:

- `sessionID` must identify an active session
- `panelID` is optional; when present it must match the active session
- Flushes all coalesced file updates before stopping the session

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
- The repo ships a `toastty notify` CLI wrapper plus session-oriented CLI
  commands; they are transport conveniences over the same socket protocol.
