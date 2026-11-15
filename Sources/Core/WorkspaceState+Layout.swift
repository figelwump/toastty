import Foundation

public extension WorkspaceState {
    var renderedLayout: WorkspaceRenderedLayout {
        splitTree.renderedLayout(
            workspaceID: id,
            focusedPanelModeActive: focusedPanelModeActive,
            focusedPanelID: focusedPanelID,
            focusModeRootNodeID: focusModeRootNodeID
        )
    }

    var effectiveFocusModeRootNodeID: UUID? {
        guard focusedPanelModeActive else { return nil }
        return splitTree.effectiveFocusModeRootNodeID(
            preferredRootNodeID: focusModeRootNodeID,
            focusedPanelID: focusedPanelID
        )
    }

    var focusModeSubtree: WorkspaceSplitTree? {
        guard let effectiveFocusModeRootNodeID else { return nil }
        return splitTree.focusedSubtree(rootNodeID: effectiveFocusModeRootNodeID)
    }

    func panelIsVisibleInFocusMode(_ panelID: UUID) -> Bool {
        guard focusedPanelModeActive else { return true }
        guard let effectiveFocusModeRootNodeID,
              let subtree = layoutTree.findSubtree(nodeID: effectiveFocusModeRootNodeID) else {
            return false
        }
        return subtree.slotContaining(panelID: panelID) != nil
    }

    /// Whether the selected tab currently draws this panel's content: it is the
    /// active tab of the open right panel outside focus mode, or a split slot focus
    /// mode does not hide. Callers decide separately whether this workspace is the
    /// one on screen.
    func panelIsDisplayedInSelectedTab(_ panelID: UUID) -> Bool {
        if rightAuxPanel.activePanelID == panelID {
            // Focus mode keeps `isVisible` but stops drawing the right panel's content.
            return rightAuxPanel.isVisible && focusedPanelModeActive == false
        }
        return layoutTree.slotContaining(panelID: panelID) != nil &&
            panelIsVisibleInFocusMode(panelID)
    }

    /// The right panel's active panel, when Select Next Split and Select
    /// Previous Split can reach it: the right panel is open and focus mode
    /// is off.
    var focusableRightAuxPanelID: UUID? {
        guard focusedPanelModeActive == false,
              rightAuxPanel.isVisible,
              let activePanelID = rightAuxPanel.activePanelID else {
            return nil
        }
        return activePanelID
    }

    /// The stops of Select Next Split and Select Previous Split, in order:
    /// the panels of the visible layout, then the right panel's active
    /// panel. The commands wrap around at either end.
    var panelFocusCycle: [PanelFocusCycleTarget] {
        let visibleRoot = focusModeSubtree?.root ?? layoutTree
        var targets = visibleRoot.allSlotInfos.compactMap { slot -> PanelFocusCycleTarget? in
            guard panels[slot.panelID] != nil else {
                return nil
            }
            return .mainPanel(slot.panelID)
        }
        if let rightAuxPanelID = focusableRightAuxPanelID,
           targets.contains(.rightAuxPanel(rightAuxPanelID)) == false {
            targets.append(.rightAuxPanel(rightAuxPanelID))
        }
        return targets
    }

    /// The stop of `panelFocusCycle` that has focus now. `nil` when no
    /// panel of the layout can take focus.
    var currentPanelFocusCycleTarget: PanelFocusCycleTarget? {
        guard let resolution = resolvedFocusedPanel else {
            return nil
        }
        if let rightAuxPanelID = focusableRightAuxPanelID,
           rightAuxPanel.focusedPanelID == rightAuxPanelID {
            return .rightAuxPanel(rightAuxPanelID)
        }
        return .mainPanel(resolution.panelID)
    }
}

/// A stop of Select Next Split and Select Previous Split.
public enum PanelFocusCycleTarget: Equatable, Sendable {
    /// A panel in the workspace's split layout.
    case mainPanel(UUID)
    /// The active panel of the workspace's right panel.
    case rightAuxPanel(UUID)

    public var panelID: UUID {
        switch self {
        case .mainPanel(let panelID), .rightAuxPanel(let panelID):
            return panelID
        }
    }
}

extension WorkspaceState {
    @discardableResult
    mutating func synchronizeFocusedPanelToLayout() -> WorkspaceSplitTree.FocusedPanelResolution? {
        guard let resolution = resolvedFocusedPanel else {
            return nil
        }
        focusedPanelID = resolution.panelID
        return resolution
    }

    mutating func apply(splitTree: WorkspaceSplitTree) {
        layoutTree = splitTree.root
    }

    func focusTargetSlotID(from sourceSlotID: UUID, direction: SlotFocusDirection) -> UUID? {
        splitTree.focusTarget(from: sourceSlotID, direction: direction)
    }

