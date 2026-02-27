# toastty implementation plan

Date: 2026-02-26

## 1) Product goal

`toastty` is a Ghostty-based multi-pane, multi-window coding workspace with first-class agent context.

Core outcomes:
- run many terminal agent sessions in parallel
- move live panels across panes, workspaces (vertical tabs), and windows/displays
- show **session-scoped diffs** (not just repo-wide diffs)
- adapt layout across display topologies (external monitor vs laptop)
- support reference/communication panels (markdown preview + scratchpad canvas)
- surface agent attention/notification state across workspaces

## 2) principles

- make panel/window/workspace movement a core primitive from day one
- keep runtime UI objects separate from serializable app state
- session attribution must be explicit and inspectable
- no hidden destructive layout transforms; profile apply should be reversible
- design for extension: `PanelKind` should not be hardcoded all over the codebase
- adding a new panel kind should require one predictable checklist, not cross-cutting edits
- aux panels (diff, markdown, scratchpad) follow focused terminal — they are contextual to the active session

## 3) scope by release

### V1 (must-have)
- terminal panels
- split panes + vertical workspace tabs
- multi-window
- panel mobility:
  - reorder within pane tab strip
  - move panel between panes in same workspace
  - move panel to another workspace (vertical tab target)
  - drag panel out to create new window
  - move panel to existing window/workspace targets
- global terminal font size control
- session registry + session->surface binding
- session-scoped diff panel (file-level first; hunk-level later)
- layout profiles (auto-save per display, manual apply, revert)
- top bar panel toggle buttons (show/hide aux panels)
- notification/attention system (workspace indicators + macOS notifications)
- agent adapters for claude + codex (lifecycle + file attribution + attention events)

### V1.5
- markdown preview panel with session-aware file suggestions
- command palette (⌘K) for panel management, workspace switching, font control
- codex + claude adapters with stronger touched-file attribution

### V2
- scratchpad canvas panel (html/css/js runtime + API)
- richer diff semantics (hunk ownership/conflict views)

## 4) architecture

## 4.1 app layers

1. `AppShell`
- app lifecycle, menus, command routing
- window scene bootstrap

2. `CoreState`
- source of truth for windows/workspaces/panes/panels
- mutation via typed actions

3. `RuntimeLayer`
- panel runtimes and native view lifecycles
- Ghostty surface lifecycle controller

4. `Services`
- session attribution
- git diff data
- notification service
- layout profile engine
- persistence and migrations

5. `Interfaces`
- socket/cli surface for automation and external tools
- deterministic automation hooks for tests/agents (seed fixture state, emit synthetic events, capture diagnostics)

## 4.2 data model (state)

```swift
enum PanelKind: String, Codable {
    case terminal
    case diff
    case markdown
    case scratchpad
}

struct AppState: Codable {
    var windows: [WindowState]
    var workspacesByID: [UUID: WorkspaceState]
    var selectedWindowID: UUID?
    var globalTerminalFontPoints: Double
}

struct WindowState: Codable, Identifiable {
    let id: UUID
    var frame: CGRectCodable
    var workspaceIDs: [UUID]
    var selectedWorkspaceID: UUID?
}

struct WorkspaceState: Codable, Identifiable {
    let id: UUID
    var title: String
    var paneTree: PaneNode
    var panels: [UUID: PanelState]
    var focusedPanelID: UUID?
    var auxPanelVisibility: Set<PanelKind> // per-workspace aux panel toggles
    var unreadNotificationCount: Int
}

indirect enum PaneNode: Codable {
    case leaf(paneID: UUID, tabPanelIDs: [UUID], selectedIndex: Int)
    case split(orientation: SplitOrientation, ratio: Double, first: PaneNode, second: PaneNode)
}

enum PanelState: Codable {
    case terminal(TerminalPanelState)
    case diff(DiffPanelState)
    case markdown(MarkdownPanelState)
    case scratchpad(ScratchpadPanelState)
}
```

