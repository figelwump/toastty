#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
import OpenCombine
@testable import ToasttyAppLogic

/// Quick entry in GTK (macOS `QuickEntryPanel` + `QuickEntryView`): a small
/// window with the task text, its files, the Workspace and Agent pills with
/// their pickers, and Create Task, or Send and Create while a coordinator
/// exists. The shared `QuickEntryController` drives it through
/// `QuickEntryFrontend`; the model and the picker are the shared ones.
///
/// Keys: Ctrl+Return submits, Ctrl+Alt+Return creates the task directly,
/// Ctrl+1 and Ctrl+2 open the pickers, Esc closes (a picker first),
/// Ctrl+V pastes files or an image as attachments.
@MainActor
final class QuickEntryWindowFrontend: QuickEntryFrontend {
    private let application: OpaquePointer
    private let toast: (String) -> Void
    private var window: WidgetPtr?
    private weak var model: QuickEntryModel?
    private weak var controller: QuickEntryController?
    private var subscriptions: [AnyCancellable] = []
    private var previousWindow: WidgetPtr?
    private var widgets: Widgets?
    private var picker: QuickEntryPickerPopover?
    private lazy var renderScheduler = RenderScheduler("quick-entry") { [weak self] in self?.render() }
    private var isSyncing = false
    private var lastFocusRequest = -1
    private var attachmentURLs: [URL] = []
    /// The desktop-wide shortcut, through the GlobalShortcuts portal.
    let globalShortcut = GlobalShortcutPortal()

    private struct Widgets {
        let title: WidgetPtr
        let hint: WidgetPtr
        let textView: WidgetPtr
        let buffer: OpaquePointer
        let placeholder: WidgetPtr
        let attachments: WidgetPtr
        let error: WidgetPtr
        let workspacePill: WidgetPtr
        let agentPill: WidgetPtr
        let create: WidgetPtr
        let send: WidgetPtr
    }

    init(application: OpaquePointer, toast: @escaping (String) -> Void) {
        self.application = application
        self.toast = toast
    }

    // MARK: - QuickEntryFrontend

    func rememberFocusBeforePresenting() {
        previousWindow = gtk_application_get_active_window(cast(application)).map { widget($0) }
    }

