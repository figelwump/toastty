#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The Tasks view's webhook banner, as a model (macOS
/// `TaskWebhookApprovalBanner`): the first webhook that waits or was stopped.
struct TaskWebhookBannerModel: Equatable {
    var webhookID: UUID
    var message: String
    var buttonTitle: String

    @MainActor
    init?(_ service: TaskWebhookService?) {
        guard let service else { return nil }
        let waiting = service.pendingWebhooks + service.stoppedWebhooks
        guard let first = waiting.first else { return nil }
        webhookID = first.id
        let parts = TaskWebhookApprovalPresentation.bannerMessage(first)
        message = parts.lead + parts.rest + (waiting.count > 1 ? " (\(waiting.count - 1) more)" : "")
        buttonTitle = TaskWebhookApprovalPresentation.reviewTitle(first)
    }
}

/// What leaves this computer and where it goes (macOS
/// `TaskWebhookApprovalSheet`). Approve has no default key, so only a click
/// approves: Return and Escape never decide.
@MainActor
final class TaskWebhookApprovalDialog {
    private static var current: TaskWebhookApprovalDialog?

    let dialog: WidgetPtr
    private let service: TaskWebhookService
    private let webhook: TaskWebhook
    private let needsKey: Bool
    private var keyEntry: WidgetPtr?
    private let errorLabel: WidgetPtr
    private let approveButton: WidgetPtr

    static func present(service: TaskWebhookService, over parent: WidgetPtr) {
        guard let webhook = (service.pendingWebhooks + service.stoppedWebhooks).first else { return }
        let dialog = TaskWebhookApprovalDialog(service: service, webhook: webhook)
        current = dialog
        adw_dialog_present(cast(dialog.dialog), parent)
    }

    private init(service: TaskWebhookService, webhook: TaskWebhook) {
        self.service = service
        self.webhook = webhook
        needsKey = TaskWebhookApprovalPresentation.needsKey(webhook, hasSecret: service.hasSecret(webhook.id))
        dialog = widget(adw_dialog_new()!)
        adw_dialog_set_title(cast(dialog), "Webhook")
        adw_dialog_set_content_width(cast(dialog), 520)
        Gtk.setName(dialog, "tasks.webhook.sheet")

        let content = Gtk.vbox(spacing: 14, classes: ["webhook-sheet"])
        Gtk.margins(content, 20)
        let title = Gtk.label(TaskWebhookApprovalPresentation.sheetTitle(webhook), classes: ["title-3"], ellipsize: false)
        gtk_label_set_wrap(cast(title), 1)
        Gtk.append(content, title)
        let explanation = Gtk.label(TaskWebhookApprovalPresentation.explanation(webhook), classes: ["dim-label"], ellipsize: false)
        gtk_label_set_wrap(cast(explanation), 1)
        Gtk.append(content, explanation)

        let grid = gtk_grid_new()!
        gtk_grid_set_column_spacing(cast(grid), 14)
        gtk_grid_set_row_spacing(cast(grid), 8)
        var row: Int32 = 0
        func add(_ label: String, _ value: WidgetPtr) {
            let key = Gtk.label(label, classes: ["dim-label"])
            gtk_widget_set_valign(key, GTK_ALIGN_START)
            gtk_grid_attach(cast(grid), key, 0, row, 1, 1)
            gtk_widget_set_hexpand(value, 1)
            gtk_grid_attach(cast(grid), value, 1, row, 1, 1)
            row += 1
        }
        func text(_ value: String, classes: [String] = []) -> WidgetPtr {
            let label = Gtk.label(value, classes: classes, ellipsize: false)
            gtk_label_set_wrap(cast(label), 1)
            gtk_label_set_selectable(cast(label), 1)
            return label
        }
        let sendsTo = Gtk.vbox(spacing: 2)
        Gtk.append(sendsTo, text(webhook.host, classes: ["monospace", "heading"]))
        Gtk.append(sendsTo, text(webhook.displayURL, classes: ["monospace", "dim-label"]))
        if TaskWebhookValidation.isLoopback(url: webhook.url) {
            Gtk.append(sendsTo, text("Local test address", classes: ["dim-label"]))
        }
        add("Sends to", sendsTo)
        add("Events", text(webhook.eventTitles.joined(separator: ", ")))
        add("Tasks", text(TaskWebhookApprovalPresentation.taskFilter(webhook)))
        add("Sign-in", text(TaskWebhookApprovalPresentation.signIn(webhook, needsKey: needsKey)))
        if needsKey {
            let keyBox = Gtk.vbox(spacing: 6)
            let entry = gtk_password_entry_new()!
            gtk_password_entry_set_show_peek_icon(cast(entry), 1)
            GProperty.setString(entry, "placeholder-text", TaskWebhookApprovalPresentation.keyPlaceholder)
            Gtk.setName(entry, "tasks.webhook.key")
            Gtk.append(keyBox, entry)
            if let hint = webhook.secretHint {
                Gtk.append(keyBox, text("Instructions from the requester. Toastty did not write or check them.", classes: ["dim-label", "caption"]))
                // Plain text, so a link cannot hide where it goes.
                let hintLabel = text(hint, classes: ["webhook-hint"])
                Gtk.setName(hintLabel, "tasks.webhook.secretHint")
                Gtk.append(keyBox, hintLabel)
            } else {
                Gtk.append(keyBox, text("Paste the key that the receiving service gave you for this webhook.", classes: ["dim-label", "caption"]))
            }
            keyEntry = entry
            add("Key", keyBox)
        }
        add("Requested by", text(TaskWebhookApprovalPresentation.requester(webhook)))
        Gtk.append(content, grid)
        if webhook.requestedBy.isAgentSession {
            let warning = text(TaskWebhookApprovalPresentation.agentWarning(webhook), classes: ["webhook-agent-warning"])
            Gtk.setName(warning, "tasks.webhook.agentWarning")
            Gtk.append(content, warning)
        }
        errorLabel = Gtk.label("", classes: ["error"], ellipsize: false)
        gtk_label_set_wrap(cast(errorLabel), 1)
        Gtk.setVisible(errorLabel, false)
        Gtk.append(content, errorLabel)
        Gtk.append(content, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))

