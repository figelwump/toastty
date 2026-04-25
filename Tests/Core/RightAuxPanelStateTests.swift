import CoreState
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
}