    func focusTargetSlotIDWithinVisibleRoot(
        from sourceSlotID: UUID,
        direction: SlotFocusDirection
    ) -> UUID? {
        let scopedTree = focusModeSubtree ?? splitTree
        return scopedTree.focusTarget(from: sourceSlotID, direction: direction)
    }

    func panelID(forSlotID slotID: UUID) -> UUID? {
        splitTree.panelID(for: slotID, livePanelIDs: livePanelIDs)
    }

    func insertionSlotID(preferred preferredSlotID: UUID?) -> UUID? {
        if let preferredSlotID {
            guard contains(slotID: preferredSlotID) else {
                return nil
            }
            return preferredSlotID
        }

        if let focusedPanelID,
           let focusedSlot = layoutTree.slotContaining(panelID: focusedPanelID) {
            return focusedSlot.slotID
        }

        return layoutTree.allSlotInfos.first?.slotID
    }

    func reopenSlotID(preferred preferredSlotID: UUID) -> UUID? {
        if contains(slotID: preferredSlotID) {
            return preferredSlotID
        }
        if let focusedPanelID,
           let focusedSlot = layoutTree.slotContaining(panelID: focusedPanelID) {
            return focusedSlot.slotID
        }
        return layoutTree.allSlotInfos.first?.slotID
    }

    func focusedPanelIDAfterClosing(
        closedPanelID: UUID,
        closedPanelWasFocused: Bool,
        previousSlotIDBeforeRemoval: UUID?
    ) -> UUID? {
        guard closedPanelWasFocused else {
            return resolvedFocusedPanel?.panelID
        }

        if let focusedPanelID,
           focusedPanelID != closedPanelID,
           panels[focusedPanelID] != nil,
           layoutTree.slotContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        if let previousSlotIDBeforeRemoval,
           let selectedPreviousPanelID = panelID(forSlotID: previousSlotIDBeforeRemoval) {
            return selectedPreviousPanelID
        }

        return resolvedFocusedPanel?.panelID
    }

    mutating func repairTransientTabState() {
        for tabID in tabIDs {
            guard var tab = tabsByID[tabID] else { continue }
            tab.rightAuxPanel.repairTransientState()

            let livePanelIDs = Set(tab.panels.keys)
            let liveUnreadPanelIDs = livePanelIDs.union(tab.rightAuxPanel.panelIDs)
            if let focusedPanelID = tab.focusedPanelID,
               tab.panels[focusedPanelID] == nil || tab.layoutTree.slotContaining(panelID: focusedPanelID) == nil {
                tab.focusedPanelID = tab.resolvedFocusedPanelID
            } else if tab.focusedPanelID == nil {
                tab.focusedPanelID = tab.resolvedFocusedPanelID
            }

            tab.selectedPanelIDs.formIntersection(livePanelIDs)
            tab.unreadPanelIDs.formIntersection(liveUnreadPanelIDs)

            if tab.focusedPanelModeActive {
                let effectiveRootNodeID = WorkspaceSplitTree(root: tab.layoutTree).effectiveFocusModeRootNodeID(
                    preferredRootNodeID: tab.focusModeRootNodeID,
                    focusedPanelID: tab.focusedPanelID
                )
                if let effectiveRootNodeID {
                    tab.focusModeRootNodeID = effectiveRootNodeID
                } else {
                    tab.focusedPanelModeActive = false
                    tab.focusModeRootNodeID = nil
                }
            } else {
                tab.focusModeRootNodeID = nil
            }

            tabsByID[tabID] = tab
        }
    }
}

extension WorkspaceTabState {
    func reopenSlotID(preferred preferredSlotID: UUID) -> UUID? {
        if layoutTree.slotNode(slotID: preferredSlotID) != nil {
            return preferredSlotID
        }
        if let focusedPanelID,
           let focusedSlot = layoutTree.slotContaining(panelID: focusedPanelID) {
            return focusedSlot.slotID
        }
        return layoutTree.allSlotInfos.first?.slotID
    }
}

private extension WorkspaceState {
    var livePanelIDs: Set<UUID> {
        Set(panels.keys)
    }

    var splitTree: WorkspaceSplitTree {
        WorkspaceSplitTree(root: layoutTree)
    }

    var resolvedFocusedPanel: WorkspaceSplitTree.FocusedPanelResolution? {
        splitTree.resolveFocusedPanel(
            preferredFocusedPanelID: focusedPanelID,
            livePanelIDs: livePanelIDs
        )
    }

    func contains(slotID: UUID) -> Bool {
        layoutTree.allSlotInfos.contains(where: { $0.slotID == slotID })
    }
}
