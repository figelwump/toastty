# Focus Mode Splits

Date: 2026-03-30

## Context

Focus mode currently zooms into a single panel and blocks split/resize/equalize/focus-navigate operations. We want to allow those operations within focus mode while still mutating the real layout tree in place. When the user exits focus mode, the updated subtree should appear in its original position in the full layout. Re-entering focus mode from normal mode always zooms to the current focused panel; there is no subtree memory between sessions.

Focus mode is **tab-scoped**: each `WorkspaceTabState` owns its own focus state. Switching tabs shows that tab's own layout state unaffected.

Today the persistent focus-mode affordance is too subtle, and `Jump to Next Unread or Active` can focus a panel that is hidden by an existing focus root. This plan fixes both problems while keeping focus mode tab-scoped rather than introducing a separate global inspection mode.

This plan is intentionally split into phases:

- **Phase 1:** subtree-backed focus mode for single-panel entry. Allow split, navigate, resize, equalize, and close within the focused subtree.
- **Phase 2:** multi-panel selection that focuses the lowest common ancestor (LCA) subtree of the selected panels.

## Current State

Today the implementation is still hard-wired to "zoom one slot and freeze the rest":

- `WorkspaceSplitTree.renderedLayout(...)` only knows how to render the full tree or a single focused slot leaf. Its render identity is `zoomedSlotID`, not a generic subtree node ID.
- `AppReducer.toggleFocusedPanelMode(...)` only toggles `focusedPanelModeActive`; it does not track a focused subtree root.
- `AppReducer.splitFocusedSlot(...)`, `focusSlot(...)`, `resizeFocusedSlotSplit(...)`, and `equalizeLayoutSplits(...)` all early-return while focus mode is active.
- `AppReducer.closePanel(...)` removes panels on the full tree and chooses follow-up focus from the full-tree previous slot, with no concept of a focused subtree root collapsing or surviving.
- `WindowCommandController.canAdjustSplitLayout(...)` disables resize/equalize outright while focus mode is active.
- Existing tests encode that blocked behavior, so Phase 1 needs explicit replacement coverage rather than just deleting those assertions.

## Out Of Scope

Aux panels are intentionally out of scope for this plan.

The current aux-panel layout convention always builds or extends a dedicated right-edge column. That may not be the UX we want long term, and this plan should not lock in future aux-panel behavior around that assumption. The focus-mode work here should stay generic enough that a later aux-panel design can integrate by updating the focused subtree root when it wraps or replaces that root.

No keyboard shortcut for multi-panel selection is included in this plan. Shift-click is enough for Phase 2. If we later want a keyboard path, we can decide then whether it should be app-owned or menu-bound.

`Jump to Next Unread or Active` stays a normal focus/navigation command. It should compose with tab-scoped focus mode rather than creating a separate temporary cross-tab mode.

---

## Design

### Phase 1 state: `focusModeRootNodeID`

Add `focusModeRootNodeID: UUID?` to **`WorkspaceTabState`**. This tracks the root of the subtree being rendered during focus mode.

- **Enter focus (single panel):** set to the focused panel's slot ID (a leaf)
- **Split within focus:** if the split replaces the node at `focusModeRootNodeID`, update it to the new split node's ID
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
- **Enter focus mode** with `selectedPanelIDs` non-empty:
  - compute the LCA of all selected panels
  - if the LCA is a proper subtree, set `focusModeRootNodeID` to that node ID and clear `selectedPanelIDs`
  - if the LCA is the full workspace root, do not activate focus mode and leave `selectedPanelIDs` intact
- **Visual indicator:** selected panels get a subtle border/highlight distinct from the focused-panel highlight

This keeps multi-selection from becoming sticky. If the user stages a selection, then clicks another panel to keep working, the old staged selection should not survive and surprise them when they later toggle focus mode.

If the computed LCA is the full workspace root, do not activate focus mode. That would be visually indistinguishable from the normal full-layout state and would make the mode indicator misleading. Leave the staged selection intact so the user can refine it.

### Core invariants

