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

        /// Answers as if the user picked `response` (automation/tests).
        public func respond(_ response: String, text: String? = nil) {
            if let text, let entry { gtk_editable_set_text(cast(entry), text) }
            let entryText = entry.map { String(cString: gtk_editable_get_text(cast($0))) }
            onResponse(response, entryText)
            adw_dialog_force_close(cast(dialog))
        }
    }

    public static func rename(
        parent: WidgetPtr,
        heading: String,
        current: String,
        placeholder: String,
        allowsEmpty: Bool = false,
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
            guard response == "rename", let text else { return }
            onRename(text)
        }
        present(handle, parent: parent)
        gtk_widget_grab_focus(entry)
        gtk_editable_select_region(cast(entry), 0, -1)
    }

    public static func confirm(
        parent: WidgetPtr,
        heading: String,
        body: String,
        confirmLabel: String,
        destructive: Bool = true,
        onConfirm: @escaping () -> Void
    ) {
        let dialog = widget(adw_alert_dialog_new(heading, body)!)
        adw_alert_dialog_add_response(cast(dialog), "cancel", "_Cancel")
        adw_alert_dialog_add_response(cast(dialog), "confirm", confirmLabel)
        adw_alert_dialog_set_response_appearance(
            cast(dialog), "confirm", destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED
        )
        adw_alert_dialog_set_default_response(cast(dialog), "cancel")
        adw_alert_dialog_set_close_response(cast(dialog), "cancel")
        let handle = AlertHandle(dialog: dialog, entry: nil) { response, _ in
            if response == "confirm" { onConfirm() }
        }
        present(handle, parent: parent)
    }

    private static func present(_ handle: AlertHandle, parent: WidgetPtr) {
        current = handle
        Signal.connectPointer(handle.dialog, "response") { [weak handle] responsePointer in
            guard let handle, let responsePointer else { return }
            let response = String(cString: responsePointer.assumingMemoryBound(to: CChar.self))
            let text = handle.entry.map { String(cString: gtk_editable_get_text(cast($0))) }
            handle.onResponse(response, text)
        }
        Signal.connect(handle.dialog, "closed") { [weak handle] in
            if let handle, current === handle { current = nil }
        }
        adw_dialog_present(cast(handle.dialog), parent)
    }
}
