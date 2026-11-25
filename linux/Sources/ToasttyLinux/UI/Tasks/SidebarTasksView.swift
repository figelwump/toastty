#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The sidebar while tasks are on (macOS `SidebarTasksHeader`,
/// `SidebarCoordinatorRow` and the bucketed cards of `SidebarView`):
///
/// - the Coordinator row, in the window that holds the coordinator: a click
///   shows or hides the dock, its menu opens the full view, the documents,
///   Restart and Close;
/// - the Tasks row: opens the Tasks view, a webhook pill, ＋ for a new task;
/// - the All | Needs you switcher, with the Needs you and Ready to review
///   counts;
/// - one card per project with its rows in buckets, an Other tasks card,
///   and each card's To ship and Done lines.
@MainActor
final class SidebarTasksView {
    let header: WidgetPtr
    let content: WidgetPtr
    private let ui: TasksUI
    private let windowID: UUID
    private weak var controller: LinuxWindowController?
    private let coordinatorRow: WidgetPtr
    private let coordinatorStatus: WidgetPtr
    private let webhookPill: WidgetPtr
    private let allToggle: WidgetPtr
    private let needsYouToggle: WidgetPtr
    private let needsYouCount: WidgetPtr
    private let reviewCount: WidgetPtr
    private let cards: WidgetPtr
    /// Each card's title click, by card index, for automation.
    private var cardTitleActions: [Int: @MainActor () -> Void] = [:]
    private var cardIndexByWorkspaceID: [UUID: Int] = [:]
    private let menu: WidgetPtr
    private var menuRef: GObjectRef?
    private var model: SidebarTasksModel?
    private var memory = SidebarTasksModel.Memory()
    private var expandedToShip: Set<UUID> = []
    private var expandedDone: Set<UUID> = []
    private var expandedFolds: Set<SidebarRowKey> = []
    private var menuEntries: [(item: TaskBoardItem, menuItem: TaskBoardPresentation.MenuItem)] = []
    private var isSyncing = false

