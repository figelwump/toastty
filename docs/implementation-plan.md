# toastty implementation plan

Date: 2026-02-26

Status update (2026-02-28):
- execution priority for this plan is paused.
- active implementation plan is now `docs/mvp-daily-driver-plan.md`.
- this document remains as historical architecture/decision context.

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
  - keyboard-driven panel movement (move panel left/right/up/down, move to workspace N)
- global terminal font size control
- session registry + session->surface binding
- session-scoped diff panel (file-level first; hunk-level later)
- top bar panel toggle buttons (show/hide aux panels)
- notification/attention system (workspace indicators + macOS notifications)
- agent adapters for claude + codex (lifecycle + file attribution + attention events)
- reopen last closed panel (per-workspace undo stack, terminal process not recoverable but panel state is)

### V1.5
- layout profiles (auto-save per display, auto-restore on display change, revert)
- markdown preview panel with session-aware file suggestions
- command palette (⌘K) for panel management, workspace switching, font control
- codex + claude adapters with stronger touched-file attribution

### V2
- scratchpad canvas panel (see `docs/scratchpad.md`)
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
    case scratchpad // V2 — declared now for forward-compatible serialization
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
    var recentlyClosedPanels: [ClosedPanelRecord] // bounded stack for reopen
}

indirect enum PaneNode: Codable {
    case leaf(paneID: UUID, tabPanelIDs: [UUID], selectedIndex: Int)
    case split(nodeID: UUID, orientation: SplitOrientation, ratio: Double, first: PaneNode, second: PaneNode)
}

enum PanelState: Codable {
    case terminal(TerminalPanelState)
    case diff(DiffPanelState)
    case markdown(MarkdownPanelState)
    case scratchpad(ScratchpadPanelState) // V2
}

