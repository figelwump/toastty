# Focus Mode Splits

## Context

Focus mode currently zooms into a single panel and blocks split/resize/equalize/focus-navigate operations. We want to allow those operations within focus mode while still mutating the real layout tree in place. When the user exits focus mode, the updated subtree should appear in its original position in the full layout. Re-entering focus mode from normal mode always zooms to the current focused panel; there is no subtree memory between sessions.

Focus mode is **tab-scoped**: each `WorkspaceTabState` owns its own focus state. Switching tabs shows that tab's own layout state unaffected.

This plan is intentionally split into phases:

- **Phase 1:** subtree-backed focus mode for single-panel entry. Allow split, navigate, resize, equalize, and close within the focused subtree.
- **Phase 2:** multi-panel selection that focuses the lowest common ancestor (LCA) subtree of the selected panels.

## Out Of Scope

Aux panels are intentionally out of scope for this plan.

The current aux-panel layout convention always builds or extends a dedicated right-edge column. That may not be the UX we want long term, and this plan should not lock in future aux-panel behavior around that assumption. The focus-mode work here should stay generic enough that a later aux-panel design can integrate by updating the focused subtree root when it wraps or replaces that root.

No keyboard shortcut for multi-panel selection is included in this plan. Shift-click is enough for Phase 2. If we later want a keyboard path, we can decide then whether it should be app-owned or menu-bound.

---

## Design

### Phase 1 state: `focusModeRootNodeID`

Add `focusModeRootNodeID: UUID?` to **`WorkspaceTabState`**. This tracks the root of the subtree being rendered during focus mode.

- **Enter focus (single panel):** set to the focused panel's slot ID (a leaf)
- **Split within focus:** if the split replaces the node at `focusModeRootNodeID` (the first split from a single-panel focus), update it to the new split node's ID
- **Subsequent subtree mutations:** if a mutation operates below the root, leave `focusModeRootNodeID` unchanged
- **Exit focus:** set to `nil`
- **Transient:** never persisted, decoded as `nil`

**Why a separate ID instead of deriving from `focusedPanelID`:**
After splitting A into A+B in focus mode, `focusedPanelID` moves to B (the new panel). We still need to remember that the rendered subtree is rooted at the original position where A lived. That root cannot be derived from the focused panel alone.

### Phase 2 state: `selectedPanelIDs`

Add `selectedPanelIDs: Set<UUID>` to **`WorkspaceTabState`**. Empty means there is no staged multi-selection.

- **Transient:** never persisted, decoded as empty
- **Selection is ephemeral:** treat it as staging for the next focus-mode entry, not as durable UI state
- **Cleared on:** exit focus mode, plain single-focus actions, tab switch, close of a selected panel, and successful focus reassignment after close

**Interaction model:**

- **Shift-click** on a panel toggles it in/out of `selectedPanelIDs`
- The first shift-click also adds the currently focused panel to the set
- **Plain click** on a panel focuses that panel and clears `selectedPanelIDs`
- **Enter focus mode** with `selectedPanelIDs` non-empty: compute the LCA of all selected panels, set `focusModeRootNodeID` to that node ID, then clear `selectedPanelIDs`
- **Visual indicator:** selected panels get a subtle border/highlight distinct from the focused-panel highlight

This keeps multi-selection from becoming sticky. If the user stages a selection, then clicks another panel to keep working, the old staged selection should not survive and surprise them when they later toggle focus mode.

---

## File Changes

### 1. `Sources/Core/LayoutNode.swift`

Add two Phase 1 methods and one Phase 2 method:

```swift
/// Find a subtree by its root node ID (slot ID or split node ID).
func findSubtree(nodeID: UUID) -> LayoutNode?

/// Replace any node (slot or split) by its ID.
mutating func replaceNode(nodeID: UUID, with replacement: LayoutNode) -> Bool

/// Phase 2: find the lowest common ancestor node ID containing all specified slot IDs.
/// Returns nil if any slot ID is not found in the tree.
func lowestCommonAncestor(containing slotIDs: Set<UUID>) -> UUID?
```

