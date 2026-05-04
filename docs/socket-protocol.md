# toastty socket protocol (v1)

Date: 2026-04-20

This document describes the current socket protocol implemented by
`Sources/App/Automation/AutomationSocketServer.swift`.

Important scope note:

- The socket server is created for normal launches as well as automation launches so session and notification events can still reach the app.
- The same server accepts always-on app-control requests, automation-only requests, and event-style envelopes (`session.*`, `notification.emit`).
- `app_control.*` commands are available in normal launches by default.
- `automation.*` commands still require automation mode.
- This is a narrow implementation doc, not an aspirational protocol design.

CLI note:

- The repo ships a `toastty` CLI wrapper for app control (`action` / `query`), notifications, and the `session` subcommands.
- Toastty-managed Claude, Codex, and Pi launches primarily use
  `session ingest-agent-event` to translate provider events into `session.status`
  updates. `session ingest-agent-event` is handled locally inside the CLI; it is
  not a socket event type.
- Manual wrappers should generally use:
  - `toastty action list` / `toastty query list` for discovery
  - `toastty action run` / `toastty query run` for live app control
  - `session start`, `session status`, optional `session update-files`, and `session stop` for agent lifecycle reporting

## 1) transport and lifecycle

- Transport: Unix domain socket only.
- The server creates the parent directory with mode `0700` and the socket file with
  mode `0600`.
- Event-style envelopes and `app_control.*` requests are available whenever the app listener is running.
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

## 5) implemented app-control requests

These commands are available in normal launches by default and are the preferred
API for live app control.

### `app_control.list_actions`

Request payload: empty

Result:

- `commands: [AppControlCommandDescriptor]`

Each descriptor includes:

- `id: String`
- `kind: "action"`
- `summary: String`
- `selectors: [windowID | workspaceID | panelID]`
- `parameters: [name, summary, valueType, required, repeatable, allowedValues?]`
- `aliases: [String]`

Use this for discovery rather than hard-coding the full catalog in external tools. Aliases are accepted for compatibility, but new integrations should prefer canonical IDs.

### `app_control.run_action`

Request payload:

- `id: String`
- `args?: Object`

Result:

- action-specific object
- `stateVersion: Int` when the action mutates app state

Selectors are passed inside `args`:

- `windowID?: UUID string`
- `workspaceID?: UUID string`
- `panelID?: UUID string`

Canonical action IDs are machine-first and parameterized. Common actions include:

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
- `panel.close`
- `panel.create.browser`
- `panel.create.local-document`
- `panel.scratchpad.set-content`
- `panel.scratchpad.rebind`
- `panel.scratchpad.export`
- `panel.focus-mode.toggle`
- `agent.launch`
- `config.reload`
- `terminal.send-text`
- `terminal.drop-image-files` (historical name; drops local file paths of any type)

Notable action-specific behavior:

- `workspace.create`
  - `args.title` is optional.
  - `args.activate` is optional and defaults to `true`.
  - When `args.activate=false`, Toastty creates the workspace without changing
    the visible workspace selection.
  - Background-created workspaces remain marked as new until selected once.
  - The action result includes `workspaceID` and `windowID`.
- `workspace.move`
  - requires `args.index` and `args.toIndex`, both 1-based workspace positions
    in the target window.
  - Reorders the window's workspace list without changing the selected
    workspace ID.
- `workspace.tab.move`
  - requires `args.index` and `args.toIndex`, both 1-based tab positions in the
    target workspace.
  - Reorders the workspace's tab list without changing the selected tab ID.
- `panel.scratchpad.set-content`
  - requires `args.sessionID`.
  - requires exactly one of `args.filePath` or `args.content`.
  - `args.filePath` is read as UTF-8. Relative paths resolve from the active
    session's `cwd` when available, then from the app process working directory.
  - `args.title` is optional.
  - `args.expectedRevision` is optional. New documents accept `0`; existing
    documents reject stale revisions.
  - Content is stored as HTML in the Scratchpad document store and is limited to
    1,048,576 UTF-8 bytes.
  - The action creates or updates the Scratchpad linked to the active managed
    session, opens new Scratchpads in the right panel, restores focus to the
    source terminal after auto-create, and marks unfocused Scratchpads updated.
  - The result includes `windowID`, `workspaceID`, `panelID`, `documentID`,
    `revision`, and `created`.
