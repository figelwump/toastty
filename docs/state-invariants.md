# toastty state invariants

Date: 2026-02-27

This document defines invariants that must hold for `AppState` at all times.
Reducers and migration code must preserve these rules.

## 1) scope

- Applies to:
  - reducer state transitions
  - persistence encode/decode and migrations
  - automation fixture loading
- Violations are treated as correctness bugs, not UI bugs.

## 2) model ownership and identity

### app-level ownership

- `AppState.workspacesByID` is the canonical storage for `WorkspaceState`.
- `AppState.windows` is an ordered array; window lookup by id may use linear scan or a transient index map.
- `WindowState.workspaceIDs` stores ordered references to workspace ids.
- A workspace id may appear in exactly one `WindowState.workspaceIDs`.
- `AppState.selectedWindowID`, if non-nil, must exist in `AppState.windows`.

### window-level ownership

- `WindowState.selectedWorkspaceID`, if non-nil, must appear in the same window's `workspaceIDs`.
- `WindowState.workspaceIDs` must not contain duplicates.

### workspace-level ownership

- `WorkspaceState.panels` is the canonical storage for panel state in that workspace.
- `WorkspaceState.focusedPanelID`, if non-nil, must exist in `WorkspaceState.panels`.
- `WorkspaceState.auxPanelVisibility` only contains aux kinds (`diff`, `markdown`, `scratchpad`) in v1.

## 3) layout tree invariants

For each workspace:

- Every `LayoutNode.slot.panelID` must exist in `WorkspaceState.panels`.
- Every key in `WorkspaceState.panels` must appear in exactly one slot.
- Empty slots are not allowed after reducer actions.
- Split `ratio` must satisfy `0.05 <= ratio <= 0.95`.
- `slotID` values (on slots) and `nodeID` values (on splits) must all be unique within a workspace tree. No ID may appear on both a slot and a split node.

## 4) panel-kind and toggle invariants

- In v1, each workspace has at most one panel instance per aux panel kind.
- If aux toggle is on for a kind, one panel of that kind must exist in the workspace.
- If aux toggle is off for a kind, no panel of that kind exists in the workspace.
- Toggle-off behavior closes the panel even if the panel was moved out of the right column.

## 5) session registry invariants

For active session records:

- `sessionID` is unique.
- `panelID` is immutable for the lifetime of a session.
- `windowID` and `workspaceID` must match current panel location in app state.
- `startedAt <= updatedAt`.
- If `stoppedAt` is non-nil, then `stoppedAt >= updatedAt`.
- `repoRoot`, if present, is absolute.
- `cwd`, if present, is absolute.

Path attribution rules:

- Absolute file paths are accepted directly.
- Relative file paths require `cwd` from the same event.
- After normalization, files outside `repoRoot` remain tracked as out-of-scope and must not be merged into the main diff view.

## 6) layout/profile invariants

- `DisplayLayoutState.displaySignature` uniquely identifies a display topology key.
- One latest saved snapshot per display signature.
- Revert applies to snapshot history of the current display signature only.
- `AppLayoutSnapshot.windowID` values must be unique inside each snapshot.

## 7) mutation contract

Every reducer action that mutates layout/panels must be atomic with respect to references:

- create panel:
  - insert into `WorkspaceState.panels`
  - insert id into exactly one slot
- close panel:
  - remove id from its slot
  - remove from `WorkspaceState.panels`
  - push `ClosedPanelRecord` onto `recentlyClosedPanels` (bounded stack, max 10)
  - clear/adjust focus if needed
  - if a slot becomes empty, collapse the split tree so no empty slot remains
- close last panel in workspace (lifecycle cascade):
  - close the workspace: remove from `AppState.workspacesByID`
  - remove workspace id from owning window's `workspaceIDs`
  - if workspace was `selectedWorkspaceID`, select nearest sibling
  - if window's `workspaceIDs` is now empty, close the window (remove from `AppState.windows`)
  - if no windows remain, app stays running with no windows (macOS dock persists; re-activate creates default window)
- reopen panel:
  - pop from `recentlyClosedPanels`
  - re-insert panel state into `WorkspaceState.panels`
  - split the original source slot if it still exists, otherwise split the focused slot
  - runtime is re-created (terminal process is not recoverable; new shell session starts)
- move panel:
  - remove id from source slot
  - split destination slot and insert into the new sibling slot
  - preserve panel object identity
  - preserve session identity; only location metadata may change
- detach panel to new window:
  - create `WindowState`
  - create `WorkspaceState`
  - install panel into new workspace tree
  - update session location metadata

## 8) validation entry points

Implement a validator callable from:

- reducer debug assertions (all debug builds)
- persistence decode/migration checkpoints
- automation fixture loader (`--automation`)
- integration test harness

Suggested interface:

```swift
enum StateInvariantError: Error, Equatable {
    case missingWorkspace(UUID)
    case duplicateWorkspaceReference(UUID)
    case panelMissingFromWorkspace(panelID: UUID, workspaceID: UUID)
    case panelUnreachableInLayoutTree(panelID: UUID, workspaceID: UUID)
    case duplicateNodeID(UUID) // covers both slot slotID and split nodeID
    case invalidSplitRatio(Double)
    case invalidFocusPanel(workspaceID: UUID, panelID: UUID)
    case auxToggleInconsistency(workspaceID: UUID, panelKind: PanelKind)
    case sessionLocationMismatch(sessionID: String, expectedWindowID: UUID, expectedWorkspaceID: UUID)
    case invalidSessionTimestampOrder(sessionID: String)
    case duplicateSnapshotWindowID(UUID)
}

func validateAppState(_ state: AppState) throws
```

## 9) violation handling policy

- Debug builds:
  - fail fast with assertion and invariant error details.
- Release builds:
  - emit telemetry/log event with invariant error details
  - apply only safe auto-recovery actions:
    - missing selected focus panel: clear `focusedPanelID`
    - missing selected workspace id: clear `selectedWorkspaceID`
  - do not auto-recover structural corruption:
    - panel/tree reference mismatch
    - duplicate ownership/ids
    - session location mismatch
  - when structural corruption is detected, reject load and request fixture/snapshot reset

## 10) fixture requirements

Automation fixtures in `Automation/Fixtures/` must:

- pass invariant validation before app UI is shown
- include deterministic ids for windows/workspaces/panels to stabilize screenshots
- avoid external dependencies (network, live agent processes)
