import CGtk
import CGtkShim
import CoreState
import Foundation

/// The workspace sidebar: a scrolling list of rounded workspace cards, each
/// with its managed-agent session rows. Rows are rebuilt only when the
/// presentation model changes.
@MainActor
public final class SidebarController {
    public let root: WidgetPtr
    private let list: WidgetPtr
    private let windowID: UUID
    private let store: any LinuxStoreBinding
    private var rows: [SidebarWorkspaceRowModel] = []
    private var hintLabels: [WidgetPtr] = []
    private var showsShortcutHints = false
    private let contextMenu: WidgetPtr
    private static let dragMimePrefix = "toastty-workspace:"

    public var onRenameWorkspace: ((UUID) -> Void)?
    public var onCloseWorkspace: ((UUID) -> Void)?

    public init(windowID: UUID, store: any LinuxStoreBinding) {
        self.windowID = windowID
        self.store = store

        let toolbar = adw_toolbar_view_new()!
        root = toolbar
        Gtk.addClasses(root, ["toastty-sidebar"])

        let header = adw_header_bar_new()!
        let title = adw_window_title_new("Workspaces", nil)!
        adw_header_bar_set_title_widget(cast(header), title)
        let newButton = Gtk.iconButton(
            "list-add-symbolic",
            tooltip: "New Workspace (\(ShortcutLabels.label(forCommand: "workspace.create") ?? ""))",
            action: "win.workspace.create"
        )
        adw_header_bar_pack_end(cast(header), newButton)
        adw_toolbar_view_add_top_bar(cast(toolbar), header)

        list = gtk_list_box_new()
        Gtk.addClasses(list, ["workspace-list"])
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_NONE)
        gtk_list_box_set_activate_on_single_click(cast(list), 1)
        contextMenu = gtk_popover_menu_new_from_model(nil)
        gtk_popover_set_has_arrow(cast(contextMenu), 0)
        gtk_widget_set_halign(contextMenu, GTK_ALIGN_START)
        gtk_widget_set_parent(contextMenu, toolbar)
        Signal.connectPointer(list, "row-activated") { [weak self] rowPointer in
            guard let self, let rowPointer else { return }
            let index = Int(gtk_list_box_row_get_index(cast(rowPointer)))
            guard self.rows.indices.contains(index) else { return }
            self.store.send(.selectWorkspace(windowID: self.windowID, workspaceID: self.rows[index].workspaceID))
        }

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), list)
        Gtk.expand(scroller)
        adw_toolbar_view_set_content(cast(toolbar), scroller)

    }

    private var isTornDown = false

    /// Unparents the context popover; call before the window is destroyed.
    public func teardown() {
        guard isTornDown == false else { return }
        isTornDown = true
        gtk_widget_unparent(contextMenu)
    }

    isolated deinit {
        teardown()
    }

    public func render(_ state: AppState) {
        let newRows = SidebarModel.rows(state: state, windowID: windowID, sessions: store.sessions)
        guard newRows != rows else { return }
        rows = newRows
        rebuild()
    }

    public func setShowsShortcutHints(_ shows: Bool) {
        guard shows != showsShortcutHints else { return }
        showsShortcutHints = shows
        for label in hintLabels { Gtk.setVisible(label, shows) }
    }

    public var rowModels: [SidebarWorkspaceRowModel] { rows }

    private func rebuild() {
        gtk_list_box_remove_all(cast(list))
        hintLabels.removeAll()
        for row in rows {
            gtk_list_box_append(cast(list), makeCard(row))
        }
    }

    private func makeCard(_ row: SidebarWorkspaceRowModel) -> WidgetPtr {
        let card = Gtk.vbox(spacing: 2, classes: ["workspace-card"])
        Gtk.setName(card, "workspace-card-\(row.index)")
        Gtk.setClass(card, "selected", row.isSelected)
        Gtk.setClass(card, "unvisited", row.showsNewBadge)

        let titleLine = Gtk.hbox(spacing: 6)
        if row.isSubspace {
            Gtk.append(titleLine, Gtk.image(row.isDone ? "object-select-symbolic" : "mail-forward-symbolic", pixelSize: 12))
        }
        let title = Gtk.label(row.title, classes: ["workspace-title"])
        gtk_widget_set_hexpand(title, 1)
        Gtk.append(titleLine, title)
        if row.showsNewBadge {
            Gtk.append(titleLine, Gtk.label("New", classes: ["count-badge", "quiet"], xalign: 0.5, ellipsize: false))
        }
        if row.hasUnread {
            let dot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, classes: ["status-dot", "ready"])
            gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(dot, "Unread")
            Gtk.append(titleLine, dot)
        }
        if row.runningAgentCount > 0 {
            let badge = Gtk.label("\(row.runningAgentCount)", classes: ["count-badge"], xalign: 0.5, ellipsize: false)
            gtk_widget_set_tooltip_text(badge, "\(row.runningAgentCount) running")
            Gtk.append(titleLine, badge)
        }
        if let shortcut = row.shortcutLabel {
            let hint = Gtk.label(shortcut, classes: ["shortcut-hint"], xalign: 0.5, ellipsize: false)
            gtk_widget_set_valign(hint, GTK_ALIGN_CENTER)
            Gtk.setVisible(hint, showsShortcutHints)
            hintLabels.append(hint)
            Gtk.append(titleLine, hint)
        }
        Gtk.append(card, titleLine)
        Gtk.append(card, Gtk.label(row.subtitle, classes: ["workspace-subtitle"]))

        if row.sessions.isEmpty == false {
            let sessions = Gtk.vbox(spacing: 0)
            gtk_widget_set_margin_top(sessions, 4)
            for session in row.sessions {
                Gtk.append(sessions, makeSessionRow(session, workspaceID: row.workspaceID))
            }
            Gtk.append(card, sessions)
        }

        attachContextMenu(to: card, workspaceID: row.workspaceID)
        attachDragAndDrop(to: card, index: row.index)
        return card
    }

    private func makeSessionRow(_ session: SidebarSessionRowModel, workspaceID: UUID) -> WidgetPtr {
        let row = Gtk.hbox(spacing: 8, classes: ["session-row"])
        Gtk.setClass(row, "unread", session.isUnread)
        Gtk.setClass(row, "focused", session.isFocused)
        if let attention = session.attentionClass { Gtk.addClasses(row, [attention]) }

        let dot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, classes: ["status-dot", session.statusClass])
        gtk_widget_set_valign(dot, GTK_ALIGN_START)
        gtk_widget_set_margin_top(dot, 5)
        Gtk.append(row, dot)

        let text = Gtk.vbox(spacing: 0)
        gtk_widget_set_hexpand(text, 1)
        let nameLine = Gtk.hbox(spacing: 6)
        let name = Gtk.label(session.name, classes: ["session-name"])
        gtk_widget_set_hexpand(name, 1)
        Gtk.append(nameLine, name)
        if session.isFlaggedForLater {
            let flag = Gtk.image("emoji-flags-symbolic", pixelSize: 12, classes: ["later-flag"])
            gtk_widget_set_tooltip_text(flag, "Flagged for later")
            Gtk.append(nameLine, flag)
        }
        if let chip = session.chipLabel {
            Gtk.append(nameLine, Gtk.label(chip, classes: ["status-chip", session.statusClass], xalign: 0.5, ellipsize: false))
        }
        Gtk.append(text, nameLine)
        if let summary = session.summary {
            Gtk.append(text, Gtk.label(summary, classes: ["session-summary"]))
        } else {
            Gtk.append(text, Gtk.label(session.agentLabel, classes: ["session-agent"]))
        }
        Gtk.append(row, text)
        gtk_widget_set_tooltip_text(row, "\(session.name) · \(session.agentLabel)")

        let click = gtk_gesture_click_new()!
        Signal.connectPress(click) { [weak self] _, _, _ in
            guard let self else { return }
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            self.focusSession(panelID: session.panelID, workspaceID: workspaceID)
        }
        gtk_widget_add_controller(row, cast(click))
        return row
    }

    private func focusSession(panelID: UUID, workspaceID: UUID) {
        guard let workspace = store.state.workspacesByID[workspaceID],
              let tabID = workspace.tabID(containingPanelID: panelID) else { return }
        store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
        store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
    }

    // MARK: Context menu

    private func attachContextMenu(to card: WidgetPtr, workspaceID: UUID) {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), guint(GDK_BUTTON_SECONDARY))
        Signal.connectPress(click) { [weak self] _, x, y in
            self?.showContextMenu(for: workspaceID, from: card, x: x, y: y)
        }
        gtk_widget_add_controller(card, cast(click))
    }

    public func contextMenuModel(for workspaceID: UUID) -> OpaquePointer {
        let id = workspaceID.uuidString
        let menu = g_menu_new()!
        let primary = g_menu_new()!
        g_menu_append(primary, "Rename…", "win.sidebar.rename::\(id)")
        g_menu_append(primary, "New Tab", "win.sidebar.new-tab::\(id)")
        g_menu_append_section(menu, nil, cast(primary))
        let move = g_menu_new()!
        g_menu_append(move, "Move Up", "win.sidebar.move-up::\(id)")
        g_menu_append(move, "Move Down", "win.sidebar.move-down::\(id)")
        g_menu_append_section(menu, nil, cast(move))
        let close = g_menu_new()!
        g_menu_append(close, "Close Workspace", "win.sidebar.close::\(id)")
        g_menu_append_section(menu, nil, cast(close))
        g_object_unref(UnsafeMutableRawPointer(primary))
        g_object_unref(UnsafeMutableRawPointer(move))
        g_object_unref(UnsafeMutableRawPointer(close))
        return menu
    }

    private func showContextMenu(for workspaceID: UUID, from card: WidgetPtr, x: Double, y: Double) {
        let model = contextMenuModel(for: workspaceID)
        gtk_popover_menu_set_menu_model(cast(contextMenu), cast(model))
        g_object_unref(UnsafeMutableRawPointer(model))
        var source = graphene_point_t(x: Float(x), y: Float(y))
        var target = graphene_point_t(x: 0, y: 0)
        guard gtk_widget_compute_point(card, root, &source, &target).bool else { return }
        var rect = GdkRectangle(x: Int32(target.x), y: Int32(target.y), width: 1, height: 1)
        gtk_popover_set_pointing_to(cast(contextMenu), &rect)
        gtk_popover_popup(cast(contextMenu))
    }

    // MARK: Drag reordering

    private func attachDragAndDrop(to card: WidgetPtr, index: Int) {
        let source = gtk_drag_source_new()!
        gtk_drag_source_set_actions(source, GDK_ACTION_MOVE)
        Signal.connectDragPrepare(source) { [weak self] _, _ in
            guard let self, self.rows.indices.contains(index) else { return nil }
            let payload = Self.dragMimePrefix + self.rows[index].workspaceID.uuidString
            return UnsafeMutableRawPointer(toastty_content_provider_new_string(payload))
        }
        gtk_widget_add_controller(card, cast(source))

        let target = gtk_drop_target_new(toastty_g_type_string(), GDK_ACTION_MOVE)!
        Signal.connectDropMotion(target, "enter") { _, _ in
            Gtk.setClass(card, "drop-target", true)
            return GDK_ACTION_MOVE.rawValue
        }
        Signal.connect(target, "leave") {
            Gtk.setClass(card, "drop-target", false)
        }
        Signal.connectDrop(target) { [weak self] value, _, y in
            Gtk.setClass(card, "drop-target", false)
            guard let self,
                  let cString = toastty_value_get_string(value?.assumingMemoryBound(to: GValue.self)) else { return false }
            let payload = String(cString: cString)
            guard payload.hasPrefix(Self.dragMimePrefix),
                  let draggedID = UUID(uuidString: String(payload.dropFirst(Self.dragMimePrefix.count))),
                  let fromIndex = self.rows.firstIndex(where: { $0.workspaceID == draggedID }) else { return false }
            let placeAfter = y > Double(gtk_widget_get_height(card)) / 2
            let toIndex = Self.reorderDestination(from: fromIndex, onto: index, placeAfter: placeAfter)
            guard toIndex != fromIndex else { return true }
            return self.store.send(.moveWorkspace(windowID: self.windowID, fromIndex: fromIndex, toIndex: toIndex))
        }
        gtk_widget_add_controller(card, cast(target))
    }

    /// Final index for a row dragged from `from` and dropped on row `onto`.
    public static func reorderDestination(from: Int, onto: Int, placeAfter: Bool) -> Int {
        var destination = placeAfter ? onto + 1 : onto
        if from < destination { destination -= 1 }
        return max(0, destination)
    }
}
