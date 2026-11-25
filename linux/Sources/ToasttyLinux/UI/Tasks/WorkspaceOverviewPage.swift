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
            taskSpaceWorkspaceID: item.taskSpaceWorkspaceID
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
        addOpen(line, subject: entry.subject, taskSpace: entry.taskSpaceWorkspaceID)
        return line
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
    private func addOpen(_ line: WidgetPtr, subject: TaskBoardItem.Subject, taskSpace: UUID?) {
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), guint(GDK_BUTTON_PRIMARY))
        Signal.connectPress(click) { [weak self] _, _, _ in
            guard let self else { return }
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
        drawn = nil
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
        open(subject: recent[index].subject, taskSpace: recent[index].taskSpaceWorkspaceID)
        return true
    }

    var automationSummary: [String: String] {
        guard let drawn else { return ["overviewScratchpads": "0"] }
        let rows = drawn.tasks.filter { if case .row = $0 { return true } else { return false } }
        return [
            "overviewWorkspace": drawn.title.replacingOccurrences(of: " ", with: "_"),
            "overviewSynopsis": drawn.synopsis.isWritten ? "agent" : "toastty",
            "overviewRecent": String(drawn.recent.count),
            "overviewTasks": String(rows.count),
            "overviewScratchpads": String(drawn.scratchpads.count),
            "overviewScratchpadTabs": String(adw_tab_view_get_n_pages(padTabs.view)),
            "overviewSelectedScratchpad": String(selectedScratchpadID.flatMap { automationScratchpadIDs.firstIndex(of: $0) } ?? -1),
            "overviewLiveScratchpads": String(drawn.scratchpads.filter(\.isLinked).count),
            "overviewPreview": preview == nil ? "none" : (previewDocument.map { "r\($0.revision)" } ?? "none"),
        ]
    }
}
#endif
