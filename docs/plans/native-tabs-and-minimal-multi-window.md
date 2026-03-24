# Native Tabs And Minimal Multi-Window Plan

## Goal

Add two related capabilities without introducing a new core tab model:

- a user-facing `New Window` flow that creates a second independent Toastty
  window seeded from the active terminal context
- native macOS window tabs built on top of that same seeded-window flow

The existing `window -> workspace -> panel` state model stays intact.

---

## UX Model

Three user actions should mean three distinct things:

- `New Workspace`
  - create another workspace inside the current Toastty window
  - the sidebar remains the switcher for those workspaces
- `New Window`
  - create a second independent Toastty window
  - the new window starts with one workspace and one terminal pane
  - the new pane inherits the active focused terminal's cwd and profile when
    available
  - the new window still shows the normal sidebar
- `New Tab`
  - create the same kind of seeded independent Toastty window
  - immediately attach that new window to the source window's native macOS tab
    group

Important non-goal: a workspace does not belong to multiple windows. We do not
share one `WorkspaceState` across windows or tabs.

---

## Why This Shape

This is the least-complex model that still matches the requested UX:

- the app already has a `WindowState` model and a `WindowGroup` scene root
- multi-window state and scene binding already exist internally
- native tabs can reuse the same seeded-window bootstrap path instead of
  requiring a second "tab" abstraction in CoreState
- if AppKit tab grouping proves unstable under `WindowGroup`, the multi-window
  work still lands as a useful standalone feature

This intentionally avoids:

- adding `TabState` under `WorkspaceState`
- sharing one workspace instance across multiple windows
- persisting native tab groups across relaunch in the first pass

---

## Current State

Relevant existing behavior:

- `AppState` already tracks multiple windows through `windows` and
  `selectedWindowID`
- `AppReducer.createWindow` already creates a new `WindowState` with a single
  bootstrap workspace
- `AppWindowSceneHostView` already spawns and binds scenes for multiple window
  IDs via `openWindow`
- `detachPanelToNewWindow` already exercises the multi-window state path
- native tab-related menu items are currently hidden
- `NSWindow.title` currently follows the selected workspace title

That means the missing work for minimal multi-window is mostly:

- seed threading
- user-facing commands
- lifecycle verification

The missing work for native tabs is mostly:

- AppKit tab attachment and cleanup
- command/menu integration
- title derivation

---

## Recommended Shape

### Window launch seed

Add one small seed object that can be used by both `New Window` and `New Tab`:

```swift
public struct WindowLaunchSeed: Equatable, Sendable {
    public var workspaceTitle: String?
    public var terminalCWD: String?
    public var terminalProfileBinding: TerminalProfileBinding?
}
```

Use this to evolve window creation away from a title-only bootstrap:

```swift
case createWindow(seed: WindowLaunchSeed?, initialFrame: CGRectCodable?)
```

### Workspace bootstrap

Keep bootstrap logic in one place. Extend `WorkspaceState.bootstrap(...)` to
accept the seeded cwd/profile instead of building a second construction path for
seeded windows.

### Frame placement

For `New Window`, use the source window frame as context and cascade it by a
small offset instead of always using a fixed origin. This avoids new windows
stacking exactly on top of each other.

For `New Tab`, the initial frame is mostly a placeholder because the new window
joins a tab group immediately, but the state still needs a sensible starting
frame until the observer publishes the live frame.

---

## Implementation Order

### 1. Ship minimal multi-window first

User-visible deliverable:

- add a `New Window` command
- create an independent seeded window from the active focused terminal context
- keep the sidebar and workspace behavior unchanged inside that window

Seed rules:

- if the active focused panel is a terminal:
  - inherit `workingDirectorySeed`
  - inherit `profileBinding`
- otherwise:
  - fall back to the default terminal profile
  - fall back to the user's home directory

Affected files:

