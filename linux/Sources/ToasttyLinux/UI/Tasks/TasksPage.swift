#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The Tasks view (macOS `TasksView`): every task in the sidebar's groups on
/// the left, the selected task's detail pane on the right. It covers the
/// workspace while `WindowState.showsTasksView`; Esc or selecting a
/// workspace leaves it, and Up and Down Arrow move the selection.
///
/// The list and the detail are rebuilt when their models change, and the
/// ages once a minute while the view shows.
@MainActor
final class TasksPage {
    let root: WidgetPtr
    private let ui: TasksUI
    private let windowID: UUID
    private let listBox: WidgetPtr
    private let listScroller: WidgetPtr
    private let detailBox: WidgetPtr
    private let bannerBox: WidgetPtr
    private let newTaskButton: WidgetPtr
    private let newTaskShortcut: WidgetPtr
    private let contextMenu: WidgetPtr
    private var contextMenuRef: GObjectRef?
    private var isShown = false
    private var isDoneExpanded = false
    private var isArchivedExpanded = false
    private var listModel: [ListItem] = []
    private var detailModel: Detail?
    /// The detail pane was drawn once, so an empty pane shows its text.
    private var hasDrawnDetail = false
    private var bannerModel: Banners?
    private var rowWidgets: [TaskBoardItem.Subject: WidgetPtr] = [:]
    /// The context menu's items, by the index its actions name.
    private var menuEntries: [(item: TaskBoardItem, menuItem: TaskBoardPresentation.MenuItem)] = []
    private var detailError: String?
    private var ageTimer: guint = 0
    /// The row to scroll into view after the next list rebuild.
    private var scrollTarget: TaskBoardItem.Subject?
    private var setupSelection: [UUID: TaskWorkspaceChoice] = [:]

    init(ui: TasksUI, windowID: UUID) {
        self.ui = ui
        self.windowID = windowID
        root = Gtk.hbox(classes: ["tasks-view"])
        Gtk.setName(root, "tasks.view")
        gtk_widget_set_focusable(root, 1)

        // List column.
        let listColumn = Gtk.vbox()
        Gtk.expand(listColumn)
        let header = Gtk.hbox(spacing: 12, classes: ["tasks-header"])
        let title = Gtk.label("Tasks", classes: ["tasks-title"])
        gtk_widget_set_hexpand(title, 1)
        Gtk.append(header, title)
        newTaskButton = gtk_button_new()!
        Gtk.addClasses(newTaskButton, ["suggested-action", "tasks-new"])
        let newTaskContent = Gtk.hbox(spacing: 7)
        Gtk.append(newTaskContent, Gtk.image("list-add-symbolic", pixelSize: 14))
        Gtk.append(newTaskContent, Gtk.label("New Task", ellipsize: false))
        newTaskShortcut = Gtk.label("", classes: ["tasks-new-key"], ellipsize: false)
        Gtk.append(newTaskContent, newTaskShortcut)
        gtk_button_set_child(cast(newTaskButton), newTaskContent)
        Gtk.setName(newTaskButton, "tasks.view.new")
        Gtk.append(header, newTaskButton)
        let close = Gtk.iconButton("window-close-symbolic", tooltip: "Close the Tasks view (Esc)")
        Gtk.setName(close, "tasks.view.close")
        Gtk.append(header, close)
        Gtk.append(listColumn, header)

        bannerBox = Gtk.vbox(spacing: 6, classes: ["tasks-banners"])
        Gtk.append(listColumn, bannerBox)

        listBox = Gtk.vbox(classes: ["tasks-list"])
        listScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(listScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(listScroller), listBox)
        Gtk.expand(listScroller)
        Gtk.append(listColumn, listScroller)
        Gtk.append(root, listColumn)

        Gtk.append(root, gtk_separator_new(GTK_ORIENTATION_VERTICAL))

        // Detail column, 360 wide as on macOS.
        detailBox = Gtk.vbox(spacing: 14, classes: ["tasks-detail"])
        Gtk.setName(detailBox, "tasks.view.detail")
        let detailScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(detailScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(detailScroller), detailBox)
        gtk_widget_set_size_request(detailScroller, 360, -1)
        gtk_widget_set_vexpand(detailScroller, 1)
        Gtk.append(root, detailScroller)

        contextMenu = gtk_popover_menu_new_from_model(nil)
        gtk_popover_set_has_arrow(cast(contextMenu), 0)
        gtk_widget_set_halign(contextMenu, GTK_ALIGN_START)
        contextMenuRef = GObjectRef(sinking: contextMenu)
        gtk_widget_set_parent(contextMenu, root)

        Signal.connect(newTaskButton, "clicked") { [weak self] in self?.ui.board.newTask?() }
        Signal.connect(close, "clicked") { [weak self] in self?.close() }
        installMenuActions()
        installKeys()
    }

    private var isTornDown = false

    func teardown() {
        guard isTornDown == false else { return }
        isTornDown = true
        MainLoop.cancel(ageTimer)
        ageTimer = 0
        Gtk.unparentIfAttached(contextMenu)
    }

    isolated deinit {
        teardown()
    }

    private func close() {
        _ = ui.store.send(.setTasksViewShown(windowID: windowID, shown: false))
    }

    // MARK: - Render

