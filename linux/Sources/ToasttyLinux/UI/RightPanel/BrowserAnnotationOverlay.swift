#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CWebKitGtk
import Foundation
import ToasttyAppLogic

/// Browser annotation mode in GTK (macOS: `WebPanelAnnotationSurface`,
/// `BrowserAnnotationOverlayView`, `BrowserAnnotationModeToolbar`,
/// `WebPanelAnnotationHeaderAccessory`, `BrowserAnnotationCommentPopover`).
///
/// - A `GtkDrawingArea` over the `WebKitWebView` (same `GtkOverlay`) draws
///   the marks and takes pointer input only while annotation mode is on
///   (crosshair cursor, accent frame); the page underneath gets no mouse
///   events then, like the AppKit overlay's hit test. Wheel/touchpad scroll
///   still scrolls the page (`window.scrollBy`).
/// - A floating pill at the top of the page: "Annotating" + count, Send to
///   Agent, Clear, Done (Esc).
/// - Browser toolbar: the annotate toggle with a count badge, and Send /
///   Clear while drafts exist.
/// - A `GtkPopover` anchored to the mark for the comment (Enter saves,
///   Shift+Enter inserts a newline, Esc cancels), and a detail popover with
///   Edit / Delete for an existing mark.
///
/// All state and rules live in `LinuxWebPanelAnnotationController`.
@MainActor
final class BrowserAnnotationOverlay {
    let controller: LinuxWebPanelAnnotationController
    private weak var panel: BrowserPanelController?
    let area: WidgetPtr
    let modeBar: WidgetPtr
    private let modeBarCount: WidgetPtr
    private let modeBarTitle: WidgetPtr
    private let modeBarSendLabel: WidgetPtr
    private var isCompact = false
    private let modeBarSend: WidgetPtr
    private let modeBarClearGroup: [WidgetPtr]
    let headerGroup: WidgetPtr
    private let toggleButton: WidgetPtr
    private let toggleBadge: WidgetPtr
    private let headerSend: WidgetPtr
    private let headerClear: WidgetPtr
    private var popover: WidgetPtr?
    private var shownPopoverID: UUID?
    private var popoverTextView: WidgetPtr?
    private var popoverPrimaryButton: WidgetPtr?
    private var popoverPrimaryAction: (@MainActor () -> Void)?
    private var isClosingPopover = false
    private var dragStart: CGPoint = .zero
    private var shownNoticeID: UUID?
    private var wasEnabled = false

    /// Last notice text (automation).
    private(set) var lastNoticeMessage: String?

