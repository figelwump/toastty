import CoreState
import Foundation
import Testing

struct AppReducerTests {
    @Test
    func splitFocusedPaneCreatesSplitAndNewTerminalPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let oldPanelCount = workspaceBefore.panels.count

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.panels.count == oldPanelCount + 1)

        if case .split(_, .horizontal, _, _, _) = workspaceAfter.paneTree {
            // expected shape after first split
        } else {
            Issue.record("expected split root after first split")
        }

        try StateValidator.validate(state)
    }

    @Test
    func createTerminalPanelAppendsToTargetPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let paneID = try #require(workspace.paneTree.allLeafInfos.first?.paneID)
        let existingCount = workspace.paneTree.allLeafInfos.first?.tabPanelIDs.count ?? 0

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedLeaf = try #require(updatedWorkspace.paneTree.allLeafInfos.first)
        #expect(updatedLeaf.tabPanelIDs.count == existingCount + 1)

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedPaneRecoversFromStaleFocusedPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        workspace.focusedPanelID = UUID()
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .vertical), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(updatedWorkspace.focusedPanelID)
        #expect(updatedWorkspace.panels[focusedPanelID] != nil)

        try StateValidator.validate(state)
    }

    @Test
    func createTerminalPanelUsesMonotonicTerminalTitleNumbering() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let paneID = try #require(workspace.paneTree.allLeafInfos.first?.paneID)

        let panelOne = UUID()
        let panelThree = UUID()
        workspace.panels = [
            panelOne: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            panelThree: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
        ]
        workspace.paneTree = .leaf(paneID: paneID, tabPanelIDs: [panelOne, panelThree], selectedIndex: 1)
        workspace.focusedPanelID = panelThree
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let newPanelIDs = Set(updatedWorkspace.panels.keys).subtracting([panelOne, panelThree])
        let newPanelID = try #require(newPanelIDs.first)
        let newPanel = try #require(updatedWorkspace.panels[newPanelID])

        guard case .terminal(let terminalState) = newPanel else {
            Issue.record("expected new panel to be terminal")
            return
        }

        #expect(terminalState.title == "Terminal 4")
        try StateValidator.validate(state)
    }

    @Test
    func createWorkspaceAppendsWorkspaceAndSelectsIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let windowID = try #require(state.windows.first?.id)
        let originalWorkspaceCount = state.windows.first?.workspaceIDs.count ?? 0

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: nil), state: &state))

        let window = try #require(state.windows.first(where: { $0.id == windowID }))
        #expect(window.workspaceIDs.count == originalWorkspaceCount + 1)

        let selectedWorkspaceID = try #require(window.selectedWorkspaceID)
        let selectedWorkspace = try #require(state.workspacesByID[selectedWorkspaceID])
        #expect(selectedWorkspace.title == "Workspace 2")

        try StateValidator.validate(state)
    }
}