struct ClosedPanelRecord: Codable {
    let panelState: PanelState
    let closedAt: Date
    let sourceLeafPaneID: UUID // where to re-insert if possible
}
```

Note: `PaneNode.split` has a `nodeID` so that interior nodes can be addressed as drag-drop targets. Without this, there is no way to identify which split edge the user is dropping onto. All node IDs (leaf `paneID` and split `nodeID`) must be unique within a workspace tree.

state invariants:
- `WindowState.workspaceIDs` is ordered and is the source of truth for workspace ordering in that window
- every id in `WindowState.workspaceIDs` must exist in `AppState.workspacesByID`
- a workspace belongs to exactly one window at a time
- aux panel visibility is persisted per workspace (`WorkspaceState.auxPanelVisibility`)
- every panel id in any `PaneNode.leaf.tabPanelIDs` must exist in `WorkspaceState.panels`
- every key in `WorkspaceState.panels` must appear exactly once in `PaneNode.leaf.tabPanelIDs` in that workspace
- empty pane leaves are not allowed after reducer actions
- `PaneNode.leaf.selectedIndex` must be in-bounds (`0 <= selectedIndex < tabPanelIDs.count`) after every reducer action
- all node IDs (leaf `paneID` and split `nodeID`) must be unique within a workspace tree

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

Note: we intentionally do not have a `PanelCapabilities` or `PanelDescriptor` abstraction in V1. Each panel kind is a concrete enum case with a factory. If we later need a plugin/dynamic panel system, we can introduce capabilities then. Avoid premature abstraction.

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
- panel toggle buttons: Diff, Markdown — multi-select, each independently shows/hides its panel (Scratchpad toggle added in V2)
- toggled-on panels appear in the right column by default, stacked vertically
- panels can be dragged from their default position to any split target

### panel headers
- every panel (terminal and aux) has a consistent header: drag grip (three vertical dots) + panel number/label + contextual controls
- drag grip communicates that all panels are rearrangeable
- terminal headers: pane number + shell name + cwd
- diff header: session attribution label ("Claude Code · Terminal 2 · abc1234") + unstaged/staged toggle
- markdown header: file dropdown selector (shows current file name + chevron; click opens picker menu with session-touched .md files + fallback candidates)

### aux panel focus-follow behavior
- when focused terminal changes, aux panels update to reflect the new terminal's session context
- diff panel: shows diffs for the newly focused session
- markdown panel: shows markdown files touched by the newly focused session

### aux panel placement algorithm ("right column")

When an aux panel toggle is turned on and no instance exists:

1. If the pane tree is a single leaf: create a vertical split (orientation: `.horizontal`, ratio: `0.65`) with the existing leaf on the left and a new leaf containing the aux panel on the right.
2. If the pane tree already has a rightmost leaf (traverse `split.second` recursively): insert the aux panel as a new tab in that rightmost leaf, or stack it vertically within the right column if multiple aux panels are visible.
3. If the user has previously moved the panel to a custom position, re-toggling on creates it in the right column (not the old custom position).

The "right column" is defined structurally: the rightmost leaf reachable by always following `split.second` in horizontal splits. This is a heuristic, not a reserved slot — the user can freely rearrange after creation.

### keyboard-driven panel movement

V1 keyboard shortcuts for panel mobility (exact bindings configurable):
- `⌘⇧←/→/↑/↓`: move focused panel to adjacent pane in that direction
- `⌘⌃1–N`: move focused panel to workspace N
- `⌘⇧D`: detach focused panel to new window
- `⌘⇧T`: reopen last closed panel in current workspace

These supplement drag-drop and menu-initiated moves. Command palette integration in V1.5.

### lifecycle cascade rules

- **Close last panel in a leaf**: collapse the leaf out of the split tree (parent split replaced by sibling node).
- **Close last panel in a workspace**: close the workspace. Remove workspace from its window's `workspaceIDs`. If it was `selectedWorkspaceID`, select the nearest sibling.
- **Close last workspace in a window**: close the window. Remove from `AppState.windows`. If it was the last window, the app remains running with no windows (macOS dock icon persists; re-activate creates a fresh default window).

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

### session lifecycle and cleanup

- **Active session**: `stoppedAt == nil`. One active session per panel at a time.
- **Stopped session**: `stoppedAt != nil`. Retained for history/diff review until pruned.
- **Panel close**: if the panel's session is active, emit implicit `session.stop`. The session record transitions to stopped.
- **Pruning**: stopped sessions older than 24 hours are pruned from the in-memory registry on app launch. Persisted session history (for forensics/review) is a separate concern and not required for V1.
- **No reopen binding**: reopening a closed panel does not rebind to the old session. A new session starts if a new agent is launched in the restored panel.

## 5.3 attribution pipeline

priority order:
1. explicit hook events from agent wrapper/adapters
2. agent session transcript/tool-event extraction
3. explicit active query to CLI for "files changed in this session"
4. git reconciliation against actual working tree/index

V1 does not track attribution confidence labels. The pipeline sources above are tried in priority order; whichever source provides data is used directly. Confidence labels (`exact` / `verified` / `heuristic`) can be added in a later release if the diff panel UI needs to distinguish attribution quality — but only when there's a concrete consumer for that metadata.

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

### event debounce and coalescing

Agents can emit `session.update_files` at high frequency (e.g., fast-moving agent touching many files). The app must coalesce rapid file updates to avoid diff panel thrashing:

- **Coalesce window**: batch `session.update_files` events within a 500ms window per session. Merge file lists, keep latest `cwd` and `repoRoot`.
- **Diff recompute debounce**: after the coalesce window closes, trigger a single diff recompute. If another update arrives during diff computation, cancel the in-progress computation and restart after the next coalesce window.
- **Progress events**: `session.progress` events are not debounced (they update a status label, which is cheap).

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
- support pointer, keyboard, and menu-initiated moves (command palette in V1.5)

approach:
- core actions:
  - `reorderPanel(panelID, toIndex, inPaneID)`
  - `movePanelToPane(panelID, targetPaneID, index?)`
  - `movePanelToWorkspace(panelID, targetWorkspaceID, targetPaneID?, splitHint?)`
  - `movePanelToWindow(panelID, targetWindowID, targetWorkspaceID, targetPaneID?)`
  - `detachPanelToNewWindow(panelID, targetDisplayID?)`
  - `movePanelInDirection(panelID, direction: up|down|left|right)` — keyboard-driven, resolves target pane from tree adjacency
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
- pane body edges: move panel as split target (left/right/up/down) — addressed via `PaneNode.split.nodeID` + edge direction
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
- `loadingState: DiffLoadingState` (`.idle`, `.computing`, `.error(String)`)

behavior:
- always session-scoped — shows diffs for the focused terminal's active session
- header displays session attribution: agent name, source terminal number, truncated session ID (e.g. "Claude Code · Terminal 2 · abc1234")
- if no session is active on the focused terminal: show explicit "No active session" state
- render file list (with +/- counts) + per-file unified diff, scrollable
- unstaged/staged toggle in header
- refresh triggers:
  - focused terminal change (re-bind to new session)
  - session touched-files update (after coalesce window)
  - git head/index/worktree change

### loading and async states

Git diff operations can be slow on large repos. The diff panel must handle async computation gracefully:

- **Loading state**: show a non-blocking loading indicator (spinner or shimmer) while computing diffs. Do not flash the indicator for fast completions (<200ms) — use a brief delay before showing.
- **Stale cancellation**: when focus changes while a diff is computing, cancel the in-progress computation and start a new one for the new session. Never show stale results from a previous session.
- **Error state**: if git operations fail (corrupt index, permission error, etc.), show an explicit error message in the diff panel body. Do not silently show an empty diff.

### repo/path resolution policy (v1)

- attribution source of truth is session events (`session.update_files`)
- git is used to render actual diff hunks for the attributed files
- session is anchored to one `repoRoot` at `session.start` (resolved from adapter payload or first valid file path + cwd fallback)
- relative file paths from adapters are normalized using the event cwd
- if a session touches files outside `repoRoot`, those files appear in a separate "Outside repo" section in the file list — visible but visually distinct from in-repo diffs
- if `repoRoot` is missing/incorrect at start, allow one correction window before first diff render using first valid attributed file path
- multi-repo is out of scope for V1. If later events send a different `repoRoot`, keep the original root. Files from the new root appear in the "Outside repo" section. No warning dialogs or special states — just let the file list show what's happening.

## 6.3 global terminal font size

- app-level `globalTerminalFontPoints`
- apply to all live terminal runtimes immediately
- new terminals inherit current global value
- support `zoomIn`, `zoomOut`, `reset` actions
- transient HUD overlay showing current size on change (auto-dismiss after ~1s)

## 6.4 layout profiles (V1.5)

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
- display signature inputs: stable display id, resolution, scale factor, relative arrangement
- revert scope: per-display-signature undo of last applied/restored snapshot
- if stable display id changes unexpectedly (dock/hub churn), try fuzzy fallback match on resolution + arrangement before treating as unknown display topology

Note: V1 ships without layout profiles. Windows remember their own frame on quit/relaunch (standard macOS `NSWindow` restoration), but there is no display-signature-based auto-switching. This is sufficient for single-display and simple multi-display setups.

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

- toggle buttons for each aux panel kind: Diff, Markdown (Scratchpad added in V2)
- multi-select: each button independently shows/hides its panel
- toggled-on panels appear in the right column by default, stacked vertically (see aux panel placement algorithm in §4.5)
- panels can be dragged from the right column to any other split position
- toggle state persists per workspace (different workspaces can have different panels visible)
- icon + label for each toggle, highlighted when active, dimmed when inactive
- each workspace has at most one instance per aux panel kind in v1
- toggle on: ensure panel instance exists (create in right column if absent, using placement algorithm)
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

## 6.8 reopen closed panel

- each workspace maintains a bounded stack of recently closed panels (`recentlyClosedPanels`, max 10 entries)
- `⌘⇧T` reopens the most recently closed panel in the current workspace
- the panel is re-inserted into its original pane if that pane still exists, otherwise into the focused pane
- terminal panels: the terminal process is gone after close (not recoverable), but the panel state (title, cwd, session history reference) is restored. A new shell session starts in the restored panel.
- aux panels: fully restored (diff rebinds to current focused session, markdown restores file selection)
- entries older than the current app session are not preserved (reopen stack is transient, not persisted)

## 6.9 focused panel mode (maximize / restore)

goal:
- temporarily focus a single panel and let it fill the workspace content area.
- restore prior multi-pane layout with one action.

v1 behavior:
- action `toggleFocusedPanelMode` on current workspace:
  - if not in focused-panel mode:
    - capture current workspace layout snapshot (`paneTree`, `focusedPanelID`).
    - show only the currently focused panel in a single leaf that fills the workspace view.
  - if already in focused-panel mode:
    - restore the captured layout snapshot.
- keyboard shortcut: `⌘⇧F` toggles focused-panel mode for the selected workspace.
- toolbar affordance: add a top-bar "Focus Panel" toggle button reflecting active state.
- while in focused-panel mode:
  - panel close/reopen continues to function and update underlying state.
  - split and aux-toggle actions are disabled (or no-op) until mode is exited to avoid ambiguous merge semantics in v1.

state model note:
- add a per-workspace transient snapshot field for focused-panel mode restore:
  - `focusedPanelModeSnapshot? { paneTree, focusedPanelID }`
- this snapshot is runtime/session-local and not persisted across app relaunch for v1.

acceptance:
- entering mode from any mixed layout (terminals + aux) shows only the focused panel.
- exiting mode restores exact prior layout and focus target.
- repeated toggle cycles are lossless under reducer/state invariant tests.

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
    Actions/
      AppAction.swift
      AppReducer.swift
  Runtime/
    Panels/
      PanelRuntime.swift
      PanelRuntimeRegistry.swift
      TerminalPanelRuntime.swift
      DiffPanelRuntime.swift
      MarkdownPanelRuntime.swift
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

Note: `PanelSystem/` directory (PanelCapabilities, PanelDescriptor) removed from V1 layout. Panel extensibility is handled by `PanelKind` enum + `PanelRuntimeRegistry` factory registration. Add a capabilities/descriptor abstraction only if/when a dynamic plugin system is needed.

Note: Scratchpad files (ScratchpadPanelRuntime, ScratchpadPanelView) are not in the V1 layout. Add them when V2 work begins.

## 8) implementation phases

## phase 0 - Ghostty spike + bootstrap

Priority order within this phase matters. Ghostty integration is the highest-risk item and the foundation everything else depends on. Do the spike first before investing in app shell polish or automation infra.

### step 1: Ghostty integration spike
- build GhosttyKit.xcframework (reference cmux's `setup.sh` and zig build pipeline)
- render a single Ghostty terminal surface in a bare-bones macOS window
- validate: surface creates, accepts keyboard input, renders output, resizes
- document the concrete `GhosttySurfaceController` API surface discovered during the spike (expected methods for create, attach to NSView, detach, reparent, resize, focus, destroy)
- document the build pipeline (zig version requirements, xcframework cache strategy, Xcode linking)
- this step should produce a standalone spike project or branch — not yet integrated into the full app scaffold

If the spike reveals blockers (zig build issues, surface API limitations, reparenting constraints), those must be resolved before proceeding. This is the make-or-break step.

See also: `docs/ghostty-integration.md` (to be created during the spike with findings).

### step 2: app scaffold
- create macOS app scaffold (SwiftUI app lifecycle) with Tuist as the project source of truth
  - check in `Project.swift` / `Workspace.swift` manifests (and `Tuist/` helpers as needed)
  - generated `.xcodeproj`/`.xcworkspace` are derived artifacts, not hand-edited
  - standardize agent-automation commands:
    - `tuist generate`
    - `tuist build` (or `xcodebuild` when needed for edge cases/tooling gaps)
    - `tuist test`
- integrate Ghostty surface from spike into app scaffold
- implement minimal pane tree + terminal panel
- implement sidebar with workspace list

### step 3: automation harness (lightweight)
- launch-time automation mode contract:
  - launch args: `--automation --run-id <id> --fixture <name> --artifacts-dir <path>`
  - env: `TOASTTY_AUTOMATION=1`, `TOASTTY_DISABLE_ANIMATIONS=1`, `TOASTTY_FIXED_LOCALE=en_US_POSIX`, `TOASTTY_FIXED_TIMEZONE=UTC`
  - behavior: use fake runtimes/adapters/clock, load fixture before first frame, then emit readiness signal
- stable accessibility identifiers for all major UI controls and panel headers
- scripted smoke loop (`scripts/automation/check.sh`) that runs generate/build/test

Note: the full screenshot baseline system (golden images, visual diffs, artifact export) can be layered in later once the app UI is stable enough for meaningful screenshots. Don't invest in screenshot infra before the core UI exists.

acceptance:
- Ghostty surface renders and accepts input
- open app, split panes, focus moves correctly
- sidebar shows workspaces, clicking switches between them

## phase 1 - multi-window + panel transfer
- window/workspace core state
- full panel mobility actions (reorder/move pane/workspace/window)
- keyboard shortcuts for panel movement
- drag/drop behaviors:
  - within pane
  - cross-pane
  - onto workspace tab
  - out-of-window -> new window
- top bar with panel toggle buttons (wired to show/hide placeholder panels)
- lifecycle cascade (close last panel → close workspace → close window)
- reopen closed panel action (`⌘⇧T`)

acceptance:
- live terminal panel moves across panes/workspaces/windows without process restart
- moving to another workspace preserves panel id + session binding
- panel toggles show/hide right column
- keyboard shortcuts move panels between panes
- closing last panel in workspace closes the workspace

## phase 2 - session registry + adapters + notifications
- session store and bindings
- claude adapter (lifecycle events + needs_input + file attribution)
- codex adapter (lifecycle events + needs_input + file attribution)
- notification service with deduplication and suppression
- workspace notification indicators in sidebar
- macOS system notifications for backgrounded sessions
- session cleanup on panel close

acceptance:
- focused panel resolves active session id reliably
- notification dot appears when agent needs input in unfocused workspace
- macOS notification fires when app is not focused

## phase 3 - diff panel v1
- diff panel runtime + ui
- session attribution label in diff header
- focus-follow behavior (diff re-binds when focused terminal changes)
- loading/async states (spinner, stale cancellation, error display)
- event coalescing for rapid `session.update_files`
- "Outside repo" section for out-of-scope files

acceptance:
- session-scoped diff works for concurrent agents in same repo
- switching focus between terminals updates diff panel content
- diff header shows which session/terminal is being diffed
- rapid file updates don't cause thrashing

## phase 4 - global font + polish
- global font actions + propagation + transient HUD
- focused panel mode (maximize/restore current panel) with keyboard shortcut and top-bar toggle
- screenshot baseline system (golden images, visual diffs, artifact export)
- automation harness refinements based on real usage from phases 0-3

acceptance:
- Cmd+=/- adjusts all terminals at once, HUD shows current size
- focused panel mode roundtrip preserves prior layout and panel focus
- automated smoke tests produce stable screenshots

## phase 5 - layout profiles (V1.5)
- auto-save layout per display signature
- auto-restore on display topology change
- "revert last layout change" action

acceptance:
- unplug external monitor → layout restores to saved laptop state
- plug back in → layout restores to saved external state

## phase 6 - markdown panel (V1.5)
- markdown panel runtime + webview render
- focus-follow behavior (re-binds to new session's touched markdown files)
- smart file suggestion from session touched files

acceptance:
- auto-pick single touched markdown file, picker for multiple
- switching terminal focus updates markdown panel

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
- notification deduplication and suppression logic
- panel tree invariants (`panels` map <-> `PaneNode` references + selected index bounds)
- codable migration roundtrip tests for `PanelState` and snapshot schema versions
- lifecycle cascade (close panel → empty leaf collapse → workspace close → window close)

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
- diff correctness for attributed files (expected hunks/counts, head/index updates, outside-repo states)
- event coalescing: rapid file updates produce single diff recompute

ui tests:
- drag panel within pane to reorder
- drag panel to another workspace tab
- drag panel out to new window
- diff panel follow-focused-session behavior
- panel toggle buttons show/hide aux panels
- keyboard panel movement
- reopen closed panel
- deterministic screenshot capture for key fixtures and compare against approved baselines
- accessibility contract tests assert required identifiers from `Automation/Fixtures/Accessibility/required_ids.json`

performance checks:
- 20+ live panels across windows
- no event-loop stalls during frequent session updates

## 10) key risks and mitigations

1. **Ghostty surface API unknowns and reparenting races**
- The Ghostty surface API contract is not fully known before the spike. The spike (phase 0 step 1) must document: surface create/destroy, attach/detach from NSView, reparent between views, focus management, resize behavior.
- Reparenting race conditions mitigated with single-threaded `GhosttySurfaceController` and deterministic attach/focus sequencing.
- If reparenting is not supported by Ghostty, the fallback is surface destroy+recreate with shell session restore (significant complexity increase — flag early).

2. **Ghostty build pipeline complexity**
- reference cmux's `setup.sh`, `scripts/reload.sh`, and GhosttyKit.xcframework caching strategy
- cmux caches built frameworks in `$HOME/.cache/cmux/ghosttykit/` by SHA — adopt similar approach
- document zig version requirements and build steps during spike

3. **Session attribution drift**
- persist source metadata; expose "why this file is attributed" in UI when needed
- V1 trusts adapter events directly without confidence scoring

4. **Notification fatigue**
- deduplication (one per panel) and suppression (no alert when already focused) prevent spam
- quality depends on agent hook configuration — ship good defaults for claude + codex

5. **Local socket abuse or schema drift**
- unix socket only, strict file permissions, protocol version checks, and typed event decoding

6. **Project config drift / non-automatable Xcode changes**
- use Tuist manifests as canonical project definition and keep build/test flows scriptable for agent execution

7. **Flaky/non-deterministic UI validation**
- add automation mode + fixture seeding + stable screenshot artifacts so agents can iterate without manual visual verification
- enforce readiness protocol and deterministic screenshot comparison in smoke scripts
- but: invest in screenshot baselines only after UI is stable enough for meaningful comparisons

## 11) immediate next steps

1. **Ghostty spike** — build GhosttyKit.xcframework, render first surface, document API surface and build pipeline. This is blocking for everything else.
2. scaffold Tuist manifests + bootstrap scripts (`generate`, `build`, `test`) and create core state models/reducer
3. integrate Ghostty surface into app scaffold, implement terminal runtime + split pane baseline + sidebar
4. add lightweight automation harness (`--automation`, fixtures, accessibility ids, scripted smoke run)
5. implement multi-window panel transfer + keyboard shortcuts before adding new panel types
6. build session registry + claude/codex adapter contracts + notification service
7. start diff panel on top of session registry (not before)
8. lock state invariants + event socket protocol docs (`docs/state-invariants.md`, `docs/socket-protocol.md`) — these are already drafted, finalize alongside implementation

smoke script exit-code contract:
- `0`: success
- `10`: generate/build failure
- `11`: unit/integration test failure
- `12`: ui test execution failure
- `13`: screenshot baseline mismatch
- `14`: automation readiness/protocol timeout

## 12) execution log

### 2026-02-27

Execution mode:
- implementing the plan in validated chunk commits with post-commit second-opinion review.

Plan adjustments:
- repository started as docs-only; bootstrapping scaffold and core state first to enable test-driven implementation.
- Ghostty spike is tracked as blocked until build prerequisites are available (`zig` missing, no local `GhosttyKit.xcframework` cache found).
- see `docs/ghostty-integration.md` for blocker details and next actions.

Chunk A (phase 0 step 2 + step 3 foundation):
- added Tuist manifests (`Project.swift`, `Workspace.swift`) and project `.gitignore`.
- added initial source layout under `Sources/App` and `Sources/Core`.
- implemented core data model and reducer baseline for windows/workspaces/panes/panels.
- implemented state invariant validator + baseline unit tests.
- added scripted smoke command `scripts/automation/check.sh` with exit-code mapping (`10` generate/build, `11` tests).
- validation passed: `./scripts/automation/check.sh` (runs `tuist generate`, `tuist build`, `tuist test`).
- technical note: Tuist 4.68 uses `.target(... product: .unitTests ...)` instead of `.testTarget(...)` in `Project.swift`.

Chunk A review reconciliation (post-commit second opinion on `99363fa`):
- accepted: recover from stale `focusedPanelID` in `splitFocusedPane` by resolving fallback focus from pane tree.
- accepted: validate `focusedPanelID` invariants (`focused panel exists` and `focused panel is present in pane tree`).
- accepted: validate split ratio bounds (`0 < ratio < 1`).
- accepted: make pane-tree mutation in `replaceLeaf`/`appendPanel` explicit with immutable branch copies.
- accepted: make terminal default titles monotonic (`Terminal N`) based on max existing ordinal instead of panel count.
- rejected: removing `@discardableResult` from reducer send; keeping non-throwing action dispatch is intentional for app-level no-op handling.
- rejected: splitting leaf/split node id namespaces at this stage; current invariant intentionally enforces uniqueness across both id categories.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` and expanded tests (9 passing).

