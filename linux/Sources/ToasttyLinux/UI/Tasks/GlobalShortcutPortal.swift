#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The quick entry key in every app, through the XDG GlobalShortcuts portal
/// (`org.freedesktop.portal.GlobalShortcuts`), as macOS registers a Carbon
/// hot key. The desktop asks the user before it binds the key, and may bind
/// another one; the portal then reports which.
///
/// Flow: CreateSession → its Request's Response gives the session handle →
/// BindShortcuts → Activated signals call the handler. A new shortcut
/// closes the session and starts again.
///
/// Without the portal (another desktop, a sandbox without it) the key works
/// inside Toastty only: `.off` here, and `task.new`'s accelerator.
@MainActor
final class GlobalShortcutPortal {
    static let shortcutID = "quick-entry"

    private var connection: OpaquePointer?
    private var sessionHandle: String?
    private var handler: (@MainActor () -> Void)?
    private var subscriptions: [guint] = []
    private var requestCounter = 0
    private(set) var boundTrigger: String?

    func register(
        _ shortcut: QuickEntryShortcut?,
        handler: @escaping @MainActor () -> Void
    ) -> QuickEntryShortcutRegistration {
        closeSession()
        guard let shortcut else { return .off }
        guard let connection = bus(), isAvailable(connection) else {
            ToasttyLog.info("The GlobalShortcuts portal is not available; the quick entry key works inside Toastty", category: .tasks)
            return .off
        }
        self.handler = handler
        createSession(connection, trigger: Self.trigger(for: shortcut))
        return .registered(shortcut)
    }

    /// The portal's trigger for a shortcut, such as `ALT+SHIFT+t` (the XDG
    /// shortcuts format: modifiers, then the key's keysym name).
    static func trigger(for shortcut: QuickEntryShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) { parts.append("CTRL") }
        if shortcut.modifiers.contains(.option) { parts.append("ALT") }
        if shortcut.modifiers.contains(.shift) { parts.append("SHIFT") }
        if shortcut.modifiers.contains(.command) { parts.append("LOGO") }
        let key: String = switch shortcut.key {
        case .character(let character):
            switch character {
            case "-": "minus"
            case "=": "equal"
            case "[": "bracketleft"
            case "]": "bracketright"
            case ";": "semicolon"
            case "'": "apostrophe"
            case ",": "comma"
            case ".": "period"
            case "/": "slash"
            case "\\": "backslash"
            case "`": "grave"
            default: String(character).lowercased()
            }
        case .space: "space"
        case .return: "Return"
        case .tab: "Tab"
        case .function(let number): "F\(number)"
        }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    // MARK: - D-Bus

