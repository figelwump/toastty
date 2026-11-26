#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
import OpenCombine
// The task and coordinator views bind to the shared view models
// (TaskBoardStore, CoordinatorChatModel, QuickEntryModel …), which are
// internal to the app layer. ToasttyAppLogic builds with testing enabled
// for this; see docs/linux.md "Tasks UI".
@testable import ToasttyAppLogic

/// Tasks and the coordinator in every window: the Tasks view, the
/// coordinator's dock, the sidebar's Tasks rows and their commands. macOS
/// draws the same from `TasksView`, `CoordinatorDockView` and
/// `SidebarTasksHeader`.
@MainActor
final class TasksUI {
    let logic: LinuxAppLogic
    var tasks: LinuxTaskStack { logic.tasks }
    var board: TaskBoardStore { tasks.board }
    var coordinator: TaskCoordinator { tasks.coordinator }
    var store: AppStore { logic.store }
    var sessionRuntimeStore: SessionRuntimeStore { logic.sessionRuntimeStore }
    private var features: [UUID: WeakFeature] = [:]
    private var subscriptions: [AnyCancellable] = []
    private lazy var renderScheduler = RenderScheduler("tasks") { [weak self] in
        guard let self else { return }
        let state = self.store.state
        for entry in self.features.values {
            entry.feature?.renderBoardChange(state)
        }
    }
    /// Quick entry's GTK window (`QuickEntryPresentation.frontend` holds it
    /// weakly).
    var quickEntryFrontend: QuickEntryWindowFrontend?
    /// Where the What's new answer is kept (nil in an automation run).
    var startOfferDefaults: UserDefaults?

    private struct WeakFeature {
        weak var feature: TasksWindowFeature?
    }

    init(logic: LinuxAppLogic) {
        self.logic = logic
        // What the board shows changes without an AppStore action: a pull
        // request's state, a record, a session.
        subscriptions.append(board.objectWillChange.sink { [weak self] _ in self?.scheduleRender() })
        if let controller = tasks.coordinatorController {
            subscriptions.append(controller.objectWillChange.sink { [weak self] _ in self?.scheduleRender() })
        }
        if let webhooks = coordinator.webhooks {
            subscriptions.append(webhooks.objectWillChange.sink { [weak self] _ in self?.scheduleRender() })
        }
    }

    func register(_ feature: TasksWindowFeature) {
        features[feature.windowID] = WeakFeature(feature: feature)
    }

    func feature(windowID: UUID) -> TasksWindowFeature? {
        features[windowID]?.feature
    }

    /// Redraws every window's task views on the next idle turn, after the
    /// change the publisher announced has happened.
    func scheduleRender() {
        renderScheduler.schedule()
    }

    /// Opens a task's space, from a row or a link.
    func openTaskSpace(_ workspaceID: UUID, windowID: UUID) {
        TaskActions.openTaskSpace(
            workspaceID: workspaceID,
            fallbackWindowID: windowID,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
    }

    /// Workspace actions use the Tasks menu's checks and coordinator. Keep
    /// completion nonblocking and recheck the action after the dialog.
    func runWorkspaceTaskMenuItem(
        _ menuItem: TaskBoardPresentation.MenuItem,
        windowID: UUID,
        parent: WidgetPtr,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        guard isCurrent() else { return }
        guard case .action(.markDone, let taskID, _) = menuItem else {
            TaskActions.runFromMenu(menuItem, coordinator: coordinator) { workspaceID in
                self.openTaskSpace(workspaceID, windowID: windowID)
            }
            return
        }

        func canMarkDone() -> Bool {
            guard isCurrent(), let item = board.items().first(where: { $0.taskID == taskID }) else { return false }
            return TaskBoardPresentation.detailActions(item).contains(.markDone)
        }
        guard canMarkDone(), let record = coordinator.records.record(id: taskID) else { return }
        let failureTitle = TaskBoardPresentation.DetailAction.markDone.failureTitle
        TaskActions.perform(failureTitle) {
            let check = try coordinator.completeCheck(taskID: taskID)
            guard check.unsavedDocuments == 0 else {
                throw TaskError("The task space has unsaved documents. Save or close them, then complete the task.")
            }
            Dialogs.confirm(
                parent: parent, heading: "Complete “\(record.title)”?",
                body: TaskActions.completeSummary(check).joined(separator: "\n"),
                confirmLabel: "Complete Task", destructive: false, confirmIsDefault: true
            ) {
                guard canMarkDone() else { return }
                TaskActions.perform(failureTitle) { try self.coordinator.complete(taskID: taskID) }
            }
        }
    }
}

/// One window's tasks UI (see `TasksUI`).
@MainActor
final class TasksWindowFeature: LinuxWindowFeature {
    static let tasksPageName = "tasks"
    static let overviewPageName = "workspace-overview"