state invariants:
- `WindowState.workspaceIDs` is ordered and is the source of truth for workspace ordering in that window
- every id in `WindowState.workspaceIDs` must exist in `AppState.workspacesByID`
- a workspace belongs to exactly one window at a time
- aux panel visibility is persisted per workspace (`WorkspaceState.auxPanelVisibility`)
- every panel id in any `PaneNode.leaf.tabPanelIDs` must exist in `WorkspaceState.panels`
- every key in `WorkspaceState.panels` must appear exactly once in `PaneNode.leaf.tabPanelIDs` in that workspace
- empty pane leaves are not allowed after reducer actions
- `PaneNode.leaf.selectedIndex` must be in-bounds (`0 <= selectedIndex < tabPanelIDs.count`) after every reducer action

Detailed invariant contract: `docs/state-invariants.md`.

## 4.3 runtime interfaces

```swift
protocol PanelRuntime: AnyObject {
    var panelID: UUID { get }
    var kind: PanelKind { get }
    func focus()
    func unfocus()
    func close()
}

protocol PanelRuntimeFactory {
    func makeRuntime(for state: PanelState, context: PanelRuntimeContext) -> PanelRuntime
}

struct PanelRuntimeContext {
    let panelID: UUID
    let workspaceID: UUID
    let windowID: UUID
    let services: RuntimeServices
}
```

`TerminalPanelRuntime` owns the Ghostty surface and view attachment/reparenting.

## 4.4 panel extensibility contract

Every panel kind must provide:
- typed state payload (`XPanelState`)
- runtime (`XPanelRuntime`) and view (`XPanelView`)
- registration entry in `PanelRuntimeRegistry`
- serializer/migration case in `PanelState`
- command/router hooks only if needed (opt-in)

Target workflow for new panel types:
1. add new `PanelKind` case
2. add new `PanelState` case + codable migration default
3. add runtime+view pair
4. register factory
5. optional commands/tests

This keeps future panels (browser/notepad/whiteboard/etc.) low-friction.

See also: `docs/panel-authoring.md` for the concrete implementation checklist.

## 4.5 UI chrome and interaction model

Visual spec: see Paper designs in "Toastty — All Panels Active" and "Toastty — Laptop" artboards.

### sidebar
- labeled workspace list with name and keyboard shortcuts (⌘1–⌘N)
- active workspace: amber left border accent
- notification indicator: colored dot on workspaces with unread agent notifications
- width: ~180px desktop, ~148px laptop (always labeled, never collapsed to icons)
- bottom: "+ New workspace" action

### top bar
- window controls (close/min/max) live in sidebar top-left, not top bar
- top bar contains: workspace name, path, panel toggle buttons, git branch + status
- panel toggle buttons: Diff, Markdown, Scratchpad — multi-select, each independently shows/hides its panel
- toggled-on panels appear in the right column, stacked vertically
- panels can be dragged from their default position to any split target

### panel headers
- every panel (terminal and aux) has a consistent header: drag grip (three vertical dots) + panel number/label + contextual controls
- drag grip communicates that all panels are rearrangeable
- terminal headers: pane number + shell name + cwd
- diff header: session attribution label ("Claude Code · Terminal 2 · abc1234") + unstaged/staged toggle
- markdown header: file dropdown selector (shows current file name + chevron; click opens picker menu with session-touched .md files + fallback candidates)
- scratchpad header: Edit/Preview toggle

### aux panel focus-follow behavior
- when focused terminal changes, aux panels update to reflect the new terminal's session context
- diff panel: shows diffs for the newly focused session
- markdown panel: shows markdown files touched by the newly focused session
- scratchpad panel: shows scratchpad content for the newly focused session

### layout adaptation
- layout profiles auto-save per display signature and auto-restore on display change
- no auto-collapsing or responsive breakpoints in V1 — user controls layout via profiles
- "revert last profile apply" available as escape hatch

## 5) session attribution design (codex + claude)

## 5.1 how focused terminal session is determined

