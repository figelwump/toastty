#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
import ToasttyAppKitShim
import ToasttyAppLogic

/// `LinuxPlatformServices` for the GTK frontend: AdwAlertDialog alerts,
/// GtkUriLauncher / GtkFileLauncher, the GDK clipboard, window presentation
/// and snapshots, GNotification desktop notifications with click-through
/// routing, and the Ubuntu Dock unread badge.
///
/// Wiring (app-logic frontend bootstrap, before `LinuxAppLogic.init`):
///
///     let services = GtkPlatformServices(app: app)
///     let logic = LinuxAppLogic(options: .init(platformServices: services, …))
@MainActor
public final class GtkPlatformServices: LinuxPlatformServices {
    private weak var app: LinuxAppController?
    public let notifications: DesktopNotifications
    private var activeObserver: [gulong] = []

    public init(app: LinuxAppController) {
        self.app = app
        notifications = app.desktopNotifications
        notifications.onActivate = { [weak self] identifier, userInfo in
            self?.activateApplication()
            LinuxPlatform.handleNotificationActivation(identifier: identifier, userInfo: userInfo)
        }
    }

    private var windowControllers: [LinuxWindowController] { app?.orderedWindows ?? [] }

    public var isApplicationActive: Bool {
        app?.isApplicationActive ?? false
    }

    public func activateApplication() {
        (app?.selectedWindowController() ?? windowControllers.first)?.present()
    }

    public func openURL(_ url: URL) -> Bool {
        DesktopLauncher.open(url, parent: app?.selectedWindowController()?.window)
    }

    // MARK: Alerts

    private func makeDialog(_ alert: LinuxAlertRequest) -> (WidgetPtr, [String]) {
        let dialog = widget(adw_alert_dialog_new(alert.messageText, alert.informativeText.isEmpty ? nil : alert.informativeText)!)
        var ids: [String] = []
        for (index, button) in alert.buttons.enumerated() {
            let id = "b\(index)"
            ids.append(id)
            adw_alert_dialog_add_response(cast(dialog), id, button.title)
            if button.isDefaultAction {
                adw_alert_dialog_set_default_response(cast(dialog), id)
                adw_alert_dialog_set_response_appearance(
                    cast(dialog), id, alert.style == .critical ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED
                )
            }
        }
        if ids.isEmpty {
            adw_alert_dialog_add_response(cast(dialog), "b0", "OK")
            ids = ["b0"]
        }
        let cancel = alert.safeDefaultButtonIndex
        adw_alert_dialog_set_close_response(cast(dialog), ids[min(cancel, ids.count - 1)])
        return (dialog, ids)
    }

    private func parentWindow(_ windowID: UUID?) -> WidgetPtr? {
        if let windowID, let controller = app?.windows[windowID] { return controller.window }
        return app?.selectedWindowController()?.window
    }

    /// Blocking alert: spins the main loop until the user answers (AppKit's
    /// `runModal` semantics). Without a window, answers the safe button.
    public func runModalAlert(_ alert: LinuxAlertRequest) -> Int {
        guard let parent = parentWindow(nil) else { return alert.safeDefaultButtonIndex }
        var answer: Int?
        present(alert, parent: parent) { answer = $0 }
        while answer == nil {
            g_main_context_iteration(nil, 1)
        }
        return answer ?? alert.safeDefaultButtonIndex
    }

    public func presentAlert(_ alert: LinuxAlertRequest, windowID: UUID?, completion: @escaping @MainActor (Int) -> Void) {
        guard let parent = parentWindow(windowID) else {
            completion(alert.safeDefaultButtonIndex)
            return
        }
        present(alert, parent: parent, completion: completion)
    }

    private func present(_ alert: LinuxAlertRequest, parent: WidgetPtr, completion: @escaping @MainActor (Int) -> Void) {
        let (dialog, ids) = makeDialog(alert)
        var answered = false
        Signal.connectPointer(dialog, "response") { response in
            guard answered == false else { return }
            answered = true
            let id = response.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            completion(ids.firstIndex(of: id) ?? alert.safeDefaultButtonIndex)
        }
        adw_dialog_present(cast(dialog), parent)
    }

    // MARK: Clipboard

    public func writeClipboardString(_ string: String) -> Bool {
        DesktopLauncher.copyToClipboard(string)
        return true
    }