- Focus mode remains **tab-scoped**. Leaving a tab does not clear that tab's `focusModeRootNodeID`.
- While focus mode is active, the visible root must always contain the tab's `focusedPanelID`.
- Validate `focusModeRootNodeID` on every render and on every focus-changing action. Treat this as a primary safety contract, not a best-effort fallback.
- Any reducer path that mutates `layoutTree`, `focusedPanelID`, or `selectedTabID` must either preserve that contract or repair `focusModeRootNodeID` before committing workspace state. This is not limited to the explicit focus-mode actions.
- If the stored root no longer resolves, fall back to the currently focused slot as the new root. If the focused slot cannot be resolved either, exit focus mode for that tab.
- The "visible root contains focused panel" rule applies to all focus changes, not just split navigation. Jumps, plain panel focus, and close-follow-up focus resolution must all preserve visibility.

### State Repair vs. Render Fallback

- Render-time fallback is **read-only**. The renderer may choose an effective root for the current frame, but it does not mutate `focusModeRootNodeID`.
- Reducers must use the same root-resolution helper before committing state so persisted runtime state converges back to the effective root instead of drifting behind the UI.
- `Jump to Next Unread or Active` keeps its existing target-resolution order. The visibility fix is downstream of target resolution: once `.focusPanel(...)` selects a panel, focus-mode state must ensure that panel is visible.

### Visual treatment

- The primary persistent status indicators are:
  - an explicit `Focused` pill/badge in the tab strip
  - a thin accent border or halo around the visible focused subtree / viewport
- The border wraps the rendered focus root, not individual panels. This keeps the treatment valid once focus mode can show multiple panels.
- Keep the existing focus-mode header button as the control for entering/exiting the mode, but do not rely on its state change as the only status signal.
- Do not add more focus-mode-specific chrome to panel headers. Panel headers already encode focused, unread, and session-status state, and adding another treatment there risks visual overload.
- The tab-strip indicator must be visible on background tabs so switching away and back still makes it obvious which tab is focused.

### Motion

- Animate focus chrome, not terminal content.
- On entering focus mode or retargeting the focus root, briefly animate the focus border/halo in with a short settle. A subtle accent wash inside the viewport is acceptable if it stays brief.
- Do not animate a large content zoom. It is harder to make feel crisp on terminal surfaces and becomes less legible once the focused root can be a multi-panel subtree.
- Do not replay the full animation on ordinary tab re-selection. A passive border + tab pill should carry the steady-state affordance. Only focus entry or focus-root retarget should animate.
- Respect macOS reduced-motion settings. In reduced-motion mode, update the focus border and badge immediately with no scale or pulse animation.

### Jump To Next Unread Or Active

- Keep the existing target-resolution order. The command still resolves "which panel should be focused next" the same way it does today.
- The command does **not** create a separate global focus/inspection mode spanning multiple tabs.
- If the destination tab is not already in focus mode, just focus the target panel. Do not auto-enter focus mode.
- If the destination tab is already in focus mode and the target panel is inside the current focused subtree, keep the existing `focusModeRootNodeID`.
- If the destination tab is already in focus mode and the target panel would be hidden by the current root, retarget that tab's `focusModeRootNodeID` to the target panel's slot ID so the target is visible immediately.
- Do not skip an otherwise valid destination just because it is outside the current focused subtree. Visibility repair happens after target selection, not by changing the target-selection algorithm.
- When jumping away from a focused tab, keep the source tab's existing focus root unchanged. The destination tab decides its own visibility independently.

---

## File Changes

### 1. `Sources/Core/LayoutNode.swift`

Add three Phase 1 methods, a tracked-removal result, and one Phase 2 method:

```swift
/// Find a subtree by its root node ID (slot ID or split node ID).
func findSubtree(nodeID: UUID) -> LayoutNode?

/// Replace any node (slot or split) by its ID.
mutating func replaceNode(nodeID: UUID, with replacement: LayoutNode) -> Bool

struct PanelRemovalResult {
    let node: LayoutNode?
    let removed: Bool
    let trackedAncestorReplacementNodeID: UUID?
}

/// Remove a panel and, if requested, report which node replaced the tracked ancestor.
func removingPanel(_ panelID: UUID, trackingAncestorNodeID: UUID?) -> PanelRemovalResult

/// Phase 2: find the lowest common ancestor node ID containing all specified slot IDs.
/// Returns nil if any slot ID is not found in the tree.
func lowestCommonAncestor(containing slotIDs: Set<UUID>) -> UUID?
```

`findSubtree` walks the tree depth-first and returns the node whose ID matches (slot's `slotID` or split's `nodeID`). `replaceNode` is like `replaceSlot` but works on split nodes too.