- app state tracks focused panel id per workspace
- `SessionRegistry` maps `panelID -> activeSessionID`
- when panel focus changes, `activeSessionID = SessionRegistry.activeSession(for: panelID)`
- aux panels observe focus changes and re-bind to the new active session

## 5.2 session registry

```swift
struct SessionRecord: Codable {
    let sessionID: String
    let agent: AgentKind // codex | claude
    let panelID: UUID
    var windowID: UUID
    var workspaceID: UUID
    var repoRoot: String?
    var cwd: String? // latest cwd; used for relative-path normalization only
    var touchedFiles: [String]
    var touchedHunks: [HunkRef]
    var startedAt: Date
    var updatedAt: Date
    var stoppedAt: Date?
}
```

## 5.3 attribution pipeline

priority order:
1. explicit hook events from agent wrapper/adapters
2. agent session transcript/tool-event extraction
3. explicit active query to CLI for "files changed in this session"
4. git reconciliation against actual working tree/index

confidence labels:
- `exact` (explicit hook/tool event)
- `verified` (agent report + git verify)
- `heuristic` (fallback inference)

## 5.4 agent integration strategy

- ship wrappers/adapters for supported CLIs (`claude`, `codex`)
- wrappers inject `TOASTTY_PANEL_ID`, `TOASTTY_SESSION_ID`
- workspace is derived from panel location in app state (not from process env)
- wrappers are launched by toastty per terminal panel; child processes inherit panel/session env by design
- adapters emit lifecycle/events to local socket:
  - `session.start`
  - `session.update_files`
  - `session.needs_input` (drives notification dot + optional macOS notification)
  - `session.progress` (status update, e.g. "Refactoring dashboard component...")
  - `session.error` (surface error state)
  - `session.stop`

## 5.5 local event socket contract

- transport: per-user unix domain socket (no tcp listener in v1)
- usage:
  - agent wrappers/adapters publish lifecycle + attribution events
  - local cli commands (e.g. `toastty notify`) publish attention events
- security:
  - socket file permissions `0600`, owned by current user
  - reject non-local transports
- protocol:
  - versioned event envelope (`protocolVersion`, `kind`, `eventType`, `payload`)
  - ignore unknown event types, reject incompatible major protocol versions

Detailed protocol contract: `docs/socket-protocol.md`.

event envelope shape:
```json
{
  "protocolVersion": "1.0",
  "kind": "event",
  "eventType": "session.update_files",
  "sessionID": "abc123",
  "panelID": "uuid",
  "timestamp": "2026-02-26T23:10:00Z",
  "payload": {}
}
```

minimum payloads (v1):
- `session.start`:
  - `agent: "claude" | "codex"` (required)
  - `cwd?: String` (absolute path)
  - `repoRoot?: String` (absolute path)
- `session.update_files`:
  - `files: [String]` (absolute paths preferred; relative allowed if `cwd` is present)
  - `cwd?: String` (absolute path, required when `files` are relative)
  - `repoRoot?: String` (absolute path)
- `session.needs_input`:
  - `title: String`
  - `body: String`
- `session.error`:
  - `message: String`
- `session.stop`:
  - `reason?: String`

## 6) major features

## 6.1 panel mobility (pane/workspace/window)

requirements:
- keep panel identity stable (`panelID`) across all moves
- keep terminal process alive when moving terminal panels (no recreate)
- preserve session binding/history/metadata on move
- move must not create a new session; only session location metadata changes
- support pointer + menu-initiated moves (command palette in V1.5)

approach:
- core actions:
  - `reorderPanel(panelID, toIndex, inPaneID)`
  - `movePanelToPane(panelID, targetPaneID, index?)`
  - `movePanelToWorkspace(panelID, targetWorkspaceID, targetPaneID?, splitHint?)`
  - `movePanelToWindow(panelID, targetWindowID, targetWorkspaceID, targetPaneID?)`
  - `detachPanelToNewWindow(panelID, targetDisplayID?)`
