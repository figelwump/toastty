import CGtk
import Foundation

/// The Toastty app icon: `linux/data/icons/hicolor`, rendered from macOS's
/// `Assets.xcassets/AppIcon` (the toast artwork in `terminal-toast-1024.svg`),
/// named after the application ID like the desktop file.
///
/// `install()` makes the icon theme find it in a checkout (`linux/data/icons`)
/// and in an install outside `XDG_DATA_DIRS` (`<prefix>/lib/toastty/share/icons`),
/// and sets it as the default window icon. GNOME's dock and Alt+Tab icon on
/// Wayland come from the installed desktop file instead (scripts/linux/install.sh).
@MainActor
public enum AppIcon {
    public static let name = LinuxAppController.applicationID

    public static func install() {
        guard let display = gdk_display_get_default(), let theme = gtk_icon_theme_get_for_display(display) else { return }
        for directory in searchDirectories() {
            gtk_icon_theme_add_search_path(theme, directory.path)
        }
        gtk_window_set_default_icon_name(name)
    }

    /// The file name the icon theme resolves the app icon to at 128px, if any.
    static func resolvedFile() -> String? {
        guard let display = gdk_display_get_default(), let theme = gtk_icon_theme_get_for_display(display),
              gtk_icon_theme_has_icon(theme, name).bool,
              let paintable = gtk_icon_theme_lookup_icon(theme, name, nil, 128, 1, GTK_TEXT_DIR_NONE, GtkIconLookupFlags(0)) else {
            return nil
        }
        defer { g_object_unref(UnsafeMutableRawPointer(paintable)) }
        guard let file = gtk_icon_paintable_get_file(paintable) else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        guard let basename = g_file_get_basename(file) else { return nil }
        defer { g_free(basename) }
        return String(cString: basename)
    }

    /// Icon directories next to the app resources (see `WebPanelResources`):
    /// `<checkout>/linux/data/icons` for `<checkout>/Sources/App/Resources`,
    /// `<prefix>/lib/toastty/share/icons` for `<prefix>/lib/toastty/share/toastty/Resources`.
    static func searchDirectories(resources: URL? = WebPanelResources.resourcesDirectory()) -> [URL] {
        guard let resources else { return [] }
        let up = { (url: URL, count: Int) in (0..<count).reduce(url) { url, _ in url.deletingLastPathComponent() } }
        let candidates = [
            up(resources, 3).appendingPathComponent("linux/data/icons", isDirectory: true),
            up(resources, 2).appendingPathComponent("icons", isDirectory: true),
        ]
        return candidates.filter { candidate in
            FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("hicolor/scalable/apps/\(name).svg").path
            )
        }
    }
}
