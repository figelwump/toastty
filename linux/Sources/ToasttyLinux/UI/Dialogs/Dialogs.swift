import CGtk
import CoreState
import Foundation

/// Alert-style dialogs (`AdwAlertDialog`): rename and close confirmations.
@MainActor
public enum Dialogs {
    /// Most recent dialog, for automation (`dialog-respond`).
    public private(set) static var current: AlertHandle?

    @MainActor
    public final class AlertHandle {
        public let dialog: WidgetPtr
        let ref: GObjectRef
        public let entry: WidgetPtr?
        let onResponse: (String, String?) -> Void

        init(dialog: WidgetPtr, entry: WidgetPtr?, onResponse: @escaping (String, String?) -> Void) {
            self.dialog = dialog
            self.ref = GObjectRef(sinking: dialog)
            self.entry = entry
            self.onResponse = onResponse
        }

        public var heading: String {
            String(cString: adw_alert_dialog_get_heading(cast(dialog)))
        }

        /// Answers as if the user clicked `response`'s button (automation/
        /// tests): types `text` into the entry, then activates the real
        /// button, so the answer travels the same `response` signal path as
        /// a click. Returns false if the response has no enabled button.
        @discardableResult
        public func respond(_ response: String, text: String? = nil) -> Bool {
            if let text, let entry { gtk_editable_set_text(cast(entry), text) }
            guard let button = responseButton(response), gtk_widget_is_sensitive(button).bool else { return false }
            return gtk_widget_activate(button).bool
        }

        /// Presses Enter in the entry (automation/tests): the entry's text
        /// widget activates the dialog's default response, as typing a name
        /// and hitting Return does. Returns false without an entry.
        @discardableResult
        public func submit(text: String? = nil) -> Bool {
            guard let entry else { return false }
            if let text { gtk_editable_set_text(cast(entry), text) }
            // Enter in an entry with `activates-default` runs its text
            // widget's `default.activate` action, which the dialog routes to
            // the default response's button.
            guard gtk_entry_get_activates_default(cast(entry)).bool else { return false }
            let textWidget = Gtk.children(entry).first(where: { isInstance($0, of: gtk_text_get_type()) }) ?? entry
            gtk_widget_activate_default(textWidget)
            return true
        }

        /// Dismisses the dialog as Escape does (the close response), after
        /// typing `text` into the entry.
        public func dismiss(text: String? = nil) {
            if let text, let entry { gtk_editable_set_text(cast(entry), text) }
            adw_dialog_close(cast(dialog))
        }

        /// The button libadwaita built for `response`, found by its label.
        func responseButton(_ response: String) -> WidgetPtr? {
            guard adw_alert_dialog_has_response(cast(dialog), response).bool,
                  let label = adw_alert_dialog_get_response_label(cast(dialog), response) else { return nil }
            let wanted = String(cString: label)
            func search(_ root: WidgetPtr) -> WidgetPtr? {
                if isInstance(root, of: gtk_button_get_type()),
                   let current = gtk_button_get_label(cast(root)), String(cString: current) == wanted {
                    return root
                }
                for child in Gtk.children(root) {
                    if let found = search(child) { return found }
                }
                return nil
            }
            return search(dialog)
        }
    }

    public static func rename(
        parent: WidgetPtr,
        heading: String,
        current: String,
        placeholder: String,
        allowsEmpty: Bool = false,
        onFinish: (() -> Void)? = nil,
        onRename: @escaping (String) -> Void
    ) {
        let dialog = widget(adw_alert_dialog_new(heading, nil)!)
        let entry = gtk_entry_new()!
        gtk_editable_set_text(cast(entry), current)
        gtk_entry_set_placeholder_text(cast(entry), placeholder)
        gtk_entry_set_activates_default(cast(entry), 1)
        adw_alert_dialog_set_extra_child(cast(dialog), entry)
        adw_alert_dialog_add_response(cast(dialog), "cancel", "_Cancel")
        adw_alert_dialog_add_response(cast(dialog), "rename", "_Rename")
        adw_alert_dialog_set_response_appearance(cast(dialog), "rename", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_default_response(cast(dialog), "rename")
        adw_alert_dialog_set_close_response(cast(dialog), "cancel")

        if allowsEmpty == false {
            let update = {
                let text = String(cString: gtk_editable_get_text(cast(entry))).trimmingCharacters(in: .whitespaces)
                adw_alert_dialog_set_response_enabled(cast(dialog), "rename", text.isEmpty ? 0 : 1)
            }
            Signal.connect(entry, "changed") { update() }
            update()
        }

        let handle = AlertHandle(dialog: dialog, entry: entry) { response, text in
            if response == "rename", let text { onRename(text) }
            onFinish?()
        }
        present(handle, parent: parent)
        gtk_widget_grab_focus(entry)
        gtk_editable_select_region(cast(entry), 0, -1)
    }

    /// - Parameter confirmIsDefault: Enter picks the confirm button. The
    ///   close and quit prompts set it, like their macOS alerts (Close/Quit
    ///   is the default button), so Ctrl+Shift+W → Enter closes; otherwise
    ///   Enter cancels. Escape always cancels.
    public static func confirm(
        parent: WidgetPtr,
        heading: String,
        body: String,
        confirmLabel: String,
        destructive: Bool = true,
        confirmIsDefault: Bool = false,
        onConfirm: @escaping () -> Void
    ) {
        let dialog = widget(adw_alert_dialog_new(heading, body)!)
        adw_alert_dialog_add_response(cast(dialog), "cancel", "_Cancel")
        adw_alert_dialog_add_response(cast(dialog), "confirm", confirmLabel)
        adw_alert_dialog_set_response_appearance(
            cast(dialog), "confirm", destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED
        )
        adw_alert_dialog_set_default_response(cast(dialog), confirmIsDefault ? "confirm" : "cancel")
        adw_alert_dialog_set_close_response(cast(dialog), "cancel")
        let handle = AlertHandle(dialog: dialog, entry: nil) { response, _ in
            if response == "confirm" { onConfirm() }
        }
        present(handle, parent: parent)
    }

    private static func present(_ handle: AlertHandle, parent: WidgetPtr) {
        current = handle
        // libadwaita emits `closed` before `response`: a clicked button or
        // Enter closes the dialog first and reports the choice afterwards.
        // `closed` releases `current` (the handle's last strong reference),
        // so the response handler must not depend on the handle; it keeps
        // only the entry and the callback. The dialog, and so its entry, is
        // alive while it emits `response`.
        let entry = handle.entry
        let onResponse = handle.onResponse
        Signal.connectPointer(handle.dialog, "response") { responsePointer in
            guard let responsePointer else { return }
            let response = String(cString: responsePointer.assumingMemoryBound(to: CChar.self))
            let text = entry.map { String(cString: gtk_editable_get_text(cast($0))) }
            onResponse(response, text)
        }
        Signal.connect(handle.dialog, "closed") { [weak handle] in
            if let handle, current === handle { current = nil }
        }
        adw_dialog_present(cast(handle.dialog), parent)
    }
}