    func render(_ state: AppState, isShown shows: Bool) {
        let opened = shows && isShown == false
        isShown = shows
        guard shows else {
            if ageTimer != 0 {
                MainLoop.cancel(ageTimer)
                ageTimer = 0
            }
            return
        }
        let board = ui.board
        if opened {
            // A new look at the board, as a SwiftUI view that appears.
            isDoneExpanded = false
            isArchivedExpanded = false
            detailError = nil
            board.tasksViewDidOpen()
            ageTimer = MainLoop.timeout(milliseconds: 60_000) { [weak self] in
                self?.ui.scheduleRender()
                return true
            }
            MainLoop.idle { [weak self] in
                guard let self, self.isShown else { return }
                gtk_widget_grab_focus(self.root)
            }
        }
        let items = board.items()
        let sections = TasksViewSections.make(items)
        applyRevealRequest(board: board)
        let selected = board.tasksViewSelection(windowID: windowID, items: items)
        let visible = sections.visible(isDoneExpanded: isDoneExpanded, isArchivedExpanded: isArchivedExpanded)
        board.tasksViewListDidChange(windowID: windowID, visible: visible.map(\.id))

        let shortcut = board.newTaskShortcut
        Gtk.setVisible(newTaskButton, board.newTask != nil)
        Gtk.setLabel(newTaskShortcut, shortcut?.label ?? "")
        Gtk.setVisible(newTaskShortcut, shortcut != nil)

        let banners = Banners(
            webhooks: TaskWebhookBannerModel(ui.coordinator.webhooks),
            configError: board.configError
        )
        if banners != bannerModel {
            bannerModel = banners
            rebuildBanners(banners)
        }

        let model = Self.listItems(sections, selectedID: selected?.id, isDoneExpanded: isDoneExpanded, isArchivedExpanded: isArchivedExpanded)
        if model != listModel {
            listModel = model
            rebuildList()
        }
        let detail = selected.map { Detail(item: $0, error: detailError, ui: ui, setupChoice: setupSelection[$0.record?.id ?? UUID()]) }
        if detail != detailModel || hasDrawnDetail == false {
            hasDrawnDetail = true
            detailModel = detail
            rebuildDetail(selected)
        }
        if let target = scrollTarget {
            scrollTarget = nil
            MainLoop.idle { [weak self] in self?.scrollIntoView(target) }
        }
    }

    /// Opens the group the sidebar or a task link asked for, once.
    private func applyRevealRequest(board: TaskBoardStore) {
        guard let group = board.revealGroupByWindowID.removeValue(forKey: windowID) else { return }
        let revealsSelectedRow = board.revealsSelectedRowWindowIDs.remove(windowID) != nil
        switch group {
        case .done: isDoneExpanded = true
        case .archived: isArchivedExpanded = true
        case .needsYou, .running, .idle, .toShip: break
        }
        if revealsSelectedRow, let selected = board.tasksViewSelection(windowID: windowID), selected.stage.group == group {
            scrollTarget = selected.id
        } else {
            scrollTarget = nil
            MainLoop.idle { [weak self] in self?.scrollToGroup(group) }
        }
    }

    // MARK: - List model

    struct Row: Equatable {
        let subject: TaskBoardItem.Subject
        let title: String
        let isBold: Bool
        let mark: TaskStageMarkKind
        let releasesAfterMerge: Bool
        let project: String?
        let pullRequest: Int?
        let branch: String?
        let statusLine: String
        let age: String?
        let isChild: Bool
        let isContext: Bool
        let isSelected: Bool
        let taskSpaceWorkspaceID: UUID?
        let accessibleLabel: String
    }

    enum ListItem: Equatable {
        case header(title: String, id: String, count: Int, style: String, collapsible: Bool, isExpanded: Bool)
        case lane(title: String)
        case row(Row)
    }

    static func listItems(
        _ sections: TasksViewSections,
        selectedID: TaskBoardItem.Subject?,
        isDoneExpanded: Bool,
        isArchivedExpanded: Bool,
        now: Date = Date()
    ) -> [ListItem] {
        func rows(_ entries: [SidebarStatusSections.Entry]) -> [ListItem] {
            entries.map { .row(row($0, selectedID: selectedID, now: now)) }
        }
        func header(_ group: TaskStage.Group, count: Int, hot: Bool = false, collapsible: Bool = false, expanded: Bool = true) -> ListItem {
            .header(
                title: TaskBoardPresentation.groupTitle(group), id: "\(group)", count: count,
                style: hot ? "hot" : "", collapsible: collapsible, isExpanded: expanded
            )
        }
        var items: [ListItem] = [header(.needsYou, count: sections.needsYou.count, hot: sections.needsYou.isEmpty == false)]
        items += rows(sections.needsYou)
        if sections.readyToReview.isEmpty == false {
            items.append(.header(
                title: SidebarBucket.readyToReview.title, id: "readyToReview",
                count: sections.readyToReview.count, style: "review", collapsible: false, isExpanded: true
            ))
            items += rows(sections.readyToReview)
        }
        items.append(header(.running, count: sections.running.count))
        items += rows(sections.running)
        items.append(header(.idle, count: sections.idle.count))
        items += rows(sections.idle)
        items.append(header(.toShip, count: sections.toShip.reduce(0) { $0 + $1.entries.count }))
        for lane in sections.toShip {
            items.append(.lane(title: "\(lane.projectTitle) · \(lane.entries.count) \(lane.entries.count == 1 ? "task" : "tasks")"))
            items += rows(lane.entries)
        }
        items.append(header(.done, count: sections.done.count, collapsible: true, expanded: isDoneExpanded))
        if isDoneExpanded { items += rows(sections.done) }
        if sections.archived.isEmpty == false {
            items.append(header(.archived, count: sections.archived.count, collapsible: true, expanded: isArchivedExpanded))
            if isArchivedExpanded { items += rows(sections.archived) }
        }
        return items
    }

