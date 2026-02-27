import CoreState
import Foundation
import Testing

struct PaneNodeMutationTests {
    @Test
    func insertPanelWithoutSelectionShiftsSelectedIndex() {
        let paneID = UUID()
        let panelA = UUID()
        let panelB = UUID()
        let panelC = UUID()

        var tree = PaneNode.leaf(paneID: paneID, tabPanelIDs: [panelA, panelB], selectedIndex: 1)
        let inserted = tree.insertPanel(panelC, toPane: paneID, at: 0, select: false)
        #expect(inserted)

        let leaf = tree.allLeafInfos[0]
        #expect(leaf.tabPanelIDs == [panelC, panelA, panelB])
        #expect(leaf.selectedIndex == 2)
    }

    @Test
    func removingPanelBeforeSelectedIndexShiftsSelectionLeft() throws {
        let paneID = UUID()
        let panelA = UUID()
        let panelB = UUID()
        let panelC = UUID()

        let tree = PaneNode.leaf(paneID: paneID, tabPanelIDs: [panelA, panelB, panelC], selectedIndex: 2)
        let result = tree.removingPanel(panelA)
        let updatedTree = try #require(result.node)

        let leaf = updatedTree.allLeafInfos[0]
        #expect(leaf.tabPanelIDs == [panelB, panelC])
        #expect(leaf.selectedIndex == 1)
    }

    @Test
    func rightColumnPanePrefersTopPaneWithinVerticalRightColumn() throws {
        let leftPaneID = UUID()
        let topRightPaneID = UUID()
        let bottomRightPaneID = UUID()

        let tree = PaneNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.65,
            first: .leaf(paneID: leftPaneID, tabPanelIDs: [UUID()], selectedIndex: 0),
            second: .split(
                nodeID: UUID(),
                orientation: .vertical,
                ratio: 0.5,
                first: .leaf(paneID: topRightPaneID, tabPanelIDs: [UUID()], selectedIndex: 0),
                second: .leaf(paneID: bottomRightPaneID, tabPanelIDs: [UUID()], selectedIndex: 0)
            )
        )

        #expect(tree.rightColumnPaneID() == topRightPaneID)
    }
}