- runtime transfer: detach runtime from source host, attach to destination host
- focus sync: destination becomes key only when user intent implies focus
- default drop policy when target workspace has no compatible pane: create pane and insert panel
- after move commit, `SessionRegistry` updates denormalized location fields (workspace/window) from panel location; `sessionID` remains unchanged
- `detachPanelToNewWindow` always creates:
  - new `WindowState` with a new frame and one workspace id
  - new `WorkspaceState` with a single leaf pane containing the detached panel
  - new window `selectedWorkspaceID` set to the created workspace
- menu-initiated move actions do not auto-focus destination window unless action explicitly requests focus

drag/drop targets:
- pane tab strip: reorder in-pane or move cross-pane
- pane body edges: move panel as split target (left/right/up/down)
- vertical workspace tab row: move panel to workspace
- outside window bounds: create new window and attach panel

notes:
- moving a panel to another workspace should be first-class (not emulated as close+reopen)
- this is required for external-monitor workflows and vertical-tab organization
- moving workspaces between windows is out of scope for v1 (panel-level mobility only)

## 6.2 session-scoped diff panel

`DiffPanelState`:
- `showStaged: Bool`
- `mode: DiffBindingMode` (`followFocusedTerminal` in v1)

behavior:
- always session-scoped — shows diffs for the focused terminal's active session
- header displays session attribution: agent name, source terminal number, truncated session ID (e.g. "Claude Code · Terminal 2 · abc1234")
- if no session is active on the focused terminal: show explicit "No active session" state
- render file list (with +/- counts) + per-file unified diff, scrollable
- unstaged/staged toggle in header
- refresh triggers:
  - focused terminal change (re-bind to new session)
  - session touched-files update
  - git head/index/worktree change

repo/path resolution policy (v1):
- attribution source of truth is session events (`session.update_files`)
- git is used to render actual diff hunks for the attributed files
- session is anchored to one `repoRoot` at `session.start` (resolved from adapter payload or first valid file path + cwd fallback)
- relative file paths from adapters are normalized using the event cwd
- if a session touches files outside `repoRoot`, show explicit "outside tracked repo" state in diff panel (no silent merge across repos in v1)
- if `repoRoot` is missing/incorrect at start, allow one correction window before first diff render using first valid attributed file path
- if later events imply conflicting roots, keep current root and surface explicit "conflicting repo roots" warning state

## 6.3 global terminal font size

- app-level `globalTerminalFontPoints`
- apply to all live terminal runtimes immediately
- new terminals inherit current global value
- support `zoomIn`, `zoomOut`, `reset` actions
- transient HUD overlay showing current size on change (auto-dismiss after ~1s)

## 6.4 layout profiles

```swift
struct DisplayLayoutState: Codable {
    var displaySignature: String // hash of connected display configuration
    var snapshot: AppLayoutSnapshot
    var savedAt: Date
}

struct AppLayoutSnapshot: Codable {
    var windows: [WindowLayoutSnapshot]
    var globalTerminalFontPoints: Double
}

struct WindowLayoutSnapshot: Codable {
    var windowID: UUID
    var frame: CGRectCodable
    var workspaceIDs: [UUID]
    var selectedWorkspaceID: UUID?
}
```

flow:
- layout state auto-saves per display signature on meaningful layout changes
- on display topology change, auto-restore the saved layout for the new display configuration
- if no saved layout exists for a display, keep current layout
- "revert last layout change" action available as escape hatch
- no named profiles, no suggestion dialogs — just automatic per-display memory
- display signature inputs (v1): stable display id, resolution, scale factor, relative arrangement
- revert scope (v1): per-display-signature undo of last applied/restored snapshot
- if stable display id changes unexpectedly (dock/hub churn), try fuzzy fallback match on resolution + arrangement before treating as unknown display topology

## 6.5 notification and attention system