    init(controller: LinuxWebPanelAnnotationController, panel: BrowserPanelController) {
        self.controller = controller
        self.panel = panel
        AnnotationStyles.install()

        area = gtk_drawing_area_new()!
        Gtk.expand(area)
        Gtk.addClasses(area, ["browser-annotation-overlay"])
        gtk_widget_set_focusable(area, 1)
        gtk_widget_set_can_target(area, 0)
        Gtk.setName(area, "browser-annotation-overlay")

        // Mode bar (floating pill).
        modeBar = Gtk.hbox(spacing: 0, classes: ["annotation-bar"])
        gtk_widget_set_halign(modeBar, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(modeBar, GTK_ALIGN_START)
        Gtk.margins(modeBar, top: 10, bottom: 0, start: 10, end: 10)
        Gtk.setName(modeBar, "browser-annotation-bar")
        let status = Gtk.hbox(spacing: 6, classes: ["annotation-bar-status"])
        Gtk.append(status, Gtk.image("document-edit-symbolic", pixelSize: 14, classes: ["accent"]))
        modeBarTitle = Gtk.label("Annotating", classes: ["annotation-bar-title"], ellipsize: false)
        Gtk.append(status, modeBarTitle)
        modeBarCount = Gtk.label("0", classes: ["annotation-count-badge"], xalign: 0.5, ellipsize: false)
        Gtk.append(status, modeBarCount)
        Gtk.append(modeBar, status)
        Gtk.append(modeBar, Self.separator())
        modeBarSend = gtk_menu_button_new()!
        Gtk.addClasses(modeBarSend, ["flat", "annotation-bar-button"])
        let sendLabel = Gtk.hbox(spacing: 5)
        Gtk.append(sendLabel, Gtk.image("mail-send-symbolic", pixelSize: 12))
        modeBarSendLabel = Gtk.label("Send to Agent", ellipsize: false)
        Gtk.append(sendLabel, modeBarSendLabel)
        gtk_menu_button_set_child(cast(modeBarSend), sendLabel)
        gtk_widget_set_tooltip_text(modeBarSend, "Send Browser Annotations to Agent")
        Gtk.setName(modeBarSend, "browser-annotation-bar-send")
        Gtk.append(modeBar, modeBarSend)
        let clearSeparator = Self.separator()
        let barClear = Gtk.button("Clear", classes: ["flat", "annotation-bar-button", "dim-label"])
        gtk_widget_set_tooltip_text(barClear, "Clear Browser Annotations")
        Gtk.setName(barClear, "browser-annotation-bar-clear")
        Gtk.append(modeBar, clearSeparator)
        Gtk.append(modeBar, barClear)
        modeBarClearGroup = [clearSeparator, barClear]
        Gtk.append(modeBar, Self.separator())
        let done = gtk_button_new()!
        Gtk.addClasses(done, ["flat", "annotation-bar-button"])
        let doneLabel = Gtk.hbox(spacing: 5)
        Gtk.append(doneLabel, Gtk.label("Done", classes: ["dim-label"], ellipsize: false))
        Gtk.append(doneLabel, Gtk.label("Esc", classes: ["annotation-keycap"], ellipsize: false))
        gtk_button_set_child(cast(done), doneLabel)
        gtk_widget_set_tooltip_text(done, "Exit Annotation Mode (Esc)")
        Gtk.setName(done, "browser-annotation-bar-done")
        Gtk.append(modeBar, done)
        Gtk.setVisible(modeBar, false)

        // Browser toolbar accessory.
        headerGroup = Gtk.hbox(spacing: 2, classes: ["browser-annotation-header"])
        toggleButton = Gtk.iconButton("document-edit-symbolic", tooltip: "Annotate Browser Page (Ctrl+Shift+A)")
        Gtk.setName(toggleButton, "browser-annotation-toggle")
        toggleBadge = Gtk.label("0", classes: ["annotation-count-badge", "annotation-header-badge"], xalign: 0.5, ellipsize: false)
        gtk_widget_set_halign(toggleBadge, GTK_ALIGN_END)
        gtk_widget_set_valign(toggleBadge, GTK_ALIGN_START)
        gtk_widget_set_can_target(toggleBadge, 0)
        Gtk.setVisible(toggleBadge, false)
        let toggleOverlay = gtk_overlay_new()!
        gtk_overlay_set_child(cast(toggleOverlay), toggleButton)
        gtk_overlay_add_overlay(cast(toggleOverlay), toggleBadge)
        Gtk.append(headerGroup, toggleOverlay)
        headerSend = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(headerSend), "mail-send-symbolic")
        gtk_widget_add_css_class(headerSend, "flat")
        gtk_widget_set_tooltip_text(headerSend, "Send Browser Annotations to Agent")
        Gtk.setName(headerSend, "browser-annotation-send")
        Gtk.append(headerGroup, headerSend)
        headerClear = Gtk.iconButton("edit-clear-all-symbolic", tooltip: "Clear Browser Annotations")
        Gtk.setName(headerClear, "browser-annotation-clear")
        Gtk.append(headerGroup, headerClear)

        Signal.connect(toggleButton, "clicked") { [weak self] in
            guard let self else { return }
            self.panel?.focusContent()
            self.controller.toggleAnnotationMode()
        }
        Signal.connect(done, "clicked") { [weak self] in self?.controller.setAnnotationModeEnabled(false) }
        Signal.connect(barClear, "clicked") { [weak self] in self?.confirmClear() }
        Signal.connect(headerClear, "clicked") { [weak self] in self?.confirmClear() }
        for button in [modeBarSend, headerSend] {
            let menu = gtk_popover_new()!
            gtk_menu_button_set_popover(cast(button), menu)
            Signal.connect(menu, "show") { [weak self, weak menuRef = Box(menu)] in
                guard let self, let menu = menuRef?.pointer else { return }
                self.fillSendMenu(menu)
            }
        }

        installDrawing()
        installInput()
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onRequestFocus = { [weak self] in
            guard let self else { return }
            MainLoop.idle { [weak self] in
                guard let self else { return }
                _ = gtk_widget_grab_focus(self.area)
            }
        }
        refresh()
    }