    func showPanel(for model: QuickEntryModel, controller: QuickEntryController) {
        closePanel()
        self.model = model
        self.controller = controller
        let built = build(model: model, controller: controller)
        subscriptions = [model.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }]
        render()
        if let window {
            gtk_window_present(cast(window))
            gtk_widget_grab_focus(built.textView)
        }
    }

    func bringPanelForward() {
        guard let window else { return }
        gtk_window_present(cast(window))
    }

    func focusPanel() {
        guard let window, let widgets else { return }
        gtk_window_present(cast(window))
        gtk_widget_grab_focus(widgets.textView)
    }

    func closePanel() {
        picker?.close()
        picker = nil
        subscriptions = []
        widgets = nil
        if let window {
            self.window = nil
            gtk_window_destroy(cast(window))
        }
    }

    func restoreFocus() {
        guard let previousWindow else { return }
        self.previousWindow = nil
        gtk_window_present(cast(previousWindow))
    }

    func chooseFiles(completion: @escaping @MainActor ([URL]) -> Void) {
        FileChooser.chooseFiles(parent: window, title: "Attach Files", completion: completion)
    }

    func showToast(_ message: String, duration: Duration) {
        toast(message)
    }

    func showPicker(_ picker: QuickEntryPicker, for model: QuickEntryModel, controller: QuickEntryController) {
        guard let widgets else { return }
        self.picker?.close()
        let anchor = picker.kind == .workspace ? widgets.workspacePill : widgets.agentPill
        self.picker = QuickEntryPickerPopover(picker: picker, anchor: anchor, controller: controller)
    }

    func hidePicker() {
        picker?.close()
        picker = nil
    }

    func registerGlobalShortcut(
        _ shortcut: QuickEntryShortcut?,
        handler: @escaping @MainActor () -> Void
    ) -> QuickEntryShortcutRegistration {
        globalShortcut.register(shortcut, handler: handler)
    }

    // MARK: - Build

    @discardableResult
    private func build(model: QuickEntryModel, controller: QuickEntryController) -> Widgets {
        let window = widget(adw_window_new()!)
        self.window = window
        gtk_window_set_title(cast(window), model.sendsToCoordinator ? "To Coordinator" : "New Task")
        gtk_window_set_default_size(cast(window), 600, -1)
        gtk_window_set_resizable(cast(window), 0)
        Gtk.setName(window, "quick-entry")
        if let previousWindow { gtk_window_set_transient_for(cast(window), cast(previousWindow)) }

        let content = Gtk.vbox(spacing: 10, classes: ["quick-entry"])
        let header = Gtk.hbox(spacing: 8, classes: ["quick-entry-header"])
        let dot = Gtk.hbox(classes: ["quick-entry-dot"])
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        Gtk.append(header, dot)
        let title = Gtk.label("", classes: ["quick-entry-title"])
        Gtk.setName(title, "quick-entry.title")
        gtk_widget_set_hexpand(title, 1)
        Gtk.append(header, title)
        let hint = Gtk.label("", classes: ["quick-entry-hint"])
        Gtk.setName(hint, "quick-entry.hint")
        Gtk.append(header, hint)
        Gtk.append(content, header)

        let field = gtk_overlay_new()!
        Gtk.addClasses(field, ["quick-entry-field"])
        let textView = gtk_text_view_new()!
        Gtk.addClasses(textView, ["quick-entry-text"])
        Gtk.setName(textView, "quick-entry.text")
        gtk_text_view_set_wrap_mode(cast(textView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(cast(textView), 0)
        for setter in [gtk_text_view_set_top_margin, gtk_text_view_set_bottom_margin] { setter(cast(textView), 8) }
        gtk_text_view_set_left_margin(cast(textView), 10)
        gtk_text_view_set_right_margin(cast(textView), 10)
        let buffer = OpaquePointer(gtk_text_view_get_buffer(cast(textView))!)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(cast(scroller), 66)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 260)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_child(cast(scroller), textView)
        gtk_overlay_set_child(cast(field), scroller)
        let placeholder = Gtk.label("What needs doing?", classes: ["quick-entry-placeholder"])
        gtk_widget_set_halign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_margin_start(placeholder, 12)
        gtk_widget_set_margin_top(placeholder, 8)
        gtk_widget_set_can_target(placeholder, 0)
        gtk_overlay_add_overlay(cast(field), placeholder)
        Gtk.append(content, field)

        let attachmentsRow = Gtk.hbox(spacing: 8)
        let attachments = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(cast(attachments), GTK_SELECTION_NONE)
        gtk_widget_set_hexpand(attachments, 1)
        Gtk.append(attachmentsRow, attachments)
        let attach = Gtk.button("＋ Attach", classes: ["flat", "quick-entry-attach"])
        gtk_widget_set_tooltip_text(attach, "Attach files. You can also paste an image with Ctrl+V or drop files on the window.")
        Gtk.setName(attach, "quick-entry.attach")
        gtk_widget_set_valign(attach, GTK_ALIGN_START)
        Gtk.append(attachmentsRow, attach)
        Gtk.append(content, attachmentsRow)

        let error = Gtk.label("", classes: ["quick-entry-error"], ellipsize: false)
        gtk_label_set_wrap(cast(error), 1)
        Gtk.setName(error, "quick-entry.error")
        Gtk.append(content, error)

        let footer = Gtk.hbox(spacing: 8, classes: ["quick-entry-footer"])
        let workspacePill = Gtk.button("", classes: ["quick-entry-pill"])
        Gtk.setName(workspacePill, "quick-entry.workspace")
        Gtk.append(footer, workspacePill)
        let agentPill = Gtk.button("", classes: ["quick-entry-pill"])
        Gtk.setName(agentPill, "quick-entry.agent")
        Gtk.append(footer, agentPill)
        let spacer = Gtk.hbox()
        gtk_widget_set_hexpand(spacer, 1)
        Gtk.append(footer, spacer)
        let esc = Gtk.button("Esc", classes: ["flat", "quick-entry-key"])
        gtk_widget_set_tooltip_text(esc, model.sendsToCoordinator ? "Close without sending" : "Close without creating a task")
        Gtk.setName(esc, "quick-entry.cancel")
        Gtk.append(footer, esc)
        let create = Gtk.button("Create  Ctrl+Alt+↩", classes: ["quick-entry-create"])
        Gtk.setName(create, "quick-entry.create")
        Gtk.append(footer, create)
        let send = Gtk.button(model.sendsToCoordinator ? "Send  Ctrl+↩" : "Create Task  Ctrl+↩", classes: ["suggested-action", "quick-entry-send"])
        Gtk.setName(send, model.sendsToCoordinator ? "quick-entry.send" : "quick-entry.submit")
        Gtk.append(footer, send)
        Gtk.setVisible(create, model.sendsToCoordinator)
        Gtk.append(content, footer)

        adw_window_set_content(cast(window), content)
        let built = Widgets(
            title: title, hint: hint, textView: textView, buffer: buffer, placeholder: placeholder,
            attachments: attachments, error: error, workspacePill: workspacePill, agentPill: agentPill,
            create: create, send: send
        )
        widgets = built

        Signal.connect(buffer, "changed") { [weak self, weak model] in
            guard let self, self.isSyncing == false, let model else { return }
            let text = self.text
            if model.text != text { model.text = text }
            Gtk.setVisible(placeholder, text.isEmpty)
        }
        Signal.connect(attach, "clicked") { [weak controller] in controller?.chooseFiles() }
        Signal.connect(workspacePill, "clicked") { [weak controller] in controller?.togglePicker(.workspace) }
        Signal.connect(agentPill, "clicked") { [weak controller] in controller?.togglePicker(.agent) }
        Signal.connect(esc, "clicked") { [weak model] in model?.cancel() }
        Signal.connect(create, "clicked") { [weak model] in model?.createTask() }
        Signal.connect(send, "clicked") { [weak model] in model?.submit() }
        Signal.connectBool(window, "close-request") { [weak model] in
            model?.cancel()
            return true
        }
        installKeys(window: window, textView: textView, model: model, controller: controller)
        installDrop(window: window, model: model)
        return built
    }

    private var text: String {
        guard let widgets else { return "" }
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(cast(widgets.buffer), &start, &end)
        guard let raw = gtk_text_buffer_get_text(cast(widgets.buffer), &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private func installKeys(window: WidgetPtr, textView: WidgetPtr, model: QuickEntryModel, controller: QuickEntryController) {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self, weak model, weak controller] keyval, _, state in
            guard let self, let model, let controller else { return false }
            let raw = state.rawValue
            let control = raw & GDK_CONTROL_MASK.rawValue != 0
            let alt = raw & GDK_ALT_MASK.rawValue != 0
            switch Int32(keyval) {
            case GDK_KEY_Return, GDK_KEY_KP_Enter where control:
                if alt { model.createTask() } else { model.submit() }
                return true
            case GDK_KEY_Escape:
                if self.picker != nil {
                    controller.closePicker(refocusText: true)
                } else {
                    model.cancel()
                }
                return true
            case GDK_KEY_1 where control:
                controller.togglePicker(.workspace)
                return true
            case GDK_KEY_2 where control:
                controller.togglePicker(.agent)
                return true
            case GDK_KEY_w where control:
                model.cancel()
                return true
            case GDK_KEY_v where control:
                return self.pasteAttachments(model)
            default:
                return false
            }
        }
        gtk_widget_add_controller(window, keys)
    }

    private func pasteAttachments(_ model: QuickEntryModel) -> Bool {
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display),
              let formats = gdk_clipboard_get_formats(clipboard) else { return false }
        if gdk_content_formats_contain_gtype(formats, gdk_file_list_get_type()).bool {
            ClipboardReader.readFiles(clipboard) { [weak model] urls in
                if urls.isEmpty == false { model?.attachFiles(urls) }
            }
            return true
        }
        let hasText = gdk_content_formats_contain_mime_type(formats, "text/plain;charset=utf-8").bool
            || gdk_content_formats_contain_mime_type(formats, "text/plain").bool
        if hasText == false, gdk_content_formats_contain_gtype(formats, gdk_texture_get_type()).bool {
            ClipboardReader.readImagePNG(clipboard) { [weak model] png in
                if let png { model?.attachImageData(png) }
            }
            return true
        }
        return false
    }

    /// Files dropped on the window are attached; a dropped web link goes
    /// into the text.
    private func installDrop(window: WidgetPtr, model: QuickEntryModel) {
        let files = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)!
        Signal.connectDrop(files) { [weak model] value, _, _ in
            guard let model, let value, let list = g_value_get_boxed(value.assumingMemoryBound(to: GValue.self)) else { return false }
            let head = gdk_file_list_get_files(OpaquePointer(list))
            var node = head
            var urls: [URL] = []
            while let current = node {
                if let file = current.pointee.data, let path = g_file_get_path(OpaquePointer(file)) {
                    urls.append(URL(fileURLWithPath: String(cString: path)))
                    g_free(path)
                }
                node = current.pointee.next
            }
            g_slist_free(head)
            model.attachFiles(urls)
            return urls.isEmpty == false
        }
        gtk_widget_add_controller(window, cast(files))
    }

    // MARK: - Render

    private func scheduleRender() {
        renderScheduler.schedule()
    }

    private func render() {
        guard let model, let widgets else { return }
        if text != model.text {
            isSyncing = true
            gtk_text_buffer_set_text(cast(widgets.buffer), model.text, -1)
            isSyncing = false
        }
        Gtk.setVisible(widgets.placeholder, model.text.isEmpty)
        Gtk.setLabel(widgets.placeholder, model.continuesTaskTitle == nil ? "What needs doing?" : "What should the new task do next?")
        gtk_text_view_set_editable(cast(widgets.textView), model.isEditable.gboolean)
        Gtk.setLabel(widgets.title, (model.sendsToCoordinator ? "To coordinator" : "New task").uppercased())
        let hint: String? = if model.isDropTargeted {
            "Drop to attach"
        } else if let coordinator = model.coordinator, let hint = coordinator.hint {
            hint
        } else if let title = model.continuesTaskTitle {
            "Continues \u{201C}\(title)\u{201D}"
        } else if model.coordinator != nil {
            nil
        } else {
            model.missingChoiceHint
        }
        Gtk.setLabel(widgets.hint, hint ?? "")
        Gtk.setVisible(widgets.hint, hint != nil)

        let urls = model.attachments.map(\.url)
        if urls != attachmentURLs || model.pendingAttachmentCount > 0 {
            attachmentURLs = urls
            while let child = gtk_widget_get_first_child(widgets.attachments) {
                gtk_flow_box_remove(cast(widgets.attachments), child)
            }
            for attachment in model.attachments {
                let id = attachment.id
                gtk_flow_box_append(cast(widgets.attachments), AttachmentChipWidget.make(
                    path: attachment.url.path, name: attachment.displayName,
                    onRemove: { [weak model] in model?.removeAttachment(id: id) }
                ))
            }
            if model.pendingAttachmentCount > 0 {
                let spinner = toastty_clock_spinner_new()!
                gtk_flow_box_append(cast(widgets.attachments), spinner)
            }
        }

        Gtk.setLabel(widgets.error, model.errorMessage ?? "")
        Gtk.setVisible(widgets.error, model.errorMessage != nil)

        gtk_button_set_label(cast(widgets.workspacePill), "\(model.workspacePillTitle)  \(QuickEntryKeyLabels.workspacePicker)")
        let agent = model.agentPillParts
        gtk_button_set_label(cast(widgets.agentPill), "\(agent.name)\(agent.effort.map { " · \($0)" } ?? "")  \(QuickEntryKeyLabels.agentPicker)")
        Gtk.setClass(widgets.workspacePill, "missing", model.sendsToCoordinator == false && model.workspaceID == nil)
        Gtk.setClass(widgets.agentPill, "missing", model.sendsToCoordinator == false && model.preset == nil)
        Gtk.setClass(widgets.workspacePill, "open", model.openPicker == .workspace)
        Gtk.setClass(widgets.agentPill, "open", model.openPicker == .agent)
        gtk_widget_set_sensitive(widgets.send, model.canSubmit.gboolean)
        gtk_widget_set_sensitive(widgets.create, model.canCreateTask.gboolean)
        gtk_widget_set_tooltip_text(widgets.create, model.missingChoiceHint.map { "\($0) to create the task directly." }
            ?? "Create the task now in \(model.workspaceTitle) with \(model.agentTitle), without the coordinator")
        if model.isSubmitting {
            gtk_button_set_label(cast(widgets.send), model.sendsToCoordinator ? "Sending…" : "Creating…")
        }
        if model.focusRequestID != lastFocusRequest {
            lastFocusRequest = model.focusRequestID
            gtk_widget_grab_focus(widgets.textView)
        }
    }

    // MARK: - Automation

    var automationSummary: [String: String] {
        guard let model else { return ["quickEntry": "closed"] }
        return [
            "quickEntry": "open",
            "quickEntryText": model.text,
            "quickEntrySendsToCoordinator": String(model.sendsToCoordinator),
            "quickEntryCanSubmit": String(model.canSubmit),
            "quickEntryWorkspace": model.workspacePillTitle,
            "quickEntryAgent": model.agentPillTitle,
            "quickEntryPicker": model.openPicker.map { $0 == .workspace ? "workspace" : "agent" } ?? "none",
            "quickEntryPickerRows": picker.map { String($0.rowCount) } ?? "0",
            "quickEntryAttachments": model.attachments.map(\.displayName).joined(separator: ","),
            "quickEntryContinues": model.continuesTaskTitle.map { _ in "true" } ?? "false",
            "quickEntryHint": widgets.map { String(cString: gtk_label_get_label(cast($0.hint))) } ?? "",
        ]
    }

    func automationType(_ text: String) {
        guard let widgets else { return }
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(cast(widgets.buffer), &end)
        gtk_text_buffer_insert(cast(widgets.buffer), &end, text, -1)
    }

    var automationModel: QuickEntryModel? { model }

    /// Writes the quick entry window, with its open picker, as a PNG.
    func automationScreenshot(_ url: URL) -> String? {
        guard let window else { return "quick entry is closed" }
        toastty_window_force_layout(cast(window), gtk_widget_get_width(window), gtk_widget_get_height(window))
        var error: UnsafeMutablePointer<GError>?
        var background = GdkRGBA(red: 0.98, green: 0.98, blue: 0.985, alpha: 1)
        guard toastty_widget_write_png(window, url.path, &background, &error).bool else {
            defer { if let error { g_error_free(error) } }
            return error.map { String(cString: $0.pointee.message) } ?? "unknown error"
        }
        return nil
    }
    var automationPicker: QuickEntryPickerPopover? { picker }
}