### sources
- agent adapter events: `session.needs_input`, `session.error`, `session.stop`
- OSC 99 (Kitty notification format) parsed by Ghostty — terminal-native notifications
- socket/CLI API: `toastty notify --title <text> --body <text>`

### notification data
```swift
struct ToasttyNotification: Identifiable {
    let id: UUID
    let workspaceID: UUID
    let panelID: UUID?
    let title: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}
```

### behavior (learned from cmux)
- **deduplication**: one active notification per panel — new notification replaces previous for same panel
- **suppression**: no notification if the source panel is already focused and the app is active
- **auto-read**: notifications marked read when user focuses the source workspace/panel
- workspace sidebar shows notification dot (colored indicator) for workspaces with unread notifications
- macOS system notification sent when app is not focused or source panel is not visible
- dock badge shows unread count
- OSC 99 notifications are attributed to the emitting terminal panel runtime before entering `NotificationStore`, then dedup/suppression use the same per-panel path

### agent notification hooks
Claude Code (via `~/.claude/settings.json`):
```json
{
  "hooks": {
    "Notification": [
      {"matcher": "idle_prompt", "hooks": [{"type": "command", "command": "toastty notify --title 'Claude Code' --body 'Waiting for input'"}]},
      {"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "toastty notify --title 'Claude Code' --body 'Approval needed'"}]}
    ]
  }
}
```

Codex (via config):
```toml
notify = ["bash", "-c", "toastty notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' | head -c 100)\""]
```

## 6.6 top bar panel toggles

- toggle buttons for each aux panel kind: Diff, Markdown, Scratchpad
- multi-select: each button independently shows/hides its panel
- toggled-on panels appear in the right column by default, stacked vertically
- panels can be dragged from the right column to any other split position
- toggle state persists per workspace (different workspaces can have different panels visible)
- icon + label for each toggle, highlighted when active, dimmed when inactive
- each workspace has at most one instance per aux panel kind in v1
- toggle on: ensure panel instance exists (create in right column if absent)
- toggle off: close that aux panel instance regardless of its current pane position

## 6.7 markdown preview panel

`MarkdownPanelState`:
- `sourcePanelID?`
- `filePath?`
- `rawMarkdown?`

behavior:
- follows focused terminal — shows markdown files from the active session
- file selection via header dropdown:
  - dropdown chip in panel header shows current file name + chevron
  - click opens picker menu listing session-touched `.md` files at top, then fallback candidates below a divider
  - if source session has touched `.md` files:
    - 1 file -> auto-select, dropdown still available to switch
    - >1 files -> auto-select first, dropdown shows all options
  - fallback candidates: `README.md`, docs top-level markdown
  - when focused terminal changes, dropdown resets to auto-selected file for the new session

rendering:
- sandboxed webview html render
- no external network access from markdown webview
- local file access restricted to workspace root and explicit file selection
- no arbitrary js evaluation in markdown preview
- sanitize markdown-rendered html before load
- disable javascript execution at webview configuration level for markdown preview

## 6.8 scratchpad canvas (v2)

goal:
- interactive HTML/CSS/JS canvas for agent-human communication
- machine-readable + machine-writable

initial API:
- `canvas.set_html(panelID, html)`
- `canvas.get_html(panelID)`
- `canvas.eval_js(panelID, script)`
- `canvas.snapshot(panelID)`

behavior:
- follows focused terminal — each terminal session can have associated scratchpad content
- Edit/Preview toggle in panel header
- default no outbound network from scratchpad runtime
- if local dev-server bridging is needed, only allow loopback (`127.0.0.1` / `localhost`) and block remote hosts

`ScratchpadPanelState` (v2 draft):
- `sourcePanelID?`
- `activeSessionID?`
- `contentBySessionID: [String: String]` // sessionID -> html string

implementation path:
- build panel host in toastty
- keep canvas runtime as separable package boundary so it can move to dedicated repo later
- run a dedicated scratchpad threat-model review before enabling `canvas.eval_js` in stable builds

## 7) initial file layout