    /// Weak holder so menu signal closures don't retain their popover.
    private final class Box {
        let pointer: WidgetPtr
        init(_ pointer: WidgetPtr) { self.pointer = pointer }
    }

    private static func separator() -> WidgetPtr {
        let separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL)!
        Gtk.addClasses(separator, ["annotation-bar-separator"])
        gtk_widget_set_valign(separator, GTK_ALIGN_CENTER)
        return separator
    }

    // MARK: Drawing

    private func installDrawing() {
        let box = Unmanaged.passRetained(AnnotationDrawBox(self)).toOpaque()
        gtk_drawing_area_set_draw_func(cast(area), annotationDrawTrampoline, box, annotationDrawDestroy)
    }

    fileprivate func draw(_ cr: OpaquePointer, width: Int32, height: Int32) {
        controller.overlaySize = CGSize(width: Int(width), height: Int(height))
        updateCompactness(width: Int(width))
        guard controller.isAnnotationModeEnabled else { return }
        for mark in controller.marks { AnnotationMarkPainter.drawMark(cr, mark) }
        if let pending = controller.pendingMark { AnnotationMarkPainter.drawMark(cr, pending) }
        if let rect = controller.inProgressRectangle { AnnotationMarkPainter.drawRectangle(cr, rect) }
    }

    /// Narrow panels drop the pill's text labels (icons and tooltips stay).
    private func updateCompactness(width: Int) {
        let compact = width < 470
        guard compact != isCompact else { return }
        isCompact = compact
        MainLoop.idle { [weak self] in
            guard let self else { return }
            Gtk.setVisible(self.modeBarTitle, self.isCompact == false)
            Gtk.setVisible(self.modeBarSendLabel, self.isCompact == false)
        }
    }

    // MARK: Input

    private func installInput() {
        let drag = gtk_gesture_drag_new()!
        gtk_gesture_single_set_button(cast(drag), 1)
        Signal.connectDoubles(drag, "drag-begin") { [weak self] x, y in
            guard let self else { return }
            self.dragStart = CGPoint(x: x, y: y)
            _ = gtk_widget_grab_focus(self.area)
            self.syncOverlaySize()
            if self.controller.pointerPressed(at: self.dragStart) == false {
                gtk_gesture_set_state(cast(drag), GTK_EVENT_SEQUENCE_DENIED)
            }
        }
        Signal.connectDoubles(drag, "drag-update") { [weak self] dx, dy in
            guard let self else { return }
            self.controller.pointerDragged(to: CGPoint(x: self.dragStart.x + dx, y: self.dragStart.y + dy))
        }
        Signal.connectDoubles(drag, "drag-end") { [weak self] dx, dy in
            guard let self else { return }
            self.controller.pointerReleased(at: CGPoint(x: self.dragStart.x + dx, y: self.dragStart.y + dy))
        }
        gtk_widget_add_controller(area, drag)

        let motion = gtk_event_controller_motion_new()!
        Signal.connectDoubles(motion, "motion") { [weak self] x, y in
            guard let self else { return }
            let point = CGPoint(x: x, y: y)
            self.controller.pointerMoved(to: point)
            gtk_widget_set_cursor_from_name(self.area, self.controller.isOverMark(point) ? "pointer" : "crosshair")
        }
        Signal.connect(motion, "leave") { [weak self] in self?.controller.pointerLeft() }
        gtk_widget_add_controller(area, motion)

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)!
        connectScroll(scroll) { [weak self] controllerPointer, dx, dy in
            self?.scrolled(controllerPointer, dx: dx, dy: dy) ?? false
        }
        gtk_widget_add_controller(area, scroll)

        let keys = gtk_event_controller_key_new()!
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, _ in
            guard let self, Int32(keyval) == GDK_KEY_Escape else { return false }
            return self.controller.escapePressed()
        }
        gtk_widget_add_controller(area, keys)
    }

    private func syncOverlaySize() {
        let width = gtk_widget_get_width(area), height = gtk_widget_get_height(area)
        if width > 0, height > 0 { controller.overlaySize = CGSize(width: Int(width), height: Int(height)) }
    }

    /// Wheel / touchpad over the overlay: scroll the page by the same
    /// amount (WebKitGTK scrolls about 40 px per wheel step).
    private func scrolled(_ scrollController: OpaquePointer, dx: Double, dy: Double) -> Bool {
        let unit = gtk_event_controller_scroll_get_unit(scrollController)
        let multiplier = unit == GDK_SCROLL_UNIT_WHEEL ? 40.0 : 1.0
        let deltaX = dx * multiplier, deltaY = dy * multiplier
        guard controller.shouldScrollPage(deltaX: deltaX, deltaY: deltaY) else { return true }
        scrollPage(byPointsX: deltaX, y: deltaY)
        return true
    }

    func scrollPage(byPointsX dx: Double, y dy: Double) {
        guard let panel else { return }
        let zoom = max(webkit_web_view_get_zoom_level(panel.webView), 0.01)
        panel.evaluate("window.scrollBy(\(dx / zoom), \(dy / zoom)); 0") { [weak self] _ in
            self?.controller.pageDidScroll()
        }
    }

    /// Escape anywhere in the panel while annotating (the root key handler).
    func handleEscape() -> Bool {
        guard controller.isAnnotationModeEnabled, popover == nil else { return false }
        return controller.escapePressed()
    }

    // MARK: State → widgets

    /// The page changed (load, URI): the toggle's availability follows.
    func pageStateChanged() { refresh() }

    private func refresh() {
        let enabled = controller.isAnnotationModeEnabled
        let count = controller.draftCount
        gtk_widget_set_can_target(area, enabled.gboolean)
        Gtk.setClass(area, "active", enabled)
        gtk_widget_set_cursor_from_name(area, enabled ? "crosshair" : nil)
        Gtk.setVisible(modeBar, enabled)
        Gtk.setLabel(modeBarCount, "\(min(count, 99))")
        Gtk.setVisible(modeBarCount, count > 0)
        for widget in modeBarClearGroup { Gtk.setVisible(widget, count > 0) }
        gtk_widget_set_sensitive(modeBarSend, (controller.isSendDisabled == false).gboolean)
        gtk_widget_set_sensitive(modeBarClearGroup[1], (controller.isSendInFlight == false).gboolean)

        let canAnnotate = panel?.canAnnotate ?? false
        gtk_widget_set_sensitive(toggleButton, (canAnnotate || enabled).gboolean)
        Gtk.setClass(toggleButton, "accent", enabled)
        gtk_widget_set_tooltip_text(
            toggleButton,
            canAnnotate == false && enabled == false ? "Load a page to annotate it"
                : (enabled ? "Exit Annotation Mode (Esc)" : "Annotate Browser Page (Ctrl+Shift+A)")
        )
        Gtk.setLabel(toggleBadge, "\(min(count, 99))")
        Gtk.setVisible(toggleBadge, count > 0)
        // While annotating the pill carries Send / Clear; showing them in the
        // toolbar too would widen it and resize the page mid-annotation.
        Gtk.setVisible(headerSend, controller.hasDrafts && enabled == false)
        Gtk.setVisible(headerClear, controller.hasDrafts && enabled == false)
        gtk_widget_set_sensitive(headerSend, (controller.isSendDisabled == false).gboolean)
        gtk_widget_set_sensitive(headerClear, (controller.isSendInFlight == false).gboolean)

        if enabled != wasEnabled {
            wasEnabled = enabled
            if enabled == false, gtk_widget_has_focus(area).bool { panel?.focusContent() }
        }
        syncPopover()
        showNoticeIfNeeded()
        gtk_widget_queue_draw(area)
    }

    private func showNoticeIfNeeded() {
        guard let notice = controller.notice, notice.id != shownNoticeID else { return }
        shownNoticeID = notice.id
        lastNoticeMessage = notice.message
        DesktopLauncher.toast(notice.message, from: panel?.root)
        let id = notice.id
        MainLoop.timeout(milliseconds: 2800) { [weak self] in
            self?.controller.clearNotice(id: id)
            return false
        }
    }

    // MARK: Send menu and clear

    private func fillSendMenu(_ menu: WidgetPtr) {
        let list = Gtk.vbox(spacing: 2, classes: ["annotation-send-menu"])
        Gtk.margins(list, 4)
        Gtk.append(list, Gtk.label("Send to Agent", classes: ["dim-label", "caption-heading"]))
        let candidates = controller.sendCandidates
        if candidates.isEmpty {
            let empty = Gtk.label("No active sessions in this tab", classes: ["dim-label"])
            Gtk.margins(empty, top: 4, bottom: 4, start: 6, end: 6)
            Gtk.append(list, empty)
        }
        for candidate in candidates {
            let button = gtk_button_new()!
            Gtk.addClasses(button, ["flat"])
            let row = Gtk.hbox(spacing: 6)
            Gtk.append(row, Gtk.image("mail-send-symbolic", pixelSize: 14))
            Gtk.append(row, Gtk.label(candidate.blockedReason.map { "\(candidate.label) (\($0))" } ?? candidate.label))
            gtk_button_set_child(cast(button), row)
            gtk_widget_set_sensitive(button, (candidate.blockedReason == nil).gboolean)
            let sessionID = candidate.sessionID
            Signal.connect(button, "clicked") { [weak self] in
                gtk_popover_popdown(cast(menu))
                self?.panel?.focusContent()
                self?.controller.send(toSessionID: sessionID)
            }
            Gtk.append(list, button)
        }
        gtk_popover_set_child(cast(menu), list)
    }

    private func confirmClear() {
        guard let root = panel?.root else { return }
        let dialog = adw_alert_dialog_new(LinuxAnnotationCopy.clearConfirmationTitle(draftCount: controller.draftCount), nil)!
        adw_alert_dialog_add_response(cast(dialog), "cancel", "Cancel")
        adw_alert_dialog_add_response(cast(dialog), "clear", "Clear All")
        adw_alert_dialog_set_response_appearance(cast(dialog), "clear", ADW_RESPONSE_DESTRUCTIVE)
        adw_alert_dialog_set_default_response(cast(dialog), "cancel")
        adw_alert_dialog_set_close_response(cast(dialog), "cancel")
        Signal.connectPointer(dialog, "response") { [weak self] response in
            let id = response.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
            if id == "clear" { self?.controller.clearAnnotations(exitAnnotationMode: false) }
        }
        adw_dialog_present(cast(dialog), root)
    }

    // MARK: Comment popovers

    private func syncPopover() {
        let wanted = controller.popover
        if wanted?.id == shownPopoverID { return }
        closePopover()
        guard let wanted else { return }
        showPopover(wanted)
    }

    private func closePopover() {
        guard let popover else { return }
        isClosingPopover = true
        gtk_popover_popdown(cast(popover))
        isClosingPopover = false
        // Often called from the popover's own button or key handler: let
        // that emission finish before the popover (and its children) go.
        MainLoop.idle { gtk_widget_unparent(popover) }
        self.popover = nil
        shownPopoverID = nil
        popoverTextView = nil
        popoverPrimaryButton = nil
        popoverPrimaryAction = nil
    }

    private func showPopover(_ model: LinuxAnnotationPopover) {
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, area)
        Gtk.addClasses(popover, ["annotation-comment-popover"])
        Gtk.setName(popover, "browser-annotation-popover")
        gtk_popover_set_position(cast(popover), GTK_POS_RIGHT)
        gtk_popover_set_autohide(cast(popover), 1)
        var anchor = Self.anchorRect(model.anchorRect, in: controller.overlaySize)
        gtk_popover_set_pointing_to(cast(popover), &anchor)

        let content = Gtk.vbox(spacing: 8, classes: ["annotation-popover-content"])
        gtk_widget_set_size_request(content, 262, -1)
        Gtk.margins(content, 4)
        let header = Gtk.hbox(spacing: 7)
        Gtk.append(header, Self.numberBadge(model.number))
        Gtk.append(header, Gtk.label(model.isEditing ? "Add comment" : "Annotation", classes: ["heading"]))
        Gtk.append(content, header)

        if model.isEditing {
            buildEditor(content, model: model)
        } else {
            buildDetail(content, model: model)
        }
        gtk_popover_set_child(cast(popover), content)

        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, state in
            guard let self else { return false }
            let key = Int32(keyval)
            if key == GDK_KEY_Escape {
                self.controller.cancelPopover()
                return true
            }
            if model.isEditing, key == GDK_KEY_Return || key == GDK_KEY_KP_Enter,
               state.rawValue & GDK_SHIFT_MASK.rawValue == 0 {
                self.savePopover()
                return true
            }
            return false
        }
        gtk_widget_add_controller(popover, keys)
        Signal.connect(popover, "closed") { [weak self] in
            guard let self, self.isClosingPopover == false, self.shownPopoverID == model.id else { return }
            // Closed by an outside click (autohide): resolve like macOS's
            // click-away on the overlay, on the next turn (GTK is still
            // inside the popover's grab handling here).
            MainLoop.idle { [weak self] in
                guard let self, self.shownPopoverID == model.id else { return }
                self.controller.popoverDismissedByOutsideClick()
            }
        }

        self.popover = popover
        shownPopoverID = model.id
        gtk_popover_popup(cast(popover))
        // Editors focus the text; the detail view focuses Edit (a focused
        // selectable label would select all of the comment).
        if let focusTarget = popoverTextView ?? popoverPrimaryButton { _ = gtk_widget_grab_focus(focusTarget) }
    }

    private func buildEditor(_ content: WidgetPtr, model: LinuxAnnotationPopover) {
        let textView = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(cast(textView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_top_margin(cast(textView), 6)
        gtk_text_view_set_bottom_margin(cast(textView), 6)
        gtk_text_view_set_left_margin(cast(textView), 8)
        gtk_text_view_set_right_margin(cast(textView), 8)
        gtk_text_view_set_accepts_tab(cast(textView), 0)
        Gtk.setName(textView, "browser-annotation-comment")
        let buffer = gtk_text_view_get_buffer(cast(textView))!
        gtk_text_buffer_set_text(buffer, model.comment, -1)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), textView)
        gtk_widget_set_size_request(scroller, -1, 58)
        let placeholder = Gtk.label("What should the agent change here?", classes: ["dim-label", "annotation-placeholder"])
        gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_halign(placeholder, GTK_ALIGN_START)
        Gtk.margins(placeholder, top: 6, bottom: 0, start: 9, end: 0)
        gtk_widget_set_can_target(placeholder, 0)
        let field = gtk_overlay_new()!
        Gtk.addClasses(field, ["annotation-comment-field"])
        gtk_overlay_set_child(cast(field), scroller)
        gtk_overlay_add_overlay(cast(field), placeholder)
        Gtk.append(content, field)

        let footer = Gtk.hbox(spacing: 8)
        let hint = Gtk.label("Enter Save · Shift+Enter Newline · Esc Cancel", classes: ["dim-label", "annotation-popover-hint"])
        gtk_widget_set_hexpand(hint, 1)
        Gtk.append(footer, hint)
        if case .edit = model.purpose {
            let delete = Gtk.button("Delete", classes: ["flat", "destructive-action", "annotation-popover-button"])
            Signal.connect(delete, "clicked") { [weak self] in self?.controller.deletePopoverAnnotation() }
            Gtk.append(footer, delete)
        }
        let save = Gtk.button(model.purpose == .create ? "Add" : "Save", classes: ["suggested-action", "pill", "annotation-popover-button"])
        Gtk.setName(save, "browser-annotation-save")
        let saveAction: @MainActor () -> Void = { [weak self] in self?.savePopover() }
        Signal.connect(save, "clicked") { saveAction() }
        Gtk.append(footer, save)
        Gtk.append(content, footer)

        let update: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let text = Self.text(of: textView)
            self.controller.popoverTextChanged(text)
            Gtk.setVisible(placeholder, text.isEmpty)
            gtk_widget_set_sensitive(save, (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false).gboolean)
        }
        Signal.connect(buffer, "changed") { update() }
        popoverTextView = textView
        popoverPrimaryButton = save
        popoverPrimaryAction = saveAction
        update()
    }

    private func buildDetail(_ content: WidgetPtr, model: LinuxAnnotationPopover) {
        let comment = Gtk.label(model.comment, classes: ["annotation-detail-comment"], ellipsize: false)
        gtk_label_set_wrap(cast(comment), 1)
        gtk_label_set_selectable(cast(comment), 1)
        gtk_label_set_max_width_chars(cast(comment), 34)
        Gtk.append(content, comment)
        // GTK selects a selectable label's text when the popover maps.
        Signal.connect(comment, "map", after: true) {
            MainLoop.idle { gtk_label_select_region(cast(comment), 0, 0) }
        }
        let footer = Gtk.hbox(spacing: 8)
        let spacer = Gtk.hbox()
        gtk_widget_set_hexpand(spacer, 1)
        Gtk.append(footer, spacer)
        let delete = Gtk.button("Delete", classes: ["flat", "destructive-action", "annotation-popover-button"])
        Signal.connect(delete, "clicked") { [weak self] in self?.controller.deletePopoverAnnotation() }
        Gtk.append(footer, delete)
        let edit = Gtk.button("Edit", classes: ["pill", "annotation-popover-button"])
        Gtk.setName(edit, "browser-annotation-edit")
        let editAction: @MainActor () -> Void = { [weak self] in self?.controller.editFromDetailPopover() }
        Signal.connect(edit, "clicked") { editAction() }
        Gtk.append(footer, edit)
        Gtk.append(content, footer)
        popoverPrimaryButton = edit
        popoverPrimaryAction = editAction
    }

    private func savePopover() {
        guard let popoverTextView else { return }
        controller.savePopover(text: Self.text(of: popoverTextView))
    }

    private static func text(of textView: WidgetPtr) -> String {
        let buffer = gtk_text_view_get_buffer(cast(textView))!
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private static func numberBadge(_ number: Int) -> WidgetPtr {
        let badge = Gtk.label("\(number)", classes: ["annotation-number-badge"], xalign: 0.5, ellipsize: false)
        gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
        return badge
    }

    /// The mark's bubble clipped to the overlay (centered when off-screen).
    private static func anchorRect(_ rect: CGRect, in size: CGSize) -> GdkRectangle {
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = rect.intersection(bounds)
        let anchor = clipped.isNull || clipped.isEmpty ? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) : clipped
        return GdkRectangle(
            x: Int32(anchor.minX.rounded(.down)), y: Int32(anchor.minY.rounded(.down)),
            width: max(1, Int32(anchor.width.rounded(.up))), height: max(1, Int32(anchor.height.rounded(.up)))
        )
    }

    // MARK: Automation

    /// Runs one primary-button gesture through the same handlers the
    /// GtkGestureDrag calls (press at `start`, drag, release at `end`).
    func simulateGesture(from start: CGPoint, to end: CGPoint) {
        syncOverlaySize()
        _ = gtk_widget_grab_focus(area)
        guard controller.pointerPressed(at: start) else { return }
        if start != end {
            controller.pointerDragged(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            controller.pointerDragged(to: end)
        }
        controller.pointerReleased(at: end)
    }

    /// Types `text` into the open editor popover (real GtkTextView buffer).
    func typeComment(_ text: String) -> Bool {
        guard let popoverTextView, let buffer = gtk_text_view_get_buffer(cast(popoverTextView)) else { return false }
        gtk_text_buffer_set_text(buffer, text, -1)
        return true
    }

    /// Clicks the popover's primary button (Add / Save / Edit): runs its
    /// `clicked` handler if the button is enabled (`gtk_widget_activate`
    /// would only animate the press and click later).
    func clickPopoverPrimaryButton() -> Bool {
        guard let popoverPrimaryButton, gtk_widget_get_sensitive(popoverPrimaryButton).bool,
              let popoverPrimaryAction else { return false }
        popoverPrimaryAction()
        return true
    }

    /// Writes the open popover to a PNG (window screenshots do not include
    /// popovers: they are separate surfaces). Returns an error message.
    func writePopoverPNG(to path: String) -> String? {
        guard let popover else { return "no popover is open" }
        var background = LinuxTheme.isDark
            ? GdkRGBA(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3a / 255.0, alpha: 1)
            : GdkRGBA(red: 1, green: 1, blue: 1, alpha: 1)
        var error: UnsafeMutablePointer<GError>?
        let target = gtk_popover_get_child(cast(popover)).map { widget($0) } ?? popover
        guard toastty_widget_write_png(target, path, &background, &error).bool else {
            let message = error.map { String(cString: $0.pointee.message) } ?? "unknown error"
            if let error { g_error_free(error) }
            return message
        }
        return nil
    }

    var isPopoverShown: Bool { popover.map { gtk_widget_get_visible($0).bool } ?? false }
    var isModeBarShown: Bool { gtk_widget_get_visible(modeBar).bool }

    func close() {
        closePopover()
        controller.onChange = nil
        controller.onRequestFocus = nil
    }
}

