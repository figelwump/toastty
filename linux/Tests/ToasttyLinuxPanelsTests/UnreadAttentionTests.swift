import CGtk
import CoreState
import Foundation
import Testing
@testable import ToasttyLinuxUI

/// The dock badge regression: Ubuntu Dock badges Toastty with the number of
/// its notifications still in GNOME's message tray, so read panels must
/// withdraw theirs (and seen panels must become read, as on macOS).
@MainActor
@Suite("Unread attention and the dock badge")
struct UnreadAttentionTests {
    /// Bootstrap state split into three panels; returns the workspace and
    /// the panels in creation order (the last one is focused).
    private func threePanelStore() throws -> (ReducerStoreBinding, UUID, UUID, [UUID]) {
        let store = ReducerStoreBinding(state: .bootstrap())
        let windowID = try #require(store.state.windows.first?.id)
        let workspaceID = try #require(store.state.workspacesByID.keys.first)
        var panels = [try #require(store.state.workspacesByID[workspaceID]?.focusedPanelID)]
        for _ in 0..<2 {
            store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right))
            panels.append(try #require(store.state.workspacesByID[workspaceID]?.focusedPanelID))
        }
        #expect(Set(panels).count == 3)
        return (store, windowID, workspaceID, panels)
    }

    private func userInfo(_ workspaceID: UUID, _ panelID: UUID?) -> [String: String] {
        var info = [DesktopNotificationUserInfoKey.workspaceID: workspaceID.uuidString]
        if let panelID { info[DesktopNotificationUserInfoKey.panelID] = panelID.uuidString }
        return info
    }

    private func unread(_ store: ReducerStoreBinding, _ workspaceID: UUID) -> Set<UUID> {
        store.state.workspacesByID[workspaceID]?.unreadPanelIDs ?? []
    }

    // MARK: Seen-unread clearing (macOS WorkspaceView parity)