`findSubtree` walks the tree depth-first and returns the node whose ID matches (slot's `slotID` or split's `nodeID`). `replaceNode` is like `replaceSlot` but works on split nodes too.

`lowestCommonAncestor` is only needed for Phase 2.

### 2. `Sources/Core/WorkspaceSplitTree.swift`

**Modify `splitting()` signature** to accept a caller-provided split node ID:

```swift
public func splitting(
    slotID: UUID,
    direction: SlotSplitDirection,
    newPanelID: UUID,
    newSlotID: UUID,
    newSplitNodeID: UUID = UUID()
) -> WorkspaceSplitTree?
```

This lets the reducer know the new split root ID when the first split in focus mode converts a single slot into a split subtree.

**Modify `renderedLayout()` signature:**

```swift
public func renderedLayout(
    workspaceID: UUID,
    focusedPanelModeActive: Bool,
    focusedPanelID: UUID?,
    focusModeRootNodeID: UUID?
) -> WorkspaceRenderedLayout
```

When `focusedPanelModeActive` is true:

- If `focusModeRootNodeID` is set, render that subtree via `root.findSubtree(nodeID:)`
- If the subtree cannot be found, fall back to the current single-slot rendering path
- Use `focusModeRootNodeID` as `zoomedNodeID` in the render identity

**Add `focusedSubtree()` helper:**

```swift
public func focusedSubtree(rootNodeID: UUID) -> WorkspaceSplitTree?
```

Returns a `WorkspaceSplitTree` wrapping the subtree rooted at `rootNodeID`. The reducer uses this to scope focus navigation, resize, and equalize to the visible subtree.

### 3. `Sources/Core/WorkspaceTabState.swift`

- **Phase 1:** add `focusModeRootNodeID: UUID?` (default `nil`)
- **Phase 2:** add `selectedPanelIDs: Set<UUID>` (default empty)
- Both transient: excluded from `CodingKeys`, decoded as `nil` / empty

### 4. `Sources/Core/WorkspaceState.swift`

- Add delegation of `focusModeRootNodeID` to `selectedTab`
- Add delegation of `selectedPanelIDs` to `selectedTab`

### 5. `Sources/Core/WorkspaceState+Layout.swift`

- Update `renderedLayout` to pass `focusModeRootNodeID`
- Add `focusModeSubtree: WorkspaceSplitTree?`
- Add a `focusedPanelIDAfterClosing` variant or parameter that scopes `.previous` slot lookup to the focused subtree during focus mode

### 6. `Sources/Core/AppReducer.swift`

**Phase 1**

**`toggleFocusedPanelMode`:**

- When toggling ON from normal mode, set `focusModeRootNodeID` to the focused panel's resolved slot ID
- When toggling OFF, set `focusModeRootNodeID` to `nil`

**`splitFocusedSlot`:**

- Remove the `focusedPanelModeActive == false` guard
- Generate `newSplitNodeID` and pass it to `splitting()`
- After splitting: if `focusModeRootNodeID` equals the slot ID that was split, update it to `newSplitNodeID`

**`focusSlot`:**

- Remove the `focusedPanelModeActive == false` guard
- When in focus mode, scope navigation to `focusModeSubtree`
- Outside focus mode, keep current behavior
- In Phase 2, a successful plain focus move clears `selectedPanelIDs`

**`resizeFocusedSlotSplit`:**

- Remove the `focusedPanelModeActive == false` guard
- When in focus mode, resize only within `focusModeSubtree`
- Replace the updated subtree back into the full tree via `replaceNode(nodeID:, with:)`

**`equalizeLayoutSplits`:**

- Remove the `focusedPanelModeActive == false` guard
- When in focus mode, equalize only within `focusModeSubtree`
- Replace the updated subtree back into the full tree

**`closePanel`:**