Chunk B (phase 0 step 3 automation baseline + workspace UX baseline):
- added automation configuration parsing (`AutomationConfig`) with launch args/env support for:
  - `--automation`
  - `--run-id`
  - `--fixture`
  - `--artifacts-dir`
  - env flags (`TOASTTY_DISABLE_ANIMATIONS`, `TOASTTY_FIXED_LOCALE`, `TOASTTY_FIXED_TIMEZONE`)
- added deterministic fixture loader (`AutomationFixtureLoader`) with `single-workspace`, `two-workspaces`, and `split-workspace` fixtures.
- added app bootstrap path that initializes state from automation fixture when automation mode is active.
- added automation readiness signaling (`automation-ready-<run-id>.json`) to artifacts directory after first app render.
- added sidebar `New workspace` action and reducer support (`createWorkspace`) to enable workspace switching flows in scaffold UI.
- added baseline accessibility identifiers for sidebar/topbar/split controls/workspace rows.
- validation passed: `./scripts/automation/check.sh` with 13 passing tests.

Chunk B review reconciliation (post-commit second opinion on `dfd617e`):
- accepted: harden ready-signal write path with lock-protected single-fire semantics in `AutomationLifecycle`.
- accepted: `createWorkspace` no longer mutates `selectedWindowID`; avoids unintended focus stealing in multi-window scenarios.
- accepted: remove silent automation fixture fallback by surfacing unknown fixture as explicit bootstrap error (`loadRequired`) and recording error state in readiness payload.
- accepted: support `TOASTTY_FIXTURE` environment fallback and `--disable-animations` argument parsing.
- accepted: ensure automation readiness artifacts always have a directory fallback when `--artifacts-dir` is omitted.
- accepted: make run-id artifact file naming less collision-prone via percent-encoding.
- rejected: renaming/splitting fixture UUID patterns; deterministic fixtures already use globally unique IDs and current shape is sufficient.
- rejected: broad state-title uniqueness across non-window-linked workspaces; invariant contract keeps `window.workspaceIDs` as source of truth.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 16 passing tests.

Chunk C (phase 1 state-layer panel mobility foundation):
- added reducer actions for panel mobility:
  - `reorderPanel`
  - `movePanelToPane`
  - `movePanelToWorkspace`
  - `detachPanelToNewWindow`
- extended pane-tree mutation primitives with:
  - indexed insert into pane tabs
  - in-pane reorder
  - panel removal with automatic empty-leaf collapse
- implemented workspace/window lifecycle updates during panel moves:
  - remove empty source workspace when its last panel moves out
  - remove empty source window when its last workspace is removed
- strengthened invariant validation with `workspaceWithoutWindow` guard.
- validation passed: `./scripts/automation/check.sh` with expanded reducer/invariant coverage (21 passing tests).

Chunk C review reconciliation (post-commit second opinion on `77b18df`):
- accepted: avoid panel-loss risk in cross-workspace moves by completing both source/target mutations in local copies before writing state.
- accepted: correct tab selection index updates for non-selecting insert operations.
- accepted: correct tab selection index updates when removing a tab before the selected tab.
- accepted: switch workspace-removal lookup from cached `windowIndex` to `windowID` lookup at mutation time to avoid stale-index hazards.
- accepted: explicit failure when caller supplies an unknown target pane for cross-workspace moves.
- rejected: changing detach-to-window focus behavior; current UX intentionally focuses newly detached window.
- rejected: dynamic detached-window frame cascade for now; fixed frame remains acceptable in current scaffold stage.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 24 passing tests.

Chunk D (phase 1 top-bar panel toggles + aux panel state behavior):
- added `toggleAuxPanel` reducer action and wired top-bar toggle controls for Diff and Markdown.
- implemented per-workspace aux panel visibility updates and single-instance enforcement per aux panel kind.
- implemented right-column placement behavior:
  - single-leaf workspace -> create horizontal split and place aux panel in right leaf
  - existing split layout -> insert aux panel into right-column pane heuristic
