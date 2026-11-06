import CGtk
import CGtkShim
import CoreState
import Foundation

/// Desktop notifications through `GNotification`
/// (`g_application_send_notification`, the org.gtk.Notifications /
/// portal path GNOME Shell shows). Clicking a notification (or its "Show"
/// button) activates `app.notification-activate` with the notification's
/// identifier and routing keys (`DesktopNotificationUserInfoKey`
/// workspace/panel IDs), which `onActivate` turns into "focus that
/// workspace and panel". GNOME only shows notifications for apps with an
/// installed `com.GiantThings.toastty.desktop` (scripts/linux/install.sh).
@MainActor
public final class DesktopNotifications {
    public static let activateActionName = "notification-activate"

    private let application: OpaquePointer
    /// Runs when the user activates a notification.
    public var onActivate: ((_ identifier: String, _ userInfo: [String: String]) -> Void)?
    /// Delivered notifications not yet withdrawn (see `DesktopNotificationLedger`).
    public private(set) var ledger = DesktopNotificationLedger()
    /// Where `ledger` is kept between runs (`adoptLedgerFile(at:)`), so a
    /// run that crashed or was killed does not leave its notifications, and
    /// the dock badge they produce, behind for good.
    public private(set) var ledgerFileURL: URL?
    private var staleIdentifiers: [String] = []
    /// Replaces `g_application_withdraw_notification` (tests).
    var withdrawHandler: ((String) -> Void)?

    public var delivered: [String] { ledger.identifiers }

    public init(application: OpaquePointer) {
        self.application = application
        let stringType = g_variant_type_new("s")
        let action = g_simple_action_new(Self.activateActionName, stringType)!
        g_variant_type_free(stringType)
        Signal.connectPointer(action, "activate") { [weak self] parameter in
            guard let self, let payload = variantStringValue(parameter.map(OpaquePointer.init)),
                  let decoded = Self.decodeTarget(payload) else { return }
            // A clicked notification is done; a server that keeps it would
            // keep it in the dock count.
            self.withdraw(identifiers: [decoded.identifier])
            self.onActivate?(decoded.identifier, decoded.userInfo)
        }
        g_action_map_add_action(cast(application), cast(action))
        g_object_unref(UnsafeMutableRawPointer(action))
        // Registration (and with it the D-Bus connection) precedes
        // "startup"; withdraw what a previous run left once it exists.
        Signal.connect(application, "startup", after: true) { [weak self] in self?.withdrawStaleNotifications() }
        // Quitting withdraws everything: unread marks persist in the layout,
        // but notifications of a closed app would only keep the dock badge.
        Signal.connect(application, "shutdown") { [weak self] in self?.withdrawAll() }
    }

    private var sessionBus: OpaquePointer? { g_application_get_dbus_connection(cast(application)) }

    public func deliver(identifier: String, title: String, body: String, userInfo: [String: String], urgent: Bool = false) {
        // Without a session bus (sandboxed tests, no DBus) GIO's notification
        // backends hit CRITICAL assertions; drop the notification instead.
        guard sessionBus != nil else {
            FileHandle.standardError.write(Data("toastty-linux: no session bus; dropped notification \"\(title)\"\n".utf8))
            return
        }
        let notification = g_notification_new(title)!
        if body.isEmpty == false { g_notification_set_body(notification, body) }
        if let icon = g_themed_icon_new(LinuxAppController.applicationID) {
            g_notification_set_icon(notification, icon)
            g_object_unref(UnsafeMutableRawPointer(icon))
        }
        g_notification_set_priority(notification, urgent ? G_NOTIFICATION_PRIORITY_HIGH : G_NOTIFICATION_PRIORITY_NORMAL)
        let target = Self.encodeTarget(identifier: identifier, userInfo: userInfo)
        g_notification_set_default_action_and_target_value(notification, "app.\(Self.activateActionName)", variantString(target))
        g_notification_add_button_with_target_value(notification, "Show", "app.\(Self.activateActionName)", variantString(target))
        g_application_send_notification(cast(application), identifier, notification)
        g_object_unref(UnsafeMutableRawPointer(notification))
        record(identifier: identifier, userInfo: userInfo)
    }

    /// Tracks a delivered notification (`deliver` calls it; tests call it directly).
    func record(identifier: String, userInfo: [String: String]) {
        ledger.record(identifier: identifier, userInfo: userInfo)
        persistLedger()
    }

    public func withdraw(identifiers: [String]) {
        guard identifiers.isEmpty == false else { return }
        for identifier in identifiers {
            withdrawFromServer(identifier)
        }
        let before = ledger
        ledger.remove(identifiers: identifiers)
        if ledger != before { persistLedger() }
    }

    /// Withdraws the notifications whose workspace/panel the user has read
    /// since (`DesktopNotificationLedger.obsoleteIdentifiers`); returns them.
    @discardableResult
    public func withdrawObsolete(in state: AppState) -> [String] {
        let obsolete = ledger.obsoleteIdentifiers(in: state)
        withdraw(identifiers: obsolete)
        return obsolete
    }

    public func withdrawAll() {
        withdraw(identifiers: ledger.identifiers)
        flushSessionBus()
    }