```text
Sources/
  App/
    ToasttyApp.swift
    AppCoordinator.swift
    WindowCoordinator.swift
  Core/
    State/
      AppState.swift
      WindowState.swift
      WorkspaceState.swift
      PanelState.swift
      PaneNode.swift
    PanelSystem/
      PanelKind.swift
      PanelCapabilities.swift
      PanelDescriptor.swift
    Actions/
      AppAction.swift
      AppReducer.swift
  Runtime/
    Panels/
      PanelRuntime.swift
      PanelRuntimeRegistry.swift
      PanelScaffold.md
      TerminalPanelRuntime.swift
      DiffPanelRuntime.swift
      MarkdownPanelRuntime.swift
      ScratchpadPanelRuntime.swift
    Ghostty/
      GhosttySurfaceController.swift
      GhosttySurfaceHostView.swift
  Services/
    Sessions/
      SessionRegistry.swift
      AgentAdapters/
        ClaudeAdapter.swift
        CodexAdapter.swift
    Diff/
      GitDiffService.swift
      DiffAttributionService.swift
    Notifications/
      NotificationService.swift
      NotificationStore.swift
    Layout/
      DisplayLayoutStore.swift
    Persistence/
      SessionStore.swift
      Migration.swift
  UI/
    TopBar/
      TopBarView.swift
      PanelToggleButtons.swift
    Sidebar/
      SidebarView.swift
      WorkspaceRow.swift
    Workspace/
      WorkspaceView.swift
      PaneSplitView.swift
    Panels/
      PanelHeaderView.swift
      DiffPanelView.swift
      MarkdownPanelView.swift
      ScratchpadPanelView.swift
Tests/
  Core/
  Services/
  Runtime/
UITests/
Automation/
  Fixtures/
    Layouts/
    Sessions/
    Accessibility/
  Baselines/
    UI/
Scripts/
  automation/
    check.sh
    smoke-ui.sh
    export-ui-artifacts.sh
```

## 8) implementation phases

## phase 0 - bootstrap (3-5 days)
- create macOS app scaffold (SwiftUI app lifecycle) with Tuist as the project source of truth
  - check in `Project.swift` / `Workspace.swift` manifests (and `Tuist/` helpers as needed)
  - generated `.xcodeproj`/`.xcworkspace` are derived artifacts, not hand-edited
  - standardize agent-automation commands:
    - `tuist generate`
    - `tuist build` (or `xcodebuild` when needed for edge cases/tooling gaps)
    - `tuist test`
- integrate Ghostty runtime wrapper baseline
  - reference cmux's `setup.sh` and GhosttyKit.xcframework build pipeline
  - get a single Ghostty surface rendering in a window as the first milestone
  - note: Ghostty build (zig → xcframework → Xcode linking) is the highest-risk step; prototype as standalone spike if needed
- implement minimal pane tree + terminal panel
- implement sidebar with workspace list
- establish agent-autonomous validation harness:
  - launch-time automation mode contract:
    - launch args: `--automation --run-id <id> --fixture <name> --artifacts-dir <path>`
    - env: `TOASTTY_AUTOMATION=1`, `TOASTTY_DISABLE_ANIMATIONS=1`, `TOASTTY_FIXED_LOCALE=en_US_POSIX`, `TOASTTY_FIXED_TIMEZONE=UTC`
    - behavior: use fake runtimes/adapters/clock, load fixture before first frame, then emit readiness signal
  - stable accessibility identifiers for all major UI controls and panel headers
  - scripted smoke loop (`scripts/automation/check.sh`) that runs generate/build/test and exports UI artifacts
  - readiness/sync protocol:
    - app writes `artifacts/ui/<run-id>/ready.json` after fixture load + automation socket bind
    - script blocks until ready file exists (with timeout) before issuing automation commands
  - screenshot capture mechanism:
    - UI tests capture via `XCUIScreen.main.screenshot()` + `XCTAttachment`
    - `export-ui-artifacts.sh` exports attachments to `artifacts/ui/<run-id>/screenshots/`
  - artifact naming policy:
    - runtime artifacts: `artifacts/ui/<run-id>/<fixture>/<step>.png`
    - golden baselines: `Automation/Baselines/UI/<fixture>/<step>.png`
    - visual diffs: `artifacts/ui/<run-id>/diffs/<fixture>/<step>.png`