- added aux panel close-on-toggle-off behavior with pane-tree collapse handling.
- added reducer/tree regression tests for aux toggle creation, placement, and removal.
- validation passed: `./scripts/automation/check.sh` with 27 passing tests.

Chunk D review reconciliation (post-commit second opinion on `757ff30`):
- accepted: adjust right-column heuristic in nested vertical splits to prefer top-right pane insertion.
- accepted: add regression coverage for right-column vertical split behavior and repeated on/off toggling of the same aux panel kind.
- rejected: workspace-leak concern on toggle-off empty-tree branch; `removeWorkspace` removes the workspace entry from `workspacesByID` directly in that path.
- rejected: visibility desync concern in empty-tree branch for same reason (workspace removal, not persistence).
- rejected: changing detach/new-window focus behavior in this chunk; still intentional for current UX.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 29 passing tests.

Chunk E (phase 1 close/reopen panel behavior):
- added reducer actions:
  - `closePanel`
  - `reopenLastClosedPanel`
- implemented bounded per-workspace closed-panel stack (`max 10`) population on close.
- implemented reopen behavior:
  - restore panel state into original pane when still present
  - fallback to focused/first pane when original pane no longer exists
  - restore aux visibility for reopened aux panels
- integrated close behavior with existing lifecycle collapse rules (empty leaf/workspace/window handling).
- added regression tests for close/reopen roundtrip, aux visibility restore, and missing-pane fallback reinsertion.
- validation passed: `./scripts/automation/check.sh` with 32 passing tests.

Chunk E review reconciliation (post-commit second opinion on `c917d07`):
- accepted: prevent duplicate aux-panel reopen by focusing existing same-kind aux panel instead of creating a duplicate.
- accepted: refactor reopen flow to "peek then commit" semantics for `recentlyClosedPanels` to keep history mutation explicit and success-driven.
- rejected: claimed history-loss on reopen insert failure; state dictionary is not mutated on failed insert path, so history remains unchanged.
- rejected: claimed workspace leak on close empty-tree path; `removeWorkspace` removes the workspace entry from `workspacesByID`.
- rejected: preserving original panel UUID on reopen; reopened panel identity is intentionally new in this state model.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 33 passing tests.

Chunk F (phase 2 session + notification service foundations):
- added typed session domain model:
  - `AgentKind`
  - `SessionRecord`
  - `HunkRef`
- added `SessionRegistry` with lifecycle/update operations:
  - start/replace active session per panel
  - file attribution updates with deduplicated touched-file accumulation
  - location updates (`windowID`/`workspaceID`) for moved panels
  - stop by session or panel
  - stopped-session pruning by cutoff timestamp
- added notification domain/store:
  - `ToasttyNotification`
  - `NotificationStore`
  - per-panel unread deduplication
  - suppression when app is focused and source panel visible
  - mark-read and unread count helpers
- added dedicated unit tests for session lifecycle and notification dedup/suppression behavior.
- validation passed: `./scripts/automation/check.sh` with 39 passing tests.

Chunk F review reconciliation (post-commit second opinion on `58f0f2e`):
- accepted: guard `updateFiles` to ignore stopped sessions.
- accepted: harden duplicate `sessionID` handling by clearing stale active-panel mapping before rebinding session ownership.
- accepted: add explicit panel-scoped mark-read test coverage in `NotificationStoreTests`.
- rejected: system-notification decision logic change (`!appIsFocused` only); current behavior intentionally follows spec ("notify when app is unfocused OR source panel is not visible").
- rejected: panel/workspace-scoped dedup change in notification store; panel IDs are treated as globally unique in this state model.
- rejected: prune-session active-map corruption concern; current two-pass prune preserves active sessions and removes only stopped records older than cutoff.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 42 passing tests.

Chunk G (phase 3 diff-service foundation):
- added `GitDiffService` core utility with typed outputs:
  - `DiffComputationResult`
  - `FileDiff`
  - `GitDiffError`
- implemented file normalization and repo partitioning:
  - in-repo file diff computation
  - explicit outside-repo file classification
- implemented staged/unstaged git diff support with:
  - per-file numstat parsing (additions/deletions)
  - per-file unified diff capture
- added integration-style tests using temporary git repositories for:
  - unstaged tracked-file diffs
  - staged diffs
  - outside-repo separation behavior
- validation passed: `./scripts/automation/check.sh` with 45 passing tests.

Chunk G review reconciliation (post-commit second opinion on `243c37f`):
- accepted: add explicit binary-file stat representation (`FileDiff.isBinary`) when git numstat reports `-`.
- accepted: replace fragile string slicing with path-component-based relative path derivation.
- accepted: use shared output pipe handling in git process execution and consume output before `waitUntilExit` to reduce IO deadlock risk.
- accepted: move in/out-of-repo dedup checks from O(n^2) array scans to set-backed dedup while preserving order.
- accepted: harden git-diff tests:
  - explicit invalid repo-root error test
  - binary diff behavior test
  - temporary repository/file cleanup
  - non-optional UTF-8 write helper
- rejected: single-command diff parsing rewrite for this chunk; retained per-file unified diff calls for simpler correctness-first implementation.
- rejected: notification to alter outside-repo test expectation; current service intentionally returns one in-repo entry per requested in-repo file even if diff body is empty.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 47 passing tests.

Chunk H (phase 0 step 1 prerequisite unblocking: Ghostty build tooling, commit `0a162b8`):
- installed `zig` (`0.15.2`) and validated local availability.
- cloned Ghostty source for spike execution under `/tmp/toastty-ghostty-spike/ghostty`.
- confirmed build options and executed native xcframework build command:
  - `zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native`
- executed universal xcframework build command:
  - `zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal`
- confirmed `GhosttyKit.xcframework` artifact generation:
  - `/tmp/toastty-ghostty-spike/ghostty/macos/GhosttyKit.xcframework`
  - note: universal build writes to the same path as native build and overwrites prior output.
- confirmed macOS universal slice output in xcframework (`macos-arm64_x86_64`).
- spike artifact caveat: output currently lives in `/tmp` and must be copied to managed cache/path to persist.
- documented concrete artifact metadata and remaining integration steps in `docs/ghostty-integration.md`.
- recorded libtool duplicate-object warning as unresolved integration risk (warning reproduced in both native and universal builds).

Chunk I (phase 2/3 event coalescing foundation):
- added `SessionUpdateCoalescer` with explicit 500ms-style coalesce window support.
- added typed event payloads:
  - `SessionFileUpdate`
  - `CoalescedSessionUpdate`
- implemented per-session merge behavior:
  - file deduplication while preserving arrival order
  - latest non-nil `cwd`/`repoRoot` wins
  - first/last event timestamps preserved
- implemented flush APIs:
  - `flushReady(at:)` for window-based emission
  - `flushAll()` for deterministic drain
- added deterministic unit tests for merge behavior, per-session independence, and drain semantics.
- validation passed: `./scripts/automation/check.sh` with 50 passing tests.

Chunk I review reconciliation (post-commit second opinion on `e0cdb96`):
- accepted: deduplicate files on first ingest to avoid duplicate seed entries.
- accepted: tighten merge dedup performance using set-backed tracking while preserving first-seen order.
- accepted: deterministic tie-break sorting for equal timestamps (`sessionID` secondary sort key) in `flushReady` and `flushAll`.
- accepted: explicit boundary/duplicate regression tests (`exact-window flush` and `duplicate first ingest`).
- rejected: nil-clearing semantics change for `cwd`/`repoRoot`; current behavior intentionally treats nil as \"no update\" and preserves prior non-nil context.
- rejected: sendable/thread-safety concern as code defect; coalescer remains value-type state intended for serialized ownership by caller.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 52 passing tests.

Chunk J (aux panel layout: one aux panel per pane):
- changed aux panel insertion behavior:
  - first aux toggle from single-leaf workspace still creates a right column (`horizontal` split).
  - additional aux toggles now split the right column pane (`vertical` split) instead of appending tabs to the same pane.
- adjusted right-column target resolution for nested vertical splits so additional aux panes append toward the bottom of the right column.
- expanded reducer coverage:
  - verify aux panel added from existing split creates a new pane (not a tab in prior right pane).
  - verify diff + markdown toggles result in separate pane hosts.
- updated pane-node behavior test to match bottom-pane preference in nested right-column vertical splits.
- validation passed: `./scripts/automation/check.sh` with 53 passing tests.

Chunk J review reconciliation (post-commit second opinion on `e6a6ffa`):
- accepted: avoid reconstructing right-column leaf nodes from `PaneLeafInfo`; use direct pane-tree node lookup (`leafNode(paneID:)`) before replacement.
- accepted: add explicit regression coverage for multi-aux close behavior (closing one aux panel collapses only its pane and preserves remaining aux pane state).
- accepted: simplify nested right-column split ratio from `0.55` to `0.5` to reduce compounding size bias during repeated aux-pane splits.
- rejected: unbounded re-toggle pane growth concern; existing early-return branch removes an already-open aux panel before any split insertion path.
- rejected: focus-steal suggestion for new aux pane; current UX intentionally preserves focused terminal panel on aux toggles.
- rejected: pane-ID tracking concern; pane identity is represented solely by `PaneNode` structure in current model.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 54 passing tests.

Chunk K (aux-column heuristic simplification for mixed terminal layouts):
- revised aux-toggle insertion policy to remove terminal-mixing ambiguity:
  - first aux panel now always creates a dedicated right aux column by wrapping the existing workspace pane tree in a horizontal split.
  - subsequent aux panels always split within the existing aux column subtree (vertical stacking), never into terminal-only panes.
