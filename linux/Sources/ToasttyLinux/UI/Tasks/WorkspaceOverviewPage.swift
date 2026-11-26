#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The workspace page (Linux-first, docs/plans/workspace-overview.md): what
/// a top-level workspace card's title opens. It covers the workspace content
/// like the Tasks view, with:
///
/// - a header with the workspace's title and folder, **Terminal** (its own
///   tabs) and **New Task**;
/// - **Recent**: the five most recently active tasks;
/// - **Past Tasks**: the rest, with the same inline description and
///   continuation controls as Recent;
/// - on the right, the workspace's kept Scratchpads, with a preview of the
///   selected one, Open (in the right panel) and Delete.
///
/// Esc, **Terminal**, a second click on the card's title, or selecting
/// anything else leaves it.
@MainActor
final class WorkspaceOverviewPage {
    let root: WidgetPtr
    private let ui: TasksUI
    private let windowID: UUID
    private let webServices: (any WebPanelServices)?
    private let titleLabel: WidgetPtr
    private let subtitleLabel: WidgetPtr
    private let mainBox: WidgetPtr
    private let browserPins = WorkspaceOverviewBrowserPins()
    private let padsList: WidgetPtr
    private let padsCount: WidgetPtr
    private let previewBox: WidgetPtr
    private let previewBoxRef: GObjectRef
    private let previewTitle: WidgetPtr
    private let previewStatus: WidgetPtr
    private let previewPurpose: WidgetPtr
    private let previewOpen: WidgetPtr
    private let previewDelete: WidgetPtr
    private let padTabs = TabViewSync()
    private let padsEmpty: WidgetPtr
    private var preview: ScratchpadPanelController?
    private let previewPanelID = UUID()
    private var previewDocument: (id: UUID, revision: Int)?
    private(set) var workspaceID: UUID?
    private(set) var selectedScratchpadID: UUID?
    private var drawn: Drawn?
    private var expandedTasks: Set<TaskBoardItem.Subject> = []
    private var serviceToken: UUID?
    /// Leaves the page for the workspace's own tabs.
    var onClose: (() -> Void)?

    /// What the page last drew, to skip rebuilding an unchanged page.
    private struct Drawn: Equatable {
        var workspaceID: UUID
        var title: String
        var subtitle: String
        var recent: [TaskRow]
        var past: [TaskRow]
        var scratchpads: [WorkspaceOverviewModel.Scratchpad]
        var selectedScratchpadID: UUID?
    }

    private struct TaskRow: Equatable {
        let summary: TasksPage.Row
        let description: String?
        let continuesTaskID: UUID?
        let menu: [[TaskBoardPresentation.MenuItem]]

        @MainActor init(_ item: TaskBoardItem, now: Date, isTriageConfigured: Bool) {
            summary = TasksPage.row(.init(item: item), selectedID: nil, now: now)
            description = TasksPage.taskDescription(item)
            continuesTaskID = TaskBoardPresentation.canContinueAsNewTask(item) ? item.taskID : nil
            menu = TaskBoardPresentation.menuItems(item, isTriageConfigured: isTriageConfigured)
        }
    }