    /// Keeps the ledger in `url` from now on and withdraws the notifications
    /// a previous run recorded there (now when the application is already
    /// registered, otherwise at "startup").
    public func adoptLedgerFile(at url: URL) {
        ledgerFileURL = url
        let current = Set(ledger.identifiers)
        let previous = DesktopNotificationLedger.load(from: url)?.identifiers ?? []
        staleIdentifiers += previous.filter { current.contains($0) == false }
        if g_application_get_is_registered(cast(application)).bool {
            withdrawStaleNotifications()
        }
    }

    func withdrawStaleNotifications() {
        let stale = staleIdentifiers
        staleIdentifiers = []
        for identifier in stale {
            withdrawFromServer(identifier)
        }
        if stale.isEmpty == false { flushSessionBus() }
        persistLedger()
    }

    private func withdrawFromServer(_ identifier: String) {
        if let withdrawHandler {
            withdrawHandler(identifier)
            return
        }
        // Same guard as `deliver`: without a bus nothing was shown.
        guard sessionBus != nil else { return }
        g_application_withdraw_notification(cast(application), identifier)
    }

    /// GIO sends withdrawals asynchronously; at shutdown they must leave
    /// before the connection closes.
    private func flushSessionBus() {
        guard withdrawHandler == nil, let bus = sessionBus else { return }
        g_dbus_connection_flush_sync(bus, nil, nil)
    }

    private func persistLedger() {
        guard let ledgerFileURL else { return }
        // Stale identifiers not withdrawn yet stay on disk until they are.
        var onDisk = ledger
        for identifier in staleIdentifiers where onDisk.identifiers.contains(identifier) == false {
            onDisk.record(identifier: identifier, userInfo: [:])
        }
        onDisk.save(to: ledgerFileURL)
    }

    nonisolated static func encodeTarget(identifier: String, userInfo: [String: String]) -> String {
        let object: [String: Any] = ["id": identifier, "userInfo": userInfo]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    nonisolated static func decodeTarget(_ payload: String) -> (identifier: String, userInfo: [String: String])? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let identifier = object["id"] as? String else { return nil }
        return (identifier, object["userInfo"] as? [String: String] ?? [:])
    }
}

/// Reducer actions that bring a notification's workspace and panel to
/// the front (used when the app-logic notification coordinator is not
/// attached; with it, `LinuxPlatform.handleNotificationActivation` routes
/// through `SystemNotificationResponseCoordinator` instead).
public enum NotificationRoute {
    public static func actions(userInfo: [String: String], state: AppState) -> [AppAction] {
        guard let workspaceID = userInfo[DesktopNotificationUserInfoKey.workspaceID].flatMap(UUID.init(uuidString:)),
              let workspace = state.workspacesByID[workspaceID],
              let windowID = state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id else { return [] }
        var actions: [AppAction] = [.selectWindow(windowID: windowID), .selectWorkspace(windowID: windowID, workspaceID: workspaceID)]
        if let panelID = userInfo[DesktopNotificationUserInfoKey.panelID].flatMap(UUID.init(uuidString:)) {
            if workspace.rightAuxPanel.tabID(containingPanelID: panelID) != nil {
                actions.append(.focusRightAuxPanel(workspaceID: workspaceID, panelID: panelID))
            } else if let tab = workspace.orderedTabs.first(where: { $0.panels[panelID] != nil }) {
                actions.append(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tab.id))
                actions.append(.focusPanel(workspaceID: workspaceID, panelID: panelID))
            }
        }
        return actions
    }
}

extension LinuxAppController {
    private static var notificationsByApplication: [OpaquePointer: DesktopNotifications] = [:]

    /// The application's notification sender. Until app-logic replaces
    /// `onActivate`, activating a notification focuses its workspace/panel
    /// with reducer actions and raises the window.
    public var desktopNotifications: DesktopNotifications {
        if let existing = Self.notificationsByApplication[application] { return existing }
        let notifications = DesktopNotifications(application: application)
        notifications.onActivate = { [weak self] _, userInfo in
            guard let self else { return }
            for action in NotificationRoute.actions(userInfo: userInfo, state: self.store.state) {
                self.store.send(action)
            }
            self.selectedWindowController()?.present()
        }
        Self.notificationsByApplication[application] = notifications
        return notifications
    }

    /// The notification sender if one was created (nothing to withdraw otherwise).
    var existingDesktopNotifications: DesktopNotifications? { Self.notificationsByApplication[application] }

    /// Smoke-script commands: `desktop-notify <body>`, `desktop-badge <n>`.
    func installDesktopAutomation() {
        AutomationScript.extensionCommands["desktop-notify"] = { app, argument, _ in
            let workspace = app.selectedWindowController().flatMap { app.store.state.workspaceSelection(in: $0.windowID) }
            var userInfo: [String: String] = [:]
            if let workspace {
                userInfo[DesktopNotificationUserInfoKey.workspaceID] = workspace.workspaceID.uuidString
                if let panel = workspace.workspace.focusedPanelID { userInfo[DesktopNotificationUserInfoKey.panelID] = panel.uuidString }
                // Like the real senders, mark the panel unread first; the
                // notification is withdrawn once that mark is read.
                app.store.send(.recordDesktopNotification(workspaceID: workspace.workspaceID, panelID: workspace.workspace.focusedPanelID))
            }
            app.desktopNotifications.deliver(identifier: "smoke-\(UUID().uuidString)", title: "Toastty", body: argument, userInfo: userInfo)
        }
        AutomationScript.extensionCommands["desktop-badge"] = { _, argument, _ in
            LauncherBadge.shared.setCount(Int(argument))
        }
    }
}
