import Foundation

public enum StateInvariantViolation: Error, Equatable, Sendable {
    case missingWorkspace(windowID: UUID, workspaceID: UUID)
    case selectedWorkspaceMissing(windowID: UUID, workspaceID: UUID)
    case workspaceInMultipleWindows(workspaceID: UUID)
    case workspaceWithoutWindow(workspaceID: UUID)
    case workspaceWithoutTab(workspaceID: UUID)
    case missingTab(workspaceID: UUID, tabID: UUID)
    case selectedTabMissing(workspaceID: UUID, tabID: UUID)
    case splitRatioOutOfBounds(workspaceID: UUID, nodeID: UUID, ratio: Double)
    case emptySlotLeaf(workspaceID: UUID, slotID: UUID)
    case missingPanel(workspaceID: UUID, panelID: UUID)
    case panelMissingFromLayoutTree(workspaceID: UUID, panelID: UUID)
    case panelReferencedMultipleTimes(workspaceID: UUID, panelID: UUID)
    case focusedPanelMissing(workspaceID: UUID, panelID: UUID)
    case focusedPanelNotInLayoutTree(workspaceID: UUID, panelID: UUID)
    case unreadPanelMissing(workspaceID: UUID, panelID: UUID)
    case selectedPanelMissing(workspaceID: UUID, panelID: UUID)
    case focusModeRootMissing(workspaceID: UUID, nodeID: UUID)
    case focusModeRootDoesNotContainFocusedPanel(workspaceID: UUID, nodeID: UUID, panelID: UUID)
    case duplicateNodeID(workspaceID: UUID, nodeID: UUID)
}

public enum StateValidator {
    public static func validate(_ state: AppState) throws {
        var windowMembership: [UUID: UUID] = [:]

        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard state.workspacesByID[workspaceID] != nil else {
                    throw StateInvariantViolation.missingWorkspace(windowID: window.id, workspaceID: workspaceID)
                }

                if windowMembership[workspaceID] != nil {
                    throw StateInvariantViolation.workspaceInMultipleWindows(workspaceID: workspaceID)
                }
                windowMembership[workspaceID] = window.id
            }

            if let selectedWorkspaceID = window.selectedWorkspaceID,
               window.workspaceIDs.contains(selectedWorkspaceID) == false {
                throw StateInvariantViolation.selectedWorkspaceMissing(windowID: window.id, workspaceID: selectedWorkspaceID)
            }
        }

        for workspaceID in state.workspacesByID.keys where windowMembership[workspaceID] == nil {
            throw StateInvariantViolation.workspaceWithoutWindow(workspaceID: workspaceID)
        }

        for workspace in state.workspacesByID.values {
            guard workspace.tabIDs.isEmpty == false else {
                throw StateInvariantViolation.workspaceWithoutTab(workspaceID: workspace.id)
            }

            for tabID in workspace.tabIDs where workspace.tabsByID[tabID] == nil {
                throw StateInvariantViolation.missingTab(workspaceID: workspace.id, tabID: tabID)
            }

            if let selectedTabID = workspace.selectedTabID,
               workspace.tabIDs.contains(selectedTabID) == false {
                throw StateInvariantViolation.selectedTabMissing(workspaceID: workspace.id, tabID: selectedTabID)
            }

            let nodeIDs = workspace.orderedTabs.flatMap { $0.layoutTree.allNodeIDs }
            if let duplicate = firstDuplicate(in: nodeIDs) {
                throw StateInvariantViolation.duplicateNodeID(workspaceID: workspace.id, nodeID: duplicate)
            }

            var panelLayoutCounts: [UUID: Int] = [:]

            for tab in workspace.orderedTabs {
                for split in tab.layoutTree.allSplitInfos {
                    if split.ratio <= 0 || split.ratio >= 1 {
                        throw StateInvariantViolation.splitRatioOutOfBounds(
                            workspaceID: workspace.id,
                            nodeID: split.nodeID,
                            ratio: split.ratio
                        )
                    }
                }

                for leaf in tab.layoutTree.allSlotInfos {
                    guard tab.panels[leaf.panelID] != nil else {
                        throw StateInvariantViolation.missingPanel(workspaceID: workspace.id, panelID: leaf.panelID)
                    }
                    panelLayoutCounts[leaf.panelID, default: 0] += 1
                }

                for panelID in tab.panels.keys {
                    let count = panelLayoutCounts[panelID, default: 0]
                    if count == 0 {
                        throw StateInvariantViolation.panelMissingFromLayoutTree(workspaceID: workspace.id, panelID: panelID)
                    }
                    if count > 1 {
                        throw StateInvariantViolation.panelReferencedMultipleTimes(workspaceID: workspace.id, panelID: panelID)
                    }
                }

                for unreadPanelID in tab.unreadPanelIDs where tab.panels[unreadPanelID] == nil {
                    throw StateInvariantViolation.unreadPanelMissing(workspaceID: workspace.id, panelID: unreadPanelID)
                }

                for selectedPanelID in tab.selectedPanelIDs where tab.panels[selectedPanelID] == nil {
                    throw StateInvariantViolation.selectedPanelMissing(workspaceID: workspace.id, panelID: selectedPanelID)
                }

                if let focusedPanelID = tab.focusedPanelID {
                    guard tab.panels[focusedPanelID] != nil else {
                        throw StateInvariantViolation.focusedPanelMissing(workspaceID: workspace.id, panelID: focusedPanelID)
                    }

                    guard tab.layoutTree.slotContaining(panelID: focusedPanelID) != nil else {
                        throw StateInvariantViolation.focusedPanelNotInLayoutTree(workspaceID: workspace.id, panelID: focusedPanelID)
                    }
                }

                if let focusModeRootNodeID = tab.focusModeRootNodeID,
                   tab.layoutTree.findSubtree(nodeID: focusModeRootNodeID) == nil {
                    throw StateInvariantViolation.focusModeRootMissing(
                        workspaceID: workspace.id,
                        nodeID: focusModeRootNodeID
                    )
                }

                if tab.focusedPanelModeActive,
                   let focusedPanelID = tab.focusedPanelID,
                   let effectiveRootNodeID = WorkspaceSplitTree(root: tab.layoutTree).effectiveFocusModeRootNodeID(
                    preferredRootNodeID: tab.focusModeRootNodeID,
                    focusedPanelID: focusedPanelID
                   ) {
                    let subtree = tab.layoutTree.findSubtree(nodeID: effectiveRootNodeID)
                    if subtree?.slotContaining(panelID: focusedPanelID) == nil {
                        throw StateInvariantViolation.focusModeRootDoesNotContainFocusedPanel(
                            workspaceID: workspace.id,
                            nodeID: effectiveRootNodeID,
                            panelID: focusedPanelID
                        )
                    }
                }
            }
        }
    }

    private static func firstDuplicate<T: Hashable>(in values: [T]) -> T? {
        var seen: Set<T> = []
        for value in values {
            if seen.contains(value) {
                return value
            }
            seen.insert(value)
        }
        return nil
    }
}
