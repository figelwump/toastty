import CoreState
import Foundation
import Testing

extension AppReducerTests {
    @Test
    func moveWorkspaceTabReordersTabsAndKeepsSelectedTabID() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        var workspace = try #require(state.workspacesByID[workspaceID])
        let originalTabIDs = workspace.tabIDs
        let selectedTabID = originalTabIDs[1]
        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: selectedTabID), state: &state))

        #expect(reducer.send(.moveWorkspaceTab(workspaceID: workspaceID, fromIndex: 1, toIndex: 2), state: &state))

        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.tabIDs == [originalTabIDs[0], originalTabIDs[2], originalTabIDs[1]])
        #expect(workspace.selectedTabID == selectedTabID)
        try StateValidator.validate(state)
    }

    @Test
    func moveWorkspaceTabRejectsSameIndexWithoutStateChurn() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        let originalState = state
        #expect(reducer.send(.moveWorkspaceTab(workspaceID: workspaceID, fromIndex: 1, toIndex: 1), state: &state) == false)
        #expect(state == originalState)
    }

    @Test
    func moveWorkspaceTabRejectsOutOfBoundsIndices() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        let originalState = state
        #expect(reducer.send(.moveWorkspaceTab(workspaceID: workspaceID, fromIndex: -1, toIndex: 0), state: &state) == false)
        #expect(reducer.send(.moveWorkspaceTab(workspaceID: workspaceID, fromIndex: 0, toIndex: 2), state: &state) == false)
        #expect(state == originalState)
    }

    @Test
    func moveWorkspaceReordersWorkspacesAndKeepsSelectedWorkspaceID() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Two", activate: true), state: &state))
        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Three", activate: true), state: &state))

        var window = try #require(state.windows.first)
        let originalWorkspaceIDs = window.workspaceIDs
        let selectedWorkspaceID = originalWorkspaceIDs[1]
        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: selectedWorkspaceID), state: &state))

        #expect(reducer.send(.moveWorkspace(windowID: windowID, fromIndex: 1, toIndex: 0), state: &state))

        window = try #require(state.windows.first)
        #expect(window.workspaceIDs == [originalWorkspaceIDs[1], originalWorkspaceIDs[0], originalWorkspaceIDs[2]])
        #expect(window.selectedWorkspaceID == selectedWorkspaceID)
        try StateValidator.validate(state)
    }

    @Test
    func moveWorkspaceRejectsSameIndexAndOutOfBoundsIndices() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Two", activate: true), state: &state))

        let originalState = state
        #expect(reducer.send(.moveWorkspace(windowID: windowID, fromIndex: 1, toIndex: 1), state: &state) == false)
        #expect(reducer.send(.moveWorkspace(windowID: windowID, fromIndex: 0, toIndex: 2), state: &state) == false)
        #expect(state == originalState)
    }

    // MARK: - Toggle Sidebar

    @Test
    func toggleSidebarHidesAndShowsSidebar() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(state.windows.first?.sidebarVisible == true)

        #expect(reducer.send(.toggleSidebar(windowID: windowID), state: &state))
        #expect(state.windows.first?.sidebarVisible == false)

        #expect(reducer.send(.toggleSidebar(windowID: windowID), state: &state))
        #expect(state.windows.first?.sidebarVisible == true)

        try StateValidator.validate(state)
    }

    @Test
    func toggleSidebarRejectsInvalidWindowID() {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        #expect(reducer.send(.toggleSidebar(windowID: UUID()), state: &state) == false)
    }

    @Test
    func setSidebarWidthPersistsWidthOverride() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(state.windows.first?.sidebarWidthPointsOverride == nil)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: 320,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            )
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == 320)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: 320,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            ) == false
        )

        try StateValidator.validate(state)
    }

    @Test
    func setSidebarWidthClearsDefaultWidthOverride() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: WindowState.defaultSidebarWidthBeforeAgentLaunch,
                    defaultWidth: WindowState.defaultSidebarWidthBeforeAgentLaunch
                ),
                state: &state
            ) == false
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == nil)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: 320,
                    defaultWidth: WindowState.defaultSidebarWidthBeforeAgentLaunch
                ),
                state: &state
            )
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == 320)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: WindowState.defaultSidebarWidthBeforeAgentLaunch,
                    defaultWidth: WindowState.defaultSidebarWidthBeforeAgentLaunch
                ),
                state: &state
            )
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == nil)

        try StateValidator.validate(state)
    }

    @Test
    func setSidebarWidthUsesCurrentDefaultWidthWhenNormalizingOverride() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: WindowState.defaultSidebarWidthBeforeAgentLaunch,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            )
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == WindowState.defaultSidebarWidthBeforeAgentLaunch)

        try StateValidator.validate(state)
    }

    @Test
    func setSidebarWidthClampsWidthOverride() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: 12,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            )
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == WindowState.minSidebarWidth)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: 900,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            )
        )
        #expect(state.windows.first?.sidebarWidthPointsOverride == WindowState.maxSidebarWidth)

        try StateValidator.validate(state)
    }

    @Test
    func setSidebarWidthRejectsInvalidInput() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let originalState = state
        let windowID = try #require(state.windows.first?.id)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: UUID(),
                    width: 320,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            ) == false
        )
        #expect(state == originalState)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: .infinity,
                    defaultWidth: WindowState.defaultSidebarWidthAfterAgentLaunch
                ),
                state: &state
            ) == false
        )
        #expect(state == originalState)

        #expect(
            reducer.send(
                .setSidebarWidth(
                    windowID: windowID,
                    width: 320,
                    defaultWidth: .infinity
                ),
                state: &state
            ) == false
        )
        #expect(state == originalState)

        try StateValidator.validate(state)
    }
}
