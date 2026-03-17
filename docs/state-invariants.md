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

- `WorkspaceState.panels` is the canonical storage for panel state.
- Every `LayoutNode.slot.panelID` exists in `WorkspaceState.panels`.
- Every panel in `WorkspaceState.panels` appears in exactly one slot in the layout tree.
- `WorkspaceState.focusedPanelID`, if non-nil, exists in `WorkspaceState.panels`.
- `WorkspaceState.focusedPanelID`, if non-nil, is also present in the layout tree.
- Every split ratio satisfies `0 < ratio < 1`.
- Slot IDs and split node IDs are unique within a workspace tree.
- `WorkspaceState.unreadPanelIDs` may only contain panel IDs present in
  `WorkspaceState.panels`.

Important model detail:

- `LayoutNode` has no empty-slot representation. A tree can become smaller when a panel
  is removed, but not contain an explicit empty leaf.
- `StateInvariantViolation` still contains an `emptySlotLeaf` case, but the current
  `LayoutNode` model and validator do not emit it.

## 4) decode and restore normalization

These behaviors are intentional current contract, not incidental implementation detail.

During `WorkspaceState` decode:

- `focusedPanelModeActive` is always reset to `false`.
- `unreadPanelIDs` is intersected with the current `panels` keys.
- `unreadWorkspaceNotificationCount` is clamped to `>= 0`.

During `WorkspaceLayoutSnapshot.makeAppState()` restore:

- window membership and `selectedWindowID` are restored from the snapshot as-is
- `makeAppState()` itself does not call `StateValidator`
- workspace titles, layout trees, panel kinds, `focusedPanelID`, and
  `auxPanelVisibility` are restored
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

- Aux panel uniqueness and toggle consistency are maintained by reducer actions:
  at most one panel per aux kind, and `auxPanelVisibility` is updated alongside panel
  creation/removal.
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