- `Sources/Core/AppAction.swift`
- `Sources/Core/AppReducer.swift`
- `Sources/Core/WorkspaceState.swift`
- `Sources/Core/PanelState.swift`
- `Sources/App/AppStore.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `Sources/App/Commands/WindowCommandController.swift`

### 2. Run a focused multi-window verification pass

This phase is not a broad architecture rewrite. It is a targeted pass to verify
that the already-existing multi-window scene lifecycle behaves correctly under a
real `New Window` command.

Verify and fix only what is needed:

- `selectedWindowID` updates when the non-selected window becomes key
- command routing stays bound to the correct window
- closing one window dismisses only that scene and does not cause the scene
  coordinator to recreate it
- existing automation assumptions still hold when more than one window exists

Affected files:

- `Sources/App/AppWindowSceneHostView.swift`
- `Sources/App/AppWindowSceneCoordinator.swift`
- `Sources/App/AppWindowSceneObserver.swift`
- `Sources/App/AppWindowSceneView.swift`

### 3. Add a native-tab spike with explicit pass/fail criteria

Do not commit to full native tabs until this spike passes.

Spike goals:

- attach a newly created seeded window as a native tab of a source window
- confirm tab-strip close tears down the right `WindowState`
- confirm the scene does not unexpectedly remount or lose its window binding
  when the window joins a tab group
- confirm tab switching gives Toastty enough signal to keep
  `selectedWindowID` accurate

If this spike fails because `WindowGroup` and AppKit tab ownership conflict too
hard, fall back to keeping multi-window only for now and revisit tabbed windows
through AppKit-owned windows later.

Implementation note:

- prefer explicit AppKit tab attachment over globally enabling automatic tab
  merging until we know the lifecycle is stable
- if AppKit surfaces any path that invokes `newWindowForTab:`, route it through
  Toastty's seeded creation path instead of accepting AppKit's default blank
  tab/window behavior

Likely affected files:

- `Sources/App/AppWindowSceneObserver.swift`
- `Sources/App/AppWindowSceneHostView.swift`
- `Sources/App/ToasttyApp.swift`
- new AppKit-focused helper such as
  `Sources/App/WindowTabs/WindowTabCoordinator.swift`

### 4. Add user-facing native-tab commands

Once the spike passes:

- `New Tab` on `Cmd-T`
- unhide safe native tab presentation items such as `Show Tab Bar` and
  `Show All Tabs`
- keep `Cmd-W` on the existing close-panel path
- allow "last panel in last workspace closes the tab" through the existing
  window removal path

Do not add extra shortcut surface yet unless the lifecycle is already proven.

`Cmd-1/2/3` tab switching stays in-scope, but only after attach/close/title
basics are working. If scope has to shrink, this is the first requested feature
to cut temporarily and land immediately after the base tab implementation.

Close Tab:

- support a menu action only in the first pass if needed
- a dedicated Close Tab shortcut is explicitly deferred unless the final command
  surface still feels incomplete after the base feature works

Affected files:

- `Sources/App/ToasttyKeyboardShortcut.swift`
- `Sources/App/Commands/ToasttyCommandMenus.swift`
- `Sources/App/Commands/WindowCommandController.swift`
- `Sources/App/ToasttyApp.swift`

### 5. Switch native tab titles to panel-derived titles

First cut:

- keep the workspace title in the top bar
- drive `NSWindow.title` from the selected workspace's focused panel label
- use the same label source the panel header already uses

Defer:

- custom tab title overrides
- persisted title override state

This keeps the first tab-title implementation small and deterministic while the
window/tab lifecycle is still settling.

Affected files:

- `Sources/App/AppWindowSceneView.swift`
- `Sources/App/AppWindowSceneObserver.swift`
- `Sources/App/WorkspaceView.swift`

---

## Explicit Non-Goals For The First Pass

Do not add these in the first pass:

- a new `TabState` model
- shared workspaces across windows
- persisted native tab-group membership across relaunch
- custom tab title overrides
- detach/merge tab affordances unless the spike proves them reliable
- a new automation socket API for tabs

If AppKit detach/merge behavior is unstable under `WindowGroup`, keep those
native affordances hidden rather than shipping a broken path.

---

## Testing And Validation

### Unit tests

Update and extend:

- `Tests/Core/AppReducerTests.swift`
- `Tests/App/AppStoreWindowSelectionTests.swift`
- `Tests/App/AppWindowSceneCoordinatorTests.swift`
- `Tests/App/AppWindowSceneObserverCoordinatorTests.swift`
- `Tests/App/WindowCommandControllerTests.swift`
- `Tests/App/DisplayShortcutInterceptorTests.swift`

Key cases:

- seeded window creation inherits cwd/profile correctly
- frame cascading uses the source window frame context
- two independent windows keep `selectedWindowID` and command routing correct
- closing one window does not leak state or respawn its scene
- native tab attach/close uses the right window IDs once that phase lands

### Runtime validation

Required validation flow:

1. `tuist generate`
2. build the app
3. run targeted tests
4. run `./scripts/automation/check.sh`
5. run a real GUI validation pass for native window and tab behavior

Because native tab behavior is AppKit-owned, expect at least one real GUI
validation pass through:

- `scripts/remote/gui-validate.sh`, or
- local `peekaboo` after permissions are confirmed

Also verify that the existing smoke flows do not accidentally assume a single
window once the user-facing `New Window` command lands.

---

## Simplifications And Tradeoffs

This plan deliberately simplifies the original combined feature request:

- minimal multi-window ships before native tabs
- `New Window` and `New Tab` share one seeded bootstrap path
- tab title overrides are deferred
- dedicated Close Tab shortcut is deferred
- native tab detach/merge is conditional on the spike, not assumed

That makes the first implementation much easier to reason about while still
moving directly toward the native tab UX.
