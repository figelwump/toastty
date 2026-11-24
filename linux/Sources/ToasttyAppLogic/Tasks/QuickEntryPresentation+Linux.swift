import CoreState
import Foundation

/// Linux has no app-switcher focus to give back: the GTK frontend returns
/// focus to the Toastty window it took it from.
typealias QuickEntryFrontmostApplication = Never

/// The windows of quick entry, as the GTK frontend draws them
/// (linux/Sources/ToasttyLinux/UI/Tasks/QuickEntryWindow.swift). The shared
/// `QuickEntryController` drives this, as it drives the macOS panels in
/// `QuickEntryController+Mac.swift`.
@MainActor
protocol QuickEntryFrontend: AnyObject {
    /// Remembers which window and widget have the keyboard.
    func rememberFocusBeforePresenting()
    func showPanel(for model: QuickEntryModel, controller: QuickEntryController)
    func bringPanelForward()
    func focusPanel()
    func closePanel()
    func restoreFocus()
    /// A file chooser; `completion` gets the chosen files, or none.
    func chooseFiles(completion: @escaping @MainActor ([URL]) -> Void)
    func showToast(_ message: String, duration: Duration)
    func showPicker(_ picker: QuickEntryPicker, for model: QuickEntryModel, controller: QuickEntryController)
    func hidePicker()
    /// Registers the global shortcut (the XDG GlobalShortcuts portal).
    func registerGlobalShortcut(
        _ shortcut: QuickEntryShortcut?,
        handler: @escaping @MainActor () -> Void
    ) -> QuickEntryShortcutRegistration
}

@MainActor
final class QuickEntryPresentation {
    static let frontmostApplication: @MainActor () -> Never? = { nil }

    /// Set by the GTK frontend at startup. Without one (tests, an
    /// app-logic-only build) the controller keeps its draft and shows
    /// nothing.
    static weak var frontend: (any QuickEntryFrontend)?

    init(frontmostApplication: @escaping @MainActor () -> Never?) {
        _ = frontmostApplication
    }

    private var frontend: (any QuickEntryFrontend)? { Self.frontend }

    func registerHotKey(
        _ shortcut: QuickEntryShortcut?,
        handler: @escaping @MainActor () -> Void
    ) -> QuickEntryShortcutRegistration {
        guard let frontend else {
            return shortcut.map { .failed($0, -1) } ?? .off
        }
        return frontend.registerGlobalShortcut(shortcut, handler: handler)
    }

    func rememberFocusBeforePresenting() { frontend?.rememberFocusBeforePresenting() }
    func showPanel(for model: QuickEntryModel, controller: QuickEntryController) {
        frontend?.showPanel(for: model, controller: controller)
    }
    func bringPanelForward() { frontend?.bringPanelForward() }
    func focusPanel() { frontend?.focusPanel() }
    var logMetadata: [String: String] { ["frontend": frontend == nil ? "none" : "gtk"] }
    func closePanel() { frontend?.closePanel() }
    func restoreFocus() { frontend?.restoreFocus() }

    func chooseFiles(completion: @escaping @MainActor ([URL]) -> Void) {
        guard let frontend else {
            completion([])
            return
        }
        frontend.chooseFiles(completion: completion)
    }

    func showToast(_ message: String, duration: Duration) {
        frontend?.showToast(message, duration: duration)
    }

    /// GTK delivers a click on a pill after the picker's focus loss, as one
    /// event; nothing to drop.
    func consumePillClickThatClosedPicker(_ kind: QuickEntryPickerKind) -> Bool { false }

    func showPicker(_ picker: QuickEntryPicker, for model: QuickEntryModel, controller: QuickEntryController) {
        frontend?.showPicker(picker, for: model, controller: controller)
    }

    func hidePicker() { frontend?.hidePicker() }
}
