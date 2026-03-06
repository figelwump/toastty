import CoreState
import Foundation
import Testing

struct WorkspaceLayoutSnapshotTests {
    @Test
    func makeAppStateRestoresLayoutAndTerminalWorkingDirectories() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let leftSlotID = UUID()
        let rightSlotID = UUID()

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Infra",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.62,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Server", shell: "zsh", cwd: "/tmp/infra")),
                rightPanelID: .terminal(TerminalPanelState(title: "Client", shell: "zsh", cwd: "/tmp/ui")),
            ],
            focusedPanelID: rightPanelID,
            auxPanelVisibility: [.diff],
            focusedPanelModeActive: true,
            unreadPanelIDs: [leftPanelID],
            unreadWorkspaceNotificationCount: 3,
            recentlyClosedPanels: [
                ClosedPanelRecord(
                    panelState: .terminal(TerminalPanelState(title: "Old", shell: "zsh", cwd: "/tmp/old")),
                    closedAt: Date(),
                    sourceSlotID: leftSlotID
                ),
            ]
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 20, y: 30, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: 15,
            globalTerminalFontPoints: 16
        )

        let snapshot = WorkspaceLayoutSnapshot(state: state)
        let restoredState = snapshot.makeAppState()

        let restoredWorkspace = try #require(restoredState.workspacesByID[workspaceID])
        #expect(restoredWorkspace.title == "Infra")
        #expect(restoredWorkspace.layoutTree == workspace.layoutTree)
        #expect(restoredWorkspace.focusedPanelID == rightPanelID)
        #expect(restoredWorkspace.auxPanelVisibility == [.diff])

        guard case .terminal(let leftTerminalState) = restoredWorkspace.panels[leftPanelID] else {
            Issue.record("Expected left panel to be terminal")
            return
        }
        guard case .terminal(let rightTerminalState) = restoredWorkspace.panels[rightPanelID] else {
            Issue.record("Expected right panel to be terminal")
            return
        }

        #expect(leftTerminalState.title == "Terminal 1")
        #expect(rightTerminalState.title == "Terminal 2")
        #expect(leftTerminalState.cwd == "/tmp/infra")
        #expect(rightTerminalState.cwd == "/tmp/ui")

        #expect(restoredWorkspace.focusedPanelModeActive == false)
        #expect(restoredWorkspace.unreadPanelIDs.isEmpty)
        #expect(restoredWorkspace.unreadWorkspaceNotificationCount == 0)
        #expect(restoredWorkspace.recentlyClosedPanels.isEmpty)

        #expect(restoredState.configuredTerminalFontPoints == nil)
        #expect(restoredState.globalTerminalFontPoints == AppState.defaultTerminalFontPoints)

        try StateValidator.validate(restoredState)
    }

    @Test
    func makeAppStateRegeneratesTerminalTitlesPerWorkspace() throws {
        let windowID = UUID()
        let workspaceOneID = UUID()
        let workspaceTwoID = UUID()
        let workspaceOneSlotID = UUID()
        let workspaceTwoSlotID = UUID()
        let workspaceOnePanelID = UUID()
        let workspaceTwoPanelID = UUID()

        let workspaceOne = WorkspaceState(
            id: workspaceOneID,
            title: "One",
            layoutTree: .slot(slotID: workspaceOneSlotID, panelID: workspaceOnePanelID),
            panels: [
                workspaceOnePanelID: .terminal(
                    TerminalPanelState(title: "Agent A", shell: "zsh", cwd: "/tmp/one")
                ),
            ],
            focusedPanelID: workspaceOnePanelID,
            auxPanelVisibility: []
        )

        let workspaceTwo = WorkspaceState(
            id: workspaceTwoID,
            title: "Two",
            layoutTree: .slot(slotID: workspaceTwoSlotID, panelID: workspaceTwoPanelID),
            panels: [
                workspaceTwoPanelID: .terminal(
                    TerminalPanelState(title: "Agent B", shell: "zsh", cwd: "/tmp/two")
                ),
            ],
            focusedPanelID: workspaceTwoPanelID,
            auxPanelVisibility: []
        )

        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceOneID, workspaceTwoID],
                    selectedWorkspaceID: workspaceOneID
                ),
            ],
            workspacesByID: [
                workspaceOneID: workspaceOne,
                workspaceTwoID: workspaceTwo,
            ],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let restoredState = WorkspaceLayoutSnapshot(state: state).makeAppState()
        let restoredWorkspaceOne = try #require(restoredState.workspacesByID[workspaceOneID])
        let restoredWorkspaceTwo = try #require(restoredState.workspacesByID[workspaceTwoID])

        guard case .terminal(let workspaceOneTerminal) = restoredWorkspaceOne.panels[workspaceOnePanelID] else {
            Issue.record("Expected workspace one panel to be terminal")
            return
        }
        guard case .terminal(let workspaceTwoTerminal) = restoredWorkspaceTwo.panels[workspaceTwoPanelID] else {
            Issue.record("Expected workspace two panel to be terminal")
            return
        }

        #expect(workspaceOneTerminal.title == "Terminal 1")
        #expect(workspaceTwoTerminal.title == "Terminal 1")
    }
}