    let windowID: UUID
    private let ui: TasksUI
    private weak var controller: LinuxWindowController?
    let tasksPage: TasksPage
    let coordinatorUI: CoordinatorWindowUI
    let sidebarView: SidebarTasksView
    let workspaceTaskControl: WorkspaceTaskControl
    let overviewPage: WorkspaceOverviewPage
    /// The workspace page shows for this workspace while it stays selected
    /// on this tab (see `coveringPage`).
    private(set) var overviewWorkspaceID: UUID?
    private var overviewTabID: UUID?
    /// The right panel header's Keep in Workspace pin.
    let keepButton: WidgetPtr

    init(ui: TasksUI, controller: LinuxWindowController) {
        self.ui = ui
        self.controller = controller
        windowID = controller.windowID
        tasksPage = TasksPage(ui: ui, windowID: controller.windowID)
        coordinatorUI = CoordinatorWindowUI(ui: ui, controller: controller)
        sidebarView = SidebarTasksView(ui: ui, controller: controller)
        workspaceTaskControl = WorkspaceTaskControl(ui: ui, controller: controller)
        overviewPage = WorkspaceOverviewPage(
            ui: ui, windowID: controller.windowID,
            webServices: (controller.hosts.rightPanel as? WebPanelHost)?.services ?? (controller.hosts.web as? WebPanelHost)?.services
        )
        keepButton = Gtk.iconButton("view-pin-symbolic", tooltip: "Keep in Workspace")
        Gtk.setName(keepButton, "right-panel.keep-in-workspace")
        Gtk.setVisible(keepButton, false)
        controller.rightPanel.addHeaderEndWidget(keepButton)
        controller.sidebar.setAlternateContent(sidebarView.content)
        ui.register(self)
        overviewPage.onClose = { [weak self] in self?.closeOverview() }
        Signal.connect(keepButton, "clicked") { [weak self] in
            guard let self else { return }
            if self.activeRightPanelWeb(self.ui.store.state)?.web.definition == .browser {
                self.pinActiveBrowser()
            } else {
                self.keepActiveScratchpad()
            }
        }
        // The What's new question shows over the window that gets the
        // keyboard, as on macOS.
        let windowID = controller.windowID
        let window = controller.window
        Signal.notify(window, "is-active") { [weak ui] in
            guard gtk_window_is_active(cast(window)).bool else { return }
            ui?.offerStartIfNeeded(windowID: windowID)
        }
        // And once the window is on screen, as macOS asks when its window
        // scene appears.
        MainLoop.timeout(milliseconds: 400) { [weak ui] in
            if gtk_widget_get_mapped(window).bool { ui?.offerStartIfNeeded(windowID: windowID) }
            return false
        }
    }

    var pages: [String: WidgetPtr] { [Self.tasksPageName: tasksPage.root, Self.overviewPageName: overviewPage.root] }

