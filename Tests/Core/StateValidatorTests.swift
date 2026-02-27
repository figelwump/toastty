import CoreState
import Foundation
import Testing

struct StateValidatorTests {
    @Test
    func bootstrapStateIsValid() throws {
        try StateValidator.validate(.bootstrap())
    }

    @Test
    func duplicatePanelReferenceFailsValidation() throws {
        let panelID = UUID()
        let paneID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Broken",
            paneTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .leaf(paneID: paneID, tabPanelIDs: [panelID], selectedIndex: 0),
                second: .leaf(paneID: UUID(), tabPanelIDs: [panelID], selectedIndex: 0)
            ),
            panels: [panelID: .terminal(TerminalPanelState(title: "Terminal", shell: "zsh", cwd: "/tmp"))],
            focusedPanelID: panelID
        )

        let window = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 0, y: 0, width: 600, height: 400),
            workspaceIDs: [workspace.id],
            selectedWorkspaceID: workspace.id
        )

        let state = AppState(
            windows: [window],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: window.id,
            globalTerminalFontPoints: 13
        )

        #expect(throws: StateInvariantViolation.panelReferencedMultipleTimes(workspaceID: workspace.id, panelID: panelID)) {
            try StateValidator.validate(state)
        }
    }
}