- added reducer helpers:
  - `auxPanelIDs(in:)` to derive currently active aux panel identities.
  - `resolveAuxColumnPaneID(in:auxPanelIDs:)` to target the existing aux subtree deterministically.
- design decision:
- keep behavior intentionally simple for now: aux panels are anchored to a dedicated right column until explicit user panel move preferences are implemented.
- added regression coverage for a complex terminal-only layout (multiple terminal splits) to ensure diff/markdown panes do not share leaves with terminal panels.
- validation passed: `./scripts/automation/check.sh` with 55 passing tests.

Chunk K review reconciliation (post-commit second opinion on `55542de`):
- accepted: make aux-pane targeting deterministic for 3+ aux panels by selecting the last aux-containing leaf in traversal order (`resolveAuxColumnPaneID` now uses `last(where:)` over aux-host leaves).
- accepted: strengthen aux-type selection to explicit auxiliary kinds (`.diff`, `.markdown`, `.scratchpad`) rather than broad non-terminal negation.
- accepted: add stronger structural assertions in complex-layout test to verify aux panels reside in the root right subtree and stay disjoint from terminal subtree panel IDs.
- accepted: add third-aux regression coverage (`.scratchpad`) to validate continued vertical stacking within the dedicated aux column.
- rejected: concern that first aux wrap fails to discover aux leaf on second toggle; current tree mutation + aux panel ID scan makes that path deterministic.
- rejected: replace-leaf leak claim; failed replacement path reverts panel dictionary mutation and does not insert transient split nodes into `paneTree`.
- follow-up validation passed after fixes: `./scripts/automation/check.sh` with 56 passing tests.

Plan adjustment note:
- added feature planning for focused panel mode (maximize/restore current panel, `⌘⇧F`, top-bar toggle) in section 6.9 and scheduled it in phase 4.

Chunk L (automation socket baseline for real running-app interaction):
- added in-app unix socket automation server (`Sources/App/Automation/AutomationSocketServer.swift`) with newline-delimited JSON request/response handling.
- wired automation server startup in app bootstrap path when automation mode is enabled:
  - `ToasttyApp` now starts socket server using parsed `AutomationConfig`.
  - startup failures are surfaced in automation readiness payload/error channel.
- expanded automation config and readiness metadata:
  - `AutomationConfig` now resolves/stores `socketPath` (arg/env/default path support).
  - readiness payload now includes `protocolVersion`, `ready` boolean, and `socketPath`.
- implemented minimal command set for automation-driven UI validation:
  - `automation.ping`
  - `automation.reset`
  - `automation.load_fixture`
  - `automation.perform_action` (split/toggle/new-workspace action IDs)
  - `automation.dump_state` (sorted JSON + SHA256 hash)
  - `automation.capture_screenshot` (window capture to PNG)
- added smoke driver script:
  - `scripts/automation/smoke-ui.sh` builds + launches app in automation mode, dispatches socket commands, captures screenshot/state artifacts, and prints output paths.
- validation infrastructure update:
  - `scripts/automation/check.sh` now runs `xcodebuild test` directly because `tuist test` intermittently returned false-success "There are no tests to run".
- expanded automation unit coverage for socket path parsing in `AutomationTests`.
- validation passed:
  - `./scripts/automation/check.sh` (xcodebuild-backed, 57 tests passing)
  - `./scripts/automation/smoke-ui.sh` (verified live socket actions + screenshot/state artifact generation against running app)

Technical note:
- the implemented socket surface is intentionally automation-focused (request commands only); adapter event ingestion via socket remains pending.

Chunk L review reconciliation (post-commit second opinion on `ba0883a`):
- accepted: cap socket client buffer size at protocol-aligned 256 KiB to prevent unbounded growth when newline framing is missing/malformed.
- accepted: remove `rg` dependency from smoke script response checks (`grep -E` now used for baseline macOS compatibility).
- accepted: tighten screenshot capture to only visible app windows (drop key-window fallback that could capture hidden/non-visible content).
- accepted: remove arm64-only assumption in scripts by detecting host architecture (`arm64`/`x86_64`) for `xcodebuild` destinations in both check and smoke scripts.
- rejected: FD double-close/UAF claim; `AutomationSocketClient.close()` is idempotent and dispatch source cancel handler runs once per client lifecycle.
- rejected: `@unchecked Sendable` race claim on command executor state; mutable command state is only read/written inside `@MainActor` command execution path.
- rejected: shared queue write-path contention as a v1 blocker; current automation protocol uses small single-response messages and single-client smoke flow.
- follow-up validation passed after fixes:
  - `./scripts/automation/check.sh` (57 tests passing)
  - `./scripts/automation/smoke-ui.sh` (socket actions + screenshot/state artifact generation verified).

Chunk M (Ghostty runtime wiring baseline with optional framework linkage):
- added optional `GhosttyKit.xcframework` integration in Tuist manifest:
  - if `Dependencies/GhosttyKit.xcframework` exists at generate-time, app target links it and compiles with `TOASTTY_HAS_GHOSTTY_KIT`.
  - if not present, app compiles/runs with fallback terminal host behavior.
- added terminal runtime infrastructure under `Sources/App/Terminal/`:
  - `TerminalRuntimeRegistry` for stable panel-id -> runtime controller ownership across pane/workspace mutations.
  - `TerminalPanelHostView` (`NSViewRepresentable`) to attach/reparent persistent native terminal hosts as panel layout changes.
  - `TerminalSurfaceController` with focus + viewport updates and per-panel lifecycle cleanup.
  - `GhosttyRuntimeManager` (compiled only when GhosttyKit is linked) that performs:
    - `ghostty_init`
    - app/config creation
    - surface creation against host NSView
    - wakeup-driven `ghostty_app_tick`
- replaced terminal text-only row rendering in `WorkspaceView` with native panel host embedding path for terminal panels, while keeping aux panels as placeholders.
- added local framework bootstrap script:
  - `scripts/ghostty/install-local-xcframework.sh` (copies GhosttyKit from local spike output into `Dependencies/`).
- updated ignore policy:
  - `.gitignore` now ignores `/Dependencies/GhosttyKit.xcframework/` (binary local dependency).
- validation passed:
  - `./scripts/automation/check.sh` with no local xcframework present (fallback build path).
  - `./scripts/automation/smoke-ui.sh` with no local xcframework present.
  - `./scripts/ghostty/install-local-xcframework.sh` then `./scripts/automation/check.sh` (Ghostty-enabled compile path).
  - `./scripts/automation/smoke-ui.sh` with Ghostty-enabled compile path.

Chunk M review reconciliation (post-commit second opinion on `68018c5`):
- accepted: remove deinit-based Ghostty surface teardown and switch to explicit `invalidate()` cleanup from `TerminalRuntimeRegistry.synchronize` (main-actor deterministic teardown).
- accepted: when Ghostty surface creation fails, hide host view and show fallback status view explicitly.
- accepted: switch scale-factor fallback from `2` to `1` when no window/screen scale can be resolved.
- accepted: remove always-on 60Hz Ghostty tick loop and rely on wakeup-triggered ticks with immediate tick after app/surface creation.
- accepted: emit stderr diagnostics when Ghostty runtime bootstrap or app creation fails.
- rejected: `withCString` lifetime concern for `working_directory`/`initial_input`; Ghostty's own Swift embedding layer uses the same immediate-call pattern for `ghostty_surface_new`, and local source inspection shows consumption during init path.
- rejected: dead-code claim for `shortID`; it is still used in pane header labels.
- rejected: retain-cycle claim in `TerminalPanelHostView.onLayout`; `superview` references are non-owning and stale controllers are explicitly invalidated/evicted by registry synchronization.
- follow-up validation passed after fixes:
  - `./scripts/automation/check.sh` (Ghostty-enabled compile path)
  - `./scripts/automation/smoke-ui.sh` (Ghostty-enabled runtime smoke path)

Chunk N (socket protocol event ingestion + session/notification runtime wiring):
- extended socket envelope parsing to support both:
  - request envelopes (`kind: "request"`) for `automation.*`
  - event envelopes (`kind: "event"`) for protocol events (`session.*`, `notification.emit`)
- added event handling in `AutomationCommandExecutor` for:
  - `session.start`
  - `session.update_files`
  - `session.needs_input`
  - `session.progress`
  - `session.error`
  - `session.stop`
  - `notification.emit`
- wired live runtime services into the command executor:
  - `SessionRegistry`
  - `SessionUpdateCoalescer` (flush on ready/stop/dump)
  - `NotificationStore`
  - transient progress/error maps
- added runtime-aware automation state dumps:
  - `automation.dump_state` now supports `{"includeRuntime": true}` and writes app state + session/notification runtime metadata.
- extracted event file normalization into shared Core utility:
  - `SocketEventNormalizer` with typed error (`missingCWDForRelativePath`).
- added targeted unit coverage:
  - `SocketEventNormalizerTests` (absolute path normalization, relative path resolution, missing-cwd failure).
- validation passed:
  - `./scripts/automation/check.sh` (60 tests passing).
  - `./scripts/automation/smoke-ui.sh`.
  - manual live running-app event smoke:
    - sent `session.start`/`session.update_files`/`session.needs_input` over unix socket.
    - verified runtime dump output contains emitted session + normalized touched files.

