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


extension AppReducerTests {
    private func sidebarOrderFixture() throws -> (AppState, UUID, [UUID]) {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        for _ in 0..<3 {
            #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        }
        let workspace = try #require(state.workspacesByID[workspaceID])
        let panelIDs = try workspace.orderedTabs.map { try #require($0.focusedPanelID) }
        return (state, workspaceID, panelIDs)
    }

    @Test
    func moveSidebarSessionChangesOnlyDisplayPreferenceAcrossTabs() throws {
        var (state, workspaceID, panels) = try sidebarOrderFixture()
        let originalState = state
        #expect(AppReducer.reduce(action: .moveSidebarSession(
            workspaceID: workspaceID, panelID: panels[3], targetPanelID: panels[0],
            placeAfter: false, visiblePanelIDs: panels
        ), state: &state))
        var expected = originalState
        expected.workspacesByID[workspaceID]?.sidebarSessionPanelOrder = [panels[3]] + Array(panels.prefix(3))
        #expect(state == expected)
        #expect(AppReducer.reduce(action: .moveSidebarSession(
            workspaceID: workspaceID, panelID: panels[3], targetPanelID: panels[2],
            placeAfter: true, visiblePanelIDs: panels
        ), state: &state))
        expected.workspacesByID[workspaceID]?.sidebarSessionPanelOrder = panels
        #expect(state == expected)
        #expect(AppReducer.reduce(action: .moveSidebarSession(
            workspaceID: workspaceID, panelID: panels[3], targetPanelID: panels[2],
            placeAfter: true, visiblePanelIDs: panels
        ), state: &state) == false)
        #expect(state == expected)
        try StateValidator.validate(state)
    }

    @Test
    func moveSidebarSessionPreservesHiddenPanelsAndSanitizesCallerOrder() throws {
        var (state, workspaceID, panels) = try sidebarOrderFixture()
        let missing = UUID()
        state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder = [panels[0], panels[1], panels[0], missing]
        let originalState = state
        #expect(AppReducer.reduce(action: .moveSidebarSession(
            workspaceID: workspaceID, panelID: panels[3], targetPanelID: panels[0],
            placeAfter: false, visiblePanelIDs: [panels[0], missing, panels[3], panels[3], panels[2]]
        ), state: &state))
        var expected = originalState
        // The stopped/hidden second panel keeps its place among saved entries. New rows append in caller order.
        expected.workspacesByID[workspaceID]?.sidebarSessionPanelOrder = [panels[3], panels[0], panels[1], panels[2]]
        #expect(state == expected)
    }

    @Test
    func moveSidebarSessionRejectsMissingForeignAndNonvisibleEndpoints() throws {
        var (state, workspaceID, panels) = try sidebarOrderFixture()
        let windowID = try #require(state.windows.first?.id)
        #expect(AppReducer.reduce(action: .createWorkspace(windowID: windowID, title: "Other", activate: false), state: &state))
        let foreignWorkspace = try #require(state.workspacesByID.values.first { $0.id != workspaceID })
        let foreignPanel = try #require(foreignWorkspace.focusedPanelID)
        let missing = UUID()
        var workspace = try #require(state.workspacesByID[workspaceID])
        let webTabID = try #require(workspace.tabID(containingPanelID: panels[2]))
        workspace.tabsByID[webTabID]?.panels[panels[2]] = .web(WebPanelState(definition: .browser, title: "Browser"))
        state.workspacesByID[workspaceID] = workspace
        let originalState = state
        let actions: [AppAction] = [
            .moveSidebarSession(workspaceID: workspaceID, panelID: panels[2], targetPanelID: panels[0], placeAfter: true, visiblePanelIDs: panels),
            .moveSidebarSession(workspaceID: workspaceID, panelID: panels[0], targetPanelID: panels[2], placeAfter: true, visiblePanelIDs: panels),
            .moveSidebarSession(workspaceID: missing, panelID: panels[0], targetPanelID: panels[1], placeAfter: true, visiblePanelIDs: panels),
            .moveSidebarSession(workspaceID: workspaceID, panelID: panels[0], targetPanelID: panels[0], placeAfter: true, visiblePanelIDs: panels),
            .moveSidebarSession(workspaceID: workspaceID, panelID: missing, targetPanelID: panels[0], placeAfter: true, visiblePanelIDs: panels + [missing]),
            .moveSidebarSession(workspaceID: workspaceID, panelID: panels[0], targetPanelID: foreignPanel, placeAfter: true, visiblePanelIDs: panels + [foreignPanel]),
            .moveSidebarSession(workspaceID: workspaceID, panelID: foreignPanel, targetPanelID: panels[0], placeAfter: true, visiblePanelIDs: panels + [foreignPanel]),
            .moveSidebarSession(workspaceID: workspaceID, panelID: panels[0], targetPanelID: panels[1], placeAfter: true, visiblePanelIDs: [panels[0]]),
            .moveSidebarSession(workspaceID: workspaceID, panelID: panels[0], targetPanelID: panels[1], placeAfter: true, visiblePanelIDs: [panels[1]])
        ]
        for action in actions {
            #expect(AppReducer.reduce(action: action, state: &state) == false)
            #expect(state == originalState)
        }
    }

    @Test
    func sidebarSessionPreferencePrunesClosedPanelsAndTabs() throws {
        var (state, workspaceID, panels) = try sidebarOrderFixture()
        state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder = panels
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabID(containingPanelID: panels[0]))
        #expect(AppReducer.reduce(action: .closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID), state: &state))
        #expect(state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder == Array(panels.dropFirst()))
        #expect(AppReducer.reduce(action: .closePanel(panelID: panels[3]), state: &state))
        #expect(state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder == [panels[1], panels[2]])
        try StateValidator.validate(state)
    }

    @Test
    func movingPanelOutRemovesOnlySourceSidebarPreference() throws {
        var (state, workspaceID, panels) = try sidebarOrderFixture()
        state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder = panels
        let windowID = try #require(state.windows.first?.id)
        #expect(AppReducer.reduce(action: .createWorkspace(windowID: windowID, title: "Other", activate: false), state: &state))
        let targetWorkspace = try #require(state.workspacesByID.values.first { $0.id != workspaceID })
        let targetPanel = try #require(targetWorkspace.focusedPanelID)
        state.workspacesByID[targetWorkspace.id]?.sidebarSessionPanelOrder = [targetPanel]
        #expect(AppReducer.reduce(action: .movePanelToWorkspace(
            panelID: panels[3], targetWorkspaceID: targetWorkspace.id, targetSlotID: nil
        ), state: &state))
        #expect(state.workspacesByID[workspaceID]?.sidebarSessionPanelOrder == Array(panels.prefix(3)))
        #expect(state.workspacesByID[targetWorkspace.id]?.sidebarSessionPanelOrder == [targetPanel])
        #expect(state.workspacesByID[targetWorkspace.id]?.allTerminalPanelIDs.contains(panels[3]) == true)
        try StateValidator.validate(state)
    }
}