- Keep removal on the full tree
- After removal, if `focusModeRootNodeID` still exists in the updated tree, keep it
- If it no longer exists because the focused subtree collapsed, retarget `focusModeRootNodeID` to the replacement subtree root
- If the focused subtree collapses to a single slot, `focusModeRootNodeID` becomes that slot ID
- If the tab/workspace is removed, focus mode exits naturally
- Focus resolution should prefer panels within the focused subtree

The plan should explicitly capture how the reducer discovers the replacement root after close. That likely means either:

- capturing the pre-removal focused subtree before mutating the tree, or
- extending the removal API to report replacement-root information

Do not leave that as implicit bookkeeping.

**Phase 2**

**`toggleFocusedPanelMode`:**

- When toggling ON with `selectedPanelIDs` non-empty, compute the LCA of the selected panels and set `focusModeRootNodeID` to that LCA node ID
- Clear `selectedPanelIDs` after consuming the selection

**`focusPanel`:**

- Plain `.focusPanel(...)` clears `selectedPanelIDs`

**`selectWorkspaceTab`:**

- Clear the source tab's `selectedPanelIDs` before switching tabs

**New actions:**

- `.togglePanelSelection(workspaceID: UUID, panelID: UUID)`
- `.clearPanelSelection(workspaceID: UUID)`

### 7. `Sources/App/WorkspaceView.swift`

**Phase 1**

- Enable split controls while focus mode is active
- Keep aux-panel controls disabled in focus mode because aux panels are out of scope here
- Render the focused subtree using the updated `renderedLayout`

**Phase 2**

- Shift-click on a panel toggles multi-selection
- Plain click focuses the panel and clears multi-selection
- Add selected-panel highlight styling distinct from the focused-panel styling

### 8. `Sources/App/Commands/WindowCommandController.swift`

**`canAdjustSplitLayout`:**

- Remove the `focusedPanelModeActive != true` guard
- When in focus mode, enable resize/equalize only if the focused subtree contains more than one slot

`canSplit` and `canFocusSplit` already do not special-case focus mode.

### 9. `Sources/App/Commands/ToasttyCommandMenus.swift`

No Phase 1 behavior change beyond whatever becomes enabled by the reducer/controller changes.

For Phase 2, if `selectedPanelIDs` is non-empty, consider changing the label from "Focus Panel" to "Focus Selected Panels". This is polish, not required for the first implementation.

### 10. `WorkspaceRenderIdentity`

Rename `zoomedSlotID` to `zoomedNodeID` because the focused root can now be a split node as well as a slot node.

---

## Edge Cases

### Phase 1

1. **First split in focus mode:** `focusModeRootNodeID` starts as a slot ID. After the split, it becomes the new split node ID. Both panels render.
2. **Multiple splits in focus mode:** only the first split changes `focusModeRootNodeID`; later splits stay inside the subtree.
3. **Close last-but-one panel in focused subtree:** the subtree collapses from a split to a single slot. `focusModeRootNodeID` becomes that remaining slot ID.
4. **Close all panels in focused subtree:** the tab/workspace is removed and focus mode exits naturally.
5. **Toggle focus off after splits:** `focusModeRootNodeID` is cleared and the full tree renders with the updated subtree in place.
6. **Toggle focus back on:** `focusModeRootNodeID` is set from the current focused slot. There is no memory of the previously zoomed subtree.
7. **`focusModeRootNodeID` becomes stale:** defensively fall back to single-slot rendering if `findSubtree` returns `nil`.
8. **Tab switching during focus mode:** tab A can stay focused while tab B shows its normal full layout. Switching back restores tab A's focused subtree.

### Phase 2

9. **Multi-panel selection + focus:** selected panels focus the minimal subtree containing them, not an arbitrary cherry-picked set of leaves.
10. **Selection cleared by normal focus work:** if the user stages a selection, then plain-clicks a panel, uses pane navigation, or focus moves after close, the staged selection is cleared.
11. **Tab switch clears staged selection:** multi-selection should not survive leaving the tab and returning later.

---

## Tests

### `WorkspaceSplitTreeTests.swift`

