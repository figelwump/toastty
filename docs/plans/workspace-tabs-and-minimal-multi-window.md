# Workspace Tabs And Minimal Multi-Window Plan

## Goal

Add two related capabilities with clear ownership boundaries:

- a user-facing `New Window` flow that creates a second independent Toastty
  window seeded from the active terminal context
- app-owned tabs that live inside each workspace rather than in the native
  macOS window chrome

The target state model becomes:

- `window -> workspace -> tab -> panel layout`

This keeps the sidebar at the window/workspace layer while making tab sets
local to each workspace.

---

## UX Model

Three user actions should mean three distinct things:

- `New Workspace`
  - create another workspace inside the current Toastty window
  - the window sidebar remains the switcher for those workspaces
  - each workspace has its own independent tab set
- `New Window`
  - create a second independent Toastty window
  - the new window starts with one workspace, one tab, and one terminal pane
  - the new pane inherits the active focused terminal's cwd and profile when
    available
  - the new window still shows the normal sidebar
- `New Tab`
  - create a tab inside the currently selected workspace
  - the tab starts with one terminal pane
  - the new pane inherits the active focused terminal's cwd and profile when
    available
  - switching workspaces shows that workspace's own tabs

Important non-goals for the first pass:

- no native macOS window tabs
- no sharing one workspace across multiple windows
- no sharing one tab across multiple workspaces
- no custom tab title override in the first cut

---

## Why This Shape

This matches the intended UX and avoids the mismatch we saw with native window
tabs:

- the sidebar should not duplicate per tab
- tab switching should stay within the selected workspace
- creating a workspace should affect the current window, not only one tabbed
  window clone
- tab UI can sit below the workspace top bar and above panel layout without
  disturbing the window chrome

This does introduce a real new core model layer, but it is the correct one:

- `WorkspaceTabState` owns panel layout
- `WorkspaceState` owns workspace identity and tab selection
- `WindowState` continues owning workspace selection and sidebar visibility

---

## Current State

Relevant existing behavior:

- `AppState` already tracks multiple windows through `windows` and
  `selectedWindowID`
- `AppReducer.createWindow` already creates a new `WindowState` with a single
  bootstrap workspace
- `WorkspaceState` directly owns `layoutTree`, `panels`, `focusedPanelID`,
  `auxPanelVisibility`, `focusedPanelModeActive`, `unreadPanelIDs`, and
  `recentlyClosedPanels`
- `WorkspaceView` renders a single panel layout for each workspace with no tab
  layer
- multi-window state and scene binding already exist internally and now have a
  user-facing seeded `New Window` command in this branch

That means the minimal multi-window slice can stay as-is, and the new work is
focused on carving panel-layout ownership out of `WorkspaceState` into a tab
model.

---

## Recommended State Shape

### Window launch seed

Keep the existing seeded window bootstrap path:

```swift
public struct WindowLaunchSeed: Equatable, Sendable {
    public var workspaceTitle: String?
    public var terminalCWD: String?
    public var terminalProfileBinding: TerminalProfileBinding?
}
```

This continues to power `New Window`.

### Workspace tab state

Introduce a new state object for tab-local panel layout:

```swift
public struct WorkspaceTabState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var layoutTree: LayoutNode
    public var panels: [UUID: PanelState]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>
    public var focusedPanelModeActive: Bool
    public var unreadPanelIDs: Set<UUID>
    public var recentlyClosedPanels: [ClosedPanelRecord]
}
```

Title behavior in the first cut:

- default title follows the most recently active panel title in that tab
- custom override support is deferred

### Workspace state

Refactor `WorkspaceState` into a workspace shell that owns tabs:

```swift
public struct WorkspaceState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var selectedTabID: UUID?
    public var tabIDs: [UUID]
    public var tabsByID: [UUID: WorkspaceTabState]
    public var unreadWorkspaceNotificationCount: Int
}
```

Add selected-tab convenience helpers on `WorkspaceState` for the current UI and
command code, but do not hide the underlying multi-tab shape. Runtime and
validation paths will need explicit all-tab helpers too.

### Bootstrap behavior

Keep bootstrap logic in one place:

- `WorkspaceState.bootstrap(...)` creates one workspace with one bootstrap tab
- `WorkspaceTabState.bootstrap(...)` creates one tab with one terminal panel
- both `New Window` and `New Tab` reuse the same cwd/profile seed rules

---

## Implementation Order

### 1. Keep the landed minimal multi-window work

Already in scope on this branch:

- `New Window` creates an independent seeded window
- the new window has its own sidebar and workspaces
- seed and frame cascade behavior are already implemented

No architectural changes needed here except compatibility updates where the tab
refactor touches multi-window code.

### 2. Introduce `WorkspaceTabState` in CoreState

First refactor slice:

- add `WorkspaceTabState`
- move tab-local layout and panel fields out of `WorkspaceState`
- update `WorkspaceState.bootstrap(...)` to create one initial tab
- add helpers for:
  - selected tab lookup
  - selected tab mutation
  - all panel IDs across tabs
  - tab title derivation from focused panel metadata

Affected files:

- `Sources/Core/WorkspaceState.swift`
- new `Sources/Core/WorkspaceTabState.swift`
- `Sources/Core/WorkspaceState+Layout.swift`
- `Sources/Core/StateValidator.swift`

### 3. Refactor reducer actions to operate on selected tabs