    func coveringPage(_ state: AppState) -> String? {
        guard ui.board.isEnabled, let window = state.window(id: windowID) else { return nil }
        if window.showsTasksView { return Self.tasksPageName }
        return overviewIsShown(state) ? Self.overviewPageName : nil
    }

    func hidesWorkspaceTabBar(on page: String) -> Bool { page == Self.overviewPageName }

    // MARK: - Workspace page

    /// The page shows while its workspace stays selected on the tab it was
    /// opened over. Selecting anything else, or another tab, leaves it.
    func overviewIsShown(_ state: AppState) -> Bool {
        guard let overviewWorkspaceID, let selection = state.workspaceSelection(in: windowID),
              selection.workspaceID == overviewWorkspaceID,
              selection.workspace.selectedTabID == overviewTabID else { return false }
        return true
    }

    /// What a top-level workspace card's title does: shows the workspace's
    /// page, or, when it already shows, returns to the workspace's own tabs.
    func toggleOverview(workspaceID: UUID) {
        if overviewIsShown(ui.store.state), overviewWorkspaceID == workspaceID {
            closeOverview()
            return
        }
        showOverview(workspaceID: workspaceID, selectingScratchpad: nil)
    }

    func showOverview(workspaceID: UUID, selectingScratchpad documentID: UUID?) {
        guard let topLevel = ui.logic.workspaceOverview.topLevelWorkspaceID(for: workspaceID) else { return }
        if ui.store.state.window(id: windowID)?.selectedWorkspaceID != topLevel || ui.store.state.window(id: windowID)?.showsTasksView == true {
            _ = ui.logic.sendNavigation([.selectWorkspace(windowID: windowID, workspaceID: topLevel)])
        }
        overviewWorkspaceID = topLevel
        overviewTabID = ui.store.state.workspacesByID[topLevel]?.selectedTabID
        if let documentID { overviewPage.selectScratchpad(documentID) }
        controller?.scheduleRender()
        ui.scheduleRender()
        MainLoop.idle { [weak self] in
            guard let self, self.overviewIsShown(self.ui.store.state) else { return }
            gtk_widget_grab_focus(self.overviewPage.root)
        }
    }

    func closeOverview() {
        guard overviewWorkspaceID != nil else { return }
        overviewWorkspaceID = nil
        overviewTabID = nil
        controller?.scheduleRender()
        MainLoop.idle { [weak self] in self?.controller?.content.refocus() }
    }

    private func activeRightPanelWeb(_ state: AppState) -> (workspaceID: UUID, panelID: UUID, web: WebPanelState)? {
        guard let selection = state.workspaceSelection(in: windowID),
              selection.workspace.rightAuxPanel.isVisible,
              let panelID = selection.workspace.rightAuxPanel.activePanelID,
              case .web(let web)? = selection.workspace.allPanelsByID[panelID] else { return nil }
        return (selection.workspaceID, panelID, web)
    }

    private func activeRightPanelScratchpad(_ state: AppState) -> (panelID: UUID, documentID: UUID)? {
        guard let active = activeRightPanelWeb(state), active.web.definition == .scratchpad,
              let documentID = active.web.scratchpad?.documentID else { return nil }
        return (active.panelID, documentID)
    }

    private func renderKeepButton(_ state: AppState) {
        let service = ui.logic.workspaceOverview
        if let active = activeRightPanelWeb(state),
           let url = WorkspaceOverviewService.pinnableBrowserURL(active.web),
           let workspaceID = service.topLevelWorkspaceID(for: active.workspaceID, state: state) {
            let pinned = service.browserPins(forWorkspace: workspaceID).contains { $0.url == url }
            Gtk.setVisible(keepButton, true)
            Gtk.setClass(keepButton, "kept", pinned)
            gtk_widget_set_tooltip_text(
                keepButton,
                pinned ? "Pinned in Workspace: show it on the workspace page" : "Pin this browser page to the workspace"
            )
            return
        }
        guard let active = activeRightPanelScratchpad(state) else {
            Gtk.setVisible(keepButton, false)
            return
        }
        let kept = service.entry(documentID: active.documentID) ?? service.linkedEntry(sourceDocumentID: active.documentID)
        Gtk.setVisible(keepButton, true)
        Gtk.setClass(keepButton, "kept", kept != nil)
        gtk_widget_set_tooltip_text(
            keepButton,
            kept == nil ? "Keep in Workspace: save this Scratchpad on the workspace page, where it stays after the task" : "Kept in Workspace: show it on the workspace page"
        )
    }

