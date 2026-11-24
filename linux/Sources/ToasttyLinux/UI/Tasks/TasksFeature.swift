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

    init(ui: TasksUI, controller: LinuxWindowController) {
        self.ui = ui
        self.controller = controller
        windowID = controller.windowID
        tasksPage = TasksPage(ui: ui, windowID: controller.windowID)
        coordinatorUI = CoordinatorWindowUI(ui: ui, controller: controller)
        ui.register(self)
    }

    var pages: [String: WidgetPtr] { [Self.tasksPageName: tasksPage.root] }

    func coveringPage(_ state: AppState) -> String? {
        guard ui.board.isEnabled, state.window(id: windowID)?.showsTasksView == true else { return nil }
        return Self.tasksPageName
    }

    var leadingColumn: WidgetPtr? { coordinatorUI.dockRoot }
    var sidebarHeader: WidgetPtr? { nil }

    func render(_ state: AppState) {
        let shows = coveringPage(state) != nil
        tasksPage.render(state, isShown: shows)
        coordinatorUI.render(state)
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

    func teardown() {
        tasksPage.teardown()
        coordinatorUI.teardown()
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
        ui.tasks.quickEntry.loadShortcutAtLaunch()
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