acceptance:
- open app, split panes, focus moves correctly
- sidebar shows workspaces, clicking switches between them

## phase 1 - multi-window + panel transfer (4-7 days)
- window/workspace core state
- full panel mobility actions (reorder/move pane/workspace/window)
- drag/drop behaviors:
  - within pane
  - cross-pane
  - onto workspace tab
  - out-of-window -> new window
- top bar with panel toggle buttons (wired to show/hide placeholder panels)

acceptance:
- live terminal panel moves across panes/workspaces/windows without process restart
- moving to another workspace preserves panel id + session binding
- panel toggles show/hide right column

## phase 2 - session registry + adapters + notifications (5-8 days)
- session store and bindings
- claude adapter (lifecycle events + needs_input + file attribution)
- codex adapter (lifecycle events + needs_input + file attribution)
- notification service with deduplication and suppression
- workspace notification indicators in sidebar
- macOS system notifications for backgrounded sessions

acceptance:
- focused panel resolves active session id reliably
- notification dot appears when agent needs input in unfocused workspace
- macOS notification fires when app is not focused

## phase 3 - diff panel v1 (4-6 days)
- diff panel runtime + ui
- session attribution label in diff header
- focus-follow behavior (diff re-binds when focused terminal changes)
- attribution pipeline + confidence labels

acceptance:
- session-scoped diff works for concurrent agents in same repo
- switching focus between terminals updates diff panel content
- diff header shows which session/terminal is being diffed

## phase 4 - global font + layout profiles (3-5 days)
- global font actions + propagation + transient HUD
- auto-save layout per display signature
- auto-restore on display topology change
- "revert last layout change" action

acceptance:
- Cmd+=/- adjusts all terminals at once, HUD shows current size
- unplug external monitor → layout restores to saved laptop state
- plug back in → layout restores to saved external state