Chunk N review reconciliation (post-commit second opinion on `85c2b9b`):
- accepted: make `AutomationCommandExecutor.execute(envelope:)` explicitly `@MainActor` to align actor isolation with request/event handlers.
- accepted: replace static `"event"` response request-id fallback with per-response UUID fallback for uncorrelated event envelopes.
- accepted: remove machine-specific absolute path from `SocketEventNormalizerTests` (use generic `/tmp/...` fixture path).
- rejected: coalescer pre-flush concern on `session.update_files`; current `flushReady` contract is window-based (`>= window`) so same-timestamp bursts do not flush immediately.
- rejected: `session.needs_input` should store `sessionID` in notification entries; V1 notification model is intentionally panel/workspace-scoped and currently has no session-id field.
- rejected: `isPanelVisible` semantic strictness as blocker; current suppression behavior intentionally treats selected-workspace presence as visible for v1.
- rejected: per-event date formatter allocation as correctness issue; current implementation prioritizes Swift concurrency safety and keeps overhead acceptable for current local event volumes.
- follow-up validation passed after fixes:
  - `./scripts/automation/check.sh` (60 tests passing)
  - `./scripts/automation/smoke-ui.sh`
  - manual live event smoke re-run (`session.start`, `session.update_files`, `session.needs_input`, `automation.dump_state includeRuntime`)

Chunk O (manual-run feedback: Ghostty fallback messaging + safer enablement gate):
- validated user-reported manual-run behavior where terminal panel displayed fallback messaging.
- found `GhosttyKit` presence alone is not sufficient for stable linkage in current state (linker dependencies unresolved for direct app link path).
- adjusted project enablement policy:
  - Ghostty compile/link path is now explicit opt-in at manifest generation time (see chunk R for Tuist env nuance).
  - default local builds stay on stable fallback path to avoid accidental linker breakage when a local xcframework artifact exists.
- updated fallback UX text from hard error-style phrasing:
  - `GhosttyKit not linked`
  - to:
  - `Ghostty terminal runtime not enabled in this build`
- validation passed:
  - `./scripts/automation/smoke-ui.sh` (fallback path)
  - direct test pass: `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived`

Chunk P (focused panel mode v1: maximize/restore with shortcut + automation coverage):
- added focused panel mode action/state wiring:
  - new reducer action `toggleFocusedPanelMode(workspaceID:)`.
  - workspace state now tracks `focusedPanelModeActive` (per-workspace mode flag).
  - reducer now blocks pane split + aux-panel toggle actions while focused mode is active.
- implementation simplification decision:
  - use non-destructive focused-mode rendering (hide non-focused panes at render-time) rather than mutating `paneTree` into a temporary single-leaf snapshot.
  - this keeps restore semantics lossless and avoids snapshot merge logic for close/reopen mutations.
- updated workspace UI behavior:
  - added top-bar toggle button (`Focus Panel` / `Restore Layout`) with `⌘⇧F`.
  - when focused mode is active, workspace content renders only the focused panel expanded to fill the available workspace area.
  - split + aux top-bar controls are disabled while focused mode is active.
- automation integration:
  - extended automation action surface with `topbar.toggle.focused-panel`.
  - expanded `scripts/automation/smoke-ui.sh` to exercise focused mode roundtrip and capture `focused-panel-smoke.png`.
- added reducer coverage:
  - focused mode roundtrip preserves layout/focus.
  - stale-focused-panel recovery on focused-mode entry.
  - split/aux actions are blocked in focused mode.
  - close panel behavior continues to operate while focused mode remains active.
- validation passed:
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived` (64 tests passing)
  - `./scripts/automation/smoke-ui.sh` (focused mode screenshot + restore screenshot generated)

Chunk P review reconciliation (post-commit second opinion on `ea2f83e`):
- accepted: remove duplicated focused-panel fallback resolution in `WorkspaceView` and rely on reducer-managed `focusedPanelID` when focused mode is active.
- accepted: make `focusedPanelModeActive` runtime-transient across codable boundaries by excluding it from `WorkspaceState` encode/decode and defaulting it to `false` on decode.
- accepted: add codable regression coverage to verify focused mode does not persist through `AppState` encode/decode.
- rejected: toggle-off focus clobber concern in `toggleFocusedPanelMode`; current implementation re-resolves to a valid current focused panel, and assignment does not regress focus after in-mode close operations.
- rejected: close-last-panel focused-mode stuck state concern; closing the last panel removes the workspace/window via existing lifecycle cascade so no empty focused-mode workspace persists.
- rejected: shortcut conflict concern as a blocker; no conflicting `⌘⇧F` binding exists in current app command surface.
- rejected: empty-workspace toggle error-path concern; workspace invariants/lifecycle prevent persistent empty workspaces in current model.
- follow-up validation passed after fixes:
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived` (64 tests passing)
  - `./scripts/automation/smoke-ui.sh`

Chunk Q (global terminal font controls + transient HUD):
- added global terminal font reducer actions:
  - `increaseGlobalTerminalFont`
  - `decreaseGlobalTerminalFont`
  - `resetGlobalTerminalFont`
- implemented bounded global font behavior in reducer:
  - min: `9`
  - max: `24`
  - step: `1`
  - reset default: `13`
- wired app-level keyboard commands:
  - `⌘=` increase terminal font
  - `⌘-` decrease terminal font
  - `⌘0` reset terminal font
- added transient font HUD in app shell:
  - displays `Terminal Font <size>` near top center on font changes.
  - auto-hides after ~1.2s.
- extended automation action support:
  - `app.font.increase`
  - `app.font.decrease`
  - `app.font.reset`
- expanded smoke automation flow:
  - exercises font increase/reset.
  - captures `font-hud-smoke.png` artifact.
- added reducer tests:
  - font increase/decrease/reset behavior.
  - bound-clamp behavior at min/max and reset no-op behavior.
- validation passed:
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived` (67 tests passing)
  - `./scripts/automation/smoke-ui.sh` (font HUD + focused panel + aux-column smoke artifacts)

Chunk Q review reconciliation (post-commit second opinion on `6d7a466`):
- accepted: simplify HUD hide-task lifecycle by running the delayed clear task on `@MainActor` and removing redundant actor hops.
- accepted: avoid system-menu ambiguity by moving font commands into a dedicated `Terminal` command menu.
- accepted: centralize terminal font constants on `AppState` and reuse them from reducer/bootstrap to avoid default-value drift.
- accepted: update font reducer tests to assert against shared constants and verify reset no-op leaves state unchanged.
- rejected: strict requirement to add sleep before font HUD screenshot; current smoke flow reliably captures HUD after synchronous action dispatch in repeated runs.
- rejected: startup HUD flash as a current blocker; observed behavior in local smoke/manual checks does not show initial-load HUD without user/action-triggered font changes.
- rejected: fractional-display precision concern for HUD label; current v1 font step is integral and display intentionally shows integer points.
- follow-up validation passed after fixes:
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived` (67 tests passing)
  - `./scripts/automation/smoke-ui.sh`

Chunk R (Ghostty manifest env-gate diagnostics + enablement fix):
- investigated user report: running `TOASTTY_ENABLE_GHOSTTY=1 tuist generate` still produced fallback runtime (`TOASTTY_HAS_GHOSTTY_KIT` absent in generated build settings).
- root cause:
  - Tuist manifest evaluation does not expose arbitrary shell env vars like `TOASTTY_ENABLE_GHOSTTY` to `Project.swift` (`ProcessInfo` saw it as `nil`).
- implementation update:
  - `Project.swift` now accepts either:
    - `TUIST_ENABLE_GHOSTTY=1` (manifest-visible, recommended)
    - `TOASTTY_ENABLE_GHOSTTY=1` (kept as compatibility alias for non-Tuist contexts)
  - explicit file-existence gating was removed from manifest path resolution to avoid false negatives from Tuist manifest execution context.
- validation:
  - default `tuist generate` -> no Ghostty linkage (`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`).
  - `TUIST_ENABLE_GHOSTTY=1 tuist generate` -> Ghostty linkage emitted:
    - `GhosttyKit.xcframework` appears in generated project.
    - `TOASTTY_HAS_GHOSTTY_KIT` appears in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
  - `xcodebuild` with Ghostty enabled still fails link with unresolved symbols from `libghostty.a` (`___cxa_*`, `___gxx_personality_v0`, `kTISProperty*`), confirming fallback mode is still expected for stable local runs.
- documentation update:
  - `docs/ghostty-integration.md` now includes manifest env behavior and verification steps.

Chunk R review reconciliation (post-commit second opinion on `e337620`):
- accepted: restore explicit xcframework presence gating so Ghostty opt-in does not force missing-path project breakage.
  - `Project.swift` now enables Ghostty only when:
    - env gate is enabled (`TUIST_ENABLE_GHOSTTY=1` or compatibility `TOASTTY_ENABLE_GHOSTTY=1`)
    - and xcframework exists in one of the manifest/cwd candidate roots.
- accepted: clarify env alias behavior in code comment (Tuist-reliable `TUIST_*`, `TOASTTY_*` best-effort compatibility only).
- rejected: docs target naming concern; `ToasttyApp` is the actual app target name in current manifests/project.
- follow-up validation passed after fixes:
  - default path: `tuist generate` + `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived` (`67` tests passing)
  - Ghostty-enabled path check: `TUIST_ENABLE_GHOSTTY=1 tuist generate` emits `TOASTTY_HAS_GHOSTTY_KIT`; build still fails at known unresolved `libghostty.a` link symbols (`___cxa_*`, `___gxx_personality_v0`, `kTISProperty*`).

Chunk S (Ghostty link dependency resolution for app target):
- investigated unresolved symbol failures from Ghostty-enabled app links (`___cxa_*`, `___gxx_personality_v0`, `kTISProperty*`).
- root cause: Ghostty static archive requires transitive link dependencies not declared automatically in current app target link settings.
- implementation update (`Project.swift`):
  - when Ghostty integration is enabled, app target now adds:
    - `OTHER_LDFLAGS = ["$(inherited)", "-lc++", "-framework", "Carbon"]`
  - retained existing env and xcframework presence gating logic.
