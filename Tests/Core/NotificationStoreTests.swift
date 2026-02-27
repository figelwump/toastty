import CoreState
import Foundation
import Testing

struct NotificationStoreTests {
    @Test
    func suppressesWhenAppFocusedAndSourceVisible() {
        var store = NotificationStore()
        let decision = store.record(
            workspaceID: UUID(),
            panelID: UUID(),
            title: "Claude",
            body: "Waiting",
            appIsFocused: true,
            sourcePanelIsVisible: true,
            at: Date()
        )

        #expect(decision == NotificationDecision(stored: false, shouldSendSystemNotification: false))
        #expect(store.notifications.isEmpty)
    }

    @Test
    func deduplicatesByPanelIDForUnreadNotifications() {
        var store = NotificationStore()
        let workspaceID = UUID()
        let panelID = UUID()

        _ = store.record(
            workspaceID: workspaceID,
            panelID: panelID,
            title: "Claude",
            body: "First",
            appIsFocused: false,
            sourcePanelIsVisible: false,
            at: Date(timeIntervalSince1970: 10)
        )

        _ = store.record(
            workspaceID: workspaceID,
            panelID: panelID,
            title: "Claude",
            body: "Second",
            appIsFocused: false,
            sourcePanelIsVisible: false,
            at: Date(timeIntervalSince1970: 20)
        )

        #expect(store.notifications.count == 1)
        #expect(store.notifications[0].body == "Second")
        #expect(store.unreadCount == 1)
    }

    @Test
    func markReadUpdatesWorkspaceUnreadCount() {
        var store = NotificationStore()
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()

        _ = store.record(
            workspaceID: workspaceID,
            panelID: UUID(),
            title: "Codex",
            body: "Needs input",
            appIsFocused: false,
            sourcePanelIsVisible: false,
            at: Date()
        )

        _ = store.record(
            workspaceID: otherWorkspaceID,
            panelID: UUID(),
            title: "Claude",
            body: "Done",
            appIsFocused: false,
            sourcePanelIsVisible: false,
            at: Date()
        )

        #expect(store.unreadCount(for: workspaceID) == 1)
        store.markRead(workspaceID: workspaceID)
        #expect(store.unreadCount(for: workspaceID) == 0)
        #expect(store.unreadCount(for: otherWorkspaceID) == 1)
    }

    @Test
    func markReadCanScopeToSinglePanel() {
        var store = NotificationStore()
        let workspaceID = UUID()
        let panelA = UUID()
        let panelB = UUID()

        _ = store.record(
            workspaceID: workspaceID,
            panelID: panelA,
            title: "A",
            body: "one",
            appIsFocused: false,
            sourcePanelIsVisible: false,
            at: Date(timeIntervalSince1970: 1)
        )
        _ = store.record(
            workspaceID: workspaceID,
            panelID: panelB,
            title: "B",
            body: "two",
            appIsFocused: false,
            sourcePanelIsVisible: false,
            at: Date(timeIntervalSince1970: 2)
        )

        store.markRead(workspaceID: workspaceID, panelID: panelA)

        let unreadForA = store.notifications.first(where: { $0.panelID == panelA })?.isRead == false
        let unreadForB = store.notifications.first(where: { $0.panelID == panelB })?.isRead == false
        #expect(unreadForA == false)
        #expect(unreadForB == true)
    }
}