        let buttons = Gtk.hbox(spacing: 8)
        let deny = Gtk.button(TaskWebhookApprovalPresentation.denyTitle(webhook), classes: ["destructive-action"])
        Gtk.setName(deny, "tasks.webhook.deny")
        Gtk.append(buttons, deny)
        let spacer = Gtk.hbox()
        gtk_widget_set_hexpand(spacer, 1)
        Gtk.append(buttons, spacer)
        let notNow = Gtk.button("Not now")
        Gtk.setName(notNow, "tasks.webhook.notNow")
        Gtk.append(buttons, notNow)
        approveButton = Gtk.button("Approve", classes: ["suggested-action"])
        Gtk.setName(approveButton, "tasks.webhook.approve")
        Gtk.append(buttons, approveButton)
        Gtk.append(content, buttons)

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), adw_header_bar_new())
        adw_toolbar_view_set_content(cast(toolbar), content)
        adw_dialog_set_child(cast(dialog), toolbar)

        Signal.connect(deny, "clicked") { [weak self] in
            self?.decide { try $0.service.deny(id: $0.webhook.id) }
        }
        Signal.connect(notNow, "clicked") { [weak self] in self?.close() }
        Signal.connect(approveButton, "clicked") { [weak self] in
            guard let self else { return }
            let key = self.enteredKey
            self.decide { try $0.service.approve(id: $0.webhook.id, shownDigest: $0.webhook.settingsDigest, secret: $0.needsKey ? key : nil) }
        }
        if let keyEntry {
            Signal.connect(keyEntry, "changed") { [weak self] in self?.updateApprove() }
        }
        Signal.connect(dialog, "closed") {
            if Self.current?.dialog == self.dialog { Self.current = nil }
        }
        updateApprove()
    }

    private var enteredKey: String {
        guard let keyEntry, let text = gtk_editable_get_text(cast(keyEntry)) else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateApprove() {
        gtk_widget_set_sensitive(approveButton, (needsKey == false || enteredKey.isEmpty == false).gboolean)
    }

    private func decide(_ action: (TaskWebhookApprovalDialog) throws -> Void) {
        do {
            try action(self)
            close()
        } catch {
            Gtk.setLabel(errorLabel, error.localizedDescription)
            Gtk.setVisible(errorLabel, true)
        }
    }

    private func close() {
        adw_dialog_close(cast(dialog))
    }
}

/// An attached file as a chip (macOS `AttachmentChip`): an image's preview
/// or a file icon, its name, and ✕ when it can be removed.
@MainActor
enum AttachmentChipWidget {
    static func make(path: String, name: String, onRemove: (() -> Void)?) -> WidgetPtr {
        let chip = Gtk.hbox(spacing: 6, classes: ["attachment-chip"])
        gtk_widget_set_tooltip_text(chip, path)
        if DraftAttachments.isImage(URL(fileURLWithPath: path)),
           let pixbuf = gdk_pixbuf_new_from_file_at_scale(path, 96, 64, 1, nil) {
            let texture = gdk_texture_new_for_pixbuf(pixbuf)!
            g_object_unref(UnsafeMutableRawPointer(pixbuf))
            let picture = gtk_picture_new_for_paintable(cast(texture))!
            g_object_unref(UnsafeMutableRawPointer(texture))
            gtk_picture_set_content_fit(cast(picture), GTK_CONTENT_FIT_COVER)
            gtk_widget_set_size_request(picture, 48, 32)
            Gtk.addClasses(picture, ["attachment-thumbnail"])
            Gtk.append(chip, picture)
        } else {
            Gtk.append(chip, Gtk.image("text-x-generic-symbolic", pixelSize: 16))
        }
        let label = Gtk.label(name, classes: ["attachment-name"])
        gtk_label_set_max_width_chars(cast(label), 24)
        Gtk.append(chip, label)
        if let onRemove {
            let remove = Gtk.iconButton("window-close-symbolic", tooltip: "Remove \(name)", classes: ["flat", "circular", "attachment-remove"])
            Signal.connect(remove, "clicked") { onRemove() }
            Gtk.append(chip, remove)
        }
        return chip
    }
}
#endif
