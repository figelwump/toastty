import CoreState
import Foundation
import Testing

struct LayoutProjectionTests {
    @Test
    func horizontalSplitProjectionIncludesDividerThickness() {
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let tree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: leftSlotID, panelID: UUID()),
            second: .slot(slotID: rightSlotID, panelID: UUID())
        )

        let projection = tree.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 100, height: 40),
            dividerThickness: 1
        )

        #expect(projection.slots.count == 2)
        #expect(projection.dividers.count == 1)

        let left = projection.slots.first(where: { $0.slotID == leftSlotID })
        let right = projection.slots.first(where: { $0.slotID == rightSlotID })
        let divider = projection.dividers.first

        #expect(left?.frame == LayoutFrame(minX: 0, minY: 0, width: 49.5, height: 40))
        #expect(divider?.frame == LayoutFrame(minX: 49.5, minY: 0, width: 1, height: 40))
        #expect(right?.frame == LayoutFrame(minX: 50.5, minY: 0, width: 49.5, height: 40))
    }

    @Test
    func normalizedProjectionMatchesFocusNavigationGeometry() {
        let topLeftSlotID = UUID()
        let bottomLeftSlotID = UUID()
        let rightSlotID = UUID()
        let tree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.4,
            first: .split(
                nodeID: UUID(),
                orientation: .vertical,
                ratio: 0.25,
                first: .slot(slotID: topLeftSlotID, panelID: UUID()),
                second: .slot(slotID: bottomLeftSlotID, panelID: UUID())
            ),
            second: .slot(slotID: rightSlotID, panelID: UUID())
        )

        let projection = tree.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 1, height: 1),
            dividerThickness: 0
        )

        let topLeft = projection.slots.first(where: { $0.slotID == topLeftSlotID })
        let bottomLeft = projection.slots.first(where: { $0.slotID == bottomLeftSlotID })
        let right = projection.slots.first(where: { $0.slotID == rightSlotID })

        #expect(topLeft?.frame == LayoutFrame(minX: 0, minY: 0, width: 0.4, height: 0.25))
        #expect(bottomLeft?.frame == LayoutFrame(minX: 0, minY: 0.25, width: 0.4, height: 0.75))
        #expect(right?.frame == LayoutFrame(minX: 0.4, minY: 0, width: 0.6, height: 1))
    }

    @Test
    func splitCloseRoundTripKeepsOriginalSlotIdentityAndRestoresFullFrame() {
        let originalSlotID = UUID()
        let originalPanelID = UUID()
        let siblingPanelID = UUID()
        let splitTree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: originalSlotID, panelID: originalPanelID),
            second: .slot(slotID: UUID(), panelID: siblingPanelID)
        )

        let splitProjection = splitTree.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 100, height: 40),
            dividerThickness: 1
        )
        let splitOriginal = splitProjection.slots.first(where: { $0.slotID == originalSlotID })
        #expect(splitOriginal?.frame == LayoutFrame(minX: 0, minY: 0, width: 49.5, height: 40))

        let collapsedTree = splitTree.removingPanel(siblingPanelID).node
        #expect(collapsedTree == .slot(slotID: originalSlotID, panelID: originalPanelID))

        let collapsedProjection = collapsedTree?.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 100, height: 40),
            dividerThickness: 1
        )
        let collapsedOriginal = collapsedProjection?.slots.first
        #expect(collapsedOriginal?.slotID == originalSlotID)
        #expect(collapsedOriginal?.frame == LayoutFrame(minX: 0, minY: 0, width: 100, height: 40))
    }
}
