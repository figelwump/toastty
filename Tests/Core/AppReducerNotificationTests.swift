import CoreState
import Foundation
import Testing

extension AppReducerTests {
    @Test
    func recordDesktopNotificationMarksUnreadPanelOnlyOnce() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        let countBefore = try #require(state.workspacesByID[workspaceID]).unreadNotificationCount
        #expect(countBefore == 0)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )

        let workspaceAfterFirstNotification = try #require(state.workspacesByID[workspaceID])
        let countAfter = workspaceAfterFirstNotification.unreadNotificationCount
        #expect(countAfter == 1)
        #expect(workspaceAfterFirstNotification.unreadPanelIDs == [panelID])
        #expect(workspaceAfterFirstNotification.unreadWorkspaceNotificationCount == 0)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])

        try StateValidator.validate(state)
    }

    @Test
    func recordDesktopNotificationReturnsFalseForUnknownWorkspace() {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let bogusWorkspaceID = UUID()

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: bogusWorkspaceID, panelID: nil),
                state: &state
            ) == false
        )
    }

    @Test
    func focusPanelClearsOnlyFocusedPanelUnreadNotification() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)
        let otherPanelID = try #require(workspace.panels.keys.first(where: { $0 != focusedPanelID }))
        workspace.unreadPanelIDs = [focusedPanelID, otherPanelID]
        workspace.unreadWorkspaceNotificationCount = 2
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: focusedPanelID), state: &state))
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [otherPanelID])
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 0)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func focusPanelClearsUnreadCountAfterRecordingDesktopNotification() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)

        #expect(
            reducer.send(
                .focusPanel(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 0)
    }

    @Test
    func recordDesktopNotificationWithoutPanelIncrementsWorkspaceScopedUnreadCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: nil),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 1)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs.isEmpty)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: nil),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 2)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 2)
    }

    @Test
    func recordDesktopNotificationReturnsFalseForUnknownPanelID() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: UUID()),
                state: &state
            ) == false
        )
    }

    @Test
    func selectWorkspaceDoesNotClearPanelUnreadNotificationCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [panelID]
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID), state: &state))
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func selectWorkspaceClearsOnlyWorkspaceScopedUnreadNotificationCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [panelID]
        workspace.unreadWorkspaceNotificationCount = 2
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID), state: &state))
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 0)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func selectWorkspaceOnlyClearsSelectedWorkspaceScopedUnreadCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Second Workspace", activate: true), state: &state))
        let secondWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        var firstWorkspace = try #require(state.workspacesByID[firstWorkspaceID])
        var secondWorkspace = try #require(state.workspacesByID[secondWorkspaceID])
        firstWorkspace.unreadWorkspaceNotificationCount = 5
        secondWorkspace.unreadWorkspaceNotificationCount = 3
        state.workspacesByID[firstWorkspaceID] = firstWorkspace
        state.workspacesByID[secondWorkspaceID] = secondWorkspace

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: firstWorkspaceID), state: &state))
        #expect(try #require(state.workspacesByID[firstWorkspaceID]).unreadWorkspaceNotificationCount == 0)
        #expect(try #require(state.workspacesByID[secondWorkspaceID]).unreadWorkspaceNotificationCount == 3)

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: secondWorkspaceID), state: &state))
        #expect(try #require(state.workspacesByID[secondWorkspaceID]).unreadWorkspaceNotificationCount == 0)
    }

    @Test
    func focusSlotClearsUnreadNotificationForFocusedTargetPanel() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelIDs = Array(workspace.panels.keys)
        workspace.unreadPanelIDs = Set(panelIDs)
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state))
        let workspaceAfterFocus = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspaceAfterFocus.focusedPanelID)
        #expect(workspaceAfterFocus.unreadPanelIDs.contains(focusedPanelID) == false)
        #expect(workspaceAfterFocus.unreadNotificationCount == max(panelIDs.count - 1, 0))
    }

    @Test
    func focusSlotNoopDoesNotClearUnreadNotificationCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [panelID]
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state) == false)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func markPanelNotificationsReadClearsOnlySpecifiedPanel() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelIDs = Array(workspace.panels.keys)
        guard panelIDs.count >= 2 else {
            Issue.record("expected split-workspace fixture to contain at least two panels")
            return
        }
        workspace.unreadPanelIDs = Set(panelIDs)
        state.workspacesByID[workspaceID] = workspace

        let panelToMarkRead = panelIDs[0]
        #expect(
            reducer.send(
                .markPanelNotificationsRead(workspaceID: workspaceID, panelID: panelToMarkRead),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == Set(panelIDs.dropFirst()))
    }

    @Test
    func markPanelNotificationsReadIsIdempotentWhenPanelIsAlreadyRead() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(
            reducer.send(
                .markPanelNotificationsRead(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 0)
    }

}
