#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
@testable import ToasttyAppLogic

/// The field under the coordinator's chat (macOS `CoordinatorComposerView`):
/// the message it replies to, its files, ＋ (Files…, Mention a Task…), the
/// text, the Steer/Queue chip while a turn runs, and one button that sends
/// or stops the turn. Return sends, Ctrl+Return queues, Shift+Return and
/// Alt+Return start a new line; Escape in an empty field drops the reply.
@MainActor
final class CoordinatorComposer: CoordinatorComposerField {
    let root: WidgetPtr
    let textView: WidgetPtr
    private let buffer: OpaquePointer
    private let placeholder: WidgetPtr
    private let replyBar: WidgetPtr
    private let replyLabel: WidgetPtr
    private let attachmentsBox: WidgetPtr
    private let deliveryChip: WidgetPtr
    private let sendButton: WidgetPtr
    private let plusButton: WidgetPtr
    private weak var model: CoordinatorChatModel?
    private let host: CoordinatorChatModel.Host
    private var isSyncing = false
    private var lastFocusRequest = 0
    private var attachmentsModel: [URL] = []
    /// The reply the bar shows, so typing does not redo its line.
    private var shownReplyTarget: CoordinatorReplyTarget?
    /// The reply bar's line, for automation.
    var replyBarLine: String? {
        gtk_widget_get_visible(replyBar).bool ? gtk_label_get_text(cast(replyLabel)).map { String(cString: $0) } : nil
    }
    private let mentions: CoordinatorMentionPopover
    var onShowTerminal: (() -> Void)?