- `renderedLayoutShowsSubtreeAfterSplitInFocusMode`
- `renderedLayoutFallsBackToSlotWhenFocusModeRootIDIsStale`
- `focusTargetInFocusModeWrapsWithinSubtree`
- `splittingPreservesCallerProvidedSplitNodeID`
- `equalizeInFocusModeOnlyScopesToSubtree`
- `resizeInFocusModeStopsAtSubtreeBoundary`

### `AppReducerTests.swift`

**Phase 1**

- `splitInFocusModeUpdatesFocusModeRootNodeID`
- `secondSplitInFocusModePreservesRootNodeID`
- `focusNavigationInFocusModeStaysInSubtree`
- `resizeInFocusModeOnlyMutatesFocusedSubtree`
- `equalizeInFocusModeOnlyMutatesFocusedSubtree`
- `closePanelInFocusModeCollapsesSubtree`
- `toggleFocusOffClearsRootNodeID`
- `reenterFocusModeResetsToSingleSlot`

Replace the current "blocked while focused mode active" tests for split/resize/equalize with positive coverage for the new behavior.

**Phase 2**

- `multiPanelSelectionFocusUsesLCA`
- `multiPanelSelectionClearedOnFocusEntry`
- `plainFocusPanelClearsMultiSelection`
- `focusNavigationClearsMultiSelection`
- `tabSwitchClearsMultiSelection`

### `WindowCommandControllerTests.swift`

- `canAdjustSplitLayoutInFocusModeWhenFocusedSubtreeHasMultipleSlots`
- `canAdjustSplitLayoutInFocusModeReturnsFalseForSingleSlotSubtree`

### `AppStateCodableTests.swift`

- `focusModeTransientFieldsResetWhenDecodingAppState`

Verify that both `focusModeRootNodeID` and `selectedPanelIDs` reset on decode.

### `WorkspaceLayoutSnapshotTests.swift`

- `makeAppStateClearsTransientFocusModeFields`

Verify the snapshot restore path clears `focusModeRootNodeID` and `selectedPanelIDs` along with `focusedPanelModeActive`.

---

## Verification

### Phase 1

1. `tuist generate`
2. `xcodebuild ... build`
3. `xcodebuild test ...`
4. `./scripts/automation/smoke-ui.sh`
5. Manual verification:
   - Enter focus mode on a panel
   - Split horizontally and vertically within focus mode
   - Navigate between visible panels
   - Resize a divider within the focused subtree
   - Equalize splits within the focused subtree
   - Close a panel within the focused subtree
   - Toggle focus off and confirm the subtree appears in the right place in the full layout
   - Toggle focus back on and confirm it resets to the current focused panel only

### Phase 2

1. Shift-click two or more panels to stage a selection
2. Enter focus mode and verify the visible subtree is the LCA subtree
3. Plain-click another panel and verify the staged selection clears
4. Switch tabs and verify staged selection clears

---

## Implementation Order

### Phase 1

1. `LayoutNode` additions needed for subtree lookup/replacement: `findSubtree`, `replaceNode`
2. `WorkspaceSplitTree` changes: split root ID plumbing, subtree rendering, `focusedSubtree`
3. `WorkspaceTabState` / `WorkspaceState` / `WorkspaceState+Layout` plumbing for `focusModeRootNodeID`
4. `AppReducer` Phase 1 changes: split/focus/resize/equalize/close within focused subtree
5. `WorkspaceView` and `WindowCommandController` updates for the newly enabled behavior
6. Rename `zoomedSlotID` to `zoomedNodeID`
7. Phase 1 tests
8. Build, smoke automation, and manual validation

### Phase 2

1. Add `selectedPanelIDs`
2. Add `lowestCommonAncestor(containing:)`
3. Reducer support for staged selection and LCA-based focus entry
4. `WorkspaceView` shift-click interaction and selection styling
5. Phase 2 tests

### Later Follow-Up

Design aux-panel UX and layout behavior separately, then integrate it with the generic focused-subtree machinery from Phase 1.
