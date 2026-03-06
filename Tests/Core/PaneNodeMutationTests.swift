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
}