`removingPanel(_:trackingAncestorNodeID:)` is the Phase 1 close-path bookkeeping primitive. When the tracked ancestor survives, `trackedAncestorReplacementNodeID` stays equal to that ancestor ID. When that ancestor collapses away because one of its descendants was removed, the result reports the surviving node/slot ID that replaced it. If the whole tab disappears, the replacement ID is `nil`.

`lowestCommonAncestor` is only needed for Phase 2.

### 2. `Sources/Core/WorkspaceSplitTree.swift`

**Replace `splitting()` with a result that reports the new split node ID:**

```swift
public struct SplitMutationResult: Equatable, Sendable {
    let tree: WorkspaceSplitTree
    let newSplitNodeID: UUID
}

public func splitting(
    slotID: UUID,
    direction: SlotSplitDirection,
    newPanelID: UUID,
    newSlotID: UUID
) -> SplitMutationResult?
```

This keeps split-node identity generation inside the tree layer while still letting the reducer update `focusModeRootNodeID` when the current root slot is replaced by a new split.

**Add a root-resolution helper:**

```swift
public func effectiveFocusModeRootNodeID(
    preferredRootNodeID: UUID?,
    focusedPanelID: UUID?
) -> UUID?
```

If the preferred root resolves and contains the focused panel, return it. Otherwise fall back to the focused slot ID. If the focused slot cannot be resolved, return `nil`.

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

- Resolve an effective render root via `effectiveFocusModeRootNodeID(...)`
- If the stored root is stale or no longer contains the focused panel, render from the focused slot for this frame only
- If the focused slot cannot be resolved, return the full layout and let the reducer clear focus mode on the next state mutation
- Use the effective rendered root as `zoomedNodeID` in the render identity so the UI can key focus-border animation off root changes

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
- Add helper(s) that answer whether a panel is inside the current focus root, apply `effectiveFocusModeRootNodeID(...)`, and repair `focusModeRootNodeID` after any layout/focus mutation before state is committed
- Add a `focusedPanelIDAfterClosing` variant or parameter that scopes `.previous` slot lookup to the focused subtree during focus mode

### 6. `Sources/Core/AppReducer.swift`

**Phase 1**

**`toggleFocusedPanelMode`:**

- When toggling ON from normal mode, require that the focused panel resolves to a live slot and set `focusModeRootNodeID` to that slot ID
- When toggling OFF, set `focusModeRootNodeID` to `nil`

**`focusPanel`:**

- Keep selecting the destination tab as today
- If the destination tab is not in focus mode, update `focusedPanelID` only
- If the destination tab is in focus mode, ensure the target panel is visible:
  - if the target panel is already inside the current focused subtree, keep the current `focusModeRootNodeID`
  - if the target panel is outside the current focused subtree, retarget `focusModeRootNodeID` to the target panel's slot ID instead of exiting focus mode
- This is the core fix for `Jump to Next Unread or Active`, because that command already flows through `.focusPanel(...)`
- This retargeting rule applies to successful focus changes that would otherwise leave the focused panel hidden. It is a visibility repair step, not a change to how the target panel is chosen.

**`splitFocusedSlot`:**

- Remove the `focusedPanelModeActive == false` guard
- Use the `SplitMutationResult` returned from `splitting()`
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
- Call `removingPanel(_:trackingAncestorNodeID:)`, passing the current `focusModeRootNodeID` when focus mode is active
- After removal, if the tracked root still exists, keep it
- If it collapsed away, retarget `focusModeRootNodeID` to `trackedAncestorReplacementNodeID`
- If the focused subtree collapses to a single slot, `focusModeRootNodeID` becomes that slot ID
- If the tab/workspace is removed, focus mode exits naturally
- Focus resolution should prefer panels within the focused subtree
- If there is no tracked replacement because the whole tab was removed, focus mode exits with the tab/workspace removal path

**Phase 2**

**`toggleFocusedPanelMode`:**

- When toggling ON with `selectedPanelIDs` non-empty, compute the LCA of the selected panels
- If the LCA is a proper subtree, set `focusModeRootNodeID` to that LCA node ID and clear `selectedPanelIDs`
- If the LCA is the workspace root, leave focus mode off and preserve `selectedPanelIDs` so the user can refine the selection

**`focusPanel`:**