    private func pinActiveBrowser() {
        guard let active = activeRightPanelWeb(ui.store.state) else { return }
        do {
            let result = try ui.logic.workspaceOverview.pinBrowser(panelID: active.panelID)
            if result.created {
                let title = ui.store.state.workspacesByID[result.workspaceID]?.title ?? "the workspace"
                controller?.toast("Pinned in \(title)")
                ui.scheduleRender()
            } else {
                showOverview(workspaceID: result.workspaceID, selectingScratchpad: nil)
            }
        } catch {
            controller?.toast(error.localizedDescription)
        }
    }

    /// Keeps the right panel's Scratchpad in its workspace, or shows the
    /// copy on the workspace page when it is kept already.
    private func keepActiveScratchpad() {
        guard let active = activeRightPanelScratchpad(ui.store.state) else {
            controller?.toast("Show a Scratchpad in the right panel first")
            return
        }
        let service = ui.logic.workspaceOverview
        do {
            let result = try service.keep(panelID: active.panelID, keptBy: "user")
            if result.created {
                let title = ui.store.state.workspacesByID[result.entry.workspaceID]?.title ?? "the workspace"
                controller?.toast("Kept in \(title)")
                ui.scheduleRender()
            } else {
                showOverview(workspaceID: result.entry.workspaceID, selectingScratchpad: result.entry.documentID)
            }
        } catch {
            controller?.toast(error.localizedDescription)
        }
    }

    var leadingColumn: WidgetPtr? { coordinatorUI.dockRoot }
    var sidebarHeader: WidgetPtr? { sidebarView.header }
    var workspaceHeaderControls: WidgetPtr? { workspaceTaskControl.root }

    func renderBoardChange(_ state: AppState) {
        render(state)
        controller?.updateWorkspaceHeader()
    }

    func render(_ state: AppState) {
        let covering = coveringPage(state)
        let shows = covering == Self.tasksPageName
        if overviewWorkspaceID != nil, overviewIsShown(state) == false {
            overviewWorkspaceID = nil
            overviewTabID = nil
        }
        workspaceTaskControl.render(state)
        tasksPage.render(state, isShown: shows)
        overviewPage.render(workspaceID: overviewWorkspaceID, isShown: covering == Self.overviewPageName)
        renderKeepButton(state)
        coordinatorUI.render(state)
        if let controller {
            // The bucketed sidebar replaces the workspace list while tasks
            // are on, as on macOS.
            controller.sidebar.showsAlternateContent = ui.board.isEnabled
            sidebarView.render(state, sessions: controller.sessions)
        }
    }

    func perform(commandID: String) -> Bool {
        switch commandID {
        case "workspace.merge":
            return workspaceTaskControl.performMergeShortcut()
        case "window.toggle-tasks-view":
            guard ui.board.isEnabled, let window = ui.store.state.window(id: windowID) else { return true }
            _ = ui.store.send(.setTasksViewShown(windowID: windowID, shown: window.showsTasksView == false))
            return true
        case "task.new":
            ui.board.newTask?()
            return true
        case "scratchpad.keep-in-workspace":
            keepActiveScratchpad()
            return true
        case "browser.pin-in-workspace":
            pinActiveBrowser()
            return true
        case "workspace.overview.toggle":
            if let workspaceID = ui.store.state.window(id: windowID)?.selectedWorkspaceID {
                toggleOverview(workspaceID: workspaceID)
            }
            return true
        case let id where id.hasPrefix("task.palette."):
            return performPaletteTaskCommand(id)
        case "coordinator.dock.toggle":
            coordinatorUI.performDockShortcut()
            return true
        case "coordinator.open":
            coordinatorUI.perform(.open)
            return true
        case "coordinator.restart":
            coordinatorUI.perform(.restart)
            return true
        // While a chat's field has the keyboard, the text size keys size
        // the chat, not the terminals.
        case "text-size.increase":
            return coordinatorUI.changeTextScale(.increase)
        case "text-size.decrease":
            return coordinatorUI.changeTextScale(.decrease)
        case "text-size.reset":
            return coordinatorUI.changeTextScale(.reset)
        default:
            return false
        }
    }