    private func bus() -> OpaquePointer? {
        if let connection { return connection }
        connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, nil)
        return connection
    }

    private func isAvailable(_ connection: OpaquePointer) -> Bool {
        guard let parameters = g_variant_parse(nil, "('org.freedesktop.portal.GlobalShortcuts', 'version')", nil, nil, nil) else { return false }
        let reply = g_dbus_connection_call_sync(
            cast(connection), "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.DBus.Properties", "Get", parameters, nil, GDBusCallFlags(rawValue: 0), 2000, nil, nil
        )
        guard let reply else { return false }
        g_variant_unref(reply)
        return true
    }

    private func nextToken() -> String {
        requestCounter += 1
        return "toastty\(ProcessInfo.processInfo.processIdentifier)_\(requestCounter)"
    }

    /// The object path the portal gives a request made with `token`.
    private func requestPath(_ connection: OpaquePointer, token: String) -> String {
        let unique = g_dbus_connection_get_unique_name(cast(connection)).map { String(cString: $0) } ?? ""
        let sender = unique.dropFirst().replacingOccurrences(of: ".", with: "_")
        return "/org/freedesktop/portal/desktop/request/\(sender)/\(token)"
    }

    private func createSession(_ connection: OpaquePointer, trigger: String) {
        let token = nextToken()
        let sessionToken = nextToken()
        awaitResponse(connection, path: requestPath(connection, token: token)) { [weak self] results in
            guard let self, let handle = Self.string(results, "session_handle") else {
                ToasttyLog.warning("The GlobalShortcuts portal refused a session", category: .tasks)
                return
            }
            self.sessionHandle = handle
            self.subscribeActivated(connection, session: handle)
            self.bind(connection, session: handle, trigger: trigger)
        }
        call(connection, "CreateSession", "({'handle_token': <'\(token)'>, 'session_handle_token': <'\(sessionToken)'>},)")
    }

    private func bind(_ connection: OpaquePointer, session: String, trigger: String) {
        let token = nextToken()
        awaitResponse(connection, path: requestPath(connection, token: token)) { [weak self] results in
            self?.boundTrigger = trigger
            ToasttyLog.info("Bound the quick entry key through the GlobalShortcuts portal", category: .tasks, metadata: [
                "trigger": trigger, "answered": String(results != nil),
            ])
        }
        let description = "Open Toastty quick entry"
        call(connection, "BindShortcuts",
             "(objectpath '\(session)', [('\(Self.shortcutID)', {'description': <'\(description)'>, 'preferred_trigger': <'\(trigger)'>})], '', {'handle_token': <'\(token)'>})")
    }

    private func subscribeActivated(_ connection: OpaquePointer, session: String) {
        let box = Unmanaged.passRetained(SignalBox { [weak self] parameters in
            guard let self, let parameters else { return }
            let id = g_variant_get_child_value(parameters, 1)
            defer { if let id { g_variant_unref(id) } }
            guard let id, let raw = g_variant_get_string(id, nil), String(cString: raw) == Self.shortcutID else { return }
            self.handler?()
        }).toOpaque()
        let subscription = g_dbus_connection_signal_subscribe(
            cast(connection), "org.freedesktop.portal.Desktop", "org.freedesktop.portal.GlobalShortcuts", "Activated",
            "/org/freedesktop/portal/desktop", nil, GDBusSignalFlags(rawValue: 0),
            GlobalShortcutPortal.signalTrampoline, box, GlobalShortcutPortal.releaseBox
        )
        subscriptions.append(subscription)
    }

    /// Calls `body` with the results of a Request's Response, or nil when
    /// the user or the portal declined.
    private func awaitResponse(_ connection: OpaquePointer, path: String, _ body: @escaping @MainActor (OpaquePointer?) -> Void) {
        var subscription: guint = 0
        let box = Unmanaged.passRetained(SignalBox { [weak self] parameters in
            if let self, let index = self.subscriptions.firstIndex(of: subscription) {
                self.subscriptions.remove(at: index)
                g_dbus_connection_signal_unsubscribe(cast(connection), subscription)
            }
            guard let parameters else { body(nil); return }
            let code = g_variant_get_child_value(parameters, 0)
            let results = g_variant_get_child_value(parameters, 1)
            defer {
                if let code { g_variant_unref(code) }
                if let results { g_variant_unref(results) }
            }
            let response = code.map { g_variant_get_uint32($0) } ?? 2
            body(response == 0 ? results : nil)
        }).toOpaque()
        subscription = g_dbus_connection_signal_subscribe(
            cast(connection), "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
            path, nil, GDBusSignalFlags(rawValue: 0),
            GlobalShortcutPortal.signalTrampoline, box, GlobalShortcutPortal.releaseBox
        )
        subscriptions.append(subscription)
    }

    private func call(_ connection: OpaquePointer, _ method: String, _ parameters: String) {
        var error: UnsafeMutablePointer<GError>?
        guard let variant = g_variant_parse(nil, parameters, nil, nil, &error) else {
            ToasttyLog.warning("Could not build a portal call", category: .tasks, metadata: [
                "method": method, "error": error.map { String(cString: $0.pointee.message) } ?? "unknown",
            ])
            if let error { g_error_free(error) }
            return
        }
        g_dbus_connection_call(
            cast(connection), "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.GlobalShortcuts", method, variant, nil, GDBusCallFlags(rawValue: 0), -1, nil, nil, nil
        )
    }

    private func closeSession() {
        guard let connection else { return }
        for subscription in subscriptions {
            g_dbus_connection_signal_unsubscribe(cast(connection), subscription)
        }
        subscriptions = []
        if let session = sessionHandle {
            g_dbus_connection_call(
                cast(connection), "org.freedesktop.portal.Desktop", session, "org.freedesktop.portal.Session",
                "Close", nil, nil, GDBusCallFlags(rawValue: 0), -1, nil, nil, nil
            )
        }
        sessionHandle = nil
        boundTrigger = nil
        handler = nil
    }

    private static func string(_ dictionary: OpaquePointer?, _ key: String) -> String? {
        guard let dictionary else { return nil }
        let type = g_variant_type_new("s")
        defer { g_variant_type_free(type) }
        guard let value = g_variant_lookup_value(cast(dictionary), key, type) else {
            // Object paths are type "o".
            let pathType = g_variant_type_new("o")
            defer { g_variant_type_free(pathType) }
            guard let path = g_variant_lookup_value(cast(dictionary), key, pathType) else { return nil }
            defer { g_variant_unref(path) }
            return g_variant_get_string(path, nil).map { String(cString: $0) }
        }
        defer { g_variant_unref(value) }
        return g_variant_get_string(value, nil).map { String(cString: $0) }
    }

    // MARK: - C callbacks

    /// Signals arrive on the main context, which runs on the main thread.
    private final class SignalBox: @unchecked Sendable {
        let body: @MainActor (OpaquePointer?) -> Void
        init(_ body: @escaping @MainActor (OpaquePointer?) -> Void) { self.body = body }
    }

    private static let signalTrampoline: GDBusSignalCallback = { _, _, _, _, _, parameters, data in
        guard let data else { return }
        let box = Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue()
        nonisolated(unsafe) let parameters = parameters
        MainActor.assumeIsolated { box.body(parameters) }
    }

    private static let releaseBox: GDestroyNotify = { data in
        guard let data else { return }
        Unmanaged<SignalBox>.fromOpaque(data).release()
    }
}
#endif