All panel/layout operations should target the selected tab in a workspace unless
the action explicitly names a tab.

Initial actions to add:

- `createWorkspaceTab(workspaceID: UUID, seed: WindowLaunchSeed?)`
- `selectWorkspaceTab(workspaceID: UUID, tabID: UUID)`
- `closeWorkspaceTab(workspaceID: UUID, tabID: UUID)`

Existing actions that must retarget through selected-tab helpers:

- `focusPanel`
- `closePanel`
- `reopenLastClosedPanel`
- `toggleAuxPanel`
- `toggleFocusedPanelMode`
- `splitFocusedSlot`
- `splitFocusedSlotInDirection`
- `focusSlot`
- `resizeFocusedSlotSplit`
- `equalizeLayoutSplits`
- `createTerminalPanel`
- `updateTerminalPanelMetadata`
- notification read/unread flows

Special cases:

- `movePanelToWorkspace` should move a panel into the target workspace's
  selected tab in the first cut
- closing the last panel in a tab closes that tab
- closing the last tab in a workspace should bootstrap a replacement tab rather
  than leaving the workspace panel-less

Affected files:

- `Sources/Core/AppAction.swift`
- `Sources/Core/AppReducer.swift`
- `Sources/Core/AppState.swift`
- `Sources/Core/WindowState.swift`

### 4. Add app-owned workspace tab UI

Render a custom tab strip inside the workspace view, below the top bar and
above the panel layout area.

First-cut behavior:

- show tabs for the selected workspace only
- click tab to select it
- `Cmd-T` creates a new tab in the selected workspace
- tab title live-follows the focused panel title
- tab strip does not replace or duplicate the sidebar

UI shape:

- keep workspace title in the existing top bar
- add a horizontal tab bar directly above layout content
- render only the selected tab's panel layout while keeping background tabs
  mounted if runtime behavior requires it

Affected files:

- `Sources/App/WorkspaceView.swift`
- `Sources/App/ToastyTheme.swift`
- new lightweight view helpers if needed, for example
  `Sources/App/WorkspaceTabs/WorkspaceTabStripView.swift`

### 5. Add workspace-tab commands and shortcuts

Commands:

- `New Tab` on `Cmd-T`
- `Select Tab 1/2/3` on `Cmd-1/2/3`

Command routing rules:

- tab commands act on the selected workspace in the key window
- `Cmd-W` still closes the focused panel
- if the last panel in a tab closes, the tab closes
- if the last tab in a workspace closes through that path, create a replacement
  empty tab and keep the workspace alive

Because terminal content can swallow shortcuts, do not rely on menu key
equivalents alone. Reuse the existing app-owned interceptor approach for
workspace shortcuts.

Affected files:

- `Sources/App/ToasttyKeyboardShortcut.swift`
- `Sources/App/ToasttyApp.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `Sources/App/Commands/WindowCommandController.swift`

### 6. Update runtime, automation, and validation paths

The tab refactor affects any code that assumes a workspace directly owns
panels.

Audit and update:

- terminal runtime store/action coordinators
- session/runtime status lookup
- automation socket commands and state snapshots
- notification bookkeeping
- state validation

Likely affected files:

- `Sources/App/Automation/AutomationSocketServer.swift`
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`
- `Sources/App/Terminal/TerminalControllerStore.swift`
- `Sources/App/Terminal/Runtime/TerminalStoreActionCoordinator.swift`
- `Sources/App/Terminal/Runtime/TerminalMetadataService.swift`
- `Sources/App/Terminal/Runtime/TerminalWorkspaceMaintenanceService.swift`
- `Sources/App/Terminal/Runtime/TerminalWindowRuntimeStore.swift`
- `Sources/App/Sessions/SessionRuntimeStore.swift`
- `Sources/App/Agents/AgentLaunchService.swift`
- `Sources/Core/StateValidator.swift`

---

## Validation

Unit tests:

- reducer coverage for workspace-tab create/select/close flows
- workspace bootstrap and migration/decode coverage
- state validator coverage for multi-tab workspaces
- command routing coverage for `Cmd-T` and tab switching

Runtime validation:

- `tuist generate`
- targeted `xcodebuild test` runs during development
- `./scripts/automation/smoke-ui.sh`
- dedicated GUI validation for:
  - `New Window`
  - `New Tab`
  - tab switching
  - per-workspace tab isolation
  - workspace switching across different tab sets
  - `Cmd-T`
  - `Cmd-1/2/3`
  - last-panel-closes-tab behavior

---

## Follow-Ups

Explicitly defer these until the base model is stable:

- custom tab title override
- drag reordering of tabs
- detach/move tab to new window
- tab persistence/restoration details beyond normal state persistence
- window-local terminal font overrides

For font behavior, the intended direction remains:

- a new window inherits the source window's current terminal font size
- later font increase/decrease/reset affect only the active window's terminals
- config defaults remain the baseline when no window-local override exists

---

## Simplification Check

This plan adds a new model layer, but that is justified because the requested UX
is truly workspace-scoped tabs, not grouped windows.

The main simplifications are:

- keep multi-window independent and unchanged
- reuse existing terminal seed rules for both `New Window` and `New Tab`
- keep `Cmd-W` semantics unchanged
- defer custom tab titles and advanced tab management until the core model is
  proven

That is the smallest architecture that actually matches the product behavior the
user wants.
