import Foundation

public enum StateInvariantViolation: Error, Equatable, Sendable {
    case missingWorkspace(windowID: UUID, workspaceID: UUID)
    case selectedWorkspaceMissing(windowID: UUID, workspaceID: UUID)
    case workspaceInMultipleWindows(workspaceID: UUID)
    case splitRatioOutOfBounds(workspaceID: UUID, nodeID: UUID, ratio: Double)
    case emptyPaneLeaf(workspaceID: UUID, paneID: UUID)
    case selectedIndexOutOfBounds(workspaceID: UUID, paneID: UUID, selectedIndex: Int, tabCount: Int)
    case missingPanel(workspaceID: UUID, panelID: UUID)
    case panelMissingFromPaneTree(workspaceID: UUID, panelID: UUID)
    case panelReferencedMultipleTimes(workspaceID: UUID, panelID: UUID)
    case focusedPanelMissing(workspaceID: UUID, panelID: UUID)
    case focusedPanelNotInPaneTree(workspaceID: UUID, panelID: UUID)
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

        for workspace in state.workspacesByID.values {
            let nodeIDs = workspace.paneTree.allNodeIDs
            if let duplicate = firstDuplicate(in: nodeIDs) {
                throw StateInvariantViolation.duplicateNodeID(workspaceID: workspace.id, nodeID: duplicate)
            }

            for split in workspace.paneTree.allSplitInfos {
                if split.ratio <= 0 || split.ratio >= 1 {
                    throw StateInvariantViolation.splitRatioOutOfBounds(
                        workspaceID: workspace.id,
                        nodeID: split.nodeID,
                        ratio: split.ratio
                    )
                }
            }

            var panePanelCounts: [UUID: Int] = [:]

            for leaf in workspace.paneTree.allLeafInfos {
                if leaf.tabPanelIDs.isEmpty {
                    throw StateInvariantViolation.emptyPaneLeaf(workspaceID: workspace.id, paneID: leaf.paneID)
                }

                if leaf.selectedIndex < 0 || leaf.selectedIndex >= leaf.tabPanelIDs.count {
                    throw StateInvariantViolation.selectedIndexOutOfBounds(
                        workspaceID: workspace.id,
                        paneID: leaf.paneID,
                        selectedIndex: leaf.selectedIndex,
                        tabCount: leaf.tabPanelIDs.count
                    )
                }

                for panelID in leaf.tabPanelIDs {
                    guard workspace.panels[panelID] != nil else {
                        throw StateInvariantViolation.missingPanel(workspaceID: workspace.id, panelID: panelID)
                    }
                    panePanelCounts[panelID, default: 0] += 1
                }
            }

            for panelID in workspace.panels.keys {
                let count = panePanelCounts[panelID, default: 0]
                if count == 0 {
                    throw StateInvariantViolation.panelMissingFromPaneTree(workspaceID: workspace.id, panelID: panelID)
                }
                if count > 1 {
                    throw StateInvariantViolation.panelReferencedMultipleTimes(workspaceID: workspace.id, panelID: panelID)
                }
            }

            if let focusedPanelID = workspace.focusedPanelID {
                guard workspace.panels[focusedPanelID] != nil else {
                    throw StateInvariantViolation.focusedPanelMissing(workspaceID: workspace.id, panelID: focusedPanelID)
                }

                guard workspace.paneTree.leafContaining(panelID: focusedPanelID) != nil else {
                    throw StateInvariantViolation.focusedPanelNotInPaneTree(workspaceID: workspace.id, panelID: focusedPanelID)
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
