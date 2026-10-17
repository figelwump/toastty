import CoreState
import Foundation
import Testing

struct BackgroundPanelCloseTests {
    // Failure modes: a background close selecting the closed panel's tab or
    // its neighbor, changing the visible tab's focus, and the default close
    // losing its select-then-close behavior.

    @Test
    func backgroundCloseOfOnePaneKeepsTheSelectedTab() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let backgroundTab = try #require(state.workspacesByID[workspaceID]?.selectedTab)
        let backgroundPanelID = try #require(backgroundTab.focusedPanelID)
        #expect(AppReducer.reduce(action: .splitPanel(
            workspaceID: workspaceID, tabID: backgroundTab.id, panelID: backgroundPanelID,
            direction: .right, profileBinding: nil, activate: false
        ), state: &state))
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let before = try #require(state.workspacesByID[workspaceID])
        #expect(before.selectedTabID != backgroundTab.id)

        #expect(AppReducer.reduce(
            action: .closePanel(panelID: backgroundPanelID, preservesTabSelection: true),
            state: &state
        ))

        let after = try #require(state.workspacesByID[workspaceID])
        #expect(after.selectedTabID == before.selectedTabID)
        #expect(after.selectedTab?.focusedPanelID == before.selectedTab?.focusedPanelID)
        #expect(after.tab(id: backgroundTab.id)?.panels[backgroundPanelID] == nil)
        #expect(after.tab(id: backgroundTab.id)?.panels.count == 1)
        try StateValidator.validate(state)
    }

    @Test
    func backgroundCloseOfATabsLastPaneKeepsTheSelectedTab() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let firstTab = try #require(state.workspacesByID[workspaceID]?.selectedTab)
        let firstPanelID = try #require(firstTab.focusedPanelID)
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let before = try #require(state.workspacesByID[workspaceID])
        let thirdTabID = try #require(before.tabIDs.last)
        #expect(before.selectedTabID == thirdTabID)

        #expect(AppReducer.reduce(
            action: .closePanel(panelID: firstPanelID, preservesTabSelection: true),
            state: &state
        ))

        let after = try #require(state.workspacesByID[workspaceID])
        #expect(after.tab(id: firstTab.id) == nil)
        // A plain tab removal would select the closed tab's neighbor.
        #expect(after.selectedTabID == thirdTabID)
        try StateValidator.validate(state)
    }

    @Test
    func defaultCloseStillSelectsTheClosedPanelsTab() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let backgroundTab = try #require(state.workspacesByID[workspaceID]?.selectedTab)
        let backgroundPanelID = try #require(backgroundTab.focusedPanelID)
        #expect(AppReducer.reduce(action: .splitPanel(
            workspaceID: workspaceID, tabID: backgroundTab.id, panelID: backgroundPanelID,
            direction: .right, profileBinding: nil, activate: false
        ), state: &state))
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        #expect(AppReducer.reduce(action: .closePanel(panelID: backgroundPanelID), state: &state))

        #expect(state.workspacesByID[workspaceID]?.selectedTabID == backgroundTab.id)
    }
}