private final class AnnotationDrawBox: @unchecked Sendable {
    weak var overlay: BrowserAnnotationOverlay?
    init(_ overlay: BrowserAnnotationOverlay) { self.overlay = overlay }
}

private let annotationDrawTrampoline: GtkDrawingAreaDrawFunc = { _, cr, width, height, data in
    guard let data, let cr else { return }
    let box = Unmanaged<AnnotationDrawBox>.fromOpaque(data).takeUnretainedValue()
    nonisolated(unsafe) let context = cr
    MainActor.assumeIsolated { box.overlay?.draw(context, width: width, height: height) }
}

private let annotationDrawDestroy: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<AnnotationDrawBox>.fromOpaque(data).release()
}

// MARK: - GtkEventControllerScroll::scroll

private final class ScrollBox: @unchecked Sendable {
    let handler: @MainActor (OpaquePointer, Double, Double) -> Bool
    init(_ handler: @escaping @MainActor (OpaquePointer, Double, Double) -> Bool) { self.handler = handler }
}

// (controller, dx, dy, user_data) -> gboolean
private let scrollTrampoline: @convention(c) (gpointer?, gdouble, gdouble, gpointer?) -> gboolean = { instance, dx, dy, data in
    let box = Unmanaged<ScrollBox>.fromOpaque(data!).takeUnretainedValue()
    nonisolated(unsafe) let controller = instance
    return MainActor.assumeIsolated { box.handler(OpaquePointer(controller!), dx, dy) }.gboolean
}

