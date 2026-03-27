import Foundation
import Testing
@testable import CoreState

struct DesktopNotificationRouteResolverTests {
    @Test
    func resolvesWorkspaceRouteWhenWorkspaceHintExists() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let hint = DesktopNotificationSelectionHint(workspaceID: workspaceID, panelID: nil)

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: nil))
    }

    @Test
    func resolvesPanelRouteWhenPanelHintExists() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let hint = DesktopNotificationSelectionHint(workspaceID: workspaceID, panelID: panelID)

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: panelID))
    }

    @Test
    func resolvesPanelRouteWhenPanelLivesInBackgroundTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let originalWorkspace = try #require(state.workspacesByID[workspaceID])
        let originalTabID = try #require(originalWorkspace.resolvedSelectedTabID)
        let panelID = try #require(originalWorkspace.focusedPanelID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let backgroundedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(backgroundedWorkspace.resolvedSelectedTabID != originalTabID)

        let hint = DesktopNotificationSelectionHint(workspaceID: workspaceID, panelID: panelID)
        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: panelID))
    }

    @Test
    func fallsBackToWorkspaceRouteWhenPanelHintIsUnknown() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let hint = DesktopNotificationSelectionHint(workspaceID: workspaceID, panelID: UUID())

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: nil))
    }

    @Test
    func panelRouteWinsWhenWorkspaceHintDoesNotMatchPanelLocation() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Second Workspace"), state: &state))
        let secondWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let secondPanelID = try #require(state.workspacesByID[secondWorkspaceID]?.focusedPanelID)
        let hint = DesktopNotificationSelectionHint(workspaceID: firstWorkspaceID, panelID: secondPanelID)

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(
            route == DesktopNotificationActivationRoute(
                windowID: windowID,
                workspaceID: secondWorkspaceID,
                panelID: secondPanelID
            )
        )
    }

    @Test
    func resolvesFromUserInfoUUIDStrings() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let hint = DesktopNotificationSelectionHint(
            userInfo: [
                DesktopNotificationUserInfoKey.workspaceID: workspaceID.uuidString,
                DesktopNotificationUserInfoKey.panelID: panelID.uuidString,
            ]
        )

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: panelID))
    }

    @Test
    func returnsNilWhenHintDoesNotContainResolvableIDs() {
        let state = AppState.bootstrap()
        let hint = DesktopNotificationSelectionHint(
            userInfo: [
                DesktopNotificationUserInfoKey.workspaceID: "not-a-uuid",
                DesktopNotificationUserInfoKey.panelID: "still-not-a-uuid",
            ]
        )

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == nil)
    }

    @Test
    func resolvesPanelRouteWhenOnlyPanelIDIsProvided() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let hint = DesktopNotificationSelectionHint(workspaceID: nil, panelID: panelID)

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: panelID))
    }

    @Test
    func returnsNilWhenUserInfoIsEmpty() {
        let state = AppState.bootstrap()
        let hint = DesktopNotificationSelectionHint(userInfo: [:])

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == nil)
    }

    @Test
    func resolvesFromNSStringValues() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let hint = DesktopNotificationSelectionHint(
            userInfo: [
                DesktopNotificationUserInfoKey.workspaceID: workspaceID.uuidString as NSString,
                DesktopNotificationUserInfoKey.panelID: panelID.uuidString as NSString,
            ]
        )

        let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: state)

        #expect(route == DesktopNotificationActivationRoute(windowID: windowID, workspaceID: workspaceID, panelID: panelID))
    }
}