- `panel.scratchpad.rebind`
  - requires `args.sessionID` for an active managed session.
  - Targets an existing Scratchpad panel using `args.panelID`, workspace/window
    selectors, or the focused/active Scratchpad resolution order.
  - The target session must be in the same workspace tab as the Scratchpad, and
    a session may only be linked to one Scratchpad at a time.
  - `panel.scratchpad.bind` is accepted as a compatibility alias.
  - The result includes `windowID`, `workspaceID`, `panelID`, `documentID`,
    `revision`, and `sessionID`.
- `panel.scratchpad.export`
  - Targets by `args.sessionID` when provided, otherwise by the normal
    Scratchpad panel selectors.
  - Writes the Scratchpad HTML to an app-chosen local file path.
  - The result includes `workspaceID`, `panelID`, `filePath`, `documentID`,
    `revision`, and `title`.

### `app_control.list_queries`

Request payload: empty

Result:

- `commands: [AppControlCommandDescriptor]`

The response shape matches `app_control.list_actions`, except each descriptor
has `kind: "query"`.

### `app_control.run_query`

Request payload:

- `id: String`
- `args?: Object`

Result:

- query-specific object

Selectors are passed inside `args` using the same keys as `app_control.run_action`.

Common query IDs include:

- `workspace.snapshot`
- `terminal.state`
- `terminal.visible-text`
- `panel.local-document.state`
- `panel.browser.state`
- `panel.scratchpad.state`

`panel.scratchpad.state` resolves a Scratchpad panel from `panelID`, or from
`workspaceID` / `windowID` using focused layout Scratchpad, focused right-panel
Scratchpad, active right-panel Scratchpad, any right-panel Scratchpad, then
layout Scratchpad order. It returns Scratchpad document metadata, linked session
ID when present, host lifecycle state, bootstrap content hashes, and recent
Scratchpad diagnostics.

## 6) implemented automation commands

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
- `workspace-tabs-wide`

Result:

- `fixture: String`
- `stateVersion: Int`

### `automation.perform_action`

Request payload:

- `action: String`
- `args?: Object`

Result:

- `stateVersion: Int`

Behavior:

- This is now a compatibility shim over the shared app-control executor.
- Canonical IDs come from `app_control.list_actions`; legacy aliases are still accepted for compatibility.
- New integrations should prefer `app_control.run_action`.

Supported action IDs:

- `window.create`
- `window.sidebar.toggle`
- `workspace.tab.new`
- `workspace.tab.select`
  - requires `args.index` (1-based) or `args.tabID`
- `workspace.tab.move`
  - requires `args.index` and `args.toIndex` (1-based)
- `workspace.tab.close`
  - accepts `args.index` (1-based) or `args.tabID`
  - if neither is provided, closes the selected tab
- `workspace.tab.rename`
  - requires `args.title`
  - accepts `args.index` (1-based) or `args.tabID`
- `workspace.select`
  - requires `args.workspaceID` or `args.index` (1-based)
- `workspace.create`
  - `args.title` is optional
  - `args.activate` is optional and defaults to `true`
  - `args.activate=false` keeps the current workspace selected and marks the
    created background workspace as new until selected once
- `workspace.move`
  - requires `args.index` and `args.toIndex` (1-based)
- `workspace.rename`
  - requires `args.title`
- `workspace.close`
- `workspace.split.horizontal`
- `workspace.split.vertical`
- `workspace.split.right`
- `workspace.split.down`
- `workspace.split.left`
- `workspace.split.up`
- `workspace.split.right.with-profile`
  - requires `args.profileID`
- `workspace.split.down.with-profile`
  - requires `args.profileID`