- Plain `.focusPanel(...)` clears `selectedPanelIDs`
- Any programmatic focus change that resolves through `.focusPanel(...)` also clears `selectedPanelIDs`

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
- Add the persistent focus-mode viewport treatment: a thin accent border / halo around the rendered focus root
- Add an explicit `Focused` pill/badge in the tab strip for tabs whose `focusedPanelModeActive` is true
- Animate the focus chrome when `zoomedNodeID` changes because of focus entry or focus-root retarget
- Do not replay the full animation on ordinary tab switching back to an already-focused tab
- Keep the existing header toggle button, but do not add extra panel-header-specific focus-mode styling

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

Rename `zoomedSlotID` to `zoomedNodeID` because the focused root can now be a split node as well as a slot node. The UI should also treat `zoomedNodeID` changes as the source of truth for focus-border animation triggers.

---

## Edge Cases

### Phase 1

1. **First split in focus mode:** `focusModeRootNodeID` starts as a slot ID. After the split, it becomes the new split node ID. Both panels render.
2. **Multiple splits in focus mode:** only a split that replaces the current focus root changes `focusModeRootNodeID`; later descendant splits stay inside the subtree.
3. **Close last-but-one panel in focused subtree:** the subtree collapses from a split to a single slot. `focusModeRootNodeID` becomes that remaining slot ID.
4. **Close all panels in focused subtree:** the tab/workspace is removed and focus mode exits naturally.
5. **Toggle focus off after splits:** `focusModeRootNodeID` is cleared and the full tree renders with the updated subtree in place.
6. **Toggle focus back on:** `focusModeRootNodeID` is set from the current focused slot. There is no memory of the previously zoomed subtree.
7. **`focusModeRootNodeID` becomes stale:** defensively fall back to single-slot rendering if `findSubtree` returns `nil`.
8. **Tab switching during focus mode:** tab A can stay focused while tab B shows its normal full layout. Switching back restores tab A's focused subtree.
9. **Direct focus change to a hidden panel while focus mode is active:** retarget `focusModeRootNodeID` to the target panel's slot ID instead of silently hiding the target or exiting focus mode.
10. **Jump to next unread or active lands on another tab that is not in focus mode:** focus the target panel but do not auto-enter focus mode on that tab.
11. **Jump back to a tab that is already in focus mode:** keep that tab's existing root if it already contains the target; otherwise retarget the root and pulse the focus border.
12. **Returning to an already-focused tab through ordinary tab switching:** show the passive border + tab badge only; do not replay the full focus-entry animation.
13. **Reduced-motion enabled:** show the focused border + tab badge immediately with no pulse or transition.

### Phase 2

14. **Multi-panel selection + focus:** selected panels focus the minimal subtree containing them, not an arbitrary cherry-picked set of leaves.
15. **Selection whose LCA is the workspace root:** do not activate focus mode, because no subtree would be hidden. Leave the staged selection intact so the user can refine it.
16. **Selection cleared by normal focus work:** if the user stages a selection, then plain-clicks a panel, uses pane navigation, or focus moves after close, the staged selection is cleared.
17. **Tab switch clears staged selection:** multi-selection should not survive leaving the tab and returning later.
18. **Selected panel closes before focus entry:** remove it from `selectedPanelIDs`; if the set empties, staged multi-selection is gone.

---

## Tests

### `WorkspaceSplitTreeTests.swift`

- `renderedLayoutShowsSubtreeAfterSplitInFocusMode`
- `renderedLayoutFallsBackToSlotWhenFocusModeRootIDIsStale`
- `renderedLayoutFallsBackToFocusedSlotWhenFocusedPanelLeavesFocusedRoot`
- `effectiveFocusModeRootNodeIDPrefersTrackedRootWhenItStillContainsFocus`
- `effectiveFocusModeRootNodeIDFallsBackToFocusedSlotWhenTrackedRootIsInvalid`
- `focusTargetInFocusModeWrapsWithinSubtree`
- `splittingReturnsNewSplitNodeID`
- `equalizeInFocusModeOnlyScopesToSubtree`
- `resizeInFocusModeStopsAtSubtreeBoundary`
- `removingPanelReportsTrackedAncestorReplacementNodeIDAfterCollapse`

### `AppReducerTests.swift`

**Phase 1**

