import CGtk
import Foundation

/// Unread count on the Ubuntu Dock (and other docks implementing the
/// `com.canonical.Unity.LauncherEntry` protocol): an `Update` signal on the
/// session bus naming `application://com.GiantThings.toastty.desktop` with
/// `count` / `count-visible`. Docks only match the signal to an icon when the
/// desktop file is installed (scripts/linux/install.sh).
///
/// Nothing in the app sets this count (macOS shows no Dock badge either);
/// the badge users see on Ubuntu Dock is its own count of Toastty's
/// notifications in the message tray, which `DesktopNotifications` keeps
/// in step with the unread marks by withdrawing read ones. Ubuntu Dock
/// adds this count to that one unless `application-counter-overrides-
/// notifications` is set, so driving both would double-count.
@MainActor
public final class LauncherBadge {
    public static let shared = LauncherBadge()
    public static let objectPath = "/com/GiantThings/toastty/LauncherEntry"
    public static var appURI: String { "application://\(LinuxAppController.applicationID).desktop" }

    public private(set) var count: Int?

    /// `nil` or 0 hides the badge.
    public func setCount(_ newCount: Int?) {
        let normalized = newCount.flatMap { $0 > 0 ? $0 : nil }
        guard normalized != count else { return }
        count = normalized
        emit()
    }

    private func emit() {
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            if let error { g_error_free(error) }
            return
        }
        defer { g_object_unref(UnsafeMutableRawPointer(connection)) }
        let parameters = Self.updateParameters(count: count)
        g_dbus_connection_emit_signal(
            connection, nil, Self.objectPath, "com.canonical.Unity.LauncherEntry", "Update", parameters, &error
        )
        if let error { g_error_free(error) }
        g_dbus_connection_flush_sync(connection, nil, nil)
    }

    /// `(sa{sv})`: app URI and {count: x, count-visible: b}. Floating.
    static func updateParameters(count: Int?) -> OpaquePointer {
        var entries: [OpaquePointer?] = [
            g_variant_new_dict_entry(g_variant_new_string("count"), g_variant_new_variant(g_variant_new_int64(gint64(count ?? 0)))),
            g_variant_new_dict_entry(g_variant_new_string("count-visible"), g_variant_new_variant(g_variant_new_boolean((count != nil).gboolean))),
        ]
        let entryType = g_variant_type_new("{sv}")
        defer { g_variant_type_free(entryType) }
        let dictionary = entries.withUnsafeMutableBufferPointer { g_variant_new_array(entryType, $0.baseAddress, 2) }
        var children: [OpaquePointer?] = [g_variant_new_string(appURI), dictionary]
        return children.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, 2) }!
    }
}