    init(host: CoordinatorChatModel.Host, mentionCandidates: @escaping () -> [CoordinatorMentionCandidate]) {
        self.host = host
        root = Gtk.vbox(spacing: 6, classes: ["composer"])
        Gtk.setName(root, "coordinator.chat.composer.\(host == .dock ? "dock" : "panel")")

        replyBar = Gtk.hbox(spacing: 6, classes: ["composer-reply"])
        replyLabel = Gtk.label("", classes: ["composer-reply-text"])
        gtk_widget_set_hexpand(replyLabel, 1)
        Gtk.append(replyBar, replyLabel)
        let cancelReply = Gtk.iconButton("window-close-symbolic", tooltip: "Don't reply (Esc)", classes: ["flat", "circular"])
        Gtk.setName(cancelReply, "coordinator.chat.reply.cancel")
        Gtk.append(replyBar, cancelReply)
        Gtk.setVisible(replyBar, false)
        Gtk.append(root, replyBar)

        attachmentsBox = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(cast(attachmentsBox), GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(cast(attachmentsBox), 6)
        Gtk.setVisible(attachmentsBox, false)
        Gtk.append(root, attachmentsBox)

        let row = Gtk.hbox(spacing: 6, classes: ["composer-row"])
        plusButton = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(plusButton), "list-add-symbolic")
        Gtk.addClasses(plusButton, ["flat", "composer-plus"])
        gtk_widget_set_tooltip_text(plusButton, "Attach files or mention a task")
        gtk_widget_set_valign(plusButton, GTK_ALIGN_END)
        Gtk.setName(plusButton, "coordinator.chat.plus")
        Gtk.append(row, plusButton)

        let field = gtk_overlay_new()!
        Gtk.addClasses(field, ["composer-field"])
        gtk_widget_set_hexpand(field, 1)
        textView = gtk_text_view_new()!
        Gtk.addClasses(textView, ["composer-text"])
        gtk_text_view_set_wrap_mode(cast(textView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(cast(textView), 0)
        gtk_text_view_set_top_margin(cast(textView), 6)
        gtk_text_view_set_bottom_margin(cast(textView), 6)
        gtk_text_view_set_left_margin(cast(textView), 8)
        gtk_text_view_set_right_margin(cast(textView), 8)
        Gtk.setName(textView, "coordinator.chat.field.\(host == .dock ? "dock" : "panel")")
        buffer = OpaquePointer(gtk_text_view_get_buffer(cast(textView))!)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 200)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_child(cast(scroller), textView)
        gtk_overlay_set_child(cast(field), scroller)
        placeholder = Gtk.label("Message Toasty…", classes: ["composer-placeholder"])
        gtk_widget_set_halign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_margin_start(placeholder, 10)
        gtk_widget_set_margin_top(placeholder, 6)
        gtk_widget_set_can_target(placeholder, 0)
        gtk_overlay_add_overlay(cast(field), placeholder)
        Gtk.append(row, field)

        deliveryChip = gtk_menu_button_new()!
        Gtk.addClasses(deliveryChip, ["flat", "composer-delivery"])
        gtk_widget_set_valign(deliveryChip, GTK_ALIGN_END)
        Gtk.setName(deliveryChip, "coordinator.chat.delivery")
        Gtk.setVisible(deliveryChip, false)
        Gtk.append(row, deliveryChip)

        sendButton = Gtk.button("Send", classes: ["suggested-action", "composer-send"])
        gtk_widget_set_valign(sendButton, GTK_ALIGN_END)
        Gtk.setName(sendButton, "coordinator.chat.send")
        Gtk.append(row, sendButton)
        Gtk.append(root, row)

        mentions = CoordinatorMentionPopover(anchor: field, candidates: mentionCandidates)

        Signal.connect(cancelReply, "clicked") { [weak self] in self?.model?.cancelReply() }
        Signal.connect(sendButton, "clicked") { [weak self] in self?.sendOrStop(queueing: false) }
        Signal.connect(buffer, "changed") { [weak self] in self?.textChanged() }
        installMenus()
        installKeys()
        mentions.onChoose = { [weak self] candidate in self?.insertMention(candidate) }
    }

    func attach(to model: CoordinatorChatModel) {
        self.model = model
        model.setComposerField(self, host: host)
    }

    func teardown() {
        mentions.teardown()
    }

    // MARK: - Render

    /// The reply bar's line, as the Mac's: who and when, then the start of
    /// the message on one line (the label cuts it to its width).
    static func replyBarText(_ reply: CoordinatorReplyTarget) -> String {
        let who = reply.time.map { "Replying to the coordinator · \($0)" } ?? "Replying to the coordinator"
        return "\(who) · \(ToasttyMessageQuote.excerpt(of: reply.text))"
    }

    func render(placeholderText: String) {
        guard let model else { return }
        if text != model.draft {
            isSyncing = true
            gtk_text_buffer_set_text(cast(buffer), model.draft, -1)
            isSyncing = false
        }
        Gtk.setLabel(placeholder, placeholderText)
        Gtk.setVisible(placeholder, model.draft.isEmpty)
        gtk_text_view_set_editable(cast(textView), (model.isSendingFiles == false).gboolean)

        if model.replyTarget != shownReplyTarget {
            shownReplyTarget = model.replyTarget
            if let reply = model.replyTarget {
                Gtk.setLabel(replyLabel, Self.replyBarText(reply))
            }
            Gtk.setVisible(replyBar, model.replyTarget != nil)
        }

        let urls = model.attachmentDraft.attachments.map(\.url)
        if urls != attachmentsModel || model.attachmentDraft.pendingCount > 0 {
            attachmentsModel = urls
            rebuildAttachments(model)
        }

        if let delivery = model.delivery {
            Gtk.setVisible(deliveryChip, true)
            gtk_menu_button_set_label(cast(deliveryChip), delivery.steers ? "Steer" : "Queue")
            Gtk.setClass(deliveryChip, "queue", delivery.steers == false)
            gtk_widget_set_tooltip_text(deliveryChip, CoordinatorComposerDelivery.chipHelp(delivery))
            gtk_widget_set_sensitive(deliveryChip, delivery.canSteer.gboolean)
        } else {
            Gtk.setVisible(deliveryChip, false)
        }

        let showsStop = model.canStop && model.canSend == false
        if showsStop {
            gtk_button_set_label(cast(sendButton), "Stop")
            gtk_widget_set_tooltip_text(sendButton, "Stop the running turn")
            Gtk.setClass(sendButton, "suggested-action", false)
            Gtk.setClass(sendButton, "destructive-action", true)
            gtk_widget_set_sensitive(sendButton, 1)
        } else {
            gtk_button_set_label(cast(sendButton), CoordinatorComposerDelivery.sendLabel(model.delivery))
            gtk_widget_set_tooltip_text(sendButton, CoordinatorComposerDelivery.sendHelp(model.delivery))
            Gtk.setClass(sendButton, "destructive-action", false)
            Gtk.setClass(sendButton, "suggested-action", true)
            gtk_widget_set_sensitive(sendButton, model.canSend.gboolean)
        }

        if model.composerFocusRequest != lastFocusRequest {
            lastFocusRequest = model.composerFocusRequest
            MainLoop.idle { [weak self] in
                guard let self, gtk_widget_get_mapped(self.textView).bool else { return }
                gtk_widget_grab_focus(self.textView)
            }
        }
    }

    private func rebuildAttachments(_ model: CoordinatorChatModel) {
        while let child = gtk_widget_get_first_child(attachmentsBox) {
            gtk_flow_box_remove(cast(attachmentsBox), child)
        }
        for attachment in model.attachmentDraft.attachments {
            let id = attachment.id
            gtk_flow_box_append(cast(attachmentsBox), AttachmentChipWidget.make(
                path: attachment.url.path, name: attachment.displayName,
                onRemove: { [weak model] in model?.attachmentDraft.remove(id: id) }
            ))
        }
        if model.attachmentDraft.pendingCount > 0 {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            gtk_flow_box_append(cast(attachmentsBox), spinner)
        }
        Gtk.setVisible(attachmentsBox, model.attachmentDraft.isEmpty == false)
    }

    var text: String {
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(cast(buffer), &start, &end)
        guard let raw = gtk_text_buffer_get_text(cast(buffer), &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private func textChanged() {
        guard isSyncing == false, let model else { return }
        let current = text
        if model.draft != current {
            model.draft = current
        }
        Gtk.setVisible(placeholder, current.isEmpty)
        mentions.textChanged(text: current, cursorOffset: cursorOffset)
    }

    private var cursorOffset: Int {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(cast(buffer), &iter, gtk_text_buffer_get_insert(cast(buffer)))
        return Int(gtk_text_iter_get_offset(&iter))
    }

    // MARK: - Actions

    private func sendOrStop(queueing: Bool) {
        guard let model else { return }
        if model.canSend {
            model.send(queueing: queueing)
        } else if model.canStop {
            model.stop()
        }
    }

    private func installMenus() {
        let group = g_simple_action_group_new()!
        func add(_ name: String, _ handler: @escaping @MainActor () -> Void) {
            let action = g_simple_action_new(name, nil)!
            Signal.connectPointer(action, "activate") { _ in handler() }
            g_action_map_add_action(cast(group), cast(action))
            g_object_unref(UnsafeMutableRawPointer(action))
        }
        add("files") { [weak self] in self?.model?.chooseFiles() }
        add("mention") { [weak self] in self?.beginMention() }
        add("steer") { [weak self] in self?.model?.queueSelected = false }
        add("queue") { [weak self] in self?.model?.queueSelected = true }
        gtk_widget_insert_action_group(root, "composer", cast(group))
        g_object_unref(UnsafeMutableRawPointer(group))

        let plus = g_menu_new()!
        g_menu_append(plus, "Files…", "composer.files")
        g_menu_append(plus, "Mention a Task…", "composer.mention")
        gtk_menu_button_set_menu_model(cast(plusButton), cast(plus))
        g_object_unref(UnsafeMutableRawPointer(plus))

        let delivery = g_menu_new()!
        g_menu_append(delivery, "Steer: add to the running turn", "composer.steer")
        g_menu_append(delivery, "Queue: send after this turn", "composer.queue")
        gtk_menu_button_set_menu_model(cast(deliveryChip), cast(delivery))
        g_object_unref(UnsafeMutableRawPointer(delivery))
    }

    private func installKeys() {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, state in
            guard let self, let model = self.model else { return false }
            let raw = state.rawValue
            let control = raw & GDK_CONTROL_MASK.rawValue != 0
            let newline = raw & (GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue) != 0
            if self.mentions.isOpen, self.mentions.handleKey(Int32(keyval)) { return true }
            switch Int32(keyval) {
            case GDK_KEY_Return, GDK_KEY_KP_Enter:
                if newline { return false }
                // An input method's own Return is not ours.
                self.sendOrStop(queueing: control)
                return true
            case GDK_KEY_Escape:
                if model.draft.isEmpty, model.replyTarget != nil {
                    model.cancelReply()
                    return true
                }
                return false
            case GDK_KEY_v where control:
                return self.pasteAttachments()
            default:
                return false
            }
        }
        gtk_widget_add_controller(textView, keys)
    }

    /// Ctrl+V with files or an image on the clipboard attaches them; text
    /// stays a normal paste.
    private func pasteAttachments() -> Bool {
        guard let model, let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display),
              let formats = gdk_clipboard_get_formats(clipboard) else { return false }
        if gdk_content_formats_contain_gtype(formats, gdk_file_list_get_type()).bool {
            ClipboardReader.readFiles(clipboard) { [weak model] urls in
                guard urls.isEmpty == false else { return }
                model?.attachmentDraft.attachFiles(urls)
            }
            return true
        }
        let hasText = gdk_content_formats_contain_mime_type(formats, "text/plain;charset=utf-8").bool
            || gdk_content_formats_contain_mime_type(formats, "text/plain").bool
        if hasText == false, gdk_content_formats_contain_gtype(formats, gdk_texture_get_type()).bool {
            ClipboardReader.readImagePNG(clipboard) { [weak model] png in
                guard let png else { return }
                model?.attachmentDraft.attachImageData(png)
            }
            return true
        }
        return false
    }

    // MARK: - Mentions

    private func beginMention() {
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(cast(buffer), &iter, gtk_text_buffer_get_insert(cast(buffer)))
        let needsSpace = text.isEmpty == false && text.hasSuffix(" ") == false && text.hasSuffix("\n") == false
        gtk_text_buffer_insert(cast(buffer), &iter, needsSpace ? " @" : "@", -1)
        _ = takeKeyboard()
    }

    /// Replaces the typed `@query` with the task's link, which the
    /// coordinator reads by its ID.
    private func insertMention(_ candidate: CoordinatorMentionCandidate) {
        guard let range = mentions.queryRange else { return }
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(cast(buffer), &start, Int32(range.lowerBound))
        gtk_text_buffer_get_iter_at_offset(cast(buffer), &end, Int32(range.upperBound))
        gtk_text_buffer_delete(cast(buffer), &start, &end)
        gtk_text_buffer_insert(cast(buffer), &start, CoordinatorTaskLink.markdown(taskID: candidate.taskID, title: candidate.title) + " ", -1)
        mentions.close()
    }

    // MARK: - CoordinatorComposerField

    var hasKeyboard: Bool { gtk_widget_has_focus(textView).bool }

    var transcriptHasKeyboard: Bool {
        guard let window = gtk_widget_get_root(textView), let focus = gtk_root_get_focus(window) else { return false }
        return isInstance(focus, of: gtk_label_get_type()) && gtk_label_get_selectable(cast(focus)).bool
    }

    func takeKeyboard() -> Bool {
        guard gtk_widget_get_mapped(textView).bool else { return false }
        return gtk_widget_grab_focus(textView).bool
    }

    func presentWindow() {
        guard let window = gtk_widget_get_root(textView) else { return }
        gtk_window_present(cast(window))
    }

    func chooseFiles(completion: @escaping @MainActor ([URL]) -> Void) {
        FileChooser.chooseFiles(parent: gtk_widget_get_root(textView).map { widget($0) }, title: "Attach Files", completion: completion)
    }
}

/// Reads the GTK clipboard asynchronously.
@MainActor
enum ClipboardReader {
    private final class Box<T> {
        let completion: @MainActor (T) -> Void
        init(_ completion: @escaping @MainActor (T) -> Void) { self.completion = completion }
    }