- validation:
  - default path: `tuist generate` + `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived` (`67` tests passing).
  - Ghostty-enabled path:
    - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
    - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived build`
    - build succeeds without ad-hoc command-line linker overrides.

Chunk S review reconciliation (post-implementation second opinion):
- accepted: express Ghostty linker flags as explicit array tokens (instead of a space-delimited scalar) to ensure stable `$(inherited)` expansion semantics in generated project settings.
  - `Project.swift` now sets:
    - `OTHER_LDFLAGS = ["$(inherited)", "-lc++", "-framework", "Carbon"]`
- accepted: add explicit Release-path validation for Ghostty-enabled links.
  - validated:
    - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
    - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived build`
    - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Release -destination \"platform=macOS,arch=arm64\" -derivedDataPath Derived build`
    - all passed.
- accepted (follow-up validation expansion): run Ghostty-enabled UI smoke for runtime confirmation.
  - result: fails before automation readiness (`error: readiness file not found ...`).
  - observed app log (`artifacts/automation/app-smoke-20260227-114016.log`) shows Ghostty-side crash capture via Sentry/breakpad; runtime stability remains unresolved even though link/build now pass.
- rejected: add dedicated manifest-setting unit tests in this chunk.
  - reason: current test harness does not execute Tuist manifest evaluation; adding a new manifest-test harness is out of scope for this targeted linker fix.
- rejected: classify `-framework Carbon` use as immediate blocker.
  - reason: current unresolved symbol set is directly tied to Text Input Source APIs exported through Carbon on macOS; this is a known explicit dependency rather than accidental usage.

Deferred work / known gaps:
- Ghostty integration is currently local/optional (depends on unmanaged `Dependencies/GhosttyKit.xcframework` install); repo-level artifact strategy and CI policy are still unresolved.
- Ghostty framework architecture/output policy (`arm64` vs `universal`) is still not finalized.
- Ghostty runtime callbacks are minimal no-op handlers; richer host integration for clipboard/actions/notifications/title updates is still pending.
- terminal input/focus UX parity with native Ghostty app behavior is not yet validated end-to-end.
- adapter/wrapper process integration is still pending (local socket now accepts protocol events, but claude/codex wrappers are not yet connected).
- session/notification runtime state is not yet surfaced in app UI (sidebar dots, badges, system notifications still pending UI wiring).

Chunk T (Ghostty startup crash on renderer thread callback isolation):
- investigated user-reported startup crash (`EXC_BREAKPOINT` in `libdispatch._dispatch_assert_queue_fail`) when launching Ghostty-enabled runtime.
- LLDB backtrace root cause:
  - `wakeup_cb` callback frame landed in `GhosttyRuntimeManager.init` callback closure.
  - Swift concurrency isolation check (`_swift_task_checkIsolatedSwift`) asserted on Ghostty renderer thread before callback body ran.
  - callback closures were constructed inside `@MainActor` initializer, making them actor-isolated even though Ghostty invokes them from non-main threads.
- implementation update (`Sources/App/Terminal/GhosttyRuntimeManager.swift`):
  - extracted runtime callback configuration into file-scope helper `makeGhosttyRuntimeConfig(...)` so callback closures are created in nonisolated context.
  - kept renderer-thread-safe wakeup bridge in file-scope `ghosttyWakeupCallback(...)`, explicitly dispatching tick scheduling to main queue.
  - preserved manager lifetime behavior (singleton `shared`) and existing tick scheduling semantics.
- validation:
  - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
  - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
    - passed with readiness file, automation ping/action responses, and screenshot/state artifacts generated.
    - no startup crash in app log for that run.
- design decision:
  - kept `GhosttyRuntimeManager` as `@MainActor` for UI-facing lifecycle safety, but ensured C callback entrypoints are nonisolated at definition site.
  - explicit guardrail: moving callbacks to file scope removes actor metadata from callback entrypoints, but callback bodies must still dispatch to main actor/queue before touching `GhosttyRuntimeManager` state.
- follow-up testing gap:
  - callback threading model is now safe for current callback set, but richer callbacks (clipboard/action handling) should be added with explicit thread-handoff rules as they are implemented.

Chunk U (Ghostty panel interactivity + spurious UUID input cleanup):
- investigated user report after crash fix:
  - terminal rendered output but was not keyboard-interactive.
  - shell prompt contained a raw UUID token (panel identifier) at startup.
- root causes:
  - `GhosttyRuntimeManager.makeSurface(...)` was writing `panelID.uuidString` into `surfaceConfig.initial_input`, which Ghostty correctly injected into the shell as typed input.
  - panel focus state was updated in SwiftUI, but AppKit first-responder handoff for the embedded terminal host view was not enforced when focus changed.
- implementation update:
  - removed `surfaceConfig.initial_input` assignment (and related panel ID conversion) from Ghostty surface creation so startup input is no longer polluted.
  - on Ghostty surface updates, when a panel is focused, explicitly call `window.makeFirstResponder(hostedView)` when needed.
  - removed now-unused `panelID` parameter from `GhosttyRuntimeManager.makeSurface(...)` and updated call sites.
- validation:
  - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
  - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination "platform=macOS,arch=arm64" -derivedDataPath Derived` (`67` tests passing)
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass; runtime stable + screenshots/state artifacts)
  - inspected smoke artifact `artifacts/automation/ui/smoke-20260227-122455/split-workspace/aux-column-smoke.png`: terminal prompt no longer contains injected UUID token.

Chunk V (explicit AppKit key-event bridge into Ghostty surface):
- deeper follow-up on terminal interactivity:
  - responder handoff alone was not sufficient as a robust input path because host view had no explicit key event bridge into Ghostty's C input APIs.
- implementation update (`Sources/App/Terminal/TerminalRuntimeRegistry.swift`):
  - `TerminalHostView` now stores the active `ghostty_surface_t` and explicitly forwards `keyDown`/`keyUp` events through `ghostty_surface_key(...)`.
  - wired per-event fields:
    - action (`press` / `repeat` / `release`)
    - modifiers (mapped from `NSEvent.ModifierFlags`)
    - consumed modifiers (`ghostty_surface_key_translation_mods(...)`)
    - keycode (`NSEvent.keyCode`)
    - optional text payload for printable UTF-8 input.
  - `TerminalSurfaceController` now updates/clears the host view's bound surface handle as surfaces are created, updated, or invalidated.
- validation:
  - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
  - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination "platform=macOS,arch=arm64" -derivedDataPath Derived` (`67` tests passing)
  - manual app exercise via scripted keystroke:
    - launched built app binary, sent `echo bridged_input_check` + return through System Events, captured `/tmp/toastty-manual-input3.png`.
    - screenshot confirms command + output rendered in terminal panel (interactive input path functioning).

Chunk V review reconciliation (post-implementation second opinion):
- accepted: tighten first-responder handoff guard by requiring `window.isKeyWindow` before calling `makeFirstResponder(...)`.
- accepted: align key event payload shaping with Ghostty's own macOS approach:
  - derive `unshifted_codepoint` via `characters(byApplyingModifiers: [])` rather than `charactersIgnoringModifiers`.
  - add dedicated text payload filtering helper to avoid sending private-use function-key scalars and to normalize control-character handling.
- rejected: consumed-modifier argument mismatch claim for `ghostty_surface_key_translation_mods(...)`.
  - reason: API signature expects `ghostty_input_mods_e`; passing mapped Ghostty modifier bits is correct for this helper.
- rejected: keycode translation claim.
  - reason: `ghostty_input_key_s.keycode` is a raw `uint32_t` keycode slot in the embedding API; passing `NSEvent.keyCode` is the intended path used by Ghostty's own AppKit bridge.
- rejected: threading race claim around `setGhosttySurface`/free path.
  - reason: `TerminalRuntimeRegistry` and `TerminalSurfaceController` are `@MainActor`, and `TerminalHostView` key event handling is AppKit main-thread-only.
- follow-up validation after accepted fixes:
  - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
  - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass)
  - `xcodebuild test -workspace toastty.xcworkspace -scheme toastty-Workspace -destination "platform=macOS,arch=arm64" -derivedDataPath Derived` (`67` tests passing)
  - manual scripted input check repeated: `/tmp/toastty-manual-input4.png` confirms command text + output roundtrip in terminal.

Chunk W (Ghostty viewport sizing fix for terminal scroll behavior):
- investigated user-reported behavior where large command output (`ls -l`) did not visibly scroll and prompt recovery looked broken.
- root cause:
  - `TerminalSurfaceController.updateSurfaceSizing(...)` multiplied logical viewport dimensions by backing scale before calling `ghostty_surface_set_size(...)`.
  - Ghostty embed API expects logical dimensions there, with DPI scaling passed separately via `ghostty_surface_set_content_scale(...)`.
  - this effectively double-scaled the surface size on Retina, causing terminal grid/viewport mismatch.
- implementation update (`Sources/App/Terminal/TerminalRuntimeRegistry.swift`):
  - keep `ghostty_surface_set_content_scale(...)` behavior unchanged.
  - pass logical `viewportSize.width/height` directly to `ghostty_surface_set_size(...)`.
  - added inline comment clarifying Ghostty embed API contract to prevent regressions.
