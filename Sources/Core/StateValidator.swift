import Foundation

public enum StateInvariantViolation: Error, Equatable, Sendable {
    case missingWorkspace(windowID: UUID, workspaceID: UUID)
    case selectedWorkspaceMissing(windowID: UUID, workspaceID: UUID)
    case workspaceInMultipleWindows(workspaceID: UUID)
    case workspaceWithoutWindow(workspaceID: UUID)
    case splitRatioOutOfBounds(workspaceID: UUID, nodeID: UUID, ratio: Double)
    case emptySlotLeaf(workspaceID: UUID, slotID: UUID)
    case missingPanel(workspaceID: UUID, panelID: UUID)
    case panelMissingFromLayoutTree(workspaceID: UUID, panelID: UUID)
    case panelReferencedMultipleTimes(workspaceID: UUID, panelID: UUID)
    case focusedPanelMissing(workspaceID: UUID, panelID: UUID)
    case focusedPanelNotInLayoutTree(workspaceID: UUID, panelID: UUID)
    case unreadPanelMissing(workspaceID: UUID, panelID: UUID)
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
            let nodeIDs = workspace.layoutTree.allNodeIDs
            if let duplicate = firstDuplicate(in: nodeIDs) {
                throw StateInvariantViolation.duplicateNodeID(workspaceID: workspace.id, nodeID: duplicate)
            }

            for split in workspace.layoutTree.allSplitInfos {
                if split.ratio <= 0 || split.ratio >= 1 {
                    throw StateInvariantViolation.splitRatioOutOfBounds(
                        workspaceID: workspace.id,
                        nodeID: split.nodeID,
                        ratio: split.ratio
                    )
                }
            }

            var panelLayoutCounts: [UUID: Int] = [:]

            for leaf in workspace.layoutTree.allSlotInfos {
                guard workspace.panels[leaf.panelID] != nil else {
                    throw StateInvariantViolation.missingPanel(workspaceID: workspace.id, panelID: leaf.panelID)
                }
                panelLayoutCounts[leaf.panelID, default: 0] += 1
            }

            for panelID in workspace.panels.keys {
                let count = panelLayoutCounts[panelID, default: 0]
                if count == 0 {
                    throw StateInvariantViolation.panelMissingFromLayoutTree(workspaceID: workspace.id, panelID: panelID)
                }
                if count > 1 {
                    throw StateInvariantViolation.panelReferencedMultipleTimes(workspaceID: workspace.id, panelID: panelID)
                }
            }

            for unreadPanelID in workspace.unreadPanelIDs where workspace.panels[unreadPanelID] == nil {
                throw StateInvariantViolation.unreadPanelMissing(workspaceID: workspace.id, panelID: unreadPanelID)
            }

            if let focusedPanelID = workspace.focusedPanelID {
                guard workspace.panels[focusedPanelID] != nil else {
                    throw StateInvariantViolation.focusedPanelMissing(workspaceID: workspace.id, panelID: focusedPanelID)
                }

                guard workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil else {
                    throw StateInvariantViolation.focusedPanelNotInLayoutTree(workspaceID: workspace.id, panelID: focusedPanelID)
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