    static func readFiles(_ clipboard: OpaquePointer, completion: @escaping @MainActor ([URL]) -> Void) {
        let box = Unmanaged.passRetained(Box(completion)).toOpaque()
        gdk_clipboard_read_value_async(clipboard, gdk_file_list_get_type(), 0, nil, { source, result, data in
            let box = Unmanaged<Box<[URL]>>.fromOpaque(data!).takeRetainedValue()
            var urls: [URL] = []
            if let value = gdk_clipboard_read_value_finish(OpaquePointer(source!), result, nil),
               let list = g_value_get_boxed(value) {
                let head = gdk_file_list_get_files(OpaquePointer(list))
                var node = head
                while let current = node {
                    if let file = current.pointee.data, let path = g_file_get_path(OpaquePointer(file)) {
                        urls.append(URL(fileURLWithPath: String(cString: path)))
                        g_free(path)
                    }
                    node = current.pointee.next
                }
                g_slist_free(head)
            }
            MainActor.assumeIsolated { box.completion(urls) }
        }, box)
    }

    static func readImagePNG(_ clipboard: OpaquePointer, completion: @escaping @MainActor (Data?) -> Void) {
        let box = Unmanaged.passRetained(Box(completion)).toOpaque()
        gdk_clipboard_read_texture_async(clipboard, nil, { source, result, data in
            let box = Unmanaged<Box<Data?>>.fromOpaque(data!).takeRetainedValue()
            var png: Data?
            if let texture = gdk_clipboard_read_texture_finish(OpaquePointer(source!), result, nil) {
                if let bytes = gdk_texture_save_to_png_bytes(texture) {
                    var size: gsize = 0
                    if let pointer = g_bytes_get_data(bytes, &size) {
                        png = Data(bytes: pointer, count: Int(size))
                    }
                    g_bytes_unref(bytes)
                }
                g_object_unref(UnsafeMutableRawPointer(texture))
            }
            MainActor.assumeIsolated { box.completion(png) }
        }, box)
    }
}

/// The desktop's file chooser (GtkFileDialog: the portal under Flatpak or
/// GNOME), several files, no folders.
@MainActor
enum FileChooser {
    private final class Box {
        let completion: @MainActor ([URL]) -> Void
        init(_ completion: @escaping @MainActor ([URL]) -> Void) { self.completion = completion }
    }

    static func chooseFiles(parent: WidgetPtr?, title: String, completion: @escaping @MainActor ([URL]) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_accept_label(dialog, "Attach")
        let box = Unmanaged.passRetained(Box(completion)).toOpaque()
        gtk_file_dialog_open_multiple(dialog, parent.map { cast($0) }, nil, { source, result, data in
            let box = Unmanaged<Box>.fromOpaque(data!).takeRetainedValue()
            var urls: [URL] = []
            if let model = gtk_file_dialog_open_multiple_finish(OpaquePointer(source!), result, nil) {
                let count = g_list_model_get_n_items(model)
                for index in 0..<count {
                    guard let file = g_list_model_get_item(model, index) else { continue }
                    if let path = g_file_get_path(OpaquePointer(file)) {
                        urls.append(URL(fileURLWithPath: String(cString: path)))
                        g_free(path)
                    }
                    g_object_unref(file)
                }
                g_object_unref(UnsafeMutableRawPointer(model))
            }
            MainActor.assumeIsolated { box.completion(urls) }
        }, box)
        g_object_unref(UnsafeMutableRawPointer(dialog))
    }
}
#endif
