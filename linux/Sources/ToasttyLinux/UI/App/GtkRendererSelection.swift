import CGtk
import Foundation

/// Keeps GTK off its Vulkan renderer, as Ghostty's own GTK app does
/// (`GDK_DISABLE=vulkan` in its `setGtkEnv`). Every Ghostty frame reaches
/// GTK as a new DMA-BUF texture; GTK's Vulkan renderer imports each one at
/// a high cost (on NVIDIA ~44% of a core for one animating terminal, plus
/// ~14 KB leaked inside the driver per frame), while the GL renderer
/// imports them cheaply and without growth.
///
/// GDK reads `GDK_DISABLE` once, in `gtk_init`, so the variable is set only
/// around that call and then restored: shells, agents and WebKit processes
/// started later inherit the user's environment unchanged. An explicit
/// `GSK_RENDERER` (e.g. `GSK_RENDERER=vulkan`) is respected.
enum GtkRendererSelection {
    @MainActor
    static func initializeGtk(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["GSK_RENDERER"] == nil else { return }
        let original = environment["GDK_DISABLE"]
        let disabled = [original, "vulkan"].compactMap { $0 }.filter { $0.isEmpty == false }.joined(separator: ",")
        setenv("GDK_DISABLE", disabled, 1)
        _ = gtk_init_check()
        if let original {
            setenv("GDK_DISABLE", original, 1)
        } else {
            unsetenv("GDK_DISABLE")
        }
    }
}