- `splitInFocusModeUpdatesFocusModeRootNodeID`
- `splitInFocusModeOnlyPromotesRootWhenCurrentRootNodeIsReplaced`
- `focusNavigationInFocusModeStaysInSubtree`
- `resizeInFocusModeOnlyMutatesFocusedSubtree`
- `equalizeInFocusModeOnlyMutatesFocusedSubtree`
- `closePanelInFocusModeCollapsesSubtree`
- `closePanelInFocusModeRetargetsRootUsingTrackedReplacementNodeID`
- `toggleFocusOffClearsRootNodeID`
- `reenterFocusModeResetsToSingleSlot`
- `focusPanelInFocusModePreservesRootWhenTargetRemainsVisible`
- `focusPanelInFocusModeRetargetsRootWhenTargetWouldBeHidden`
- `toggleFocusModeRequiresResolvableFocusedSlot`
- `layoutMutationsRepairFocusModeRootBeforeCommittingState`

Replace the current "blocked while focused mode active" tests for split/resize/equalize with positive coverage for the new behavior.

**Phase 2**

- `multiPanelSelectionFocusUsesLCA`
- `multiPanelSelectionDoesNotEnterFocusModeWhenLCAIsWorkspaceRoot`
- `multiPanelSelectionClearedOnFocusEntry`
- `plainFocusPanelClearsMultiSelection`
- `focusNavigationClearsMultiSelection`
- `tabSwitchClearsMultiSelection`
- `closeSelectedPanelClearsItFromMultiSelection`

### `WindowCommandControllerTests.swift`

- `canAdjustSplitLayoutInFocusModeWhenFocusedSubtreeHasMultipleSlots`
- `canAdjustSplitLayoutInFocusModeReturnsFalseForSingleSlotSubtree`

### `AppStoreWindowSelectionTests.swift`

- `focusNextUnreadOrActiveRetargetsDestinationFocusRootWhenNeeded`
- `focusNextUnreadOrActivePreservesDestinationRootWhenTargetAlreadyVisible`
- `focusNextUnreadOrActiveDoesNotAutoEnterFocusModeOnNormalDestinationTab`
- `focusNextUnreadOrActivePreservesSourceTabFocusRoot`

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
   - Confirm the focused viewport gets the persistent border / halo and the tab gets the `Focused` pill
   - Split horizontally and vertically within focus mode
   - Navigate between visible panels
   - Resize a divider within the focused subtree
   - Equalize splits within the focused subtree
   - Close a panel within the focused subtree
   - Toggle focus off and confirm the subtree appears in the right place in the full layout
   - Toggle focus back on and confirm it resets to the current focused panel only
   - Switch away from a focused tab and back again and confirm the passive indicators remain visible without replaying the full animation
   - Trigger `Jump to Next Unread or Active` from a focused tab and verify the destination panel is always visible
   - Verify that a jump into a non-focused tab does not auto-enter focus mode
   - Verify that a jump into an already-focused tab retargets the root only when needed and replays the border pulse only for that retarget
   - With reduced motion enabled, verify the indicator updates immediately with no pulse/settle animation

### Phase 2

1. Shift-click two or more panels to stage a selection
2. Enter focus mode and verify the visible subtree is the LCA subtree
3. Select panels whose LCA is the whole workspace and verify focus mode does not activate
4. Plain-click another panel and verify the staged selection clears
5. Switch tabs and verify staged selection clears

---

## Implementation Order

### Phase 1

1. `LayoutNode` additions needed for subtree lookup/replacement: `findSubtree`, `replaceNode`
2. `LayoutNode.removingPanel(_:trackingAncestorNodeID:)` so close-path root retargeting is explicit instead of inferred
3. `WorkspaceSplitTree` changes: split result plumbing, effective-root resolution, subtree rendering, `focusedSubtree`
4. `WorkspaceTabState` / `WorkspaceState` / `WorkspaceState+Layout` plumbing for `focusModeRootNodeID`
5. `AppReducer` Phase 1 changes: split/focus/resize/equalize/close within focused subtree, plus the "focused panel must stay visible" invariant for `.focusPanel(...)`
6. `WorkspaceView` and `WindowCommandController` updates for the newly enabled behavior and the persistent focus-mode affordance
7. Rename `zoomedSlotID` to `zoomedNodeID`
8. Phase 1 tests, including jump-to-next-unread-or-active coverage and root-repair coverage
9. Build, smoke automation, and manual validation

### Phase 2

1. Add `selectedPanelIDs`
2. Add `lowestCommonAncestor(containing:)`
3. Reducer support for staged selection and LCA-based focus entry
4. `WorkspaceView` shift-click interaction and selection styling
5. Phase 2 tests

### Later Follow-Up

Design aux-panel UX and layout behavior separately, then integrate it with the generic focused-subtree machinery from Phase 1.
