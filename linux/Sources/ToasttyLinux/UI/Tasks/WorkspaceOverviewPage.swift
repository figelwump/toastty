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
/// - **About**: the synopsis an agent wrote, or one Toastty makes from the
///   tasks;
/// - **Recently**: the latest tasks and what each did (its agent's last
///   reply, kept after the session ends, else the request);
/// - **Tasks**: the workspace's tasks in the Tasks view's groups;
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
    private let padsList: WidgetPtr
    private let padsCount: WidgetPtr
    private let previewBox: WidgetPtr
    private let previewTitle: WidgetPtr
    private let previewOpen: WidgetPtr
    private let previewDelete: WidgetPtr
    private var preview: ScratchpadPanelController?
    private let previewPanelID = UUID()
    private var previewDocument: (id: UUID, revision: Int)?
    private(set) var workspaceID: UUID?
    private(set) var selectedScratchpadID: UUID?
    private var drawn: Drawn?
    private var serviceToken: UUID?
    /// Leaves the page for the workspace's own tabs.
    var onClose: (() -> Void)?

    /// What the page last drew, to skip rebuilding an unchanged page.
    private struct Drawn: Equatable {
        var workspaceID: UUID
        var title: String
        var subtitle: String
        var synopsis: WorkspaceOverviewModel.Synopsis
        var recent: [Recent]
        var tasks: [TasksPage.ListItem]
        var scratchpads: [WorkspaceOverviewModel.Scratchpad]
        var selectedScratchpadID: UUID?
    }

    struct Recent: Equatable {
        var subject: TaskBoardItem.Subject
        var title: String
        var mark: TaskStageMarkKind
        var status: String
        var pullRequest: Int?
        var age: String?
        var outcome: String?
        var outcomeIsRequest: Bool
        var taskSpaceWorkspaceID: UUID?
        /// The finished task Continue starts a new task from.
        var continuesTaskID: UUID?
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

        // Scratchpads column: the list, then the selected one's preview.
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
        padsList = Gtk.vbox(spacing: 2, classes: ["workspace-overview-pad-list"])
        let listScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(listScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(cast(listScroller), 1)
        gtk_scrolled_window_set_max_content_height(cast(listScroller), 240)
        gtk_scrolled_window_set_child(cast(listScroller), padsList)
        Gtk.append(side, listScroller)

        previewBox = Gtk.vbox(classes: ["workspace-overview-preview"])
        Gtk.setName(previewBox, "workspace.overview.preview")
        Gtk.expand(previewBox)
        let previewHeader = Gtk.hbox(spacing: 6, classes: ["workspace-overview-preview-header"])
        previewTitle = Gtk.label("", classes: ["tasks-row-title"])
        gtk_widget_set_hexpand(previewTitle, 1)
        Gtk.append(previewHeader, previewTitle)
        previewOpen = Gtk.iconButton("view-dual-symbolic", tooltip: "Open in the right panel")
        Gtk.setName(previewOpen, "workspace.overview.preview.open")
        Gtk.append(previewHeader, previewOpen)
        previewDelete = Gtk.iconButton("user-trash-symbolic", tooltip: "Delete from this workspace…")
        Gtk.setName(previewDelete, "workspace.overview.preview.delete")
        Gtk.append(previewHeader, previewDelete)
        Gtk.append(previewBox, previewHeader)
        Gtk.setVisible(previewBox, false)
        Gtk.append(side, previewBox)
        Gtk.append(root, side)

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
        self.workspaceID = workspaceID
        guard isShown, let workspaceID,
              let model = WorkspaceOverviewModel.make(workspaceID: workspaceID, service: ui.logic.workspaceOverview) else { return }
        if let selected = selectedScratchpadID, model.scratchpads.contains(where: { $0.entry.documentID == selected }) == false {
            selectedScratchpadID = nil
        }
        if selectedScratchpadID == nil { selectedScratchpadID = model.scratchpads.first?.entry.documentID }
        let now = Date()
        let next = Drawn(
            workspaceID: workspaceID,
            title: model.title,
            subtitle: Self.subtitle(model),
            synopsis: model.synopsis,
            recent: model.recent.map { Self.recent($0, now: now) },
            tasks: TasksPage.listItems(
                TasksViewSections.make(model.items), selectedID: nil,
                isDoneExpanded: true, isArchivedExpanded: true, now: now
            ),
            scratchpads: model.scratchpads,
            selectedScratchpadID: selectedScratchpadID
        )
        guard next != drawn else { return }
        drawn = next
        Gtk.setLabel(titleLabel, next.title)
        Gtk.setLabel(subtitleLabel, next.subtitle)
        rebuildMain(next)
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

    static func recent(_ recent: WorkspaceOverviewModel.RecentTask, now: Date) -> Recent {
        let item = recent.item
        return Recent(
            subject: item.id,
            title: item.title,
            mark: TaskStageMarkKind(item),
            status: TaskBoardPresentation.tasksViewStatusLine(item, now: now),
            pullRequest: item.pullRequest?.number,
            age: item.activityAt > .distantPast ? TaskAge.label(since: item.activityAt, now: now) : nil,
            outcome: recent.outcome.map(Self.plainExcerpt),
            outcomeIsRequest: recent.outcomeIsRequest,
            taskSpaceWorkspaceID: item.taskSpaceWorkspaceID,
            continuesTaskID: TaskBoardPresentation.canContinueAsNewTask(item) ? item.taskID : nil
        )
    }

    /// The first lines of an agent's markdown reply, as plain text.
    static func plainExcerpt(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false && $0.hasPrefix("```") == false && $0.hasPrefix("|") == false }
            .map { line -> String in
                var line = line
                while let first = line.first, "#>-*".contains(first) { line.removeFirst() }
                return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        return WorkspaceOverviewStore.clipped(lines.prefix(4).joined(separator: " "), to: 360)
    }

    // MARK: - Main column

    private func rebuildMain(_ drawn: Drawn) {
        Gtk.removeAllChildren(mainBox)

        let about = makeCard("About")
        Gtk.setName(about.card, "workspace.overview.about")
        let synopsis = Gtk.label(drawn.synopsis.text, classes: ["workspace-overview-synopsis"], ellipsize: false)
        gtk_label_set_wrap(cast(synopsis), 1)
        gtk_label_set_selectable(cast(synopsis), 1)
        Gtk.setName(synopsis, "workspace.overview.synopsis")
        Gtk.append(about.body, synopsis)
        let caption: String
        if drawn.synopsis.isWritten {
            caption = "Written by an agent" + (drawn.synopsis.updatedAt.map { " · \(TaskAge.label(since: $0, now: Date()))" } ?? "")
        } else {
            caption = "Made from the tasks. Ask an agent to describe this workspace and it writes one here."
        }
        let captionLabel = Gtk.label(caption, classes: ["tasks-why"], ellipsize: false)
        gtk_label_set_wrap(cast(captionLabel), 1)
        Gtk.append(about.body, captionLabel)
        Gtk.append(mainBox, about.card)

        let recent = makeCard("Recently")
        Gtk.setName(recent.card, "workspace.overview.recent")
        if drawn.recent.isEmpty {
            Gtk.append(recent.body, Gtk.label("No tasks yet. New Task starts one here.", classes: ["tasks-why"], ellipsize: false))
        }
        for (index, entry) in drawn.recent.enumerated() {
            Gtk.append(recent.body, makeRecentRow(entry, index: index))
        }
        Gtk.append(mainBox, recent.card)

        let tasks = makeCard("Tasks")
        Gtk.setName(tasks.card, "workspace.overview.tasks")
        let rows = drawn.tasks.filter { if case .row = $0 { return true } else { return false } }
        if rows.isEmpty {
            Gtk.append(tasks.body, Gtk.label("No tasks in this workspace.", classes: ["tasks-why"], ellipsize: false))
        } else {
            for item in drawn.tasks {
                switch item {
                case .header(let title, _, let count, let style, _, _):
                    guard count > 0 else { continue }
                    let line = Gtk.hbox(spacing: 8, classes: ["tasks-group"])
                    if style.isEmpty == false { Gtk.addClasses(line, [style]) }
                    Gtk.append(line, Gtk.label(title, classes: ["tasks-group-title"], ellipsize: false))
                    Gtk.append(line, Gtk.label("\(count)", classes: ["tasks-group-count"], ellipsize: false))
                    Gtk.append(tasks.body, line)
                case .lane:
                    continue
                case .row(let row):
                    Gtk.append(tasks.body, makeTaskRow(row))
                }
            }
        }
        Gtk.append(mainBox, tasks.card)
    }

    private func makeCard(_ title: String) -> (card: WidgetPtr, body: WidgetPtr) {
        let card = Gtk.vbox(classes: ["tasks-card", "workspace-overview-card"])
        Gtk.append(card, Gtk.label(title.uppercased(), classes: ["tasks-card-title"]))
        Gtk.append(card, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
        let body = Gtk.vbox(spacing: 8, classes: ["tasks-card-body"])
        Gtk.append(card, body)
        return (card, body)
    }

    private func makeRecentRow(_ entry: Recent, index: Int) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 10, classes: ["tasks-row", "workspace-overview-recent"])
        Gtk.setName(line, "workspace.overview.recent.\(index)")
        Gtk.append(line, TaskMarkWidget.make(entry.mark))
        let text = Gtk.vbox(spacing: 3)
        gtk_widget_set_hexpand(text, 1)
        Gtk.append(text, Gtk.label(entry.title, classes: ["tasks-row-title"]))
        let detail = Gtk.hbox(spacing: 8)
        if let number = entry.pullRequest {
            Gtk.append(detail, Gtk.label("PR #\(number)", classes: ["task-pr-tag"], ellipsize: false))
        }
        let status = Gtk.label(entry.status, classes: ["tasks-row-status"])
        gtk_widget_set_hexpand(status, 1)
        Gtk.append(detail, status)
        Gtk.append(text, detail)
        if let outcome = entry.outcome {
            let label = Gtk.label(
                entry.outcomeIsRequest ? "Asked: \(outcome)" : outcome,
                classes: ["workspace-overview-outcome"], ellipsize: false
            )
            gtk_label_set_wrap(cast(label), 1)
            gtk_label_set_lines(cast(label), 3)
            gtk_label_set_ellipsize(cast(label), PANGO_ELLIPSIZE_END)
            Gtk.append(text, label)
        }
        Gtk.append(line, text)
        if let age = entry.age {
            let label = Gtk.label(age, classes: ["tasks-row-age"], ellipsize: false)
            gtk_widget_set_valign(label, GTK_ALIGN_START)
            Gtk.append(line, label)
        }
        var continueButton: WidgetPtr?
        if let taskID = entry.continuesTaskID {
            let button = Gtk.button("Continue", classes: ["flat", "workspace-overview-continue"])
            continueButton = button
            gtk_widget_set_valign(button, GTK_ALIGN_START)
            gtk_widget_set_tooltip_text(button, "Continue as New Task: start a new task with this task's context attached")
            Gtk.setName(button, "workspace.overview.recent.\(index).continue")
            Signal.connect(button, "clicked") { [weak self] in
                self?.continueTask(taskID)
            }
            Gtk.append(line, button)
        }
        addOpen(line, subject: entry.subject, taskSpace: entry.taskSpaceWorkspaceID, excluding: continueButton)
        return line
    }

    /// Opens New Task with the finished task's context attached.
    func continueTask(_ taskID: UUID) {
        TaskActions.runFromMenu(.continueAsNewTask(taskID: taskID), coordinator: ui.coordinator) { _ in }
    }

    private func makeTaskRow(_ row: TasksPage.Row) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 10, classes: ["tasks-row"])
        Gtk.setClass(line, "child", row.isChild)
        Gtk.setName(line, "workspace.overview.task.\(TasksPage.rowName(row.subject))")
        gtk_widget_set_tooltip_text(line, row.accessibleLabel)
        Gtk.append(line, TaskMarkWidget.make(row.mark))
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
        Gtk.append(text, detail)
        Gtk.append(line, text)
        if let age = row.age {
            let label = Gtk.label(age, classes: ["tasks-row-age"], ellipsize: false)
            gtk_widget_set_valign(label, GTK_ALIGN_START)
            Gtk.append(line, label)
        }
        addOpen(line, subject: row.subject, taskSpace: row.taskSpaceWorkspaceID)
        return line
    }

    /// A click opens the task's space when it is open, else the task in the
    /// Tasks view.
    /// A press on `excluding` (the row's Continue button) is the button's.
    private func addOpen(_ line: WidgetPtr, subject: TaskBoardItem.Subject, taskSpace: UUID?, excluding: WidgetPtr? = nil) {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), guint(GDK_BUTTON_PRIMARY))
        Signal.connectPress(click) { [weak self] _, x, y in
            guard let self else { return }
            if let excluding, let picked = gtk_widget_pick(line, x, y, GTK_PICK_DEFAULT),
               picked == excluding || gtk_widget_is_ancestor(picked, excluding).bool {
                return
            }
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            self.open(subject: subject, taskSpace: taskSpace)
        }
        gtk_widget_add_controller(line, cast(click))
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
        Gtk.removeAllChildren(padsList)
        Gtk.setLabel(padsCount, drawn.scratchpads.isEmpty ? "" : "\(drawn.scratchpads.count)")
        if drawn.scratchpads.isEmpty {
            let empty = Gtk.label(
                "Keep a task's Scratchpad here with the pin in the right panel's header, or ask its agent to keep it. Kept Scratchpads stay after their task finishes.",
                classes: ["tasks-why", "workspace-overview-pads-empty"], ellipsize: false
            )
            gtk_label_set_wrap(cast(empty), 1)
            Gtk.setName(empty, "workspace.overview.scratchpads.empty")
            Gtk.append(padsList, empty)
        }
        for (index, pad) in drawn.scratchpads.enumerated() {
            Gtk.append(padsList, makePadRow(pad, index: index, isSelected: pad.entry.documentID == drawn.selectedScratchpadID))
        }
        updatePreview(drawn.scratchpads.first { $0.entry.documentID == drawn.selectedScratchpadID })
    }

    private func makePadRow(_ pad: WorkspaceOverviewModel.Scratchpad, index: Int, isSelected: Bool) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 8, classes: ["tasks-row", "workspace-overview-pad"])
        Gtk.setClass(line, "selected", isSelected)
        Gtk.setName(line, "workspace.overview.scratchpad.\(index)")
        Gtk.append(line, Gtk.image("text-x-generic-symbolic", pixelSize: 14, classes: ["workspace-overview-pad-icon"]))
        let text = Gtk.vbox(spacing: 2)
        gtk_widget_set_hexpand(text, 1)
        let titleLine = Gtk.hbox(spacing: 6)
        let title = Gtk.label(pad.title, classes: ["tasks-row-title"])
        gtk_widget_set_hexpand(title, 1)
        Gtk.append(titleLine, title)
        if pad.isLinked {
            let live = Gtk.label("Live", classes: ["task-tag", "workspace-overview-live"], ellipsize: false)
            gtk_widget_set_tooltip_text(live, "Its task is open: changes to the task's Scratchpad copy here.")
            Gtk.append(titleLine, live)
        }
        Gtk.append(text, titleLine)
        var detail: [String] = []
        if let task = pad.sourceTaskTitle { detail.append("From \(task)") }
        if let updated = pad.updatedAt { detail.append("updated \(TaskAge.label(since: updated, now: Date()))") }
        if pad.isMissing { detail = ["Its file is missing"] }
        Gtk.append(text, Gtk.label(detail.joined(separator: " · "), classes: ["tasks-row-status"]))
        if let purpose = pad.purpose, purpose.isEmpty == false {
            Gtk.append(text, Gtk.label(purpose, classes: ["tasks-why"]))
        }
        Gtk.append(line, text)
        let id = pad.entry.documentID
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), guint(GDK_BUTTON_PRIMARY))
        Signal.connectPress(click) { [weak self] count, _, _ in
            guard let self else { return }
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            if count == 2 {
                self.openScratchpad(id)
            } else {
                self.selectScratchpad(id)
            }
        }
        gtk_widget_add_controller(line, cast(click))
        return line
    }

    func selectScratchpad(_ documentID: UUID) {
        guard selectedScratchpadID != documentID else { return }
        selectedScratchpadID = documentID
        drawn = nil
        ui.scheduleRender()
    }

    private func updatePreview(_ pad: WorkspaceOverviewModel.Scratchpad?) {
        guard let pad, pad.isMissing == false, let webServices else {
            Gtk.setVisible(previewBox, false)
            preview?.close()
            preview.map { Gtk.unparentIfAttached($0.root) }
            preview = nil
            previewDocument = nil
            return
        }
        Gtk.setVisible(previewBox, true)
        Gtk.setLabel(previewTitle, pad.title)
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

    func automationOpenRecent(_ index: Int) -> Bool {
        guard let recent = drawn?.recent, recent.indices.contains(index) else { return false }
        open(subject: recent[index].subject, taskSpace: recent[index].taskSpaceWorkspaceID)
        return true
    }

    /// Continue on the Recent row at `index`, as a click does.
    func automationContinueRecent(_ index: Int) -> Bool {
        guard let recent = drawn?.recent, recent.indices.contains(index),
              let taskID = recent[index].continuesTaskID else { return false }
        continueTask(taskID)
        return true
    }

    var automationSummary: [String: String] {
        guard let drawn else { return ["overviewScratchpads": "0"] }
        let rows = drawn.tasks.filter { if case .row = $0 { return true } else { return false } }
        return [
            "overviewWorkspace": drawn.title.replacingOccurrences(of: " ", with: "_"),
            "overviewSynopsis": drawn.synopsis.isWritten ? "agent" : "toastty",
            "overviewRecent": String(drawn.recent.count),
            "overviewContinuable": String(drawn.recent.filter { $0.continuesTaskID != nil }.count),
            "overviewTasks": String(rows.count),
            "overviewScratchpads": String(drawn.scratchpads.count),
            "overviewLiveScratchpads": String(drawn.scratchpads.filter(\.isLinked).count),
            "overviewPreview": preview == nil ? "none" : (previewDocument.map { "r\($0.revision)" } ?? "none"),
        ]
    }
}
#endif
