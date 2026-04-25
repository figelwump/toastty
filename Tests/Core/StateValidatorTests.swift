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
        let slotID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Broken",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: slotID, panelID: panelID),
                second: .slot(slotID: UUID(), panelID: panelID)
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
            selectedWindowID: window.id
        )

        #expect(throws: StateInvariantViolation.panelReferencedMultipleTimes(workspaceID: workspace.id, panelID: panelID)) {
            try StateValidator.validate(state)
        }
    }

    @Test
    func duplicatePanelReferenceBetweenLayoutAndRightPanelFailsValidation() throws {
        let panelID = UUID()
        let rightTabID = UUID()
        var workspace = WorkspaceState(
            id: UUID(),
            title: "Broken right panel",
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [panelID: .terminal(TerminalPanelState(title: "Terminal", shell: "zsh", cwd: "/tmp"))],
            focusedPanelID: panelID
        )
        workspace.rightAuxPanel = RightAuxPanelState(
            isVisible: true,
            activeTabID: rightTabID,
            tabIDs: [rightTabID],
            tabsByID: [
                rightTabID: RightAuxPanelTabState(
                    id: rightTabID,
                    identity: .browserSession(panelID),
                    panelID: panelID,
                    panelState: .web(WebPanelState(definition: .browser))
                ),
            ]
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
            selectedWindowID: window.id
        )

        #expect(throws: StateInvariantViolation.panelReferencedMultipleTimes(workspaceID: workspace.id, panelID: panelID)) {
            try StateValidator.validate(state)
        }
    }

    @Test
    func missingRightPanelTabFailsValidation() throws {
        let missingTabID = UUID()
        var workspace = WorkspaceState.bootstrap(title: "Broken right panel tab")
        workspace.rightAuxPanel.tabIDs = [missingTabID]
        workspace.rightAuxPanel.activeTabID = missingTabID

        let window = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 0, y: 0, width: 600, height: 400),
            workspaceIDs: [workspace.id],
            selectedWorkspaceID: workspace.id
        )

        let state = AppState(
            windows: [window],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: window.id
        )

        #expect(throws: StateInvariantViolation.missingRightAuxPanelTab(workspaceID: workspace.id, tabID: missingTabID)) {
            try StateValidator.validate(state)
        }
    }

    @Test
    func staleFocusedPanelFailsValidation() throws {
        let panelID = UUID()
        let staleFocusedPanelID = UUID()
        let slotID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Broken focus",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
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
            selectedWindowID: window.id
        )

        #expect(throws: StateInvariantViolation.focusedPanelMissing(workspaceID: workspace.id, panelID: staleFocusedPanelID)) {
            try StateValidator.validate(state)
        }
    }

    @Test
    func outOfBoundsSplitRatioFailsValidation() throws {
        let panelID = UUID()
        let secondPanelID = UUID()
        let firstSlotID = UUID()
        let secondSlotID = UUID()
        let splitID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Broken ratio",
            layoutTree: .split(
                nodeID: splitID,
                orientation: .horizontal,
                ratio: 1.3,
                first: .slot(slotID: firstSlotID, panelID: panelID),
                second: .slot(slotID: secondSlotID, panelID: secondPanelID)
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
            selectedWindowID: window.id
        )

        #expect(throws: StateInvariantViolation.splitRatioOutOfBounds(workspaceID: workspace.id, nodeID: splitID, ratio: 1.3)) {
            try StateValidator.validate(state)
        }
    }

    @Test
    func orphanWorkspaceFailsValidation() throws {
        let workspace = WorkspaceState.bootstrap(title: "Orphan")
        let state = AppState(
            windows: [],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil
        )

        #expect(throws: StateInvariantViolation.workspaceWithoutWindow(workspaceID: workspace.id)) {
            try StateValidator.validate(state)
        }
    }
}
