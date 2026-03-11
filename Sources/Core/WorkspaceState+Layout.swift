import Foundation

public extension WorkspaceState {
    var renderedLayout: WorkspaceRenderedLayout {
        splitTree.renderedLayout(
            workspaceID: id,
            focusedPanelModeActive: focusedPanelModeActive,
            focusedPanelID: focusedPanelID
        )
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

    func auxiliaryColumnSlotID(for auxPanelIDs: Set<UUID>) -> UUID? {
        guard auxPanelIDs.isEmpty == false else { return nil }
        return layoutTree.allSlotInfos.last(where: { slot in
            auxPanelIDs.contains(slot.panelID)
        })?.slotID
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
