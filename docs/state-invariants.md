# toastty app-state contract

Date: 2026-03-13

This document describes the current hard contract for persisted and reducer-managed
`AppState`.

It is intentionally narrow:

- Include rules only when they are enforced by `StateValidator`, normalized during
  decode/restore, or relied on by reducer/bootstrap code.
- Exclude runtime-only services and aspirational rules that are not enforced today.

## 1) scope

This document applies to:

- `AppState`
- `WindowState`
- `WorkspaceState`
- `LayoutNode`
- workspace layout snapshot restore

This document does not apply to:

- `SessionRegistry`
- `NotificationStore`
- terminal runtime/controller state
- other automation-only runtime bookkeeping

## 2) app-level ownership and membership

Current enforced rules:

- `AppState.workspacesByID` is the canonical storage for `WorkspaceState`.
- `AppState.windows` is an ordered array of windows.
- Every `workspaceID` referenced by a window must exist in `AppState.workspacesByID`.
- A workspace may appear in at most one window.
- Every workspace in `AppState.workspacesByID` must belong to some window.
- `WindowState.selectedWorkspaceID`, if non-nil, must be present in that window's
  `workspaceIDs`.

Current non-rule:

- `AppState.selectedWindowID` is not validated. Callers must treat it as a UI
  preference that may be nil or stale and fall back accordingly.

## 3) workspace layout invariants

For each workspace, the validator enforces:

- `WorkspaceState.tabIDs` must contain at least one tab ID.
- Every tab ID in `WorkspaceState.tabIDs` must exist in `WorkspaceState.tabsByID`.
- `WorkspaceState.selectedTabID`, if non-nil, must be present in
  `WorkspaceState.tabIDs`.
- For each tab, `WorkspaceTabState.panels` is the canonical storage for panel
  state.
- Every `LayoutNode.slot.panelID` exists in its tab's `WorkspaceTabState.panels`.
- Every panel in a tab's `WorkspaceTabState.panels` appears in exactly one slot
  in that tab's layout tree.
- `WorkspaceTabState.focusedPanelID`, if non-nil, exists in that tab's
  `WorkspaceTabState.panels`.
- `WorkspaceTabState.focusedPanelID`, if non-nil, is also present in that tab's
  layout tree.
- Every split ratio satisfies `0 < ratio < 1`.
- Slot IDs and split node IDs are unique across all tab layout trees in a
  workspace.
- `WorkspaceTabState.unreadPanelIDs` and `WorkspaceTabState.selectedPanelIDs`
  may only contain panel IDs present in that tab's `WorkspaceTabState.panels`.

Important model detail:

- `LayoutNode` has no empty-slot representation. A tree can become smaller when a panel
  is removed, but not contain an explicit empty leaf.
- `StateInvariantViolation` still contains an `emptySlotLeaf` case, but the current
  `LayoutNode` model and validator do not emit it.

## 4) decode and restore normalization

These behaviors are intentional current contract, not incidental implementation detail.

During `WorkspaceState` decode:

- `unreadWorkspaceNotificationCount` is clamped to `>= 0`.
- missing `hasBeenVisited` values default to `true` for compatibility with
  older persisted state.

During `WorkspaceTabState` decode:

- `focusedPanelModeActive` is always reset to `false`.
- `focusModeRootNodeID` is reset to `nil`.
- `unreadPanelIDs` is intersected with the current `panels` keys.
- `selectedPanelIDs` is reset to `[]`.

During `AppState` initialization or decode:

- workspaces selected in visible windows are normalized to `hasBeenVisited=true`.
- background workspaces preserve their decoded `hasBeenVisited` value.

During `WorkspaceLayoutSnapshot.makeAppState()` restore:

- window membership and `selectedWindowID` are restored from the snapshot as-is
- `makeAppState()` itself does not call `StateValidator`
- workspace titles, visit state, tab order, layout trees, panel kinds, and
  `focusedPanelID` are restored
- `focusedPanelModeActive` is reset to `false`
- `unreadPanelIDs` is reset to `[]`
- `unreadWorkspaceNotificationCount` is reset to `0`
- `recentlyClosedPanels` is reset to `[]`
- `configuredTerminalFontPoints` is reset to `nil`
- `globalTerminalFontPoints` is reset to `AppState.defaultTerminalFontPoints`
- restored terminal panels get regenerated `Terminal N` titles per workspace
- restored terminal panels keep their stable `panelID` values from the snapshot
- restored terminal panels keep `launchWorkingDirectory`
- restored terminal panels keep `profileBinding` when present so profile-backed
  panes can resume with the same terminal profile ID after restart
- restored terminal panels start with blank live `cwd` and wait for authoritative
  runtime metadata

## 5) reducer-maintained conventions that are not validator rules

These behaviors are current reducer contract, but `StateValidator` does not check them.

- Panel removal collapses the layout tree instead of leaving placeholders.
- Closing the last panel in a workspace removes the workspace, and removing the last
  workspace in a window removes the window for valid reducer-managed state.
- Reducer paths generally keep `selectedWindowID` pointing at a live window for valid
  reducer-managed state, but that is not currently a validated invariant.

## 6) validation entry points

`StateValidator.validate(_:)` is currently used from:

- reducer tests
- persistence load/persist checkpoints
- fixture and snapshot tests

Current caveat:

- Automation fixtures are validated in tests, but fixture loading/bootstrap paths do
  not currently call `StateValidator` before installing the fixture into the app store.
  Treat this as a known gap, not a guarantee.

## 7) primary enforcement points

When this contract changes, update the code and the doc together.

- `Sources/Core/StateValidator.swift`
- `Sources/Core/WorkspaceState.swift`
- `Sources/Core/AppReducer.swift`
- `Sources/Core/WorkspaceLayoutSnapshot.swift`
- `Tests/Core/StateValidatorTests.swift`
- `Tests/Core/WorkspaceLayoutSnapshotTests.swift`
