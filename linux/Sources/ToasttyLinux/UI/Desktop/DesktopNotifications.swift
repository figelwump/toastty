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
    public private(set) var delivered: [String] = []

    public init(application: OpaquePointer) {
        self.application = application
        let stringType = g_variant_type_new("s")
        let action = g_simple_action_new(Self.activateActionName, stringType)!
        g_variant_type_free(stringType)
        Signal.connectPointer(action, "activate") { [weak self] parameter in
            guard let self, let payload = variantStringValue(parameter.map(OpaquePointer.init)),
                  let decoded = Self.decodeTarget(payload) else { return }
            self.onActivate?(decoded.identifier, decoded.userInfo)
        }
        g_action_map_add_action(cast(application), cast(action))
        g_object_unref(UnsafeMutableRawPointer(action))
    }

    public func deliver(identifier: String, title: String, body: String, userInfo: [String: String], urgent: Bool = false) {
        // Without a session bus (sandboxed tests, no DBus) GIO's notification
        // backends hit CRITICAL assertions; drop the notification instead.
        guard g_application_get_dbus_connection(cast(application)) != nil else {
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
        delivered.removeAll { $0 == identifier }
        delivered.append(identifier)
    }

    public func withdraw(identifiers: [String]) {
        for identifier in identifiers {
            g_application_withdraw_notification(cast(application), identifier)
        }
        delivered.removeAll { identifiers.contains($0) }
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

    /// Smoke-script commands: `desktop-notify <body>`, `desktop-badge <n>`.
    func installDesktopAutomation() {
        AutomationScript.extensionCommands["desktop-notify"] = { app, argument, _ in
            let workspace = app.selectedWindowController().flatMap { app.store.state.workspaceSelection(in: $0.windowID) }
            var userInfo: [String: String] = [:]
            if let workspace {
                userInfo[DesktopNotificationUserInfoKey.workspaceID] = workspace.workspaceID.uuidString
                if let panel = workspace.workspace.focusedPanelID { userInfo[DesktopNotificationUserInfoKey.panelID] = panel.uuidString }
            }
            app.desktopNotifications.deliver(identifier: "smoke-\(UUID().uuidString)", title: "Toastty", body: argument, userInfo: userInfo)
        }
        AutomationScript.extensionCommands["desktop-badge"] = { _, argument, _ in
            LauncherBadge.shared.setCount(Int(argument))
        }
    }
}