private let scrollRelease: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    guard let data else { return }
    Unmanaged<ScrollBox>.fromOpaque(data).release()
}

@MainActor
private func connectScroll(_ controller: OpaquePointer, _ handler: @escaping @MainActor (OpaquePointer, Double, Double) -> Bool) {
    let box = Unmanaged.passRetained(ScrollBox(handler)).toOpaque()
    let callback = unsafeBitCast(scrollTrampoline, to: GCallback.self)
    g_signal_connect_data(UnsafeMutableRawPointer(controller), "scroll", callback, box, scrollRelease, GConnectFlags(rawValue: 0))
}

// MARK: - Styles

@MainActor
private enum AnnotationStyles {
    private static var installed = false

    static func install() {
        guard installed == false, let display = gdk_display_get_default() else { return }
        installed = true
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(display, OpaquePointer(provider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    static let css = """
    .browser-annotation-overlay.active { box-shadow: inset 0 0 0 2px alpha(var(--accent-bg-color), 0.85); }
    .annotation-bar {
      background-color: color-mix(in srgb, var(--popover-bg-color) 96%, transparent);
      color: var(--popover-fg-color);
      border: 1px solid alpha(currentColor, 0.14);
      border-radius: 999px;
      padding: 3px 4px;
      box-shadow: 0 3px 9px alpha(black, 0.30);
    }
    .annotation-bar .annotation-bar-status { padding: 0 8px 0 10px; }
    .annotation-bar .annotation-bar-title { font-size: 0.85em; font-weight: 700; }
    .annotation-bar button.annotation-bar-button,
    .annotation-bar menubutton.annotation-bar-button > button { min-height: 24px; padding: 0 10px; border-radius: 999px; font-size: 0.85em; font-weight: 600; }
    .annotation-bar separator.annotation-bar-separator { min-height: 14px; margin: 0 2px; background-color: alpha(currentColor, 0.15); }
    .annotation-keycap {
      font-family: monospace; font-size: 0.72em; font-weight: 700; padding: 0 4px; border-radius: 4px;
      background-color: alpha(currentColor, 0.1); opacity: 0.75;
    }
    .annotation-count-badge {
      background-color: #e5484d; color: white; font-size: 0.66em; font-weight: 800;
      border-radius: 999px; min-width: 14px; min-height: 14px; padding: 0 3px;
    }
    .annotation-header-badge { margin: 1px 0 0 0; }
    .annotation-number-badge {
      background-color: #e5484d; color: white; font-size: 0.75em; font-weight: 800;
      border-radius: 999px; min-width: 18px; min-height: 18px; border: 1.5px solid white;
    }
    .annotation-comment-field {
      border-radius: 8px; border: 1px solid alpha(currentColor, 0.15); background-color: var(--view-bg-color);
    }
    .annotation-comment-field textview, .annotation-comment-field textview text { background: transparent; }
    .annotation-placeholder, .annotation-detail-comment { font-size: 0.92em; }
    .annotation-popover-hint { font-size: 0.75em; }
    .annotation-comment-popover button.annotation-popover-button { min-height: 24px; padding: 0 12px; font-size: 0.85em; font-weight: 600; }
    """
}
#endif