- `workspace.close-focused-panel`
- `workspace.reopen-last-closed-panel`
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
  - a `ready` session only participates while unread; once visited it collapses back to `idle`
  - if no unread panel exists, it next falls back to managed-session panels whose live status is `needsApproval` or `error`
  - if no attention-required panel exists, it builds an active-session cycle anchored to the current focus
  - that active cycle first includes working panels ahead of the current focus, then later-flagged active panels that have not already appeared, then wrapped working panels, and finally the starting focused active panel when it still belongs to the cycle
  - repeated invocations continue through that same active cycle without repeating a target until the cycle wraps or the active set changes
  - manual focus changes, window/workspace/layout changes, panel removals, active status-kind changes, later-flag changes, or unread/attention preemption reset the active cycle and rebuild it from the new focus
  - if no target exists, the selected sidebar row flashes instead of changing focus
  - `workspace.focus-next-unread` was removed and is no longer accepted
- `workspace.focus-panel`
  - requires `args.panelID`
- `workspace.resize-split.left`
- `workspace.resize-split.right`
- `workspace.resize-split.up`
- `workspace.resize-split.down`
  - `args.amount` is optional and clamps to at least `1`
- `workspace.equalize-splits`
- `panel.create.browser`
  - `args.placement` is optional: `rightPanel`, `newTab`, or `splitRight`; legacy `rootRight` is still accepted as an alias for `rightPanel`
  - When `args.placement` is omitted, the default is now `rightPanel` rather than `newTab`
  - `args.url` is optional
- `panel.create.localDocument`
  - opens a supported local document: Markdown (`md`, `markdown`, `mdown`, `mkd`), YAML/TOML/JSON/config/dotenv files, CSV/TSV/XML, shell scripts (`sh`, `bash`, `zsh`), or common source files (`swift`, `js`, `mjs`, `cjs`, `jsx`, `ts`, `mts`, `cts`, `tsx`, `py`, `go`, `rs`)
  - requires `args.filePath`
  - `args.placement` is optional: `rightPanel`, `newTab`, or `splitRight`; legacy `rootRight` is still accepted as an alias for `rightPanel`
  - when `args.placement` is omitted, the default is `rightPanel`
  - if the same normalized file is already open in the target workspace, the action focuses that existing panel instead of creating a duplicate
  - unsupported or extension-less file paths return `INVALID_PAYLOAD`
- `panel.create.markdown`
  - legacy alias for `panel.create.localDocument`
- `panel.create.local-document`
  - canonical ID for `panel.create.localDocument`
- `panel.scratchpad.set-content`
  - requires `args.sessionID`
  - requires exactly one of `args.filePath` or `args.content`
  - accepts optional `args.title` and `args.expectedRevision`
  - creates or updates the Scratchpad linked to the active managed session
  - returns `windowID`, `workspaceID`, `panelID`, `documentID`, `revision`, and
    `created`
- `panel.scratchpad.rebind`
  - requires `args.sessionID`
  - targets an existing Scratchpad panel by `args.panelID`, workspace/window
    selectors, or focused/active Scratchpad resolution
  - returns `windowID`, `workspaceID`, `panelID`, `documentID`, `revision`, and
    `sessionID`
- `panel.scratchpad.export`
  - targets by `args.sessionID` when provided, otherwise by the normal
    Scratchpad panel selectors
  - writes the Scratchpad HTML to an app-chosen local file path
  - returns `workspaceID`, `panelID`, `filePath`, `documentID`, `revision`, and
    `title`