    static func row(_ entry: SidebarStatusSections.Entry, selectedID: TaskBoardItem.Subject?, now: Date) -> Row {
        let item = entry.item
        let statusLine = TaskBoardPresentation.tasksViewStatusLine(item, now: now)
        return Row(
            subject: entry.id,
            title: item.title,
            isBold: item.hasUnreadTurn,
            mark: TaskStageMarkKind(item),
            releasesAfterMerge: TaskBoardPresentation.releaseAfterMergeRequestedAt(item) != nil,
            project: item.projectTitle,
            pullRequest: item.pullRequest?.number,
            branch: item.branch,
            statusLine: statusLine,
            // A watched task space with no agent activity has no date.
            age: item.activityAt > .distantPast ? TaskAge.label(since: item.activityAt, now: now) : nil,
            isChild: entry.isLinkedChild,
            isContext: entry.isContext,
            isSelected: entry.id == selectedID,
            taskSpaceWorkspaceID: item.taskSpaceWorkspaceID,
            accessibleLabel: TaskBoardPresentation.addingReleaseAfterMerge(
                to: "\(item.title), \(item.hasUnreadTurn ? "unread, " : "")\(statusLine)", item
            )
        )
    }

    // MARK: - List widgets

    private func rebuildList() {
        Gtk.removeAllChildren(listBox)
        rowWidgets = [:]
        for item in listModel {
            switch item {
            case .header(let title, let id, let count, let style, let collapsible, let isExpanded):
                Gtk.append(listBox, makeHeader(title: title, id: id, count: count, style: style, collapsible: collapsible, isExpanded: isExpanded))
            case .lane(let title):
                Gtk.append(listBox, Gtk.label(title, classes: ["tasks-lane"]))
            case .row(let row):
                let widget = makeRow(row)
                rowWidgets[row.subject] = widget
                Gtk.append(listBox, widget)
            }
        }
    }