    func isEnabled(commandID: String, state: AppState) -> Bool? {
        switch commandID {
        case "workspace.merge": workspaceTaskControl.canMerge(state)
        case "window.toggle-tasks-view": ui.board.isEnabled
        case "task.new": ui.board.newTask != nil
        case "scratchpad.keep-in-workspace": activeRightPanelScratchpad(state) != nil
        case "browser.pin-in-workspace": activeRightPanelWeb(state).flatMap { WorkspaceOverviewService.pinnableBrowserURL($0.web) } != nil
        case "workspace.overview.toggle": state.window(id: windowID)?.selectedWorkspaceID != nil
        case "coordinator.dock.toggle", "coordinator.open": ui.tasks.coordinatorController != nil
        case "coordinator.restart": ui.tasks.coordinatorController?.location != nil
        default: nil
        }
    }

    // MARK: - Palette

    /// macOS `CommandPaletteTaskCatalog`: "Task: <action>" for the current
    /// task (the Tasks view's row while it shows, else the selected task
    /// space's task), its pull request and task space, Restart Coordinator
    /// once it is open, and the dock's toggle in the coordinator's window.
    func paletteItems(_ state: AppState) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let current = currentTask() {
            let item = current.item
            let subtitle = "\(item.title) · \(TaskBoardPresentation.stageDescription(item).stage)"
            let keywords = ["task", "done", "merge", "archive", "ship"]
            for action in TaskBoardPresentation.detailActions(item) {
                items.append(PaletteItem(
                    id: "task.palette.action.\(action)", title: "Task: \(action.title)", subtitle: subtitle,
                    keywords: keywords + ["\(action)"],
                    accelerator: action == .merge && current.source == .selectedTaskSpace && current.hasMergeButton ? "<Alt><Shift>m" : nil
                ))
            }
            if let link = item.pullRequest, URL(string: link.url) != nil {
                items.append(PaletteItem(id: "task.palette.pull-request", title: "Task: Open PR #\(link.number)", subtitle: subtitle,
                                         keywords: keywords + ["open", "pr", "pull", "request", "github"]))
            }
            if current.source == .tasksView, item.taskSpaceWorkspaceID != nil {
                items.append(PaletteItem(id: "task.palette.task-space", title: "Task: Open Task Space", subtitle: subtitle,
                                         keywords: keywords + ["open", "space", "workspace"]))
            }
        }
        if ui.board.isEnabled, let selected = ui.store.state.window(id: windowID)?.selectedWorkspaceID {
            let shows = overviewIsShown(ui.store.state)
            let title = ui.store.state.workspacesByID[ui.logic.workspaceOverview.topLevelWorkspaceID(for: selected) ?? selected]?.title ?? "Workspace"
            items.append(PaletteItem(
                id: "workspace.overview.toggle",
                title: shows ? "Hide Workspace Page" : "Show Workspace Page",
                subtitle: shows ? nil : "\(title): its synopsis, latest tasks and kept Scratchpads",
                keywords: ["workspace", "page", "overview", "history", "synopsis", "scratchpad", "summary"]
            ))
        }
        if activeRightPanelScratchpad(ui.store.state) != nil {
            items.append(PaletteItem(
                id: "scratchpad.keep-in-workspace",
                title: "Keep Scratchpad in Workspace",
                subtitle: "Save the right panel's Scratchpad on its workspace page",
                keywords: ["scratchpad", "keep", "pin", "promote", "sticky", "workspace", "save"]
            ))
        }
        if isEnabled(commandID: "browser.pin-in-workspace", state: state) == true {
            items.append(PaletteItem(
                id: "browser.pin-in-workspace",
                title: "Pin Browser Page to Workspace",
                subtitle: "Save the right panel’s current address on its workspace page",
                keywords: ["browser", "bookmark", "pin", "workspace", "save"]
            ))
        }
        if let controller = ui.tasks.coordinatorController {
            if controller.location != nil {
                items.append(PaletteItem(id: "coordinator.restart", title: "Restart Coordinator",
                                         subtitle: "Starts a fresh agent session in the coordinator's workspace",
                                         keywords: ["coordinator", "agent", "restart", "start", "new", "session"]))
            }
            if CoordinatorDockPresentation.showsToggle(windowID: windowID, coordinator: controller.location, chatAvailable: controller.chatIsAvailable) {
                let shows = controller.dockShows(in: windowID)
                items.append(PaletteItem(id: "coordinator.dock.toggle", title: CoordinatorDockPresentation.toggleTitle(dockShows: shows),
                                         subtitle: shows ? nil : "The coordinator's chat beside your workspace",
                                         keywords: ["coordinator", "dock", "chat", "show", "hide", "toggle"],
                                         accelerator: "<Control><Shift>k"))
            }
        }
        return items
    }

