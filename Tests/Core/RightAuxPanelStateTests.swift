import CoreState
import Foundation
import Testing

struct RightAuxPanelStateTests {
    @Test
    func defaultWidthTracksWorkspaceWidthWithinBounds() {
        #expect(RightAuxPanelState.defaultWidth(for: 1_200) == 480)
        #expect(RightAuxPanelState.defaultWidth(for: 500) == RightAuxPanelState.minWidth)
        #expect(RightAuxPanelState.defaultWidth(for: 3_000) == 1_200)
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

        #expect(panel.width == 900)
        #expect(panel.effectiveWidth(for: 1_000) == 800)
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

    @Test
    func removingFocusedTabFocusesSuccessorTab() throws {
        let firstTabID = UUID()
        let firstPanelID = UUID()
        let secondTabID = UUID()
        let secondPanelID = UUID()
        var panel = RightAuxPanelState(
            isVisible: true,
            activeTabID: firstTabID,
            tabIDs: [firstTabID, secondTabID],
            tabsByID: [
                firstTabID: RightAuxPanelTabState(
                    id: firstTabID,
                    identity: .browserSession(firstPanelID),
                    panelID: firstPanelID,
                    panelState: .web(WebPanelState(definition: .browser))
                ),
                secondTabID: RightAuxPanelTabState(
                    id: secondTabID,
                    identity: .browserSession(secondPanelID),
                    panelID: secondPanelID,
                    panelState: .web(WebPanelState(definition: .browser))
                ),
            ],
            focusedPanelID: firstPanelID
        )

        let removedTab = panel.removeTab(id: firstTabID)

        #expect(removedTab?.id == firstTabID)
        #expect(panel.activeTabID == secondTabID)
        #expect(panel.focusedPanelID == secondPanelID)
    }

    @Test
    func removingUnfocusedTabPreservesFocusedTab() throws {
        let firstTabID = UUID()
        let firstPanelID = UUID()
        let secondTabID = UUID()
        let secondPanelID = UUID()
        var panel = RightAuxPanelState(
            isVisible: true,
            activeTabID: firstTabID,
            tabIDs: [firstTabID, secondTabID],
            tabsByID: [
                firstTabID: RightAuxPanelTabState(
                    id: firstTabID,
                    identity: .browserSession(firstPanelID),
                    panelID: firstPanelID,
                    panelState: .web(WebPanelState(definition: .browser))
                ),
                secondTabID: RightAuxPanelTabState(
                    id: secondTabID,
                    identity: .browserSession(secondPanelID),
                    panelID: secondPanelID,
                    panelState: .web(WebPanelState(definition: .browser))
                ),
            ],
            focusedPanelID: firstPanelID
        )

        let removedTab = panel.removeTab(id: secondTabID)

        #expect(removedTab?.id == secondTabID)
        #expect(panel.activeTabID == firstTabID)
        #expect(panel.focusedPanelID == firstPanelID)
    }
}