    public func readClipboardString() -> String? {
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) else { return nil }
        final class Box: @unchecked Sendable { var done = false; var text: String? }
        let box = Box()
        let unmanaged = Unmanaged.passRetained(box).toOpaque()
        gdk_clipboard_read_text_async(clipboard, nil, { source, result, data in
            let box = Unmanaged<Box>.fromOpaque(data!).takeRetainedValue()
            if let raw = gdk_clipboard_read_text_finish(OpaquePointer(source!), result, nil) {
                box.text = String(cString: raw)
                g_free(raw)
            }
            box.done = true
        }, unmanaged)
        let deadline = g_get_monotonic_time() + 1_000_000
        while box.done == false, g_get_monotonic_time() < deadline {
            g_main_context_iteration(nil, 0)
            g_usleep(1000)
        }
        return box.text
    }

    // MARK: Badge, windows, screens

    public func setApplicationBadgeCount(_ count: Int?) {
        LauncherBadge.shared.setCount(count)
    }

    public func windowSnapshots() -> [LinuxWindowSnapshot] {
        windowControllers.map { controller in
            let window = controller.window
            let focus = gtk_root_get_focus(cast(window))
            let editing = focus.map { isInstance($0, of: gtk_text_get_type()) || isInstance($0, of: gtk_text_view_get_type()) } ?? false
            return LinuxWindowSnapshot(
                id: controller.windowID,
                frame: CGRect(x: 0, y: 0, width: CGFloat(gtk_widget_get_width(window)), height: CGFloat(gtk_widget_get_height(window))),
                isVisible: gtk_widget_get_visible(window).bool,
                isMiniaturized: false,
                isKey: gtk_window_is_active(cast(window)).bool,
                isMain: gtk_window_is_active(cast(window)).bool,
                hasTextInputFocus: editing
            )
        }
    }

    public func presentWindow(id: UUID, makeKey: Bool) {
        guard let controller = app?.windows[id] else { return }
        if makeKey { controller.present() } else { gtk_widget_set_visible(controller.window, 1) }
    }

    public func screenSnapshots() -> [LinuxScreenSnapshot] {
        guard let display = gdk_display_get_default(), let monitors = gdk_display_get_monitors(display) else { return [] }
        var result: [LinuxScreenSnapshot] = []
        for index in 0..<g_list_model_get_n_items(monitors) {
            guard let item = g_list_model_get_item(monitors, index) else { continue }
            defer { g_object_unref(item) }
            let monitor = OpaquePointer(item)
            var geometry = GdkRectangle()
            gdk_monitor_get_geometry(monitor, &geometry)
            let frame = CGRect(x: CGFloat(geometry.x), y: CGFloat(geometry.y), width: CGFloat(geometry.width), height: CGFloat(geometry.height))
            let name = gdk_monitor_get_connector(monitor).map { String(cString: $0) } ?? ""
            result.append(LinuxScreenSnapshot(frame: frame, scale: CGFloat(gdk_monitor_get_scale(monitor)), name: name))
        }
        return result
    }

    public func captureWindowPNG(id: UUID) -> Data? {
        guard let controller = app?.windows[id] else { return nil }
        let path = NSTemporaryDirectory() + "toastty-window-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // A window whose state just changed may still be waiting for its
        // frame clock (Broadway without a viewer never ticks one); lay it out
        // at its current size so the snapshot sees every new widget.
        toastty_window_force_layout(cast(controller.window), 0, 0)
        var error: UnsafeMutablePointer<GError>?
        guard toastty_widget_write_png(controller.window, path, nil, &error).bool else {
            let message = error.flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "unknown error"
            if let error { g_error_free(error) }
            ToasttyLog.warning("window capture failed", category: .automation, metadata: ["error": message])
            return nil
        }
        return FileManager.default.contents(atPath: path)
    }

    public func userIdleSeconds() -> TimeInterval? { LinuxSessionPresence.idleSeconds() }
    public func isScreenLocked() -> Bool? { LinuxSessionPresence.isScreenLocked() }

    // MARK: Notifications

    public func notificationAuthorization() -> LinuxNotificationAuthorization { .authorized }
    public func requestNotificationAuthorization() -> Bool { true }

    public func deliverNotification(_ notification: LinuxDesktopNotification) throws {
        notifications.deliver(
            identifier: notification.identifier,
            title: notification.title,
            body: notification.body,
            userInfo: notification.userInfo
        )
        // Delivery is asynchronous (authorization, Task hops): the panel may
        // have been read meanwhile, with no state change left to notice it.
        if let state = app?.store.state {
            notifications.withdrawObsolete(in: state)
        }
    }

    public func removeNotifications(identifiers: [String]) {
        notifications.withdraw(identifiers: identifiers)
    }
}
#endif