    init(ui: TasksUI, windowID: UUID, webServices: (any WebPanelServices)?) {
        self.ui = ui
        self.windowID = windowID
        self.webServices = webServices
        root = Gtk.hbox(classes: ["tasks-view", "workspace-overview"])
        Gtk.setName(root, "workspace.overview")
        gtk_widget_set_focusable(root, 1)

        // Main column.
        let column = Gtk.vbox()
        Gtk.expand(column)
        let header = Gtk.hbox(spacing: 12, classes: ["tasks-header"])
        let titles = Gtk.vbox(spacing: 2)
        gtk_widget_set_hexpand(titles, 1)
        titleLabel = Gtk.label("", classes: ["tasks-title"])
        Gtk.setName(titleLabel, "workspace.overview.title")
        subtitleLabel = Gtk.label("", classes: ["workspace-overview-subtitle"])
        Gtk.append(titles, titleLabel)
        Gtk.append(titles, subtitleLabel)
        Gtk.append(header, titles)
        let terminal = gtk_button_new()!
        let terminalContent = Gtk.hbox(spacing: 7)
        Gtk.append(terminalContent, Gtk.image("utilities-terminal-symbolic", pixelSize: 14))
        Gtk.append(terminalContent, Gtk.label("Terminal", ellipsize: false))
        gtk_button_set_child(cast(terminal), terminalContent)
        gtk_widget_set_tooltip_text(terminal, "Show this workspace's own tabs (Esc)")
        Gtk.setName(terminal, "workspace.overview.terminal")
        Gtk.append(header, terminal)
        let newTask = gtk_button_new()!
        Gtk.addClasses(newTask, ["suggested-action", "tasks-new"])
        let newTaskContent = Gtk.hbox(spacing: 7)
        Gtk.append(newTaskContent, Gtk.image("list-add-symbolic", pixelSize: 14))
        Gtk.append(newTaskContent, Gtk.label("New Task", ellipsize: false))
        gtk_button_set_child(cast(newTask), newTaskContent)
        Gtk.setName(newTask, "workspace.overview.new-task")
        Gtk.append(header, newTask)
        Gtk.append(column, header)

        mainBox = Gtk.vbox(spacing: 16, classes: ["workspace-overview-main"])
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), mainBox)
        Gtk.expand(scroller)
        Gtk.append(column, scroller)
        Gtk.append(root, column)

        Gtk.append(root, gtk_separator_new(GTK_ORIENTATION_VERTICAL))

        // Kept Scratchpads use the same tab widgets as the Tasks right panel.
        let side = Gtk.vbox(classes: ["workspace-overview-pads"])
        Gtk.setName(side, "workspace.overview.scratchpads")
        gtk_widget_set_size_request(side, 380, -1)
        gtk_widget_set_vexpand(side, 1)
        let sideHeader = Gtk.hbox(spacing: 8, classes: ["workspace-overview-pads-header"])
        let sideTitle = Gtk.label("Workspace Scratchpads", classes: ["tasks-card-title"])
        gtk_widget_set_hexpand(sideTitle, 1)
        Gtk.append(sideHeader, sideTitle)
        padsCount = Gtk.label("", classes: ["tasks-group-count"], ellipsize: false)
        Gtk.append(sideHeader, padsCount)
        Gtk.append(side, sideHeader)
        let tabBar = adw_tab_bar_new()!
        padsList = widget(tabBar)
        Gtk.setName(padsList, "workspace.overview.scratchpads.tabs")
        adw_tab_bar_set_view(tabBar, padTabs.view)
        adw_tab_bar_set_autohide(tabBar, 0)
        Gtk.append(side, padsList)
        Gtk.append(side, padTabs.widget)
        padsEmpty = Gtk.label(
            "Keep a task's Scratchpad here with the pin in the right panel's header, or ask its agent to keep it. Kept Scratchpads stay after their task finishes.",
            classes: ["tasks-why", "workspace-overview-pads-empty"], ellipsize: false
        )
        gtk_label_set_wrap(cast(padsEmpty), 1)
        Gtk.setName(padsEmpty, "workspace.overview.scratchpads.empty")
        Gtk.append(side, padsEmpty)

        previewBox = Gtk.vbox(classes: ["workspace-overview-preview"])
        previewBoxRef = GObjectRef(sinking: previewBox)
        Gtk.setName(previewBox, "workspace.overview.preview")
        Gtk.expand(previewBox)
        let previewHeader = Gtk.hbox(spacing: 6, classes: ["workspace-overview-preview-header"])
        let previewLabels = Gtk.vbox(spacing: 2)
        gtk_widget_set_hexpand(previewLabels, 1)
        previewTitle = Gtk.label("", classes: ["tasks-row-title"])
        previewStatus = Gtk.label("", classes: ["tasks-row-status"])
        previewPurpose = Gtk.label("", classes: ["tasks-why"])
        Gtk.append(previewLabels, previewTitle)
        Gtk.append(previewLabels, previewStatus)
        Gtk.append(previewLabels, previewPurpose)
        Gtk.append(previewHeader, previewLabels)
        previewOpen = Gtk.iconButton("view-dual-symbolic", tooltip: "Open in the right panel")
        Gtk.setName(previewOpen, "workspace.overview.preview.open")
        Gtk.append(previewHeader, previewOpen)
        previewDelete = Gtk.iconButton("user-trash-symbolic", tooltip: "Delete from this workspace…")
        Gtk.setName(previewDelete, "workspace.overview.preview.delete")
        Gtk.append(previewHeader, previewDelete)
        Gtk.append(previewBox, previewHeader)
        Gtk.append(root, side)

        gtk_box_prepend(cast(side), browserPins.root)
        browserPins.onOpen = { [weak self] pin in
            guard let self, let workspaceID = self.workspaceID else { return }
            do {
                try self.ui.logic.workspaceOverview.openBrowser(pin, in: workspaceID)
                self.onClose?()
            } catch {
                TaskActions.presentFailure("Could Not Open the Browser Page", error.localizedDescription)
            }
        }
        browserPins.onRemove = { [weak self] pin in
            guard let self, let workspaceID = self.workspaceID else { return }
            do {
                try self.ui.logic.workspaceOverview.unpinBrowser(pin, in: workspaceID)
            } catch {
                TaskActions.presentFailure("Could Not Unpin the Browser Page", error.localizedDescription)
            }
        }
        Signal.connect(terminal, "clicked") { [weak self] in self?.onClose?() }
        Signal.connect(newTask, "clicked") { [weak self] in self?.ui.board.newTask?() }
        Signal.connect(previewOpen, "clicked") { [weak self] in
            guard let self, let id = self.selectedScratchpadID else { return }
            self.openScratchpad(id)
        }
        Signal.connect(previewDelete, "clicked") { [weak self] in
            guard let self, let id = self.selectedScratchpadID else { return }
            self.confirmDelete(id)
        }
        padTabs.onSelect = { [weak self] in self?.selectScratchpad($0) }
        padTabs.onCloseRequest = { [weak self] in self?.confirmDelete($0) }
        installKeys()
        serviceToken = ui.logic.workspaceOverview.observeChanges { [weak self] in
            self?.drawn = nil
            self?.ui.scheduleRender()
        }
    }

    func teardown() {
        if let serviceToken { ui.logic.workspaceOverview.removeObserver(serviceToken) }
        serviceToken = nil
        preview?.close()
        preview = nil
    }

    private func installKeys() {
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        Signal.connectKeyPressed(keys) { [weak self] keyval, _, _ in
            guard let self, Int32(keyval) == GDK_KEY_Escape else { return false }
            self.onClose?()
            return true
        }
        gtk_widget_add_controller(root, keys)
    }

    // MARK: - Render

    func render(workspaceID: UUID?, isShown: Bool) {
        if self.workspaceID != workspaceID {
            expandedTasks.removeAll()
            drawn = nil
        }
        self.workspaceID = workspaceID
        guard isShown, let workspaceID,
              let model = WorkspaceOverviewModel.make(workspaceID: workspaceID, service: ui.logic.workspaceOverview) else { return }
        browserPins.render(workspaceID: workspaceID, pins: ui.logic.workspaceOverview.browserPins(forWorkspace: workspaceID))
        if let selected = selectedScratchpadID, model.scratchpads.contains(where: { $0.entry.documentID == selected }) == false {
            selectedScratchpadID = nil
        }
        if selectedScratchpadID == nil { selectedScratchpadID = model.scratchpads.first?.entry.documentID }
        let now = Date()
        let isTriageConfigured = ui.coordinator.isTriageConfigured
        func row(_ item: TaskBoardItem) -> TaskRow {
            TaskRow(item, now: now, isTriageConfigured: isTriageConfigured)
        }
        let next = Drawn(
            workspaceID: workspaceID,
            title: model.title,
            subtitle: Self.subtitle(model),
            recent: model.recent.map { row($0.item) },
            past: model.pastItems.map(row),
            scratchpads: model.scratchpads,
            selectedScratchpadID: selectedScratchpadID
        )
        let previous = drawn
        guard next != previous else { return }
        drawn = next
        Gtk.setLabel(titleLabel, next.title)
        Gtk.setLabel(subtitleLabel, next.subtitle)
        if previous?.workspaceID != workspaceID || previous?.recent != next.recent || previous?.past != next.past {
            rebuildMain(next)
        }
        rebuildScratchpads(next)
    }

    static func subtitle(_ model: WorkspaceOverviewModel) -> String {
        var parts: [String] = []
        if let root = model.projectRoot { parts.append(WorkspaceOverviewModel.tildePath(root)) }
        let total = model.items.count
        parts.append(total == 1 ? "1 task" : "\(total) tasks")
        if model.openCount > 0 { parts.append("\(model.openCount) open") }
        let pads = model.scratchpads.count
        if pads > 0 { parts.append(pads == 1 ? "1 Scratchpad" : "\(pads) Scratchpads") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Main column

    private func rebuildMain(_ drawn: Drawn) {
        expandedTasks.formIntersection((drawn.recent + drawn.past).compactMap {
            $0.description == nil ? nil : $0.summary.subject
        })
        Gtk.removeAllChildren(mainBox)
        Gtk.append(mainBox, makeTaskSection(
            "Recent", name: "recent", rows: drawn.recent, empty: "No tasks yet. New Task starts one here."
        ))
        Gtk.append(mainBox, makeTaskSection("Past Tasks", name: "past", rows: drawn.past, empty: "No past tasks yet."))
    }

    private func makeTaskSection(_ title: String, name: String, rows: [TaskRow], empty: String) -> WidgetPtr {
        let name = "workspace.overview.\(name)"
        let card = Gtk.vbox(classes: ["tasks-card", "workspace-overview-card"])
        Gtk.setName(card, name)
        Gtk.append(card, Gtk.label(title.uppercased(), classes: ["tasks-card-title"]))
        Gtk.append(card, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        let body = Gtk.vbox(spacing: 2, classes: ["tasks-card-body"])
        if rows.isEmpty {
            let label = Gtk.label(empty, classes: ["tasks-why"], ellipsize: false)
            Gtk.margins(label, 6)
            Gtk.append(body, label)
        }
        for (index, row) in rows.enumerated() {
            Gtk.append(body, makeTaskRow(row, name: "\(name).\(index)"))
        }
        Gtk.append(card, body)
        return card
    }

    /// Opens New Task with the finished task's context attached.
    func continueTask(_ taskID: UUID) {
        TaskActions.runFromMenu(.continueAsNewTask(taskID: taskID), coordinator: ui.coordinator) { _ in }
    }

    private func makeTaskRow(_ entry: TaskRow, name: String) -> WidgetPtr {
        let row = entry.summary
        let container = Gtk.vbox(classes: ["workspace-overview-row"])
        Gtk.setName(container, name)
        let line = Gtk.hbox(spacing: 4)
        Gtk.append(container, line)
        if let description = entry.description {
            let label = Gtk.label(description, classes: ["tasks-detail-text", "workspace-overview-description"], ellipsize: false)
            gtk_label_set_wrap(cast(label), 1)
            gtk_label_set_wrap_mode(cast(label), PANGO_WRAP_WORD_CHAR)
            gtk_label_set_selectable(cast(label), 1)
            Gtk.setName(label, "\(name).description")
            Gtk.append(container, label)

            let toggle = gtk_toggle_button_new()!
            Gtk.addClasses(toggle, ["flat", "workspace-overview-disclosure"])
            Gtk.setName(toggle, "\(name).expand")
            gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
            let icon = Gtk.image("pan-end-symbolic", pixelSize: 12)
            gtk_button_set_child(cast(toggle), icon)
            let expanded = expandedTasks.contains(row.subject)
            gtk_toggle_button_set_active(cast(toggle), expanded.gboolean)
            Self.showDescription(expanded, title: row.title, label: label, toggle: toggle, icon: icon)
            Signal.connect(toggle, "toggled") { [weak self] in
                guard let self else { return }
                let expanded = gtk_toggle_button_get_active(cast(toggle)).bool
                if expanded { self.expandedTasks.insert(row.subject) } else { self.expandedTasks.remove(row.subject) }
                Self.showDescription(expanded, title: row.title, label: label, toggle: toggle, icon: icon)
            }
            Gtk.append(line, toggle)
        } else {
            let spacer = Gtk.hbox()
            gtk_widget_set_size_request(spacer, 26, -1)
            Gtk.append(line, spacer)
        }

        // Opening the task and disclosing its description are separate
        // controls. Selecting or copying the text can't navigate away.
        let open = gtk_button_new()!
        Gtk.addClasses(open, ["flat", "workspace-overview-open"])
        Gtk.setName(open, "\(name).open")
        gtk_widget_set_hexpand(open, 1)
        gtk_widget_set_tooltip_text(open, row.accessibleLabel)
        let summary = Gtk.hbox(spacing: 10)
        Gtk.append(summary, TaskMarkWidget.make(row.mark))
        let text = Gtk.vbox(spacing: 3)
        gtk_widget_set_hexpand(text, 1)
        Gtk.append(text, Gtk.label(row.title, classes: row.isBold ? ["tasks-row-title", "unread"] : ["tasks-row-title"]))
        let detail = Gtk.hbox(spacing: 8)
        if let number = row.pullRequest {
            Gtk.append(detail, Gtk.label("PR #\(number)", classes: ["task-pr-tag"], ellipsize: false))
        } else if let branch = row.branch {
            Gtk.append(detail, Gtk.label(branch, classes: ["task-branch"]))
        }
        let status = Gtk.label(row.statusLine, classes: ["tasks-row-status"])
        gtk_widget_set_hexpand(status, 1)
        Gtk.append(detail, status)
        if let age = row.age {
            Gtk.append(detail, Gtk.label(age, classes: ["tasks-row-age"], ellipsize: false))
        }
        Gtk.append(text, detail)
        Gtk.append(summary, text)
        gtk_button_set_child(cast(open), summary)
        Signal.connect(open, "clicked") { [weak self] in
            self?.open(subject: row.subject, taskSpace: row.taskSpaceWorkspaceID)
        }
        Gtk.append(line, open)
        if let taskID = entry.continuesTaskID {
            let button = Gtk.button("Continue", classes: ["suggested-action", "task-success-action"])
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(button, "Continue as New Task: start a new task with this task's context attached")
            Gtk.setName(button, "\(name).continue")
            Signal.connect(button, "clicked") { [weak self] in
                self?.continueTask(taskID)
            }
            Gtk.append(line, button)
        }
        if let menu = makeTaskMenu(entry.menu, name: name, title: row.title) {
            gtk_widget_set_valign(menu, GTK_ALIGN_CENTER)
            Gtk.append(line, menu)
            let click = gtk_gesture_click_new()!
            gtk_gesture_single_set_button(cast(click), guint(GDK_BUTTON_SECONDARY))
            Signal.connectPress(click) { _, _, _ in
                gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
                gtk_menu_button_popup(cast(menu))
            }
            gtk_widget_add_controller(line, cast(click))
        }
        return container
    }

    private func makeTaskMenu(
        _ sections: [[TaskBoardPresentation.MenuItem]], name: String, title: String
    ) -> WidgetPtr? {
        guard !sections.isEmpty else { return nil }
        let button = gtk_menu_button_new()!
        Gtk.setName(button, "\(name).menu")
        Gtk.addClasses(button, ["flat"])
        gtk_menu_button_set_icon_name(cast(button), "view-more-symbolic")
        gtk_widget_set_tooltip_text(button, "Actions for \(title)")
        let popover = gtk_popover_new()!
        let entries = Gtk.vbox()
        for (index, section) in sections.enumerated() {
            if index > 0 { Gtk.append(entries, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)) }
            for item in section {
                let entry = Gtk.button(item.title, classes: item.isDestructive ? ["flat", "destructive-action"] : ["flat"])
                if case .action(let action, _, _) = item {
                    Gtk.setName(entry, "\(name).\(action)")
                    gtk_widget_set_tooltip_text(entry, action.help)
                }
                Signal.connect(entry, "clicked") { [weak self, workspaceID] in
                    gtk_popover_popdown(cast(popover))
                    guard let self, let parent = gtk_widget_get_ancestor(self.root, gtk_window_get_type()) else { return }
                    self.ui.runWorkspaceTaskMenuItem(item, windowID: self.windowID, parent: parent) { [weak self] in
                        guard let self else { return false }
                        return self.workspaceID == workspaceID && gtk_widget_get_mapped(self.root) != 0
                    }
                }
                Gtk.append(entries, entry)
            }
        }
        gtk_popover_set_child(cast(popover), entries)
        gtk_menu_button_set_popover(cast(button), popover)
        return button
    }

    private static func showDescription(_ expanded: Bool, title: String, label: WidgetPtr, toggle: WidgetPtr, icon: WidgetPtr) {
        Gtk.setVisible(label, expanded)
        gtk_image_set_from_icon_name(cast(icon), expanded ? "pan-down-symbolic" : "pan-end-symbolic")
        gtk_widget_set_tooltip_text(toggle, "\(expanded ? "Hide" : "Show") description for \(title)")
    }

    func open(subject: TaskBoardItem.Subject, taskSpace: UUID?) {
        if let taskSpace, ui.store.state.workspacesByID[taskSpace] != nil {
            ui.openTaskSpace(taskSpace, windowID: windowID)
        } else {
            ui.board.showTasksView(windowID: windowID, selecting: subject, revealing: nil, store: ui.store, source: .ui("workspace_overview"))
        }
    }

    // MARK: - Scratchpads column

    private func rebuildScratchpads(_ drawn: Drawn) {
        let items = drawn.scratchpads.map { pad in
            let id = pad.entry.documentID
            let child = padTabs.page(for: id).flatMap { adw_tab_page_get_child($0) } ?? Gtk.vbox()
            return TabItem(id: id, title: pad.title, child: child)
        }
        let selectedChild = items.first { $0.id == drawn.selectedScratchpadID }?.child
        // Only the selected tab needs a WebKit preview. Hold the preview box
        // across moves (and across removal of its previous tab).
        if gtk_widget_get_parent(previewBox) != selectedChild {
            Gtk.detachFromParent(previewBox)
            if let selectedChild { Gtk.append(selectedChild, previewBox) }
        }
        padTabs.sync(items, selectedID: drawn.selectedScratchpadID)
        Gtk.setVisible(padsList, !items.isEmpty)
        Gtk.setVisible(padTabs.widget, !items.isEmpty)
        Gtk.setVisible(padsEmpty, items.isEmpty)
        Gtk.setLabel(padsCount, items.isEmpty ? "" : "\(items.count)")
        updatePreview(drawn.scratchpads.first { $0.entry.documentID == drawn.selectedScratchpadID })
    }

    func selectScratchpad(_ documentID: UUID) {
        guard selectedScratchpadID != documentID else { return }
        selectedScratchpadID = documentID
        ui.scheduleRender()
    }

    private func updatePreview(_ pad: WorkspaceOverviewModel.Scratchpad?) {
        if let pad {
            Gtk.setLabel(previewTitle, pad.title)
            var detail: [String] = []
            if pad.isLinked { detail.append("Live") }
            if let task = pad.sourceTaskTitle { detail.append("From \(task)") }
            if let updated = pad.updatedAt { detail.append("Updated \(TaskAge.label(since: updated, now: Date()))") }
            if pad.isMissing { detail = ["Its file is missing"] }
            Gtk.setLabel(previewStatus, detail.joined(separator: " · "))
            Gtk.setVisible(previewStatus, !detail.isEmpty)
            Gtk.setLabel(previewPurpose, pad.purpose ?? "")
            Gtk.setVisible(previewPurpose, pad.purpose?.isEmpty == false)
        }
        Gtk.setVisible(previewOpen, pad?.isMissing == false)
        guard let pad, pad.isMissing == false, let webServices else {
            preview?.close()
            preview.map { Gtk.unparentIfAttached($0.root) }
            preview = nil
            previewDocument = nil
            return
        }
        let webState = WebPanelState(
            definition: .scratchpad,
            title: pad.title,
            scratchpad: ScratchpadState(documentID: pad.entry.documentID, sessionLink: nil, revision: pad.revision, purpose: pad.purpose)
        )
        if let preview, previewDocument?.id == pad.entry.documentID {
            if previewDocument?.revision != pad.revision {
                preview.update(webState, windowID: windowID)
                previewDocument = (pad.entry.documentID, pad.revision)
            }
            return
        }
        if let preview {
            preview.close()
            Gtk.unparentIfAttached(preview.root)
        }
        let controller = ScratchpadPanelController(panelID: previewPanelID, webState: webState, windowID: windowID, services: webServices)
        Gtk.expand(controller.root)
        Gtk.append(previewBox, controller.root)
        preview = controller
        previewDocument = (pad.entry.documentID, pad.revision)
    }

    /// Opens a kept Scratchpad in the workspace's right panel and leaves the
    /// page, so it shows beside the workspace's own tabs.
    func openScratchpad(_ documentID: UUID) {
        guard let workspaceID else { return }
        do {
            try ui.logic.workspaceOverview.open(documentID: documentID, in: workspaceID)
            onClose?()
        } catch {
            TaskActions.presentFailure("Could Not Open the Scratchpad", error.localizedDescription)
        }
    }

    private func confirmDelete(_ documentID: UUID) {
        let title = drawn?.scratchpads.first { $0.entry.documentID == documentID }?.title ?? "Scratchpad"
        Dialogs.confirm(
            parent: root,
            heading: "Delete “\(title)” from This Workspace?",
            body: "The workspace's copy is deleted. A task that is still open keeps its own Scratchpad.",
            confirmLabel: "_Delete"
        ) { [weak self] in
            self?.deleteScratchpad(documentID)
        }
    }

    func deleteScratchpad(_ documentID: UUID) {
        do {
            try ui.logic.workspaceOverview.delete(documentID: documentID)
        } catch {
            TaskActions.presentFailure("Could Not Delete the Scratchpad", error.localizedDescription)
        }
    }

    // MARK: - Automation

    var automationScratchpadIDs: [UUID] { drawn?.scratchpads.map(\.entry.documentID) ?? [] }

    func automationSelectScratchpad(_ documentID: UUID) {
        if let page = padTabs.page(for: documentID) {
            adw_tab_view_set_selected_page(padTabs.view, page)
        }
    }

    func automationCloseScratchpad(_ documentID: UUID) {
        if let page = padTabs.page(for: documentID) {
            adw_tab_view_close_page(padTabs.view, page)
        }
    }

    func automationOpenRecent(_ index: Int) -> Bool {
        guard let recent = drawn?.recent, recent.indices.contains(index) else { return false }
        let row = recent[index].summary
        open(subject: row.subject, taskSpace: row.taskSpaceWorkspaceID)
        return true
    }

    /// Continue on the Recent row at `index`, as a click does.
    func automationContinueRecent(_ index: Int) -> Bool {
        guard let recent = drawn?.recent, recent.indices.contains(index),
              let taskID = recent[index].continuesTaskID else { return false }
        continueTask(taskID)
        return true
    }

    func automationTaskMenu(_ index: Int, action: String?) -> Bool {
        guard let drawn, index >= 0, index < drawn.recent.count + drawn.past.count else { return false }
        let name = index < drawn.recent.count ? "workspace.overview.recent.\(index)"
            : "workspace.overview.past.\(index - drawn.recent.count)"
        guard let menu = Gtk.find(named: "\(name).menu", in: root), gtk_widget_get_mapped(menu) != 0 else { return false }
        if let action {
            if action == "close" {
                guard let popover = gtk_menu_button_get_popover(cast(menu)), gtk_widget_get_mapped(widget(popover)) != 0 else { return false }
                gtk_menu_button_popdown(cast(menu))
                return true
            }
            guard let button = Gtk.find(named: "\(name).\(action)", in: menu), gtk_widget_get_mapped(button) != 0 else { return false }
            return gtk_widget_activate(button) != 0
        }
        gtk_menu_button_popup(cast(menu))
        return true
    }

    var automationSummary: [String: String] {
        guard let drawn else { return ["overviewScratchpads": "0"] }
        let rowNames = drawn.recent.indices.map { "workspace.overview.recent.\($0)" }
            + drawn.past.indices.map { "workspace.overview.past.\($0)" }
        let expanded = rowNames.filter {
            Gtk.find(named: "\($0).description", in: mainBox).map { gtk_widget_get_mapped($0).bool } ?? false
        }
        return [
            "overviewWorkspace": drawn.title.replacingOccurrences(of: " ", with: "_"),
            "overviewRecent": String(drawn.recent.count),
            "overviewPast": String(drawn.past.count),
            "overviewContinuable": String((drawn.recent + drawn.past).filter { $0.continuesTaskID != nil }.count),
            "overviewExpanded": String(expanded.count),
            "overviewDescription": expanded.first
                .flatMap { Gtk.find(named: "\($0).description", in: mainBox) }
                .flatMap { gtk_label_get_text(cast($0)) }.map { String(cString: $0) } ?? "",
            "overviewScratchpads": String(drawn.scratchpads.count),
            "overviewScratchpadTabs": String(adw_tab_view_get_n_pages(padTabs.view)),
            "overviewSelectedScratchpad": String(selectedScratchpadID.flatMap { automationScratchpadIDs.firstIndex(of: $0) } ?? -1),
            "overviewLiveScratchpads": String(drawn.scratchpads.filter(\.isLinked).count),
            "overviewPreview": preview == nil ? "none" : (previewDocument.map { "r\($0.revision)" } ?? "none"),
        ]
    }
}
#endif