- validation:
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass).
  - `./scripts/automation/check.sh` (pass; 67 tests).
  - live app validation (non-automation app run):
    - `TUIST_ENABLE_GHOSTTY=1 tuist generate`
    - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`
    - launched built app, clicked terminal panel, sent `ls -l` + repeated return via System Events, captured screenshot:
      - `artifacts/manual/ghostty-scroll-validation-click-20260227-124214.png`
    - screenshot shows command output scrolled and prompt visible at buffer bottom.

Chunk W review reconciliation (post-commit second opinion on `2f5cbec`, "Fix Ghostty surface sizing to restore terminal scrolling"):
- decision:
  - keep the committed sizing behavior in `Sources/App/Terminal/TerminalRuntimeRegistry.swift` (`TerminalSurfaceController.update(...)`) where `ghostty_surface_set_content_scale(...)` remains enabled and `ghostty_surface_set_size(...)` receives logical viewport dimensions.
- rationale/evidence:
  - cross-checked Ghostty upstream embedding references (`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, `src/apprt/embedded.zig`) and ran local A/B behavior checks in this app host.
  - in this host integration, switching back to framebuffer-style size inputs reproduced the stuck-viewport behavior (end marker/prompt not visible at cursor), while committed logical sizing restored expected scroll/cursor-follow behavior.
- artifact policy clarification:
  - manual evidence screenshots are produced under ignored local artifact paths (`artifacts/manual/...`) and referenced here for reproducibility; they are intentionally not committed.
- deferred follow-up (W-1):
  - add stronger automated coverage for terminal viewport/input behavior.
  - current XCTest suites do not directly exercise Ghostty C-surface geometry or terminal keystroke I/O.
  - candidate implementation: extend automation socket actions with terminal text input primitives and assert viewport progression via deterministic screenshot/state checks.

Chunk X (repo-level agent workflow notes for live app validation):
- introduced and refined `AGENTS.md` at repo root to record project-specific expectations:
  - UI/runtime changes must be validated in a running app instance, not only via reducer/unit tests.
  - standard validation command set for Ghostty flows (`TUIST_ENABLE_GHOSTTY=1 tuist generate`, smoke automation, full `check.sh` gate).
  - manual screenshot artifact workflow under `artifacts/manual/` (at this point in time, `.gitignore` includes `/artifacts/`).
- second-opinion follow-up refinement:
  - clarified architecture selection guidance for `xcodebuild` destination (`ARCH="$(uname -m)"`) and Rosetta caveat.
  - clarified that scripted click coordinates are example values and must be adapted per machine/window layout.

Chunk Y (expanded repo day-to-day workflow notes in AGENTS):
- expanded `AGENTS.md` from focused validation notes into a broader development playbook:
  - Tuist daily loop (where settings live, when to regenerate, deterministic local build invocation).
  - Ghostty configuration model (manifest gate, local dependency requirement, compile-condition/linker behavior).
  - automation nuts and bolts (smoke/check scripts, key env overrides, artifact/readiness/log locations).
  - manual scripting caveats (focus requirements, coordinate dependence, keyboard-layout and clipboard side effects).
  - current project snapshot to reflect what is already working vs. what still needs manual verification.
- rationale:
  - preserve reliable daily commands and local gotchas in one repo-local place so future changes don’t regress through missed setup details.

Chunk Y review reconciliation A (post-commit second opinion on `96be276`):
- accepted:
  - clarified Rosetta wording (`uname -m` will report `x86_64` when shell is translated).
  - clarified Ghostty env behavior by tying it directly to `Project.swift` dual-key check and Tuist manifest reliability of `TUIST_*`.
  - clarified Ghostty-path validation preconditions in smoke/check notes (xcframework must exist for Ghostty-linked coverage).
  - strengthened manual scripting guidance with a single-block AppleScript sequence including explicit delays for ordering.
  - added explicit staleness caveat to the “current snapshot” section date scope.
- accepted with adjustment:
  - `check.sh` scheme note now documents that `toastty-Workspace` is current and script must be updated if naming changes.
- rejected:
  - claim that current plan notes are too duplicative to keep.
  - reason: this plan tracks implementation/documentation decisions and review reconciliations; retaining concise rationale here is intentional for project traceability.

Chunk Y review reconciliation B (post-commit second opinion on `b0efc74`):
- accepted:
  - clarified that Ghostty-related runtime work requires both baseline and Ghostty-path smoke validation.
  - converted multi-line AppleScript example into a copy/paste-safe fenced code block.
  - added explicit caveat that delay values are machine/load dependent.
  - tightened Ghostty env guidance to prefer `TUIST_ENABLE_GHOSTTY=1` for `tuist generate` flows.
  - reduced Rosetta wording from absolute to practical (`typically reports x86_64`).
  - removed uncertainty phrasing around `artifacts/` ignore status.
- rejected:
  - claim that referencing prior reviewed commit (`96be276`) was inconsistent.
  - reason: section A intentionally records reconciliation for that specific earlier commit; section B now records the follow-up review for `b0efc74`.

Chunk Z (W-1 follow-up: automation terminal input + viewport assertion hooks):
- implemented new automation commands in `AutomationSocketServer`:
  - `automation.terminal_send_text`
    - sends text to a resolved terminal panel surface.
    - optional `submit` appends newline submit behavior.
  - `automation.terminal_visible_text`
    - returns visible viewport text for a resolved terminal panel.
    - optional `contains` marker check returns boolean for deterministic polling/assertion.
- panel-targeting behavior:
  - explicit `panelID` targeting is supported.
  - otherwise resolves workspace (`workspaceID` or selected workspace) and targets focused terminal panel with fallback to first terminal in pane-tree order.
- runtime wiring:
  - `AutomationSocketServer` now receives `TerminalRuntimeRegistry` from app bootstrap/wiring.
  - `TerminalRuntimeRegistry` + `TerminalSurfaceController` now expose automation-only helpers:
    - send text to Ghostty surface via `ghostty_surface_text(...)`
    - read viewport text via `ghostty_surface_read_text(...)` with `GHOSTTY_POINT_VIEWPORT` selection.
- smoke automation enhancements (`scripts/automation/smoke-ui.sh`):
  - added Ghostty-conditional terminal viewport validation path when Ghostty gate is requested.
  - sends deterministic long-output command + unique end marker.
  - polls `automation.terminal_visible_text` until marker appears.
  - captures `terminal-viewport-smoke.png` artifact and prints path in script output.
  - baseline (non-Ghostty) smoke path remains unchanged and reports terminal viewport screenshot as skipped.
- validation:
  - `./scripts/automation/check.sh` (pass; 67 tests).
  - `./scripts/automation/smoke-ui.sh` (pass; baseline path, terminal viewport check skipped).
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (pass; terminal viewport marker check + screenshot artifact generated).
  - artifact example:
    - `artifacts/automation/ui/smoke-20260227-132250/split-workspace/terminal-viewport-smoke.png`

Chunk Z review reconciliation (post-commit second opinion on `2094316`):
- accepted:
  - added startup-race handling for `automation.terminal_send_text` surface availability.
  - switched Ghostty automation text-send path to `utf8CString` byte handling to keep byte-count and pointer representation aligned.
  - adjusted visible-text read path so `ghostty_surface_free_text(...)` always runs after successful `ghostty_surface_read_text(...)`, even when payload text pointer is unexpectedly missing.
  - removed hard-coded newline byte length by routing submit behavior through shared text-send helper.
- rejected:
  - actor-isolation race claim on terminal registry access.
  - reason: automation command execution path is `@MainActor`, registry/controller types are `@MainActor`, and surface access remains on main-thread AppKit/SwiftUI context.
  - viewport selection coordinate misuse claim.
  - reason: `GHOSTTY_POINT_VIEWPORT` with `TOP_LEFT`/`BOTTOM_RIGHT` coord enums and zeroed x/y mirrors Ghostty’s own AppKit usage.
  - shell-JSON injection concern in smoke marker command.
  - reason: marker is sanitized to alphanumeric/underscore and command payload does not include user-provided quotes/backslashes in this flow.
- testing gap acknowledged:
  - no direct XCTest coverage added for new automation terminal commands because current test target is `CoreState`-only; command behavior remains covered by smoke automation and artifact checks.
- follow-up validation passed:
  - `./scripts/automation/check.sh` (67 tests).
  - `./scripts/automation/smoke-ui.sh` (baseline path).
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (Ghostty path, terminal marker + viewport screenshot).

Chunk Z review reconciliation B (post-commit second opinion on `cb2779c`):
- accepted:
  - removed main-actor run-loop wait (`waitForSurfaceMs`) from automation command path.
  - replaced with non-blocking retry model:
    - `automation.terminal_send_text` now supports `allowUnavailable`.
    - smoke script retries `terminal_send_text` until `"available": true` before proceeding.
- accepted:
  - removed now-unused surface-readiness helpers tied to the old wait-loop approach.
- rejected:
  - claim that `ghostty_surface_free_text(...)` is unsafe when text pointer is nil.
  - reason: Ghostty text deinit path is null-safe in upstream implementation and API usage mirrors current embed patterns.
- follow-up validation passed:
  - `./scripts/automation/check.sh` (67 tests).
  - `./scripts/automation/smoke-ui.sh` (baseline path).
  - `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (Ghostty path with send-text availability retry + viewport marker assertion).

Chunk Z review reconciliation C (post-commit second opinion on `e5df811`):
- accepted:
  - made deprecated behavior explicit: `automation.terminal_send_text` now rejects legacy `waitForSurfaceMs` payloads with actionable error text instead of silently ignoring them.
  - hardened smoke retry parsing by extracting `available` as a dedicated boolean field (instead of loose grep matching).
  - made terminal surface retry loop tunable via env:
    - `TERMINAL_READY_ATTEMPTS`
    - `TERMINAL_READY_INTERVAL_SEC`
- rejected:
  - duplicate-send race claim during unavailable retries.
  - reason: send path gates on captured non-nil surface handle before any write; unavailable responses perform no write.