/// A pill's list (macOS `QuickEntryPickerPanel` + `QuickEntryPickerView`):
/// the search field, the rows in sections, the Agent picker's Agent | Model
/// | Effort columns and the Codex catalog's status.
@MainActor
final class QuickEntryPickerPopover {
    private let popover: WidgetPtr
    private var popoverRef: GObjectRef?
    private let picker: QuickEntryPicker
    private weak var controller: QuickEntryController?
    private let search: WidgetPtr
    private let body: WidgetPtr
    private let status: WidgetPtr
    private var subscription: AnyCancellable?
    private var isClosing = false
    private(set) var rowCount = 0

    init(picker: QuickEntryPicker, anchor: WidgetPtr, controller: QuickEntryController) {
        self.picker = picker
        self.controller = controller
        popover = gtk_popover_new()!
        Gtk.addClasses(popover, ["quick-entry-picker"])
        Gtk.setName(popover, "quick-entry.picker")
        gtk_popover_set_position(cast(popover), GTK_POS_TOP)
        let column = Gtk.vbox(spacing: 6)
        gtk_widget_set_size_request(column, 380, -1)
        search = gtk_search_entry_new()!
        GProperty.setString(search, "placeholder-text", picker.kind == .workspace ? "Search workspaces" : "Search agents and models")
        Gtk.setName(search, "quick-entry.picker.search")
        Gtk.append(column, search)
        body = Gtk.vbox(spacing: 2)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(cast(scroller), 320)
        gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
        gtk_scrolled_window_set_child(cast(scroller), body)
        Gtk.append(column, scroller)
        status = Gtk.hbox(spacing: 6, classes: ["quick-entry-picker-status"])
        Gtk.append(column, status)
        gtk_popover_set_child(cast(popover), column)
        popoverRef = GObjectRef(sinking: popover)
        gtk_widget_set_parent(popover, anchor)

        Signal.connect(search, "search-changed") { [weak self] in
            guard let self, let raw = gtk_editable_get_text(cast(self.search)) else { return }
            let text = String(cString: raw)
            if self.picker.query != text { self.picker.query = text }
        }
        Signal.connect(popover, "closed") { [weak self] in
            guard let self, self.isClosing == false else { return }
            // A click outside, or another app in front.
            self.controller?.closePicker(refocusText: false)
        }
        installKeys()
        subscription = picker.objectWillChange.sink { [weak self] _ in
            MainLoop.idle { self?.render() }
        }
        render()
        gtk_popover_popup(cast(popover))
        gtk_widget_grab_focus(search)
    }