## phase 5 - markdown panel (3-4 days)
- markdown panel runtime + webview render
- focus-follow behavior (re-binds to new session's touched markdown files)
- smart file suggestion from session touched files

acceptance:
- auto-pick single touched markdown file, picker for multiple
- switching terminal focus updates markdown panel

## phase 6 - scratchpad v1 (7-12 days)
- web canvas panel
- read/write/eval api
- focus-follow behavior (per-session scratchpad content)
- Edit/Preview toggle

acceptance:
- agent can render/update/read structured canvas content

## 9) testing strategy

agent-autonomous validation loop:
- provide a deterministic app launch profile for tests (`--automation`, fixed locale/timezone, animations reduced/disabled)
- support fixture-driven startup states (workspace/pane/panel/session fixtures from `Automation/Fixtures/`)
- expose a lightweight automation command surface (unix socket) to trigger app actions without manual pointer interaction
- run UI smoke tests via script and always export screenshots + logs to a stable artifact directory
- keep a baseline "golden" fixture set for regression screenshots (layout, diff panel, notifications, markdown)

automation command surface (v1 minimum):
- transport: same per-user unix socket used by local automation interfaces
- envelope:
```json
{
  "requestID": "uuid",
  "command": "automation.capture_screenshot",
  "payload": {}
}
```
- commands:
  - `automation.ping`
  - `automation.reset`
  - `automation.load_fixture`
  - `automation.perform_action`
  - `automation.capture_screenshot`
  - `automation.dump_state`
- responses:
  - ack envelope with `requestID`, `ok`, optional `error`, optional `result`

automation determinism requirements:
- every smoke run begins with `automation.reset` then fixture load
- fake adapter event streams are fixture-driven and reset per run
- smoke script fails on readiness timeout (non-zero exit)

unit tests:
- reducers/state transitions
- session registry conflict resolution
- diff attribution reconciliation
- layout profile save/restore
- notification deduplication and suppression logic
- panel tree invariants (`panels` map <-> `PaneNode` references + selected index bounds)
- codable migration roundtrip tests for `PanelState` and snapshot schema versions

test harness/fakes:
- `FakePanelRuntime` for integration tests that do not require Ghostty surfaces
- fake adapter transport feeding deterministic socket events
- deterministic clock + fixture-based event streams for attribution and notification flows

integration tests:
- panel move matrix:
  - pane->pane
  - workspace->workspace
  - window->window
  - window drag-out create
- focus correctness after moves/splits/closes
- session mapping from adapter events
- session metadata update after panel move (same `sessionID`, new workspace/window location)
- focus-follow: aux panels rebind on terminal focus change
- notification flow: adapter event → notification store → sidebar indicator
- diff correctness for attributed files (expected hunks/counts, head/index updates, outside-tracked-repo states)

ui tests:
- drag panel within pane to reorder
- drag panel to another workspace tab
- drag panel out to new window
- layout profile save/restore across display changes
- diff panel follow-focused-session behavior
- panel toggle buttons show/hide aux panels
- deterministic screenshot capture for key fixtures and compare against approved baselines
- accessibility contract tests assert required identifiers from `Automation/Fixtures/Accessibility/required_ids.json`

performance checks:
- 20+ live panels across windows
- no event-loop stalls during frequent session updates

## 10) key risks and mitigations

1. Ghostty surface reparenting/focus race conditions
- mitigate with single-threaded `GhosttySurfaceController` and deterministic attach/focus sequencing

2. Ghostty build pipeline complexity
- reference cmux's `setup.sh`, `scripts/reload.sh`, and GhosttyKit.xcframework caching strategy
- prototype Ghostty integration as standalone spike before committing to full scaffold
- cmux caches built frameworks in `$HOME/.cache/cmux/ghosttykit/` by SHA — adopt similar approach

3. session attribution drift
- persist confidence + source metadata; expose "why this file is attributed" in UI

4. layout profile surprise
- auto-save is non-destructive (just remembers layout per display)
- explicit revert action available

5. scratchpad scope creep
- keep v1 api intentionally small; isolate runtime boundary early
- treat `eval_js` as gated by explicit security review before production enablement

6. notification fatigue
- deduplication (one per panel) and suppression (no alert when already focused) prevent spam
- quality depends on agent hook configuration — ship good defaults for claude + codex

7. local socket abuse or schema drift
- unix socket only, strict file permissions, protocol version checks, and typed event decoding

8. project config drift / non-automatable Xcode changes
- use Tuist manifests as canonical project definition and keep build/test flows scriptable for agent execution

9. flaky/non-deterministic UI validation
- add automation mode + fixture seeding + stable screenshot artifacts so agents can iterate without manual visual verification
- enforce readiness protocol and deterministic screenshot comparison in smoke scripts

## 11) immediate next steps

1. lock state invariants + event socket protocol docs (`docs/state-invariants.md`, `docs/socket-protocol.md`) before scaffolding
2. scaffold Tuist manifests + bootstrap scripts (`generate`, `build`, `test`) and create core state models/reducer
3. add automation harness (`--automation`, fixtures, accessibility ids, scripted smoke run + artifact export)
4. spike Ghostty integration: build GhosttyKit.xcframework, render first surface (reference cmux)
5. implement terminal runtime + split pane baseline + sidebar
6. implement multi-window panel transfer before adding new panel types
7. build session registry + claude/codex adapter contracts + notification service
8. start diff panel on top of session registry (not before)

smoke script exit-code contract:
- `0`: success
- `10`: generate/build failure
- `11`: unit/integration test failure
- `12`: ui test execution failure
- `13`: screenshot baseline mismatch
- `14`: automation readiness/protocol timeout
