import CoreState
import Foundation
import Testing

struct WorkspaceSplitTreeTests {
    @Test
    func resolveFocusedPanelSkipsMissingPanelsInLayoutOrder() throws {
        let missingPanelID = UUID()
        let livePanelID = UUID()
        let missingSlotID = UUID()
        let liveSlotID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: missingSlotID, panelID: missingPanelID),
                second: .slot(slotID: liveSlotID, panelID: livePanelID)
            )
        )

        let resolution = try #require(
            tree.resolveFocusedPanel(
                preferredFocusedPanelID: UUID(),
                livePanelIDs: [livePanelID]
            )
        )

        #expect(resolution.panelID == livePanelID)
        #expect(resolution.slot == SlotInfo(slotID: liveSlotID, panelID: livePanelID))
    }

    @Test
    func renderedLayoutShowsTrackedSubtreeWhenFocusedPanelModeIsActive() {
        let workspaceID = UUID()
        let leftPanelID = UUID()
        let topRightPanelID = UUID()
        let bottomRightPanelID = UUID()
        let leftSlotID = UUID()
        let topRightSlotID = UUID()
        let bottomRightSlotID = UUID()
        let rightBranchNodeID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .split(
                    nodeID: rightBranchNodeID,
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: topRightSlotID, panelID: topRightPanelID),
                    second: .slot(slotID: bottomRightSlotID, panelID: bottomRightPanelID)
                )
            )
        )

        let renderedLayout = tree.renderedLayout(
            workspaceID: workspaceID,
            focusedPanelModeActive: true,
            focusedPanelID: bottomRightPanelID,
            focusModeRootNodeID: rightBranchNodeID
        )

        #expect(renderedLayout.identity == WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedNodeID: rightBranchNodeID))
        let projection = renderedLayout.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 100, height: 80)
        )
        #expect(Set(projection.slots.map(\.slotID)) == Set([topRightSlotID, bottomRightSlotID]))
        #expect(projection.dividers.count == 1)
    }

    @Test
    func renderedLayoutUsesFullTreeWhenFocusedPanelModeIsDisabled() {
        let workspaceID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let root = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: leftPanelID),
            second: .slot(slotID: UUID(), panelID: rightPanelID)
        )
        let tree = WorkspaceSplitTree(root: root)

        let renderedLayout = tree.renderedLayout(
            workspaceID: workspaceID,
            focusedPanelModeActive: false,
            focusedPanelID: UUID(),
            focusModeRootNodeID: nil
        )

        #expect(renderedLayout.identity == WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedNodeID: nil))
        #expect(renderedLayout.layoutTree == root)
    }

    @Test
    func renderedLayoutFallsBackToFullTreeWhenFocusedPanelModeHasNoFocusedPanel() {
        let workspaceID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let root = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: leftPanelID),
            second: .slot(slotID: UUID(), panelID: rightPanelID)
        )
        let tree = WorkspaceSplitTree(root: root)

        let renderedLayout = tree.renderedLayout(
            workspaceID: workspaceID,
            focusedPanelModeActive: true,
            focusedPanelID: nil,
            focusModeRootNodeID: UUID()
        )

        #expect(renderedLayout.identity == WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedNodeID: nil))
        #expect(renderedLayout.layoutTree == root)
    }

    @Test
    func renderedLayoutFallsBackToFocusedSlotWhenFocusModeRootIDIsStale() {
        let workspaceID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            )
        )

        let renderedLayout = tree.renderedLayout(
            workspaceID: workspaceID,
            focusedPanelModeActive: true,
            focusedPanelID: rightPanelID,
            focusModeRootNodeID: UUID()
        )

        #expect(renderedLayout.identity == WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedNodeID: rightSlotID))
        #expect(renderedLayout.layoutTree == .slot(slotID: rightSlotID, panelID: rightPanelID))
    }

    @Test
    func renderedLayoutFallsBackToFocusedSlotWhenFocusedPanelLeavesTrackedRoot() {
        let workspaceID = UUID()
        let topLeftSlotID = UUID()
        let bottomLeftSlotID = UUID()
        let rightSlotID = UUID()
        let topLeftPanelID = UUID()
        let bottomLeftPanelID = UUID()
        let rightPanelID = UUID()
        let leftBranchNodeID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .split(
                    nodeID: leftBranchNodeID,
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: topLeftSlotID, panelID: topLeftPanelID),
                    second: .slot(slotID: bottomLeftSlotID, panelID: bottomLeftPanelID)
                ),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            )
        )

        let renderedLayout = tree.renderedLayout(
            workspaceID: workspaceID,
            focusedPanelModeActive: true,
            focusedPanelID: rightPanelID,
            focusModeRootNodeID: leftBranchNodeID
        )

        #expect(renderedLayout.identity == WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedNodeID: rightSlotID))
        #expect(renderedLayout.layoutTree == .slot(slotID: rightSlotID, panelID: rightPanelID))
    }

    @Test
    func effectiveFocusModeRootNodeIDPrefersTrackedRootWhenItStillContainsFocus() {
        let trackedRootNodeID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: UUID()),
                second: .split(
                    nodeID: trackedRootNodeID,
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: UUID(), panelID: UUID()),
                    second: .slot(slotID: UUID(), panelID: UUID())
                )
            )
        )
        let focusedPanelID = tree.root.allSlotInfos.last?.panelID

        #expect(
            tree.effectiveFocusModeRootNodeID(
                preferredRootNodeID: trackedRootNodeID,
                focusedPanelID: focusedPanelID
            ) == trackedRootNodeID
        )
    }

    @Test
    func focusTargetWrapsForPreviousAndNextTraversal() {
        let firstSlotID = UUID()
        let secondSlotID = UUID()
        let thirdSlotID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: firstSlotID, panelID: UUID()),
                second: .split(
                    nodeID: UUID(),
                    orientation: .horizontal,
                    ratio: 0.5,
                    first: .slot(slotID: secondSlotID, panelID: UUID()),
                    second: .slot(slotID: thirdSlotID, panelID: UUID())
                )
            )
        )

        #expect(tree.focusTarget(from: firstSlotID, direction: .previous) == thirdSlotID)
        #expect(tree.focusTarget(from: thirdSlotID, direction: .next) == firstSlotID)
    }

    @Test
    func focusTargetWrapsWithinFocusedSubtree() throws {
        let leftSlotID = UUID()
        let topRightSlotID = UUID()
        let bottomRightSlotID = UUID()
        let rightBranchNodeID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: UUID()),
                second: .split(
                    nodeID: rightBranchNodeID,
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: topRightSlotID, panelID: UUID()),
                    second: .slot(slotID: bottomRightSlotID, panelID: UUID())
                )
            )
        )

        let focusedSubtree = try #require(tree.focusedSubtree(rootNodeID: rightBranchNodeID))
        #expect(focusedSubtree.focusTarget(from: topRightSlotID, direction: .previous) == bottomRightSlotID)
        #expect(focusedSubtree.focusTarget(from: bottomRightSlotID, direction: .next) == topRightSlotID)
    }

    @Test
    func directionalFocusPrefersAlignedNeighborInMixedSplitLayout() {
        let leftSlotID = UUID()
        let topRightSlotID = UUID()
        let bottomRightSlotID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: UUID()),
                second: .split(
                    nodeID: UUID(),
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: topRightSlotID, panelID: UUID()),
                    second: .slot(slotID: bottomRightSlotID, panelID: UUID())
                )
            )
        )

        #expect(tree.focusTarget(from: bottomRightSlotID, direction: .up) == topRightSlotID)
        #expect(tree.focusTarget(from: topRightSlotID, direction: .down) == bottomRightSlotID)
        #expect(tree.focusTarget(from: topRightSlotID, direction: .left) == leftSlotID)
        #expect(tree.focusTarget(from: bottomRightSlotID, direction: .left) == leftSlotID)
    }

    @Test
    func splittingPlacesNewLeafOnRequestedSideAndReturnsNewSplitNodeID() throws {
        let sourcePanelID = UUID()
        let sourceSlotID = UUID()
        let baseTree = WorkspaceSplitTree(
            root: .slot(slotID: sourceSlotID, panelID: sourcePanelID)
        )
        let expectations: [(direction: SlotSplitDirection, orientation: SplitOrientation, newPanelFirst: Bool)] = [
            (.left, .horizontal, true),
            (.right, .horizontal, false),
            (.up, .vertical, true),
            (.down, .vertical, false),
        ]

        for expectation in expectations {
            let newPanelID = UUID()
            let newSlotID = UUID()
            let splitResult = try #require(
                baseTree.splitting(
                    slotID: sourceSlotID,
                    direction: expectation.direction,
                    newPanelID: newPanelID,
                    newSlotID: newSlotID
                )
            )

            guard case .split(let newSplitNodeID, let orientation, _, let first, let second) = splitResult.tree.root,
                  case .slot(let firstSlotID, let firstPanelID) = first,
                  case .slot(let secondSlotID, let secondPanelID) = second else {
                Issue.record("expected single-slot tree to become a split for \(expectation.direction)")
                continue
            }

            #expect(splitResult.newSplitNodeID == newSplitNodeID)
            #expect(orientation == expectation.orientation)
            if expectation.newPanelFirst {
                #expect(firstSlotID == newSlotID)
                #expect(firstPanelID == newPanelID)
                #expect(secondSlotID == sourceSlotID)
                #expect(secondPanelID == sourcePanelID)
            } else {
                #expect(firstSlotID == sourceSlotID)
                #expect(firstPanelID == sourcePanelID)
                #expect(secondSlotID == newSlotID)
                #expect(secondPanelID == newPanelID)
            }
        }
    }

    @Test
    func resizedUsesNearestMatchingAncestor() throws {
        let focusedPanelID = UUID()
        let siblingPanelID = UUID()
        let rightPanelID = UUID()
        let focusedSlotID = UUID()
        let siblingSlotID = UUID()
        let rightSlotID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .split(
                    nodeID: UUID(),
                    orientation: .horizontal,
                    ratio: 0.6,
                    first: .slot(slotID: focusedSlotID, panelID: focusedPanelID),
                    second: .slot(slotID: siblingSlotID, panelID: siblingPanelID)
                ),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            )
        )

        let resizedTree = try #require(
            tree.resized(
                focusedSlotID: focusedSlotID,
                direction: .right,
                amount: 1
            )
        )

        guard case .split(_, _, let rootRatio, let firstNode, _) = resizedTree.root,
              case .split(_, _, let nestedRatio, _, _) = firstNode else {
            Issue.record("expected nested horizontal split tree after resize")
            return
        }

        #expect(rootRatio == 0.5)
        #expect(abs(nestedRatio - 0.605) < 0.0001)
    }

    @Test
    func equalizedUsesOrientationAwareWeightsForMixedTree() throws {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let extraPanelID = UUID()
        let tree = WorkspaceSplitTree(
            root: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.7,
                first: .slot(slotID: UUID(), panelID: leftPanelID),
                second: .split(
                    nodeID: UUID(),
                    orientation: .vertical,
                    ratio: 0.8,
                    first: .slot(slotID: UUID(), panelID: rightPanelID),
                    second: .slot(slotID: UUID(), panelID: extraPanelID)
                )
            )
        )

        let equalizedTree = try #require(tree.equalized())

        guard case .split(_, _, let rootRatio, _, let nestedNode) = equalizedTree.root,
              case .split(_, _, let nestedRatio, _, _) = nestedNode else {
            Issue.record("expected mixed-orientation split tree after equalize")
            return
        }

        #expect(abs(rootRatio - 0.5) < 0.0001)
        #expect(nestedRatio == 0.5)
        #expect(equalizedTree.equalized() == nil)
    }

    @Test
    func removingPanelReportsTrackedAncestorReplacementNodeIDAfterCollapse() throws {
        let removedPanelID = UUID()
        let survivingPanelID = UUID()
        let survivingSlotID = UUID()
        let trackedRootNodeID = UUID()
        let tree = LayoutNode.split(
            nodeID: trackedRootNodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: removedPanelID),
            second: .slot(slotID: survivingSlotID, panelID: survivingPanelID)
        )

        let removal = tree.removingPanel(
            removedPanelID,
            trackingAncestorNodeID: trackedRootNodeID
        )

        let updatedTree = try #require(removal.node)
        #expect(removal.removed)
        #expect(removal.trackedAncestorReplacementNodeID == survivingSlotID)
        #expect(updatedTree == .slot(slotID: survivingSlotID, panelID: survivingPanelID))
    }
}