    private func makeHeader(title: String, id: String, count: Int, style: String, collapsible: Bool, isExpanded: Bool) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 8, classes: ["tasks-group"])
        if style.isEmpty == false { Gtk.addClasses(line, [style]) }
        Gtk.setName(line, "tasks.view.group.\(id)")
        if collapsible {
            Gtk.append(line, Gtk.image(isExpanded ? "pan-down-symbolic" : "pan-end-symbolic", pixelSize: 10))
        }
        Gtk.append(line, Gtk.label(title.uppercased(), classes: ["tasks-group-title"], ellipsize: false))
        Gtk.append(line, Gtk.label("\(count)", classes: ["tasks-group-count"], ellipsize: false))
        guard collapsible else { return line }
        let button = gtk_button_new()!
        Gtk.addClasses(button, ["flat", "tasks-group-toggle"])
        gtk_button_set_child(cast(button), line)
        gtk_widget_set_tooltip_text(button, "\(title), \(count), \(isExpanded ? "expanded" : "collapsed")")
        Gtk.setName(button, "tasks.view.toggle.\(id)")
        Signal.connect(button, "clicked") { [weak self] in
            guard let self else { return }
            if id == "\(TaskStage.Group.done)" { self.isDoneExpanded.toggle() } else { self.isArchivedExpanded.toggle() }
            self.ui.scheduleRender()
        }
        return button
    }

    private func makeRow(_ row: Row) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 10, classes: ["tasks-row"])
        Gtk.setClass(line, "selected", row.isSelected)
        Gtk.setClass(line, "child", row.isChild)
        Gtk.setClass(line, "context", row.isContext)
        Gtk.setName(line, "tasks.view.row.\(Self.rowName(row.subject))")
        gtk_widget_set_tooltip_text(line, row.accessibleLabel)
        if row.isChild {
            Gtk.append(line, Gtk.label("↳", classes: ["tasks-child-arrow"], ellipsize: false))
        }
        Gtk.append(line, TaskMarkWidget.make(row.mark))

        let text = Gtk.vbox(spacing: 3)
        gtk_widget_set_hexpand(text, 1)
        let titleLine = Gtk.hbox(spacing: 6)
        let title = Gtk.label(row.title, classes: row.isBold ? ["tasks-row-title", "unread"] : ["tasks-row-title"])
        Gtk.append(titleLine, title)
        if row.releasesAfterMerge {
            let bolt = Gtk.label("⚡", classes: ["task-release-mark"], ellipsize: false)
            gtk_widget_set_tooltip_text(bolt, "Release right after merge")
            Gtk.append(titleLine, bolt)
        }
        Gtk.append(text, titleLine)
        let detailLine = Gtk.hbox(spacing: 8)
        if let project = row.project {
            Gtk.append(detailLine, Gtk.label(project, classes: ["task-tag"], ellipsize: false))
        }
        if let number = row.pullRequest {
            Gtk.append(detailLine, Gtk.label("PR #\(number)", classes: ["task-pr-tag"], ellipsize: false))
        } else if let branch = row.branch {
            Gtk.append(detailLine, Gtk.label(branch, classes: ["task-branch"]))
        }
        let status = Gtk.label(row.statusLine, classes: ["tasks-row-status"])
        gtk_widget_set_hexpand(status, 1)
        Gtk.append(detailLine, status)
        Gtk.append(text, detailLine)
        Gtk.append(line, text)
        if let age = row.age {
            let label = Gtk.label(age, classes: ["tasks-row-age"], ellipsize: false)
            gtk_widget_set_valign(label, GTK_ALIGN_START)
            Gtk.append(line, label)
        }

        let subject = row.subject
        let workspaceID = row.taskSpaceWorkspaceID
        // The first click selects; the second click of a double click also
        // opens the task space.
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), guint(GDK_BUTTON_PRIMARY))
        Signal.connectPress(click) { [weak self] count, _, _ in
            guard let self else { return }
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            self.select(subject)
            if count == 2, let workspaceID {
                self.ui.openTaskSpace(workspaceID, windowID: self.windowID)
            }
        }
        gtk_widget_add_controller(line, cast(click))
        let secondary = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(secondary), guint(GDK_BUTTON_SECONDARY))
        Signal.connectPress(secondary) { [weak self] _, x, y in
            self?.showContextMenu(subject: subject, from: line, x: x, y: y)
        }
        gtk_widget_add_controller(line, cast(secondary))
        return line
    }

    static func rowName(_ subject: TaskBoardItem.Subject) -> String {
        switch subject {
        case .task(let id): "task-\(id.uuidString)"
        case .taskSpace(let id): "space-\(id.uuidString)"
        }
    }

    private func select(_ subject: TaskBoardItem.Subject) {
        guard ui.board.selectionByWindowID[windowID] != subject else { return }
        detailError = nil
        ui.board.selectionByWindowID[windowID] = subject
    }

    private func scrollIntoView(_ subject: TaskBoardItem.Subject) {
        guard let row = rowWidgets[subject] else { return }
        scroll(to: row)
    }

    private func scrollToGroup(_ group: TaskStage.Group) {
        guard let header = Gtk.find(named: "tasks.view.toggle.\(group)", in: listBox)
                ?? Gtk.find(named: "tasks.view.group.\(group)", in: listBox) else { return }
        scroll(to: header, toTop: true)
    }

    private func scroll(to widget: WidgetPtr, toTop: Bool = false) {
        var source = graphene_point_t(x: 0, y: 0)
        var target = graphene_point_t(x: 0, y: 0)
        guard gtk_widget_compute_point(widget, listBox, &source, &target).bool,
              let adjustment = gtk_scrolled_window_get_vadjustment(cast(listScroller)) else { return }
        let top = Double(target.y)
        let height = Double(gtk_widget_get_height(widget))
        let value = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        if toTop || top < value {
            gtk_adjustment_set_value(adjustment, top)
        } else if top + height > value + page {
            gtk_adjustment_set_value(adjustment, top + height - page)
        }
    }

    // MARK: - Keys

    private func installKeys() {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, modifiers in
            guard let self, self.isShown else { return false }
            let plain = modifiers.rawValue & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_SUPER_MASK.rawValue) == 0
            switch Int32(keyval) {
            case GDK_KEY_Escape:
                // An open menu or entry handles its own Esc.
                if gtk_widget_get_visible(self.contextMenu).bool { return false }
                self.close()
                return true
            case GDK_KEY_Down where plain:
                self.moveSelection(by: 1)
                return true
            case GDK_KEY_Up where plain:
                self.moveSelection(by: -1)
                return true
            default:
                return false
            }
        }
        gtk_widget_add_controller(root, keys)
    }

    func moveSelection(by offset: Int) {
        let items = ui.board.items()
        let sections = TasksViewSections.make(items)
        let visible = sections.visible(isDoneExpanded: isDoneExpanded, isArchivedExpanded: isArchivedExpanded).map(\.id)
        let selected = ui.board.tasksViewSelection(windowID: windowID, items: items)?.id
        guard let next = TasksViewSections.selection(movingFrom: selected, by: offset, in: visible) else { return }
        scrollTarget = next
        select(next)
    }

    // MARK: - Context menu

    private func installMenuActions() {
        let group = g_simple_action_group_new()!
        let stringType = g_variant_type_new("s")
        defer { g_variant_type_free(stringType) }
        let action = g_simple_action_new("run", stringType)!
        Signal.connectPointer(action, "activate") { [weak self] parameter in
            guard let self, let value = variantStringValue(parameter.map(OpaquePointer.init)), let index = Int(value),
                  self.menuEntries.indices.contains(index) else { return }
            let entry = self.menuEntries[index]
            TaskActions.runFromMenu(entry.menuItem, coordinator: self.ui.coordinator) { [weak self] workspaceID in
                guard let self else { return }
                self.ui.openTaskSpace(workspaceID, windowID: self.windowID)
            }
        }
        g_action_map_add_action(cast(group), cast(action))
        g_object_unref(UnsafeMutableRawPointer(action))
        gtk_widget_insert_action_group(root, "tasks", cast(group))
        g_object_unref(UnsafeMutableRawPointer(group))
    }

    /// The task's menu (macOS `TaskContextMenuItems`), one section per group.
    func contextMenuModel(for item: TaskBoardItem) -> OpaquePointer {
        menuEntries = []
        let menu = g_menu_new()!
        for section in TaskBoardPresentation.menuItems(item, isTriageConfigured: ui.coordinator.isTriageConfigured) {
            let part = g_menu_new()!
            for menuItem in section {
                let index = menuEntries.count
                menuEntries.append((item, menuItem))
                g_menu_append(part, menuItem.title, "tasks.run::\(index)")
            }
            g_menu_append_section(menu, nil, cast(part))
            g_object_unref(UnsafeMutableRawPointer(part))
        }
        return menu
    }

    private func showContextMenu(subject: TaskBoardItem.Subject, from row: WidgetPtr, x: Double, y: Double) {
        guard let item = ui.board.items().first(where: { $0.id == subject }) else { return }
        let model = contextMenuModel(for: item)
        gtk_popover_menu_set_menu_model(cast(contextMenu), cast(model))
        g_object_unref(UnsafeMutableRawPointer(model))
        var source = graphene_point_t(x: Float(x), y: Float(y))
        var target = graphene_point_t(x: 0, y: 0)
        guard gtk_widget_compute_point(row, root, &source, &target).bool else { return }
        var rect = GdkRectangle(x: Int32(target.x), y: Int32(target.y), width: 1, height: 1)
        gtk_popover_set_pointing_to(cast(contextMenu), &rect)
        gtk_popover_popup(cast(contextMenu))
    }

    // MARK: - Banners

    struct Banners: Equatable {
        var webhooks: TaskWebhookBannerModel?
        var configError: String?
    }

    private func rebuildBanners(_ banners: Banners) {
        Gtk.removeAllChildren(bannerBox)
        if let webhooks = banners.webhooks {
            let banner = Gtk.hbox(spacing: 10, classes: ["tasks-banner", "webhook"])
            Gtk.setName(banner, "tasks.view.webhooks")
            let text = Gtk.label(webhooks.message, classes: ["tasks-banner-text"])
            gtk_label_set_wrap(cast(text), 1)
            gtk_widget_set_hexpand(text, 1)
            Gtk.append(banner, text)
            let review = Gtk.button(webhooks.buttonTitle, classes: ["tasks-banner-button"])
            Gtk.setName(review, "tasks.view.webhooks.review")
            Signal.connect(review, "clicked") { [weak self] in
                guard let self, let service = self.ui.coordinator.webhooks else { return }
                TaskWebhookApprovalDialog.present(service: service, over: self.root)
            }
            Gtk.append(banner, review)
            Gtk.append(bannerBox, banner)
        }
        if let message = banners.configError {
            let banner = Gtk.label(message, classes: ["tasks-banner", "config-error"])
            gtk_label_set_wrap(cast(banner), 1)
            Gtk.setName(banner, "tasks.view.configError")
            Gtk.append(bannerBox, banner)
        }
        Gtk.setVisible(bannerBox, Gtk.children(bannerBox).isEmpty == false)
    }

    // MARK: - Detail

    /// What the detail pane shows; rebuilt when it changes.
    struct Detail: Equatable {
        var subject: TaskBoardItem.Subject
        var origin: String
        var title: String
        var isSetup: Bool
        var setupRecord: TaskRecord?
        var setupChoice: TaskWorkspaceChoice?
        var setupChoices: TaskWorkspaceChoices?
        var isTriageConfigured: Bool
        var text: String?
        var status: [KeyValue]
        var source: TaskExternalRef?
        var history: [String]
        var actions: [[TaskBoardPresentation.MenuItem]]
        var error: String?

        struct KeyValue: Equatable {
            var key: String
            var value: String
            var why: String?
            var monospaced = false
        }

        @MainActor
        init(item: TaskBoardItem, error: String?, ui: TasksUI, setupChoice: TaskWorkspaceChoice?, now: Date = Date()) {
            subject = item.id
            origin = TaskBoardPresentation.originLine(item, now: now)
            title = item.title
            self.error = error
            isTriageConfigured = ui.coordinator.isTriageConfigured
            if let record = item.record, item.stage.isBeforeStart {
                isSetup = true
                setupRecord = record
                setupChoices = TaskSetupCardPresentation.isPickingWorkspace(record)
                    ? ui.coordinator.workspaceChoices(taskID: record.id) : nil
                self.setupChoice = setupChoice
                text = nil
                status = []
                source = nil
                history = []
                actions = []
                return
            }
            isSetup = false
            setupRecord = nil
            setupChoices = nil
            self.setupChoice = nil
            let recordText = item.record?.text
            text = recordText.flatMap { $0.isEmpty || $0 == item.title ? nil : $0 }
            let stage = TaskBoardPresentation.stageDescription(item, now: now)
            var status = [KeyValue(key: "Stage", value: stage.stage, why: stage.why)]
            if let pullRequest = TaskBoardPresentation.pullRequestLine(item) {
                status.append(KeyValue(key: "PR", value: pullRequest))
            }
            if let branch = item.branch {
                status.append(KeyValue(key: "Branch", value: branch, monospaced: true))
            }
            if let agent = item.record?.resolved?.agent {
                status.append(KeyValue(key: "Agent", value: [agent, item.record?.resolved?.model].compactMap { $0 }.joined(separator: " · ")))
            }
            if let requestedAt = TaskBoardPresentation.releaseAfterMergeRequestedAt(item) {
                let age = TaskAge.label(since: requestedAt, now: now)
                status.append(KeyValue(key: "Release", value: "Right after merge", why: age == "now" ? "asked just now" : "asked \(age) ago"))
            }
            self.status = status
            source = item.record?.externalRef
            history = TaskBoardPresentation.history(item)
            actions = TaskBoardPresentation.menuItems(item)
        }
    }

    private func rebuildDetail(_ item: TaskBoardItem?) {
        Gtk.removeAllChildren(detailBox)
        guard let detail = detailModel, let item else {
            let empty = Gtk.vbox(spacing: 6, classes: ["tasks-empty"])
            gtk_widget_set_valign(empty, GTK_ALIGN_CENTER)
            gtk_widget_set_vexpand(empty, 1)
            Gtk.append(empty, Gtk.label("No tasks yet.", xalign: 0.5))
            if ui.board.newTask != nil, let hint = Self.emptyStateShortcutHint(ui.board.newTaskShortcut) {
                let label = Gtk.label(hint, classes: ["dim-label"], xalign: 0.5)
                Gtk.setName(label, "tasks.view.empty.shortcut")
                Gtk.append(empty, label)
            }
            Gtk.append(detailBox, empty)
            return
        }
        Gtk.append(detailBox, Gtk.label(detail.origin, classes: ["tasks-detail-origin"]))
        let title = Gtk.label(detail.title, classes: ["tasks-detail-title"], ellipsize: false)
        gtk_label_set_wrap(cast(title), 1)
        gtk_label_set_selectable(cast(title), 1)
        Gtk.append(detailBox, title)

        if detail.isSetup, let record = detail.setupRecord {
            Gtk.append(detailBox, makeSetupCard(record, detail: detail))
        } else {
            if let text = detail.text {
                let label = Gtk.label(text, classes: ["tasks-detail-text"], ellipsize: false)
                gtk_label_set_wrap(cast(label), 1)
                gtk_label_set_lines(cast(label), 14)
                gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
                gtk_label_set_selectable(cast(label), 1)
                Gtk.append(detailBox, label)
            }
            let status = makeCard("Status")
            for row in detail.status {
                Gtk.append(status.body, keyValue(row))
            }
            if let source = detail.source {
                Gtk.append(status.body, sourceRow(source))
            }
            Gtk.append(detailBox, status.card)
            if detail.history.isEmpty == false {
                let history = makeCard("History")
                for line in detail.history {
                    let label = Gtk.label(line, classes: ["tasks-history-line"], ellipsize: false)
                    gtk_label_set_wrap(cast(label), 1)
                    Gtk.append(history.body, label)
                }
                Gtk.append(detailBox, history.card)
            }
            let actions = Gtk.vbox(spacing: 8)
            for section in detail.actions {
                let line = gtk_flow_box_new()!
                gtk_flow_box_set_selection_mode(cast(line), GTK_SELECTION_NONE)
                gtk_flow_box_set_column_spacing(cast(line), 8)
                gtk_flow_box_set_row_spacing(cast(line), 8)
                gtk_flow_box_set_max_children_per_line(cast(line), 4)
                for menuItem in section {
                    gtk_flow_box_append(cast(line), actionButton(menuItem, item: item))
                }
                Gtk.append(actions, line)
            }
            Gtk.append(detailBox, actions)
        }
        if let error = detail.error {
            let label = Gtk.label(error, classes: ["tasks-detail-error"], ellipsize: false)
            gtk_label_set_wrap(cast(label), 1)
            Gtk.setName(label, "tasks.view.detail.error")
            Gtk.append(detailBox, label)
        }
    }

    static func emptyStateShortcutHint(_ shortcut: NewTaskShortcutHint?) -> String? {
        guard let shortcut else { return nil }
        return shortcut.isGlobal
            ? "Press \(shortcut.label) in any app to add a task."
            : "Press \(shortcut.label) to add a task."
    }

    private func makeCard(_ title: String) -> (card: WidgetPtr, body: WidgetPtr) {
        let card = Gtk.vbox(classes: ["tasks-card"])
        Gtk.append(card, Gtk.label(title.uppercased(), classes: ["tasks-card-title"]))
        Gtk.append(card, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        let body = Gtk.vbox(spacing: 7, classes: ["tasks-card-body"])
        Gtk.append(card, body)
        return (card, body)
    }

    private func keyValue(_ row: Detail.KeyValue) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 10)
        let key = Gtk.label(row.key, classes: ["tasks-key"])
        gtk_widget_set_size_request(key, 60, -1)
        gtk_widget_set_valign(key, GTK_ALIGN_START)
        Gtk.append(line, key)
        let values = Gtk.vbox(spacing: 2)
        gtk_widget_set_hexpand(values, 1)
        let value = Gtk.label(row.value, classes: row.monospaced ? ["tasks-value", "monospace"] : ["tasks-value"])
        gtk_label_set_ellipsize(cast(value), PANGO_ELLIPSIZE_MIDDLE)
        gtk_label_set_selectable(cast(value), 1)
        Gtk.append(values, value)
        if let why = row.why {
            let label = Gtk.label(why, classes: ["tasks-why"], ellipsize: false)
            gtk_label_set_wrap(cast(label), 1)
            Gtk.append(values, label)
        }
        Gtk.append(line, values)
        return line
    }

    /// The issue or report the task came from; its page opens in the
    /// browser.
    private func sourceRow(_ source: TaskExternalRef) -> WidgetPtr {
        guard let url = source.url.flatMap(URL.init(string:)) else {
            return keyValue(Detail.KeyValue(key: "Source", value: source.id, monospaced: true))
        }
        let line = Gtk.hbox(spacing: 10)
        let key = Gtk.label("Source", classes: ["tasks-key"])
        gtk_widget_set_size_request(key, 60, -1)
        Gtk.append(line, key)
        let link = gtk_link_button_new_with_label(url.absoluteString, source.id)!
        Gtk.addClasses(link, ["tasks-source-link"])
        Gtk.setName(link, "tasks.view.detail.source")
        Gtk.append(line, link)
        return line
    }

    private func actionButton(_ menuItem: TaskBoardPresentation.MenuItem, item: TaskBoardItem) -> WidgetPtr {
        let isPrimary: Bool
        let help: String?
        let identifier: String
        switch menuItem {
        case .openTaskSpace:
            (isPrimary, help, identifier) = (true, nil, "tasks.view.detail.open")
        case .trackAsTask:
            (isPrimary, help, identifier) = (false, "Give this task space a task record, so its history stays after it closes.", "tasks.view.detail.adopt")
        case .action(let action, _, _):
            (isPrimary, help, identifier) = (action.isPrimary, action.help, "tasks.view.detail.\(action)")
        case .openPullRequest:
            (isPrimary, help, identifier) = (false, nil, "tasks.view.detail.openPullRequest")
        case .delete:
            (isPrimary, help, identifier) = (false, nil, "tasks.view.detail.delete")
        case .retry, .retryTriage:
            (isPrimary, help, identifier) = (false, nil, "tasks.view.detail.retry")
        }
        var classes = ["tasks-action"]
        if isPrimary { classes.append("suggested-action") }
        if menuItem.isDestructive { classes.append("destructive-action") }
        let button = Gtk.button(menuItem.title, classes: classes)
        if let help { gtk_widget_set_tooltip_text(button, help) }
        Gtk.setName(button, identifier)
        Signal.connect(button, "clicked") { [weak self] in
            guard let self else { return }
            self.perform {
                try TaskActions.run(menuItem, coordinator: self.ui.coordinator) { [weak self] workspaceID in
                    guard let self else { return }
                    self.ui.openTaskSpace(workspaceID, windowID: self.windowID)
                }
            }
        }
        return button
    }

    // MARK: - Automation

    var automationListModel: [ListItem] { listModel }
    var automationDetailTitle: String? { detailModel?.title }
    var automationDetailError: String? { detailModel?.error }
    var automationBanner: String? { bannerModel?.webhooks?.message ?? bannerModel?.configError }

    /// A click on a row, as the row's gesture handles it.
    func automationClick(_ subject: TaskBoardItem.Subject, count: Int) {
        select(subject)
        if count == 2, let workspaceID = ui.board.items().first(where: { $0.id == subject })?.taskSpaceWorkspaceID {
            ui.openTaskSpace(workspaceID, windowID: windowID)
        }
    }

    /// Runs a row's context menu item by its title.
    func automationRunMenuItem(_ subject: TaskBoardItem.Subject, title: String) -> Bool {
        guard let item = ui.board.items().first(where: { $0.id == subject }) else { return false }
        let model = contextMenuModel(for: item)
        g_object_unref(UnsafeMutableRawPointer(model))
        guard let entry = menuEntries.first(where: { $0.menuItem.title == title }) else { return false }
        TaskActions.runFromMenu(entry.menuItem, coordinator: ui.coordinator) { [weak self] workspaceID in
            guard let self else { return }
            self.ui.openTaskSpace(workspaceID, windowID: self.windowID)
        }
        return true
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            detailError = nil
        } catch {
            detailError = error.localizedDescription
        }
        ui.scheduleRender()
    }

    // MARK: - Setup card

    /// macOS `TaskSetupCard`: the task as written, why it waits, the
    /// workspace field while it waits for one, and Start, Retry and Delete.
    private func makeSetupCard(_ record: TaskRecord, detail: Detail) -> WidgetPtr {
        let card = Gtk.vbox(spacing: 12, classes: ["task-setup"])
        Gtk.setName(card, "task.setup")
        let text = record.text.isEmpty ? (record.pinned.prompt ?? "") : record.text
        if text.isEmpty == false, text != record.title {
            let label = Gtk.label(text, classes: ["task-setup-text"], ellipsize: false)
            gtk_label_set_wrap(cast(label), 1)
            gtk_label_set_selectable(cast(label), 1)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_max_content_height(cast(scroller), 240)
            gtk_scrolled_window_set_propagate_natural_height(cast(scroller), 1)
            gtk_scrolled_window_set_child(cast(scroller), label)
            Gtk.append(card, scroller)
        }
        if record.attachments.isEmpty == false {
            let files = gtk_flow_box_new()!
            gtk_flow_box_set_selection_mode(cast(files), GTK_SELECTION_NONE)
            for attachment in record.attachments {
                gtk_flow_box_append(cast(files), AttachmentChipWidget.make(path: attachment.path, name: attachment.displayName, onRemove: nil))
            }
            Gtk.append(card, files)
        }
        for note in TaskSetupCardPresentation.notes(record) {
            let label = Gtk.label(note.text, classes: note.isProblem ? ["task-setup-note", "problem"] : ["task-setup-note"], ellipsize: false)
            gtk_label_set_wrap(cast(label), 1)
            gtk_label_set_selectable(cast(label), 1)
            Gtk.append(card, label)
        }
        let isPicking = TaskSetupCardPresentation.isPickingWorkspace(record)
        let choices = detail.setupChoices ?? TaskWorkspaceChoices(open: [], recent: [])
        var chosen: TaskWorkspaceChoice? = detail.setupChoice.flatMap {
            TaskSetupCardPresentation.isAvailable($0, in: choices) ? $0 : nil
        } ?? choices.suggested?.choice
        if isPicking {
            Gtk.append(card, makeWorkspaceField(record: record, choices: choices, chosen: chosen))
        }

        let buttons = Gtk.hbox(spacing: 8)
        if TaskSetupPresentation.canRetry(record) {
            let retry = Gtk.button(record.setup.isStarted ? "Retry Move" : "Retry Setup", classes: ["suggested-action"])
            Gtk.setName(retry, "task.setup.retry")
            Signal.connect(retry, "clicked") { [weak self] in
                self?.perform { try self?.ui.coordinator.retry(taskID: record.id) }
            }
            Gtk.append(buttons, retry)
        } else if isPicking {
            if chosen.map({ TaskSetupCardPresentation.isAvailable($0, in: choices) }) != true { chosen = nil }
            let start = Gtk.button(TaskSetupCardPresentation.startTitle(for: chosen, choices: choices), classes: ["suggested-action"])
            gtk_widget_set_sensitive(start, (chosen != nil).gboolean)
            Gtk.setName(start, "task.setup.start")
            let choice = chosen
            Signal.connect(start, "clicked") { [weak self] in
                guard let choice else { return }
                self?.perform { try self?.ui.coordinator.setWorkspace(taskID: record.id, choice: choice) }
            }
            Gtk.append(buttons, start)
        }
        if isPicking, detail.isTriageConfigured {
            let triage = Gtk.button("Retry Triage")
            Gtk.setName(triage, "task.setup.retryTriage")
            Signal.connect(triage, "clicked") { [weak self] in
                self?.perform { try self?.ui.coordinator.retry(taskID: record.id) }
            }
            Gtk.append(buttons, triage)
        }
        let delete = Gtk.button("Delete", classes: ["destructive-action"])
        Gtk.setName(delete, "task.setup.delete")
        Signal.connect(delete, "clicked") { [weak self] in
            self?.perform { try self?.ui.coordinator.delete(taskID: record.id) }
        }
        Gtk.append(buttons, delete)
        Gtk.append(card, buttons)
        return card
    }

    /// The workspace picker: Suggested, Open and Recently closed.
    private func makeWorkspaceField(record: TaskRecord, choices: TaskWorkspaceChoices, chosen: TaskWorkspaceChoice?) -> WidgetPtr {
        let field = Gtk.vbox(spacing: 6, classes: ["task-setup-workspace"])
        Gtk.append(field, Gtk.label("WORKSPACE", classes: ["tasks-card-title"]))
        var options: [(choice: TaskWorkspaceChoice, title: String)] = []
        if let suggested = choices.suggested {
            options.append((suggested.choice, "\(choices.title(of: suggested.choice) ?? "Suggested") — Suggested"))
        }
        for workspace in choices.open where .open(workspace.id) != choices.suggested?.choice {
            options.append((.open(workspace.id), workspace.title))
        }
        for workspace in choices.recent where .recent(workspace.id) != choices.suggested?.choice {
            options.append((.recent(workspace.id), "\(workspace.title) — Recently closed"))
        }
        let titles = options.map(\.title)
        let list = titles.withCStrings { gtk_string_list_new($0) }!
        let dropdown = gtk_drop_down_new(cast(list), nil)!
        Gtk.setName(dropdown, "task.setup.workspace")
        if let chosen, let index = options.firstIndex(where: { $0.choice == chosen }) {
            gtk_drop_down_set_selected(cast(dropdown), guint(index))
        } else {
            gtk_drop_down_set_selected(cast(dropdown), guint(GTK_INVALID_LIST_POSITION))
        }
        Signal.notify(dropdown, "selected") { [weak self] in
            guard let self else { return }
            let index = Int(gtk_drop_down_get_selected(cast(dropdown)))
            guard options.indices.contains(index) else { return }
            self.setupSelection[record.id] = options[index].choice
            self.ui.scheduleRender()
        }
        Gtk.append(field, dropdown)
        if let hint = TaskSetupCardPresentation.hint(for: chosen, choices: choices) {
            Gtk.append(field, Gtk.label(hint, classes: ["tasks-why"], ellipsize: false))
        }
        if let chosen, let root = TaskSetupCardPresentation.rootDirectory(of: chosen, in: choices) {
            Gtk.append(field, Gtk.label(TaskSetupCardPresentation.abbreviated(root), classes: ["tasks-value", "monospace"]))
        }
        return field
    }
}

extension Array where Element == String {
    /// A NULL-terminated C string array for the duration of `body`.
    func withCStrings<Result>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> Result) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count, body)
        }
    }
}
#endif
