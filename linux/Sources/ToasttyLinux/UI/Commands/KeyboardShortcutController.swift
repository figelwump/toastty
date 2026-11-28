import CGtk
import Foundation

/// Capture-phase key handling on a window: matches the command table before
/// the focused widget (a terminal) sees the key, so app shortcuts win, and
/// reports Alt press/release for the sidebar shortcut hints.
///
/// Skipped while an `AdwDialog` is open so text entries in dialogs keep
/// their editing keys.
@MainActor
public final class KeyboardShortcutController {
    public var matcher: ShortcutMatcher
    private let window: WidgetPtr
    private let perform: (String) -> Bool
    private let onAltChanged: (Bool) -> Void
    private var altDown = false

    public init(
        window: WidgetPtr,
        matcher: ShortcutMatcher,
        perform: @escaping (String) -> Bool,
        onAltChanged: @escaping (Bool) -> Void
    ) {
        self.window = window
        self.matcher = matcher
        self.perform = perform
        self.onAltChanged = onAltChanged

        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(controller) { [weak self] keyval, keycode, state in
            self?.keyPressed(controller: controller, keyval: keyval, keycode: keycode, state: state) ?? false
        }
        Signal.connectKeyReleased(controller) { [weak self] keyval, _, _ in
            guard let self else { return }
            if Self.isAlt(keyval) { self.setAlt(false) }
        }
        gtk_widget_add_controller(window, controller)

        let focus = gtk_event_controller_focus_new()!
        Signal.connect(focus, "leave") { [weak self] in self?.setAlt(false) }
        gtk_widget_add_controller(window, focus)
    }

    public func resetModifiers() { setAlt(false) }

    private static func isAlt(_ keyval: UInt32) -> Bool {
        let key = Int32(keyval)
        return key == GDK_KEY_Alt_L || key == GDK_KEY_Alt_R || key == GDK_KEY_Meta_L || key == GDK_KEY_Meta_R
    }

    private func setAlt(_ down: Bool) {
        guard down != altDown else { return }
        altDown = down
        onAltChanged(down)
    }

    private var dialogIsOpen: Bool {
        adw_application_window_get_visible_dialog(cast(window)) != nil
    }

    private func keyPressed(controller: OpaquePointer, keyval: UInt32, keycode: UInt32, state: GdkModifierType) -> Bool {
        if Self.isAlt(keyval) {
            // Alt alone shows hints; with Ctrl/Shift held it is a chord.
            let others = state.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_SUPER_MASK.rawValue)
            setAlt(others == 0)
            return false
        }
        if altDown, state.rawValue & GDK_ALT_MASK.rawValue == 0 { setAlt(false) }
        guard dialogIsOpen == false else { return false }

        var unshifted: UInt32?
        var consumed: UInt32 = 0
        if let event = gtk_event_controller_get_current_event(controller) {
            consumed = gdk_key_event_get_consumed_modifiers(event).rawValue
            if let display = gdk_event_get_display(event) {
                var level0: guint = 0
                if gdk_display_translate_key(display, keycode, GdkModifierType(rawValue: 0), Int32(gdk_key_event_get_layout(event)), &level0, nil, nil, nil).bool {
                    unshifted = level0
                }
            }
        }
        guard let commandID = matcher.match(keyval: keyval, unshiftedKeyval: unshifted, state: state.rawValue, consumed: consumed) else {
            return false
        }
        return perform(commandID)
    }
}