    func close() {
        guard isClosing == false else { return }
        isClosing = true
        subscription = nil
        gtk_popover_popdown(cast(popover))
        Gtk.unparentIfAttached(popover)
    }

    private func installKeys() {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, state in
            guard let self else { return false }
            let raw = state.rawValue
            let control = raw & GDK_CONTROL_MASK.rawValue != 0
            let alt = raw & GDK_ALT_MASK.rawValue != 0
            let shift = raw & GDK_SHIFT_MASK.rawValue != 0
            let picker = self.picker
            switch Int32(keyval) {
            case GDK_KEY_Up: picker.move(-1); return true
            case GDK_KEY_Down: picker.move(1); return true
            case GDK_KEY_Left where control == false: return picker.adjustEffort(-1)
            case GDK_KEY_Right where control:
                guard picker.kind == .agent, picker.columns == nil else { return false }
                picker.openColumns()
                return true
            case GDK_KEY_Right: return picker.adjustEffort(1)
            case GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab:
                guard picker.columns != nil else { return false }
                picker.tab(shift || keyval == UInt32(GDK_KEY_ISO_Left_Tab) ? -1 : 1)
                return true
            case GDK_KEY_Return, GDK_KEY_KP_Enter:
                if control {
                    self.controller?.submitFromPicker(createsTask: alt)
                } else {
                    picker.submit()
                }
                return true
            case GDK_KEY_Escape:
                picker.cancel()
                return true
            case GDK_KEY_r where control:
                guard picker.showsCodexCatalogStatus, picker.codexCatalogStatus == .unavailable else { return false }
                picker.onRetryCodexModels()
                return true
            case GDK_KEY_1 where control, GDK_KEY_2 where control:
                self.controller?.togglePicker(Int32(keyval) == GDK_KEY_1 ? .workspace : .agent)
                return true
            case GDK_KEY_1...GDK_KEY_9 where control == false && picker.query.isEmpty:
                return picker.chooseFrequent(number: Int(Int32(keyval) - GDK_KEY_0))
            default:
                return false
            }
        }
        gtk_widget_add_controller(popover, keys)
    }

    private func render() {
        guard isClosing == false else { return }
        Gtk.removeAllChildren(body)
        if let columns = picker.columns {
            rowCount = 0
            let row = Gtk.hbox(spacing: 8, classes: ["quick-entry-columns"])
            for column in columns.visibleColumns {
                let list = Gtk.vbox(spacing: 2, classes: ["quick-entry-column"])
                Gtk.setClass(list, "focused", columns.focused == column)
                gtk_widget_set_hexpand(list, 1)
                Gtk.append(list, Gtk.label(column.title.uppercased(), classes: ["quick-entry-section"]))
                for cell in columns.cells(in: column) {
                    let button = Gtk.button(cell.title, classes: ["flat", "quick-entry-row"])
                    Gtk.setClass(button, "selected", columns.isSelected(cell))
                    Gtk.setClass(button, "muted", cell.isMuted)
                    gtk_widget_set_sensitive(button, cell.isSelectable.gboolean)
                    Signal.connect(button, "clicked") { [weak self] in self?.picker.select(cell, in: column) }
                    Gtk.append(list, button)
                    rowCount += 1
                }
                Gtk.append(row, list)
            }
            Gtk.append(body, row)
        } else {
            rowCount = picker.rows.count
            if picker.rows.isEmpty {
                let empty = Gtk.label(picker.emptyText, classes: ["dim-label"], ellipsize: false)
                gtk_label_set_wrap(cast(empty), 1)
                Gtk.append(body, empty)
            }
            var section: String?
            for row in picker.rows {
                if let rowSection = row.section, rowSection != section {
                    section = rowSection
                    Gtk.append(body, Gtk.label(rowSection.uppercased(), classes: ["quick-entry-section"]))
                }
                let button = gtk_button_new()!
                Gtk.addClasses(button, ["flat", "quick-entry-row"])
                Gtk.setClass(button, "selected", row.id == picker.highlightedID)
                let content = Gtk.hbox(spacing: 8)
                if let number = row.number {
                    Gtk.append(content, Gtk.label("\(number)", classes: ["quick-entry-number"], ellipsize: false))
                }
                let title = Gtk.label(row.title)
                gtk_widget_set_hexpand(title, 1)
                Gtk.append(content, title)
                if let detail = row.detail {
                    let label = Gtk.label(detail, classes: row.detailIsShortcut ? ["quick-entry-key"] : ["dim-label"])
                    if row.detailIsPath { gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_MIDDLE) }
                    gtk_label_set_max_width_chars(cast(label), 28)
                    Gtk.append(content, label)
                }
                if let warning = row.warning {
                    Gtk.append(content, Gtk.label(warning, classes: ["quick-entry-warning"], ellipsize: false))
                }
                gtk_button_set_child(cast(button), content)
                let id = row.id
                Signal.connect(button, "clicked") { [weak self] in self?.picker.choose(rowID: id) }
                Gtk.append(body, button)
            }
        }
        Gtk.removeAllChildren(status)
        if picker.showsCodexCatalogStatus {
            switch picker.codexCatalogStatus {
            case .loading?:
                Gtk.append(status, Gtk.label("Loading Codex models…", classes: ["dim-label"]))
            case .unavailable?:
                Gtk.append(status, Gtk.label("Codex models unavailable", classes: ["dim-label"]))
                let retry = Gtk.button("Retry  Ctrl+R", classes: ["flat"])
                Signal.connect(retry, "clicked") { [weak self] in self?.picker.onRetryCodexModels() }
                Gtk.append(status, retry)
            case nil:
                break
            }
        }
        Gtk.setVisible(status, Gtk.children(status).isEmpty == false)
        if let raw = gtk_editable_get_text(cast(search)), String(cString: raw) != picker.query {
            gtk_editable_set_text(cast(search), picker.query)
        }
    }
}
#endif