    private func currentTask() -> TaskBoardCurrentTask? {
        guard let selection = ui.store.commandSelection(preferredWindowID: windowID) else { return nil }
        return ui.board.currentTask(in: selection) { [weak ui] in ui?.sessionRuntimeStore.workspaceStatuses(for: $0) ?? [] }
    }

    /// Runs a palette row for the current task. The task may have moved on
    /// since the palette listed it.
    private func performPaletteTaskCommand(_ commandID: String) -> Bool {
        guard let item = currentTask()?.item else {
            controller?.toast("No current task")
            return true
        }
        if commandID == "task.palette.pull-request" {
            if let url = item.pullRequest.flatMap({ URL(string: $0.url) }) {
                _ = DesktopLauncher.open(url, parent: controller?.window)
            }
            return true
        }
        if commandID == "task.palette.task-space" {
            if let workspaceID = item.taskSpaceWorkspaceID { ui.openTaskSpace(workspaceID, windowID: windowID) }
            return true
        }
        let name = String(commandID.dropFirst("task.palette.action.".count))
        guard let record = item.record,
              let action = TaskBoardPresentation.detailActions(item).first(where: { "\($0)" == name }) else { return true }
        do {
            try TaskActions.run(action, taskID: record.id, coordinator: ui.coordinator)
        } catch {
            TaskActions.presentFailure("\(action.failureTitle) \(record.title)", error.localizedDescription)
        }
        return true
    }

    func teardown() {
        tasksPage.teardown()
        overviewPage.teardown()
        coordinatorUI.teardown()
        sidebarView.teardown()
    }

    func toast(_ message: String) {
        controller?.toast(message)
    }
}