    @Test func focusedUnreadPanelIsSeenOnlyWhileActive() throws {
        let (store, _, workspaceID, panels) = try threePanelStore()
        store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panels[0]))
        store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panels[2]))
        let workspace = try #require(store.state.workspacesByID[workspaceID])
        // Only the focused panel counts as seen; background panels stay unread.
        #expect(SeenUnreadPolicy.seenUnreadPanelIDs(in: workspace) == [panels[2]])
        #expect(SeenUnreadPolicy.candidate(workspace: workspace, appIsActive: false) == nil)
        #expect(SeenUnreadPolicy.candidate(workspace: workspace, appIsActive: true)?.panelIDs == [panels[2]])
    }

    @Test func schedulerMarksSeenPanelReadWhenAppIsActive() throws {
        let (store, windowID, workspaceID, panels) = try threePanelStore()
        var active = false
        let scheduler = SeenUnreadClearScheduler(store: store) { active }
        defer { scheduler.cancelAll() }
        // A notification for the focused panel while Toastty is in the background.
        store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panels[2]))
        store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panels[0]))
        scheduler.refresh(store.state)
        #expect(scheduler.pendingWindowIDs.isEmpty)
        #expect(unread(store, workspaceID) == [panels[0], panels[2]])

        // Toastty becomes active: the focused panel is seen and becomes read.
        active = true
        scheduler.refresh(store.state)
        #expect(scheduler.pendingWindowIDs == [windowID])
        scheduler.fire(windowID: windowID)
        #expect(unread(store, workspaceID) == [panels[0]])
        scheduler.refresh(store.state)
        #expect(scheduler.pendingWindowIDs.isEmpty)
    }

    @Test func schedulerKeepsPanelUnreadWhenUserMovedOnOrLeft() throws {
        let (store, windowID, workspaceID, panels) = try threePanelStore()
        var active = true
        let scheduler = SeenUnreadClearScheduler(store: store) { active }
        defer { scheduler.cancelAll() }
        store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panels[2]))
        scheduler.refresh(store.state)
        #expect(scheduler.pendingWindowIDs == [windowID])
        // Toastty lost focus before the delay ran out.
        active = false
        scheduler.fire(windowID: windowID)
        #expect(unread(store, workspaceID) == [panels[2]])
    }

    // MARK: Withdrawing read notifications

    @Test func ledgerWithdrawsExactlyTheReadNotifications() throws {
        let (store, _, workspaceID, panels) = try threePanelStore()
        var ledger = DesktopNotificationLedger()
        for (index, panelID) in panels.enumerated() {
            store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))
            ledger.record(identifier: "n\(index)", userInfo: userInfo(workspaceID, panelID))
        }
        ledger.record(identifier: "no-route", userInfo: [:])
        #expect(ledger.obsoleteIdentifiers(in: store.state).isEmpty)

        store.send(.markPanelNotificationsRead(workspaceID: workspaceID, panelID: panels[1]))
        #expect(ledger.obsoleteIdentifiers(in: store.state) == ["n1"])
        store.send(.focusPanel(workspaceID: workspaceID, panelID: panels[0]))
        #expect(ledger.obsoleteIdentifiers(in: store.state) == ["n0", "n1"])
        // A notification nothing tracks as unread is never "read".
        #expect(ledger.obsoleteIdentifiers(in: store.state).contains("no-route") == false)
    }

    @Test func workspaceLevelAndVanishedWorkspaceNotifications() throws {
        let (store, _, workspaceID, panels) = try threePanelStore()
        var ledger = DesktopNotificationLedger()
        store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: nil))
        ledger.record(identifier: "workspace", userInfo: userInfo(workspaceID, nil))
        ledger.record(identifier: "gone", userInfo: userInfo(UUID(), UUID()))
        #expect(ledger.obsoleteIdentifiers(in: store.state) == ["gone"])
        store.send(.focusPanel(workspaceID: workspaceID, panelID: panels[0]))
        #expect(ledger.obsoleteIdentifiers(in: store.state) == ["workspace", "gone"])
    }

    /// The dock count (Toastty's notifications left in the tray) follows the
    /// unread marks down and reaches zero, end to end through the reducer,
    /// the seen-unread scheduler and `DesktopNotifications`.
    @Test func dockNotificationCountDropsToZeroAsPanelsAreRead() throws {
        let (store, windowID, workspaceID, panels) = try threePanelStore()
        let application = try #require(g_application_new("com.GiantThings.toastty.tests", GApplicationFlags(rawValue: 1 << 5)))
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        let notifications = DesktopNotifications(application: OpaquePointer(application))
        var withdrawn: [String] = []
        notifications.withdrawHandler = { withdrawn.append($0) }
        let scheduler = SeenUnreadClearScheduler(store: store) { true }
        defer { scheduler.cancelAll() }

        for (index, panelID) in panels.enumerated() {
            store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))
            notifications.record(identifier: "n\(index)", userInfo: userInfo(workspaceID, panelID))
        }
        var counts = [notifications.ledger.entries.count]
        // The focused panel (n2) is on screen: seen, read, withdrawn.
        scheduler.refresh(store.state)
        scheduler.fire(windowID: windowID)
        notifications.withdrawObsolete(in: store.state)
        counts.append(notifications.ledger.entries.count)
        // Clicking into the other panels reads them.
        for panelID in [panels[0], panels[1]] {
            store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
            notifications.withdrawObsolete(in: store.state)
            counts.append(notifications.ledger.entries.count)
        }
        #expect(counts == [3, 2, 1, 0])
        #expect(withdrawn == ["n2", "n0", "n1"])
        #expect(unread(store, workspaceID).isEmpty)
        // Nothing left: another pass withdraws nothing.
        #expect(notifications.withdrawObsolete(in: store.state).isEmpty)
    }

    @Test func previousRunNotificationsAreWithdrawnAtStartupAndQuitWithdrawsAll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("linux-desktop-notifications.json")
        var previous = DesktopNotificationLedger()
        previous.record(identifier: "old-1", userInfo: [:])
        previous.record(identifier: "old-2", userInfo: userInfo(UUID(), UUID()))
        previous.save(to: url)

        let application = try #require(g_application_new("com.GiantThings.toastty.tests", GApplicationFlags(rawValue: 1 << 5)))
        defer { g_object_unref(UnsafeMutableRawPointer(application)) }
        let notifications = DesktopNotifications(application: OpaquePointer(application))
        var withdrawn: [String] = []
        notifications.withdrawHandler = { withdrawn.append($0) }
        // Not registered yet: the leftovers wait for "startup" and stay on disk.
        notifications.adoptLedgerFile(at: url)
        #expect(withdrawn.isEmpty)
        #expect(DesktopNotificationLedger.load(from: url)?.identifiers == ["old-1", "old-2"])
        notifications.withdrawStaleNotifications()
        #expect(withdrawn == ["old-1", "old-2"])
        #expect(FileManager.default.fileExists(atPath: url.path) == false)

        // This run's notifications are on disk until withdrawn.
        notifications.record(identifier: "new", userInfo: [:])
        #expect(DesktopNotificationLedger.load(from: url)?.identifiers == ["new"])
        notifications.withdrawAll()
        #expect(withdrawn == ["old-1", "old-2", "new"])
        #expect(notifications.ledger.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func launcherEntryHidesTheCountAtZero() {
        for count in [nil, 0] as [Int?] {
            let payload = LauncherBadge.updateParameters(count: count.flatMap { $0 > 0 ? $0 : nil })
            let text = String(cString: g_variant_print(payload, 1))
            #expect(text.contains("application://com.GiantThings.toastty.desktop"))
            #expect(text.contains("'count-visible': <false>"))
            g_variant_unref(g_variant_ref_sink(payload))
        }
    }
}