- `topbar.toggle.focused-panel`
- `app.font.increase`
  - terminal-only window font increase
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.font.decrease`
  - terminal-only window font decrease
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.font.reset`
  - terminal-only window font reset
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.markdown_text.increase`
  - window-local local-document text-size increase for supported local-document panels
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.markdown_text.decrease`
  - window-local local-document text-size decrease for supported local-document panels
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.markdown_text.reset`
  - window-local local-document text-size reset to `100%`
  - `args.windowID` is optional when exactly one window exists, and required when multiple windows exist
- `app.browser_zoom.increase`
  - browser-panel page zoom increase
  - `args.panelID` is optional; when omitted, the target resolves from `args.workspaceID` or `args.windowID`, then prefers the focused right-panel browser, the active right-panel browser, the focused layout browser, and otherwise the first browser panel in layout order
- `app.browser_zoom.decrease`
  - browser-panel page zoom decrease
  - `args.panelID` is optional; when omitted, the target resolves from `args.workspaceID` or `args.windowID`, then prefers the focused right-panel browser, the active right-panel browser, the focused layout browser, and otherwise the first browser panel in layout order
- `app.browser_zoom.reset`
  - browser-panel page zoom reset to `100%`
  - `args.panelID` is optional; when omitted, the target resolves from `args.workspaceID` or `args.windowID`, then prefers the focused right-panel browser, the active right-panel browser, the focused layout browser, and otherwise the first browser panel in layout order
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

- Compatibility shim over `app_control.run_action` with `id: "terminal.send-text"`.
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
- `acceptedFileCount: Int`
- `acceptedImageCount: Int` (deprecated compatibility duplicate of `acceptedFileCount`)
- `available: Bool`

Behavior:

- Compatibility shim over `app_control.run_action` with `id: "terminal.drop-image-files"`.
- Despite the historical image-specific name, this command accepts local file paths of any type.
- Relative file paths require `cwd`.
- Paths are normalized with Foundation path standardization.
- If no usable local file paths remain, return `INVALID_PAYLOAD`.
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

Behavior:

- Compatibility shim over `app_control.run_query` with `id: "terminal.visible-text"`.

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

- Compatibility shim over `app_control.run_action` with `id: "agent.launch"`.
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

- `windowID: UUID string`
- `workspaceID: UUID string`
- `panelID: UUID string`
- `title: String`
- `cwd: String`
- `shell: String`
- `profileID: String | null`

Behavior:

- Compatibility shim over `app_control.run_query` with `id: "terminal.state"`.
- The resolved terminal always reports its owning `windowID`, whether you target it by `panelID`, `workspaceID`, or `windowID`.

### `automation.local_document_panel_state`

Request payload:

- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `stateTitle: String`
- `stateFilePath: String | null`
- `stateFormat: "markdown" | "yaml" | "toml" | "json" | "jsonl" | "config" | "csv" | "tsv" | "xml" | "shell" | null`
- `hostLifecycleState: String`
- `hostAttachmentID: UUID string | null`
- `currentTheme: String`
- `hasCurrentBootstrap: Bool`
- `pendingBootstrapScript: Bool`
- `currentAssetPath: String | null`
- `bootstrapContractVersion: Int | null`
- `bootstrapFilePath: String | null`
- `bootstrapDisplayName: String | null`
- `bootstrapFormat: "markdown" | "yaml" | "toml" | "json" | "jsonl" | "config" | "csv" | "tsv" | "xml" | "shell" | null`
- `bootstrapShouldHighlight: Bool | null`
- `bootstrapContentRevision: Int | null`
- `bootstrapIsEditing: Bool | null`
- `bootstrapIsDirty: Bool | null`
- `bootstrapHasExternalConflict: Bool | null`
- `bootstrapIsSaving: Bool | null`
- `bootstrapSaveErrorMessage: String | null`
- `bootstrapTheme: String | null`
- `bootstrapTextScale: Double | null`
- `bootstrapContentLength: Int | null`
- `bootstrapContentSHA256: String | null`

Behavior:

- Compatibility shim over `app_control.run_query` with `id: "panel.local-document.state"`.
- `panelID` is optional; when omitted, Toastty resolves the local-document panel from `workspaceID` or `windowID`, then prefers the focused right-panel local document, the active right-panel local document, the focused layout local document, and otherwise the first local-document panel in layout order.
- `automation.markdown_panel_state` is accepted as a legacy alias and returns the same payload.
- All `bootstrap*` fields are `null` when the panel runtime does not currently have an active bootstrap payload.

### `automation.browser_panel_state`

Request payload:

- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `stateTitle: String`
- `stateRestorableURL: String | null`
- `statePageZoom: Double`
- `statePageZoomOverride: Double | null`
- `hostLifecycleState: String`
- `hostAttachmentID: UUID string | null`
- `runtimePageZoom: Double`

Behavior:

- Compatibility shim over `app_control.run_query` with `id: "panel.browser.state"`.
- `panelID` is optional; when omitted, Toastty resolves the browser panel from `workspaceID` or `windowID`, then prefers the focused right-panel browser, the active right-panel browser, the focused layout browser, and otherwise the first browser panel in layout order.

### `automation.scratchpad_panel_state`

Request payload:

- `panelID?: UUID string`
- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `panelID: UUID string`
- `stateTitle: String`
- `stateDocumentID: UUID string | null`
- `stateRevision: Int | null`
- `stateSessionID: String | null`
- `hostLifecycleState: String`
- `hostAttachmentID: UUID string | null`
- `currentTheme: String`
- `hasCurrentBootstrap: Bool`
- `pendingBootstrapScript: Bool`
- `currentAssetPath: String | null`
- `diagnosticCount: Int`
- `recentDiagnostics: [{ sequence, source, kind, level, message, metadata }]`
- `bootstrapContractVersion: Int | null`
- `bootstrapDocumentID: UUID string | null`
- `bootstrapDisplayName: String | null`
- `bootstrapRevision: Int | null`
- `bootstrapMissingDocument: Bool | null`
- `bootstrapMessage: String | null`
- `bootstrapTheme: String | null`
- `bootstrapContentLength: Int | null`
- `bootstrapContentSHA256: String | null`

Behavior:

- Compatibility shim over `app_control.run_query` with `id: "panel.scratchpad.state"`.
- `panelID` is optional; when omitted, Toastty resolves the Scratchpad panel from `workspaceID` or `windowID`, then prefers the focused layout Scratchpad, the focused right-panel Scratchpad, the active right-panel Scratchpad, any right-panel Scratchpad, and otherwise the first layout Scratchpad.

### `automation.workspace_snapshot`

Request payload:

- `workspaceID?: UUID string`
- `windowID?: UUID string`

Result:

- `workspaceID: UUID string`
- `tabCount: Int`
- `selectedTabID: UUID string | null`
- `selectedTabIndex: Int | null`
- `tabIDs: [UUID string]`
- `slotCount: Int`
- `layoutPanelCount: Int`
- `panelCount: Int` (layout panels plus right-panel tabs across the workspace)
- `focusedPanelID: UUID string | null`
- `rootSplitRatio: Double | null`
- `slotIDs: [UUID string]`
- `slotPanelIDs: [UUID string]`
- `slotMappings: [{ slotID, panelID }]`
- `rightPanel: { isVisible, width, hasCustomWidth, tabCount, activeTabID, activePanelID, focusedPanelID, tabIDs, panelIDs, tabs }`
  - describes the selected workspace tab's right panel; switching workspace tabs changes this object with the selected tab
  - `width` is the stored custom width. When `hasCustomWidth` is false, the visible panel width is resolved responsively from the workspace width.
- `layoutSignature: String`

`selectedTabIndex` is 1-based when present.

Behavior:

- Compatibility shim over `app_control.run_query` with `id: "workspace.snapshot"`.

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

## 7) implemented event types

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
- Built-in examples include `claude`, `codex`, and `pi`

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

## 8) error codes

Current response error codes:

- `INVALID_JSON`
- `INVALID_ENVELOPE`
- `INCOMPATIBLE_PROTOCOL`
- `UNKNOWN_EVENT_TYPE`
- `UNKNOWN_COMMAND`
- `INVALID_PAYLOAD`
- `INTERNAL_ERROR`

## 9) implementation notes that are not separate protocol guarantees

- `session.update_files` coalescing currently uses a 0.5 second window per session.
- The protocol does not currently expose a standalone schema version beyond
  `protocolVersion`.
- The repo ships a `toastty notify` CLI wrapper plus session-oriented CLI
  commands; they are transport conveniences over the same socket protocol.
