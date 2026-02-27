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

    @Test
    func staleFocusedPanelFailsValidation() throws {
        let panelID = UUID()
        let staleFocusedPanelID = UUID()
        let paneID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Broken focus",
            paneTree: .leaf(paneID: paneID, tabPanelIDs: [panelID], selectedIndex: 0),
            panels: [panelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp"))],
            focusedPanelID: staleFocusedPanelID
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

        #expect(throws: StateInvariantViolation.focusedPanelMissing(workspaceID: workspace.id, panelID: staleFocusedPanelID)) {
            try StateValidator.validate(state)
        }
    }

    @Test
    func outOfBoundsSplitRatioFailsValidation() throws {
        let panelID = UUID()
        let secondPanelID = UUID()
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let splitID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Broken ratio",
            paneTree: .split(
                nodeID: splitID,
                orientation: .horizontal,
                ratio: 1.3,
                first: .leaf(paneID: firstPaneID, tabPanelIDs: [panelID], selectedIndex: 0),
                second: .leaf(paneID: secondPaneID, tabPanelIDs: [secondPanelID], selectedIndex: 0)
            ),
            panels: [
                panelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                secondPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            ],
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

        #expect(throws: StateInvariantViolation.splitRatioOutOfBounds(workspaceID: workspace.id, nodeID: splitID, ratio: 1.3)) {
            try StateValidator.validate(state)
        }
    }
}