extension LinuxAppController {
    /// Installs tasks and the coordinator in every window (app-logic runs).
    func installTasksUI(logic: LinuxAppLogic) {
        let ui = TasksUI(logic: logic)
        hosts.windowFeatureFactories.append { controller in
            TasksWindowFeature(ui: ui, controller: controller)
        }
        tasksUI = ui
        // Quick entry's window and the desktop-wide key. The app layer read
        // the key before this frontend existed: read it again.
        let quickEntry = QuickEntryWindowFrontend(application: application) { [weak self] message in
            self?.selectedWindowController()?.toast(message)
        }
        ui.quickEntryFrontend = quickEntry
        QuickEntryPresentation.frontend = quickEntry
        // The key waits for the What's new question (a first launch).
        ui.installStartOffer(app: self)
        ui.tasks.quickEntry.loadShortcutAtLaunch()
        GhosttyTerminalHost.newTaskFromSelection = { [weak ui] text, panelID in
            ui?.tasks.quickEntry.presentFromSelection(text, panelID: panelID)
        }
        installTasksAutomation(ui: ui)
        installCoordinatorAutomation(ui: ui)
    }
}

// MARK: - Marks

/// A task's square mark (macOS `TaskStageMark`), drawn with CSS: a 12×16
/// slot holding a tinted box, a glyph or a spinner.
@MainActor
enum TaskMarkWidget {
    static func make(_ kind: TaskStageMarkKind) -> WidgetPtr {
        let slot = Gtk.hbox(classes: ["task-mark-slot"])
        gtk_widget_set_size_request(slot, 12, 16)
        gtk_widget_set_valign(slot, GTK_ALIGN_START)
        // The mark below expands to center itself, and GTK passes a child's
        // expand up to its parent. Without this the slot would share the
        // row's spare width with the text, and the mark would move whenever
        // the row's text changed length (a running task's status line).
        gtk_widget_set_hexpand(slot, 0)
        let mark: WidgetPtr
        switch kind {
        case .working:
            let spinner = toastty_clock_spinner_new()!
            gtk_widget_set_size_request(spinner, 9, 9)
            mark = spinner
        case .question:
            mark = Gtk.label("?", classes: ["task-mark", "question"], xalign: 0.5, ellipsize: false)
        case .toShip:
            mark = Gtk.label("↑", classes: ["task-mark", "to-ship"], xalign: 0.5, ellipsize: false)
        case .done:
            mark = Gtk.label("✓", classes: ["task-mark", "done"], xalign: 0.5, ellipsize: false)
        case .archived:
            mark = Gtk.label("✕", classes: ["task-mark", "archived"], xalign: 0.5, ellipsize: false)
        case .waiting:
            mark = Gtk.image("alarm-symbolic", pixelSize: 10, classes: ["task-mark-icon", "waiting"])
        case .review:
            let box = Gtk.hbox(classes: ["task-mark", "review"])
            let dot = Gtk.hbox(classes: ["task-mark-dot"])
            gtk_widget_set_halign(dot, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
            gtk_widget_set_hexpand(dot, 1)
            Gtk.append(box, dot)
            mark = box
        case .starting, .setupProblem, .error, .ready, .needsInput, .quiet:
            mark = Gtk.hbox(classes: ["task-mark", Self.cssClass(kind)])
        }
        gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(mark, 1)
        Gtk.append(slot, mark)
        Gtk.setName(slot, "task-mark.\(Self.cssClass(kind))")
        return slot
    }

    /// The drawn width of each mark slot under `root`, in tree order, for
    /// automation: every slot is 12 wide, whatever the row's text.
    static func slotWidths(in root: WidgetPtr) -> [Int32] {
        if let name = gtk_widget_get_name(root), String(cString: name).hasPrefix("task-mark.") {
            return gtk_widget_get_mapped(root).bool ? [gtk_widget_get_width(root)] : []
        }
        return Gtk.children(root).flatMap { slotWidths(in: $0) }
    }

    static func cssClass(_ kind: TaskStageMarkKind) -> String {
        switch kind {
        case .starting: "starting"
        case .review: "review"
        case .question: "question"
        case .setupProblem: "setup-problem"
        case .error: "error"
        case .ready: "ready"
        case .needsInput: "needs-input"
        case .working: "working"
        case .waiting: "waiting"
        case .quiet: "quiet"
        case .toShip: "to-ship"
        case .done: "done"
        case .archived: "archived"
        }
    }
}
#endif
