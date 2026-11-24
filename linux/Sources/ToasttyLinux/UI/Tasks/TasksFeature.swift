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
    private var renderScheduled = false
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
        guard renderScheduled == false else { return }
        renderScheduled = true
        MainLoop.idle(priority: Int32(G_PRIORITY_HIGH_IDLE)) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            let state = self.store.state
            for entry in self.features.values {
                entry.feature?.render(state)
            }
        }
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
}

/// One window's tasks UI (see `TasksUI`).
@MainActor
final class TasksWindowFeature: LinuxWindowFeature {
    static let tasksPageName = "tasks"

    let windowID: UUID
    private let ui: TasksUI
    private weak var controller: LinuxWindowController?
    let tasksPage: TasksPage
    let coordinatorUI: CoordinatorWindowUI
    let sidebarView: SidebarTasksView

    init(ui: TasksUI, controller: LinuxWindowController) {
        self.ui = ui
        self.controller = controller
        windowID = controller.windowID
        tasksPage = TasksPage(ui: ui, windowID: controller.windowID)
        coordinatorUI = CoordinatorWindowUI(ui: ui, controller: controller)
        sidebarView = SidebarTasksView(ui: ui, controller: controller)
        controller.sidebar.setAlternateContent(sidebarView.content)
        ui.register(self)
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

    var pages: [String: WidgetPtr] { [Self.tasksPageName: tasksPage.root] }

    func coveringPage(_ state: AppState) -> String? {
        guard ui.board.isEnabled, state.window(id: windowID)?.showsTasksView == true else { return nil }
        return Self.tasksPageName
    }

    var leadingColumn: WidgetPtr? { coordinatorUI.dockRoot }
    var sidebarHeader: WidgetPtr? { sidebarView.header }

    func render(_ state: AppState) {
        let shows = coveringPage(state) != nil
        tasksPage.render(state, isShown: shows)
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
        case "window.toggle-tasks-view":
            guard ui.board.isEnabled, let window = ui.store.state.window(id: windowID) else { return true }
            _ = ui.store.send(.setTasksViewShown(windowID: windowID, shown: window.showsTasksView == false))
            return true
        case "task.new":
            ui.board.newTask?()
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
        case "window.toggle-tasks-view": ui.board.isEnabled
        case "task.new": ui.board.newTask != nil
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
        let mark: WidgetPtr
        switch kind {
        case .working:
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
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