    init(ui: TasksUI, controller: LinuxWindowController) {
        self.ui = ui
        self.controller = controller
        windowID = controller.windowID

        header = Gtk.vbox(spacing: 2, classes: ["sidebar-tasks-header"])
        // The coordinator's row.
        coordinatorRow = Gtk.hbox(spacing: 8, classes: ["sidebar-coordinator"])
        Gtk.setName(coordinatorRow, "sidebar.coordinator")
        Gtk.append(coordinatorRow, Gtk.image(LinuxAppController.applicationID, pixelSize: 18))
        let coordinatorTitle = Gtk.label(AppState.coordinatorWorkspaceTitle, classes: ["sidebar-coordinator-title"])
        gtk_widget_set_hexpand(coordinatorTitle, 1)
        Gtk.append(coordinatorRow, coordinatorTitle)
        coordinatorStatus = Gtk.label("", classes: ["sidebar-coordinator-status"], ellipsize: false)
        Gtk.append(coordinatorRow, coordinatorStatus)
        Gtk.setVisible(coordinatorRow, false)
        Gtk.append(header, coordinatorRow)

        // The Tasks row.
        let tasksRow = Gtk.hbox(spacing: 8, classes: ["sidebar-tasks-row"])
        // Independent targets: the row's activation must not claim the
        // pointer sequence of New Task or the webhook button.
        let openTasks = gtk_button_new()!
        Gtk.setName(openTasks, "sidebar.tasks")
        Gtk.addClasses(openTasks, ["flat", "sidebar-tasks-open"])
        gtk_widget_set_hexpand(openTasks, 1)
        let openLabel = Gtk.hbox(spacing: 8)
        Gtk.append(openLabel, Gtk.image("view-list-bullet-symbolic", pixelSize: 16))
        Gtk.append(openLabel, Gtk.label("Tasks", classes: ["sidebar-tasks-title"]))
        gtk_button_set_child(cast(openTasks), openLabel)
        Gtk.append(tasksRow, openTasks)
        webhookPill = Gtk.button("", classes: ["flat", "sidebar-webhook-pill"])
        gtk_widget_set_tooltip_text(webhookPill, "A webhook needs you in the Tasks view")
        Gtk.setName(webhookPill, "sidebar.tasks.webhooks")
        Gtk.setVisible(webhookPill, false)
        Gtk.append(tasksRow, webhookPill)
        let newTask = Gtk.iconButton("list-add-symbolic", tooltip: "New Task", classes: ["flat", "circular"])
        Gtk.setName(newTask, "sidebar.tasks.new")
        Gtk.append(tasksRow, newTask)
        Gtk.append(header, tasksRow)

        // All | Needs you.
        let segment = Gtk.hbox(spacing: 0, classes: ["linked", "sidebar-segment"])
        allToggle = gtk_toggle_button_new_with_label("All")!
        Gtk.setName(allToggle, "sidebar.segment.all")
        needsYouToggle = gtk_toggle_button_new()!
        Gtk.setName(needsYouToggle, "sidebar.segment.needsYou")
        let needsYouContent = Gtk.hbox(spacing: 5)
        gtk_widget_set_halign(needsYouContent, GTK_ALIGN_CENTER)
        Gtk.append(needsYouContent, Gtk.label("Needs you", ellipsize: false))
        needsYouCount = Gtk.label("", classes: ["sidebar-count", "needs-you"], ellipsize: false)
        reviewCount = Gtk.label("", classes: ["sidebar-count", "review"], ellipsize: false)
        Gtk.append(needsYouContent, needsYouCount)
        Gtk.append(needsYouContent, reviewCount)
        gtk_button_set_child(cast(needsYouToggle), needsYouContent)
        gtk_toggle_button_set_group(cast(needsYouToggle), cast(allToggle))
        for toggle in [allToggle, needsYouToggle] {
            gtk_widget_set_hexpand(toggle, 1)
            Gtk.append(segment, toggle)
        }
        Gtk.append(header, segment)

        cards = Gtk.vbox(spacing: 6, classes: ["sidebar-task-cards"])
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), cards)
        Gtk.expand(scroller)
        content = gtk_overlay_new()!
        gtk_overlay_set_child(cast(content), scroller)

        menu = gtk_popover_menu_new_from_model(nil)
        gtk_popover_set_has_arrow(cast(menu), 0)
        gtk_widget_set_halign(menu, GTK_ALIGN_START)
        menuRef = GObjectRef(sinking: menu)
        // Card rebuilds remove every child of `cards`. Keep the shared
        // popover beside the scroller so it stays rooted across rebuilds.
        gtk_overlay_add_overlay(cast(content), menu)

        click(coordinatorRow) { [weak self] in self?.coordinatorClicked() }
        contextClick(coordinatorRow) { [weak self] x, y in self?.showCoordinatorMenu(x: x, y: y) }
        Signal.connect(openTasks, "clicked") { [weak self] in self?.openTasksView(selecting: nil) }
        Signal.connect(newTask, "clicked") { [weak self] in self?.ui.board.newTask?() }
        Signal.connect(webhookPill, "clicked") { [weak self] in self?.openTasksView(selecting: nil) }
        Signal.connect(allToggle, "toggled") { [weak self] in self?.segmentToggled() }
        Signal.connect(needsYouToggle, "toggled") { [weak self] in self?.segmentToggled() }
        installActions()
    }

    func teardown() {
        if gtk_widget_get_parent(menu) != nil {
            gtk_overlay_remove_overlay(cast(content), menu)
        }
    }

    // MARK: - Render

    func render(_ state: AppState, sessions: any LinuxSessionSource) {
        let next = SidebarTasksModel.make(
            ui: ui, state: state, windowID: windowID, sessions: sessions,
            memory: &memory, expandedToShip: expandedToShip,
            expandedDone: expandedDone, expandedFolds: expandedFolds
        )
        renderCoordinatorRow(state)
        guard let next else { return }
        isSyncing = true
        gtk_toggle_button_set_active(cast(allToggle), (next.segment == .all).gboolean)
        gtk_toggle_button_set_active(cast(needsYouToggle), (next.segment == .needsYou).gboolean)
        isSyncing = false
        Gtk.setLabel(needsYouCount, "\(next.needsYouCount)")
        Gtk.setVisible(needsYouCount, next.needsYouCount > 0)
        Gtk.setLabel(reviewCount, "\(next.readyToReviewCount)")
        Gtk.setVisible(reviewCount, next.readyToReviewCount > 0)
        gtk_button_set_label(cast(webhookPill), TaskWebhookApprovalPresentation.pillTitle(count: next.webhookCount))
        Gtk.setVisible(webhookPill, next.webhookCount > 0)
        guard next != model else { return }
        model = next
        rebuild(next)
    }

    private func renderCoordinatorRow(_ state: AppState) {
        guard let coordinator = ui.tasks.coordinatorController, let location = coordinator.location,
              location.windowID == windowID, let workspace = state.workspacesByID[location.workspaceID] else {
            Gtk.setVisible(coordinatorRow, false)
            return
        }
        Gtk.setVisible(coordinatorRow, true)
        let selected = state.window(id: windowID)?.selectedWorkspaceID == location.workspaceID
        let dockShows = coordinator.dockShows(in: windowID)
        let readPanelID = selected || dockShows ? location.panelID : nil
        let mark = SidebarCoordinatorPresentation.currentMark(
            controller: coordinator, sessionRuntimeStore: ui.sessionRuntimeStore,
            workspace: workspace, readPanelID: readPanelID
        )
        Gtk.setLabel(coordinatorStatus, SidebarCoordinatorPresentation.statusText(mark) ?? "")
        for kind in ["working", "unread", "approval", "error"] { Gtk.setClass(coordinatorStatus, kind, false) }
        switch mark {
        case .working: Gtk.setClass(coordinatorStatus, "working", true)
        case .unread: Gtk.setClass(coordinatorStatus, "unread", true)
        case .needsApproval: Gtk.setClass(coordinatorStatus, "approval", true)
        case .error: Gtk.setClass(coordinatorStatus, "error", true)
        case .quiet, .starting, .notRunning: break
        }
        Gtk.setClass(coordinatorRow, "selected", selected || dockShows)
        gtk_widget_set_tooltip_text(coordinatorRow, SidebarCoordinatorPresentation.accessibilityLabel(mark, isSelected: selected, dockShows: dockShows))
    }

    private func rebuild(_ model: SidebarTasksModel) {
        Gtk.removeAllChildren(cards)
        cardTitleActions = [:]
        cardIndexByWorkspaceID = [:]
        if model.segment == .needsYou, model.cards.allSatisfy({ $0.sections.isEmpty }) {
            let empty = Gtk.label("Nothing needs you", classes: ["dim-label", "sidebar-nothing"], xalign: 0.5)
            Gtk.setName(empty, "sidebar.needsYou.empty")
            Gtk.append(cards, empty)
            let showAll = Gtk.button("Show all workspaces", classes: ["flat"])
            Gtk.setName(showAll, "sidebar.needsYou.showAll")
            Signal.connect(showAll, "clicked") { [weak self] in
                guard let self else { return }
                _ = self.ui.store.send(.setSidebarSegment(windowID: self.windowID, segment: .all))
            }
            Gtk.append(cards, showAll)
            return
        }
        for (index, card) in model.cards.enumerated() {
            if model.segment == .needsYou, card.sections.isEmpty { continue }
            Gtk.append(cards, makeCard(card, index: index, segment: model.segment))
        }
    }

    private func makeCard(_ card: SidebarTasksModel.Card, index: Int, segment: SidebarSegment) -> WidgetPtr {
        let box = Gtk.vbox(spacing: 2, classes: ["workspace-card", "task-card"])
        Gtk.setName(box, "sidebar.card.\(index)")
        Gtk.setClass(box, "selected", card.isSelected)
        let titleLine = Gtk.hbox(spacing: 6)
        if let workspaceID = card.workspaceID, segment == .all {
            let chevron = Gtk.iconButton(card.isCollapsed ? "pan-end-symbolic" : "pan-down-symbolic",
                                         tooltip: card.isCollapsed ? "Expand" : "Collapse", classes: ["flat", "sidebar-chevron"])
            Gtk.setName(chevron, "sidebar.card.\(index).disclosure")
            Signal.connect(chevron, "clicked") { [weak self] in
                guard let self else { return }
                _ = self.ui.store.send(.setSidebarWorkspaceCollapsed(windowID: self.windowID, workspaceID: workspaceID, collapsed: card.isCollapsed == false))
            }
            Gtk.append(titleLine, chevron)
        }
        // Keep selection off the chevron's ancestor chain so its press gesture
        // cannot claim the pointer sequence before the button's release.
        let titleContent = Gtk.hbox(spacing: 6)
        let title = Gtk.label(card.title, classes: ["workspace-title"])
        gtk_widget_set_hexpand(title, 1)
        Gtk.append(titleContent, title)
        Gtk.append(titleContent, countsBadge(card.counts))
        Gtk.append(titleLine, titleContent)
        Gtk.append(box, titleLine)
        if let workspaceID = card.workspaceID {
            Gtk.setName(titleContent, "sidebar.card.\(index).title")
            gtk_widget_set_tooltip_text(titleContent, "Show \(card.title)'s workspace page")
            cardIndexByWorkspaceID[workspaceID] = index
            cardTitleActions[index] = { [weak self] in
                guard let self else { return }
                self.ui.feature(windowID: self.windowID)?.toggleOverview(workspaceID: workspaceID)
            }
            click(titleContent) { [weak self] in
                guard let self else { return }
                // The workspace page (Linux-first): its synopsis, latest
                // tasks and kept Scratchpads. A second click returns to the
                // workspace's own tabs.
                if let feature = self.ui.feature(windowID: self.windowID) {
                    feature.toggleOverview(workspaceID: workspaceID)
                } else {
                    _ = self.ui.logic.sendNavigation([.selectWorkspace(windowID: self.windowID, workspaceID: workspaceID)])
                }
            }
        }
        guard card.isCollapsed == false || segment == .needsYou else { return box }
        for section in card.sections {
            let sectionHeader = Gtk.label(section.bucket.title.uppercased(), classes: ["sidebar-bucket", Self.bucketClass(section.bucket)])
            Gtk.append(box, sectionHeader)
            for item in section.items {
                switch item {
                case .row(let row):
                    Gtk.append(box, makeRow(row))
                case .folded(let parent, let rows, let isExpanded):
                    let line = Gtk.button("\(isExpanded ? "⌄" : "›") ☑ \(rows.count) merged", classes: ["flat", "sidebar-folded"])
                    Signal.connect(line, "clicked") { [weak self] in
                        guard let self else { return }
                        if self.expandedFolds.remove(parent) == nil { self.expandedFolds.insert(parent) }
                        self.ui.scheduleRender()
                    }
                    Gtk.append(box, line)
                    if isExpanded {
                        for row in rows { Gtk.append(box, makeRow(row)) }
                    }
                }
            }
        }
        if segment == .all, card.toShipCount > 0 || card.doneCount > 0 || card.heldDoneRows.isEmpty == false {
            let footer = Gtk.hbox(spacing: 6, classes: ["sidebar-finished"])
            if card.toShipCount > 0 {
                let toShip = Gtk.button("\(card.isToShipExpanded ? "⌄" : "›") To ship \(card.toShipCount)", classes: ["flat", "sidebar-to-ship"])
                Gtk.setName(toShip, "sidebar.card.\(index).toShip")
                let key = card.workspaceID ?? SidebarTasksModel.otherTasksCardID
                Signal.connect(toShip, "clicked") { [weak self] in
                    guard let self else { return }
                    if self.expandedToShip.remove(key) == nil { self.expandedToShip.insert(key) }
                    self.ui.scheduleRender()
                }
                Gtk.append(footer, toShip)
            }
            let spacer = Gtk.hbox()
            gtk_widget_set_hexpand(spacer, 1)
            Gtk.append(footer, spacer)
            let cardKey = card.workspaceID ?? SidebarTasksModel.otherTasksCardID
            if card.heldDoneRows.isEmpty == false {
                // Done tasks whose task spaces Toastty keeps open: their
                // rows under the Done line, which expands in place.
                let done = Gtk.button("\(card.isDoneExpanded ? "⌄" : "›") Done \(card.doneCount) · \(card.heldDoneRows.count) open", classes: ["flat", "sidebar-done"])
                Signal.connect(done, "clicked") { [weak self] in
                    guard let self else { return }
                    if self.expandedDone.remove(cardKey) == nil { self.expandedDone.insert(cardKey) }
                    self.ui.scheduleRender()
                }
                Gtk.append(footer, done)
            } else if card.doneCount > 0 {
                let done = Gtk.button("Done \(card.doneCount)", classes: ["flat", "sidebar-done"])
                Signal.connect(done, "clicked") { [weak self] in self?.openTasksView(selecting: nil, revealing: .done) }
                Gtk.append(footer, done)
            }
            Gtk.append(box, footer)
            if card.isDoneExpanded {
                for row in card.heldDoneRows { Gtk.append(box, makeRow(row)) }
            }
            for row in card.toShipRows {
                Gtk.append(box, makeTaskRow(row, key: .task(row.subject)))
            }
            if card.isToShipExpanded, card.toShipCount > card.toShipRows.count {
                let more = Gtk.button("Show \(card.toShipCount - card.toShipRows.count) more", classes: ["flat", "sidebar-more"])
                Signal.connect(more, "clicked") { [weak self] in self?.openTasksView(selecting: nil, revealing: .toShip) }
                Gtk.append(box, more)
            }
        }
        return box
    }

    /// The card's counts: a yellow dot, a blue square, a spinner and a gray
    /// dot, each with its count.
    private func countsBadge(_ counts: [Int]) -> WidgetPtr {
        let badge = Gtk.hbox(spacing: 6, classes: ["sidebar-bucket-counts"])
        for (index, bucket) in SidebarBucket.allCases.enumerated() where counts.indices.contains(index) && counts[index] > 0 {
            let part = Gtk.hbox(spacing: 3)
            if bucket == .running {
                let spinner = toastty_clock_spinner_new()!
                gtk_widget_set_size_request(spinner, 8, 8)
                Gtk.append(part, spinner)
            } else {
                let mark = Gtk.hbox(classes: ["sidebar-count-mark", Self.bucketClass(bucket)])
                gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
                Gtk.append(part, mark)
            }
            Gtk.append(part, Gtk.label("\(counts[index])", classes: ["sidebar-count-number"], ellipsize: false))
            Gtk.append(badge, part)
        }
        return badge
    }

    static func bucketClass(_ bucket: SidebarBucket) -> String {
        switch bucket {
        case .needsYou: "needs-you"
        case .readyToReview: "review"
        case .running: "running"
        case .idle: "idle"
        }
    }

    // MARK: - Rows

    private func makeRow(_ row: SidebarTasksModel.Row) -> WidgetPtr {
        let widget: WidgetPtr
        switch row.kind {
        case .session(let session, let workspaceID):
            widget = makeSessionRow(session, workspaceID: workspaceID)
        case .taskSpace(let space):
            widget = makeTaskSpaceRow(space)
        case .task(let task):
            widget = makeTaskRow(task, key: row.key)
        }
        Gtk.setClass(widget, "child", row.isLinkedChild)
        Gtk.setClass(widget, "context", row.isContext)
        return widget
    }

    private func makeSessionRow(_ session: SidebarSessionRowModel, workspaceID: UUID) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 8, classes: ["session-row"])
        Gtk.setClass(line, "unread", session.isUnread)
        Gtk.setClass(line, "focused", session.isFocused)
        if let attention = session.attentionClass { Gtk.addClasses(line, [attention]) }
        let dot = Gtk.box(GTK_ORIENTATION_HORIZONTAL, classes: ["status-dot", session.dotClass])
        gtk_widget_set_valign(dot, GTK_ALIGN_START)
        gtk_widget_set_margin_top(dot, 5)
        Gtk.append(line, dot)
        let text = Gtk.vbox()
        gtk_widget_set_hexpand(text, 1)
        let nameLine = Gtk.hbox(spacing: 6)
        let name = Gtk.label(session.name, classes: ["session-name"])
        gtk_widget_set_hexpand(name, 1)
        Gtk.append(nameLine, name)
        if let chip = session.chipLabel {
            Gtk.append(nameLine, Gtk.label(chip, classes: ["status-chip", chip == "waiting" ? "waiting" : session.statusClass], ellipsize: false))
        }
        Gtk.append(text, nameLine)
        Gtk.append(text, Gtk.label(session.summary ?? session.agentLabel, classes: session.summaryIsWaiting ? ["session-summary", "waiting"] : ["session-summary"]))
        Gtk.append(line, text)
        click(line) { [weak self] in
            guard let self, let workspace = self.ui.store.state.workspacesByID[workspaceID],
                  let tabID = workspace.tabID(containingPanelID: session.panelID) else { return }
            _ = self.ui.logic.sendNavigation([
                .selectWorkspace(windowID: self.windowID, workspaceID: workspaceID),
                .selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID),
                .focusPanel(workspaceID: workspaceID, panelID: session.panelID),
            ])
        }
        return line
    }

    private func makeTaskSpaceRow(_ space: SidebarTasksModel.TaskSpaceRow) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 8, classes: ["session-row", "task-space-row"])
        Gtk.setName(line, "sidebar.taskSpace.\(space.workspaceID.uuidString)")
        Gtk.setClass(line, "focused", space.isSelected)
        Gtk.setClass(line, "unread", space.isUnread)
        Gtk.append(line, TaskMarkWidget.make(space.mark))
        let text = Gtk.vbox()
        gtk_widget_set_hexpand(text, 1)
        let nameLine = Gtk.hbox(spacing: 6)
        let name = Gtk.label(space.title, classes: ["session-name"])
        gtk_widget_set_hexpand(name, 1)
        Gtk.append(nameLine, name)
        if let tag = space.tag {
            Gtk.append(nameLine, Gtk.label(tag, classes: ["task-tag"], ellipsize: false))
        }
        Gtk.append(text, nameLine)
        if let summary = space.summary {
            Gtk.append(text, Gtk.label(summary, classes: ["session-summary"]))
        }
        Gtk.append(line, text)
        let workspaceID = space.workspaceID
        click(line) { [weak self] in
            guard let self else { return }
            self.ui.openTaskSpace(workspaceID, windowID: self.windowID)
        }
        contextClick(line) { [weak self] x, y in
            self?.showTaskSpaceMenu(workspaceID: workspaceID, from: line, x: x, y: y)
        }
        return line
    }

    private func makeTaskRow(_ task: SidebarTasksModel.TaskRow, key: SidebarRowKey) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 8, classes: ["session-row", "task-record-row"])
        Gtk.append(line, TaskMarkWidget.make(task.mark))
        let text = Gtk.vbox()
        gtk_widget_set_hexpand(text, 1)
        let nameLine = Gtk.hbox(spacing: 6)
        let name = Gtk.label(task.title, classes: ["session-name"])
        gtk_widget_set_hexpand(name, 1)
        Gtk.append(nameLine, name)
        if let tag = task.tag {
            Gtk.append(nameLine, Gtk.label(tag, classes: ["task-tag"], ellipsize: false))
        }
        Gtk.append(text, nameLine)
        Gtk.append(text, Gtk.label(task.statusLine, classes: ["session-summary"]))
        Gtk.append(line, text)
        let subject = task.subject
        click(line) { [weak self] in self?.openTasksView(selecting: subject) }
        contextClick(line) { [weak self] x, y in
            guard let self, let item = self.ui.board.items().first(where: { $0.id == subject }) else { return }
            self.showTaskMenu(item, from: line, x: x, y: y)
        }
        return line
    }

    // MARK: - Actions

    private func openTasksView(selecting subject: TaskBoardItem.Subject?, revealing group: TaskStage.Group? = nil) {
        ui.board.showTasksView(windowID: windowID, selecting: subject, revealing: group, store: ui.store, source: .ui("sidebar_tasks"))
    }

    private func segmentToggled() {
        guard isSyncing == false else { return }
        let segment: SidebarSegment = gtk_toggle_button_get_active(cast(needsYouToggle)).bool ? .needsYou : .all
        guard ui.store.state.window(id: windowID)?.sidebarSegment != segment else { return }
        _ = ui.store.send(.setSidebarSegment(windowID: windowID, segment: segment))
    }

    /// A click shows or hides the dock; on the selected Coordinator row it
    /// gives the full view's field the keyboard; without the chat it
    /// selects the coordinator's workspace.
    private func coordinatorClicked() {
        guard let coordinator = ui.tasks.coordinatorController, let location = coordinator.location else { return }
        let selected = ui.store.state.window(id: windowID)?.selectedWorkspaceID == location.workspaceID
        if coordinator.chatIsAvailable, selected == false {
            coordinator.toggleDock()
        } else if selected {
            coordinator.chat?.requestComposerFocus(host: .panel)
        } else {
            _ = ui.logic.sendNavigation([.selectWorkspace(windowID: windowID, workspaceID: location.workspaceID)])
        }
    }

    private func installActions() {
        let group = g_simple_action_group_new()!
        let stringType = g_variant_type_new("s")
        defer { g_variant_type_free(stringType) }
        let run = g_simple_action_new("run", stringType)!
        Signal.connectPointer(run, "activate") { [weak self] parameter in
            guard let self, let value = variantStringValue(parameter.map(OpaquePointer.init)), let index = Int(value),
                  self.menuEntries.indices.contains(index) else { return }
            let entry = self.menuEntries[index]
            TaskActions.runFromMenu(entry.menuItem, coordinator: self.ui.coordinator) { [weak self] workspaceID in
                guard let self else { return }
                self.ui.openTaskSpace(workspaceID, windowID: self.windowID)
            }
        }
        g_action_map_add_action(cast(group), cast(run))
        g_object_unref(UnsafeMutableRawPointer(run))
        func add(_ name: String, _ handler: @escaping @MainActor () -> Void) {
            let action = g_simple_action_new(name, nil)!
            Signal.connectPointer(action, "activate") { _ in handler() }
            g_action_map_add_action(cast(group), cast(action))
            g_object_unref(UnsafeMutableRawPointer(action))
        }
        add("full-view") { [weak self] in self?.ui.tasks.coordinatorController?.openFullView() }
        add("toggle-dock") { [weak self] in self?.ui.tasks.coordinatorController?.toggleDock() }
        add("close") { [weak self] in
            guard let self, let location = self.ui.tasks.coordinatorController?.location else { return }
            self.controller?.handleUI(.confirmCloseWorkspace(workspaceID: location.workspaceID))
        }
        let document = g_simple_action_new("document", stringType)!
        Signal.connectPointer(document, "activate") { [weak self] parameter in
            guard let self, let name = variantStringValue(parameter.map(OpaquePointer.init)),
                  let document = CoordinatorDocument.allCases.first(where: { $0.fileName == name }) else { return }
            do { try self.ui.tasks.coordinatorController?.openDocument(document) } catch { self.controller?.toast(error.localizedDescription) }
        }
        g_action_map_add_action(cast(group), cast(document))
        g_object_unref(UnsafeMutableRawPointer(document))
        gtk_widget_insert_action_group(content, "sidebartasks", cast(group))
        gtk_widget_insert_action_group(header, "sidebartasks", cast(group))
        g_object_unref(UnsafeMutableRawPointer(group))
    }

    private func showTaskSpaceMenu(workspaceID: UUID, from row: WidgetPtr, x: Double, y: Double) {
        guard let taskID = ui.store.state.workspacesByID[workspaceID]?.taskID,
              let item = ui.board.items().first(where: { $0.taskID == taskID }) else { return }
        showTaskMenu(item, from: row, x: x, y: y)
    }

    private func showTaskMenu(_ item: TaskBoardItem, from widget: WidgetPtr, x: Double, y: Double) {
        menuEntries = []
        let model = g_menu_new()!
        for section in TaskBoardPresentation.menuItems(item, isTriageConfigured: ui.coordinator.isTriageConfigured) {
            let part = g_menu_new()!
            for menuItem in section {
                g_menu_append(part, menuItem.title, "sidebartasks.run::\(menuEntries.count)")
                menuEntries.append((item, menuItem))
            }
            g_menu_append_section(model, nil, cast(part))
            g_object_unref(UnsafeMutableRawPointer(part))
        }
        popup(model, from: widget, x: x, y: y)
    }

    private func showCoordinatorMenu(x: Double, y: Double) {
        guard let coordinator = ui.tasks.coordinatorController else { return }
        let model = g_menu_new()!
        let views = g_menu_new()!
        g_menu_append(views, "Open Full View", "sidebartasks.full-view")
        g_menu_append(views, CoordinatorDockPresentation.toggleTitle(dockShows: coordinator.dockShows(in: windowID)), "sidebartasks.toggle-dock")
        g_menu_append_section(model, nil, cast(views))
        let documents = g_menu_new()!
        for document in CoordinatorDocument.allCases {
            g_menu_append(documents, "Open \(document.name)", "sidebartasks.document::\(document.fileName)")
        }
        g_menu_append_section(model, nil, cast(documents))
        let actions = g_menu_new()!
        g_menu_append(actions, "Restart Coordinator", "win.coordinator.restart")
        g_menu_append(actions, "Close Coordinator", "sidebartasks.close")
        g_menu_append_section(model, nil, cast(actions))
        for part in [views, documents, actions] { g_object_unref(UnsafeMutableRawPointer(part)) }
        popup(model, from: coordinatorRow, x: x, y: y)
    }

    private func popup(_ model: OpaquePointer, from widget: WidgetPtr, x: Double, y: Double) {
        gtk_popover_menu_set_menu_model(cast(menu), cast(model))
        g_object_unref(UnsafeMutableRawPointer(model))
        var source = graphene_point_t(x: Float(x), y: Float(y))
        var target = graphene_point_t(x: 0, y: 0)
        guard gtk_widget_compute_point(widget, content, &source, &target).bool else { return }
        var rect = GdkRectangle(x: Int32(target.x), y: Int32(target.y), width: 1, height: 1)
        gtk_popover_set_pointing_to(cast(menu), &rect)
        gtk_popover_popup(cast(menu))
    }

    private func click(_ widget: WidgetPtr, _ action: @escaping @MainActor () -> Void) {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(gesture), guint(GDK_BUTTON_PRIMARY))
        Signal.connectPress(gesture) { _, _, _ in
            gtk_gesture_set_state(cast(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
            action()
        }
        gtk_widget_add_controller(widget, cast(gesture))
    }

    private func contextClick(_ widget: WidgetPtr, _ action: @escaping @MainActor (Double, Double) -> Void) {
        let gesture = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(gesture), guint(GDK_BUTTON_SECONDARY))
        Signal.connectPress(gesture) { _, x, y in action(x, y) }
        gtk_widget_add_controller(widget, cast(gesture))
    }

    // MARK: - Automation

    func automationOpenTaskSpaceMenu() -> Bool {
        for row in model?.cards.flatMap(\.sections).flatMap(\.rows) ?? [] {
            guard case .taskSpace(let space) = row.kind,
                  let widget = Gtk.find(named: "sidebar.taskSpace.\(space.workspaceID.uuidString)", in: cards),
                  gtk_widget_get_mapped(widget).bool else { continue }
            showTaskSpaceMenu(workspaceID: space.workspaceID, from: widget, x: 12, y: 12)
            return true
        }
        return false
    }

    func automationDismissContextMenu() {
        gtk_popover_popdown(cast(menu))
    }

    /// The index of the card that shows `workspaceID`, for automation.
    func automationCardIndex(workspaceID: UUID) -> Int? {
        cardIndexByWorkspaceID[workspaceID]
    }

    /// Runs card `index`'s title click; false when no card has one.
    func automationClickCardTitle(_ index: Int) -> Bool {
        guard let action = cardTitleActions[index] else { return false }
        action()
        return true
    }

    var automationSummary: [String: String] {
        guard let model else { return [:] }
        let rows = model.cards.flatMap { $0.sections.flatMap(\.rows) }
        let markWidths = TaskMarkWidget.slotWidths(in: cards)
        return [
            "sidebarSegment": model.segment.rawValue,
            "sidebarNeedsYou": String(model.needsYouCount),
            "sidebarReview": String(model.readyToReviewCount),
            "sidebarCards": model.cards.map(\.title).joined(separator: ","),
            "sidebarBuckets": model.cards.flatMap { card in card.sections.map { "\(Self.bucketClass($0.bucket)):\($0.rows.count)" } }.joined(separator: ","),
            "sidebarTaskRows": String(rows.filter { if case .session = $0.kind { false } else { true } }.count),
            "sidebarCoordinator": gtk_widget_get_visible(coordinatorRow).bool ? "shown" : "hidden",
            "sidebarContextMenu": gtk_widget_get_mapped(menu).bool ? "shown" : "hidden",
            "sidebarVisibleRows": String(markWidths.count),
            "sidebarMarkWidths": markWidths.map(String.init).joined(separator: ","),
        ]
    }
}
#endif
