import CoreState
import Foundation
import Testing

struct PaneNodeMutationTests {
    @Test
    func removingSingleLeafPanelRemovesTree() {
        let panelID = UUID()
        let tree = PaneNode.leaf(paneID: UUID(), panelID: panelID)

        let result = tree.removingPanel(panelID)

        #expect(result.removed)
        #expect(result.node == nil)
    }

    @Test
    func removingLeafFromSplitCollapsesToSibling() {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()

        let tree = PaneNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .leaf(paneID: leftPaneID, panelID: leftPanelID),
            second: .leaf(paneID: rightPaneID, panelID: rightPanelID)
        )

        let result = tree.removingPanel(leftPanelID)
        let updatedTree = result.node

        #expect(result.removed)
        #expect(updatedTree == .leaf(paneID: rightPaneID, panelID: rightPanelID))
    }

    @Test
    func rightColumnPanePrefersBottomPaneWithinVerticalRightColumn() {
        let leftPaneID = UUID()
        let topRightPaneID = UUID()
        let bottomRightPaneID = UUID()

        let tree = PaneNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.65,
            first: .leaf(paneID: leftPaneID, panelID: UUID()),
            second: .split(
                nodeID: UUID(),
                orientation: .vertical,
                ratio: 0.5,
                first: .leaf(paneID: topRightPaneID, panelID: UUID()),
                second: .leaf(paneID: bottomRightPaneID, panelID: UUID())
            )
        )

        #expect(tree.rightColumnPaneID() == bottomRightPaneID)
    }

    @Test
    func structuralIdentityIgnoresSplitRatioChanges() {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let nodeID = UUID()

        let originalTree = PaneNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.35,
            first: .leaf(paneID: leftPaneID, panelID: leftPanelID),
            second: .leaf(paneID: rightPaneID, panelID: rightPanelID)
        )
        let resizedTree = PaneNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.8,
            first: .leaf(paneID: leftPaneID, panelID: leftPanelID),
            second: .leaf(paneID: rightPaneID, panelID: rightPanelID)
        )

        #expect(originalTree.structuralIdentity == resizedTree.structuralIdentity)
    }

    @Test
    func structuralIdentityIgnoresPanelReplacementInExistingSlot() {
        let leftPaneID = UUID()
        let rightPaneID = UUID()
        let nodeID = UUID()

        let originalTree = PaneNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .leaf(paneID: leftPaneID, panelID: UUID()),
            second: .leaf(paneID: rightPaneID, panelID: UUID())
        )
        let replacedPanelTree = PaneNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .leaf(paneID: leftPaneID, panelID: UUID()),
            second: .leaf(paneID: rightPaneID, panelID: UUID())
        )

        #expect(originalTree.structuralIdentity == replacedPanelTree.structuralIdentity)
    }

    @Test
    func structuralIdentityChangesOnlyForAffectedBranchTopology() {
        let leftTopPaneID = UUID()
        let leftBottomPaneID = UUID()
        let rightPaneID = UUID()

        let originalLeftBranch = PaneNode.split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.5,
            first: .leaf(paneID: leftTopPaneID, panelID: UUID()),
            second: .leaf(paneID: leftBottomPaneID, panelID: UUID())
        )
        let originalRightBranch = PaneNode.leaf(paneID: rightPaneID, panelID: UUID())
        let originalTree = PaneNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: originalLeftBranch,
            second: originalRightBranch
        )

        let mutatedLeftBranch = PaneNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: originalLeftBranch,
            second: .leaf(paneID: UUID(), panelID: UUID())
        )
        let mutatedTree = PaneNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: mutatedLeftBranch,
            second: originalRightBranch
        )

        guard case .split(_, let originalOrientation, _, let originalFirst, let originalSecond) = originalTree,
              case .split(_, let mutatedOrientation, _, let mutatedFirst, let mutatedSecond) = mutatedTree else {
            Issue.record("expected split roots for structural identity branch-locality test")
            return
        }

        #expect(originalOrientation == mutatedOrientation)
        #expect(originalFirst.structuralIdentity != mutatedFirst.structuralIdentity)
        #expect(originalSecond.structuralIdentity == mutatedSecond.structuralIdentity)
        #expect(originalTree.structuralIdentity != mutatedTree.structuralIdentity)
    }
}
