import CoreState
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
}
