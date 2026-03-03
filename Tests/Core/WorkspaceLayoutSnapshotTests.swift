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
        let leftPaneID = UUID()
        let rightPaneID = UUID()

        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Infra",
            paneTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.62,
                first: .leaf(paneID: leftPaneID, tabPanelIDs: [leftPanelID], selectedIndex: 0),
                second: .leaf(paneID: rightPaneID, tabPanelIDs: [rightPanelID], selectedIndex: 0)
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
                    sourceLeafPaneID: leftPaneID
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
        #expect(restoredWorkspace.paneTree == workspace.paneTree)
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
}
