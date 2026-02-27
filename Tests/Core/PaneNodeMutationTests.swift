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
}
