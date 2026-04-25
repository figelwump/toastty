import CoreState
import Foundation
import Testing

struct RightAuxPanelStateTests {
    @Test
    func defaultWidthTracksWorkspaceWidthWithinBounds() {
        #expect(RightAuxPanelState.defaultWidth(for: 1_200) == 480)
        #expect(RightAuxPanelState.defaultWidth(for: 500) == RightAuxPanelState.minWidth)
        #expect(RightAuxPanelState.defaultWidth(for: 3_000) == RightAuxPanelState.maxWidth)
    }

    @Test
    func effectiveWidthUsesDynamicDefaultUntilUserCustomizesWidth() {
        var panel = RightAuxPanelState(width: 360, hasCustomWidth: false)

        #expect(panel.effectiveWidth(for: 1_200) == 480)

        panel.hasCustomWidth = true

        #expect(panel.effectiveWidth(for: 1_200) == 360)
    }

    @Test
    func effectiveWidthKeepsCustomWidthWithinVisibleWorkspaceBounds() {
        let panel = RightAuxPanelState(width: 900, hasCustomWidth: true)

        #expect(panel.width == RightAuxPanelState.maxWidth)
        #expect(panel.effectiveWidth(for: 1_000) == 720)
    }

    @Test
    func repairKeepsEmptyVisiblePanelShellOpen() {
        var panel = RightAuxPanelState(
            isVisible: true,
            activeTabID: UUID(),
            tabIDs: [],
            tabsByID: [:],
            focusedPanelID: UUID()
        )

        panel.repairTransientState()

        #expect(panel.isVisible)
        #expect(panel.activeTabID == nil)
        #expect(panel.focusedPanelID == nil)
    }

    @Test
    func removingFinalTabKeepsVisiblePanelShellOpen() throws {
        let tabID = UUID()
        let panelID = UUID()
        var panel = RightAuxPanelState(
            isVisible: true,
            activeTabID: tabID,
            tabIDs: [tabID],
            tabsByID: [
                tabID: RightAuxPanelTabState(
                    id: tabID,
                    identity: .browserSession(panelID),
                    panelID: panelID,
                    panelState: .web(WebPanelState(definition: .browser))
                ),
            ],
            focusedPanelID: panelID
        )

        let removedTab = panel.removeTab(id: tabID)

        #expect(removedTab?.id == tabID)
        #expect(panel.isVisible)
        #expect(panel.tabIDs.isEmpty)
        #expect(panel.activeTabID == nil)
        #expect(panel.focusedPanelID == nil)
    }
}
