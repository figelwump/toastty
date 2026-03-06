import CoreState
import Foundation
import Testing

struct LayoutNodeMutationTests {
    @Test
    func removingSingleLeafPanelRemovesTree() {
        let panelID = UUID()
        let tree = LayoutNode.slot(slotID: UUID(), panelID: panelID)

        let result = tree.removingPanel(panelID)

        #expect(result.removed)
        #expect(result.node == nil)
    }

    @Test
    func removingLeafFromSplitCollapsesToSibling() {
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()

        let tree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )

        let result = tree.removingPanel(leftPanelID)
        let updatedTree = result.node

        #expect(result.removed)
        #expect(updatedTree == .slot(slotID: rightSlotID, panelID: rightPanelID))
    }

    @Test
    func rightColumnSlotPrefersBottomSlotWithinVerticalRightColumn() {
        let leftSlotID = UUID()
        let topRightSlotID = UUID()
        let bottomRightSlotID = UUID()

        let tree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.65,
            first: .slot(slotID: leftSlotID, panelID: UUID()),
            second: .split(
                nodeID: UUID(),
                orientation: .vertical,
                ratio: 0.5,
                first: .slot(slotID: topRightSlotID, panelID: UUID()),
                second: .slot(slotID: bottomRightSlotID, panelID: UUID())
            )
        )

        #expect(tree.rightColumnSlotID() == bottomRightSlotID)
    }

    @Test
    func structuralIdentityIgnoresSplitRatioChanges() {
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let nodeID = UUID()

        let originalTree = LayoutNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.35,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )
        let resizedTree = LayoutNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.8,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )

        #expect(originalTree.structuralIdentity == resizedTree.structuralIdentity)
    }

    @Test
    func structuralIdentityIgnoresPanelReplacementInExistingSlot() {
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let nodeID = UUID()

        let originalTree = LayoutNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: leftSlotID, panelID: UUID()),
            second: .slot(slotID: rightSlotID, panelID: UUID())
        )
        let replacedPanelTree = LayoutNode.split(
            nodeID: nodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: leftSlotID, panelID: UUID()),
            second: .slot(slotID: rightSlotID, panelID: UUID())
        )

        #expect(originalTree.structuralIdentity == replacedPanelTree.structuralIdentity)
    }

    @Test
    func structuralIdentityChangesOnlyForAffectedBranchTopology() {
        let leftTopSlotID = UUID()
        let leftBottomSlotID = UUID()
        let rightSlotID = UUID()

        let originalLeftBranch = LayoutNode.split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.5,
            first: .slot(slotID: leftTopSlotID, panelID: UUID()),
            second: .slot(slotID: leftBottomSlotID, panelID: UUID())
        )
        let originalRightBranch = LayoutNode.slot(slotID: rightSlotID, panelID: UUID())
        let originalTree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: originalLeftBranch,
            second: originalRightBranch
        )

        let mutatedLeftBranch = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: originalLeftBranch,
            second: .slot(slotID: UUID(), panelID: UUID())
        )
        let mutatedTree = LayoutNode.split(
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
