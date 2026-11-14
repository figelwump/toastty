import AppKit
import CoreState
import Foundation

/// A palette command for tasks: one of the current task's actions, or a
/// release of a project.
enum PaletteTaskCommand: Equatable, Sendable {
    case action(TaskBoardPresentation.DetailAction, subject: TaskBoardItem.Subject)
    case openPullRequest(subject: TaskBoardItem.Subject)
    case openTaskSpace(subject: TaskBoardItem.Subject)
    case release(workspaceID: UUID)
    case openCoordinator
    case restartCoordinator
    case toggleCoordinatorDock
}

/// What the palette offers for the coordinator.
struct PaletteCoordinatorOption: Equatable {
    /// The coordinator's workspace is open, so it can restart.
    let isOpen: Bool
    /// Whether the dock shows, in the window that holds the coordinator's
    /// workspace. `nil` in other windows, and where the chat cannot show.
    var dockShows: Bool? = nil
}

/// An open project that can release from Toastty, so the palette can start
/// a release.
struct PaletteTaskReleaseOption: Equatable {
    let workspaceID: UUID
    let projectTitle: String
    let projectRoot: String
    let toShipCount: Int
}

/// The palette's task commands: "Task: <action>" for the current task, and
/// "Release <project>…" for each project that can release.
@MainActor
enum CommandPaletteTaskCatalog {
    static let keywords = ["task", "done", "merge", "archive", "ship"]

    static func descriptors(
        current: TaskBoardCurrentTask?,
        releases: [PaletteTaskReleaseOption],
        coordinator: PaletteCoordinatorOption? = nil
    ) -> [PaletteCommandDescriptor] {
        currentTaskDescriptors(current) + releases.map(releaseDescriptor) + coordinatorDescriptors(coordinator)
    }

    /// "Open Coordinator" while the task system is on, "Restart
    /// Coordinator" once the coordinator's workspace is open, and "Show
    /// Coordinator Dock" or "Hide Coordinator Dock" in its window.
    private static func coordinatorDescriptors(_ option: PaletteCoordinatorOption?) -> [PaletteCommandDescriptor] {
        guard let option else { return [] }
        var descriptors = [PaletteCommandDescriptor(
            id: "coordinator.open",
            usageKey: "coordinator.open",
            title: "Open Coordinator",
            subtitle: nil,
            keywords: ["coordinator", "agent", "tasks", "open", "show"],
            shortcut: nil,
            invocation: .task(.openCoordinator)
        )]
        if option.isOpen {
            descriptors.append(PaletteCommandDescriptor(
                id: "coordinator.restart",
                usageKey: "coordinator.restart",
                title: "Restart Coordinator",
                subtitle: "Starts a fresh agent session in the coordinator's workspace",
                keywords: ["coordinator", "agent", "restart", "start", "new", "session"],
                shortcut: nil,
                invocation: .task(.restartCoordinator)
            ))
        }
        if let dockShows = option.dockShows {
            descriptors.append(PaletteCommandDescriptor(
                id: "coordinator.dock.toggle",
                usageKey: "coordinator.dock.toggle",
                title: CoordinatorDockPresentation.toggleTitle(dockShows: dockShows),
                subtitle: dockShows ? nil : "The coordinator's chat beside your workspace",
                keywords: ["coordinator", "dock", "chat", "show", "hide", "toggle", "panel", "left"],
                shortcut: PaletteShortcut(ToasttyKeyboardShortcuts.toggleCoordinatorDock),
                invocation: .task(.toggleCoordinatorDock)
            ))
        }
        return descriptors
    }

    /// The detail pane's actions for the task, in its order, then its pull
    /// request and task space. Each row names the task, so a wrong guess
    /// about which task is current shows before anything runs.
    private static func currentTaskDescriptors(_ current: TaskBoardCurrentTask?) -> [PaletteCommandDescriptor] {
        guard let current else { return [] }
        let item = current.item
        let subtitle = "\(item.title) · \(TaskBoardPresentation.stageDescription(item).stage)"
        var descriptors = TaskBoardPresentation.detailActions(item).map { action in
            // Option+Shift+M runs the selected task space's Merge button,
            // which is this Merge. It does not follow the Tasks view's row.
            let shortcut = action == .merge && current.source == .selectedTaskSpace && current.hasMergeButton
                ? PaletteShortcut(ToasttyKeyboardShortcuts.mergeWorkspacePullRequest)
                : nil
            return descriptor(
                key: "task.action.\(action)",
                title: "Task: \(action.title)",
                subtitle: subtitle,
                keywords: actionKeywords(action),
                shortcut: shortcut,
                command: .action(action, subject: item.id)
            )
        }
        if let link = item.pullRequest, URL(string: link.url) != nil {
            descriptors.append(descriptor(
                key: "task.open-pull-request",
                title: "Task: Open PR #\(link.number)",
                subtitle: subtitle,
                keywords: ["open", "pr", "pull", "request", "github"],
                command: .openPullRequest(subject: item.id)
            ))
        }
        if current.source == .tasksView, item.taskSpaceWorkspaceID != nil {
            descriptors.append(descriptor(
                key: "task.open-task-space",
                title: "Task: Open Task Space",
                subtitle: subtitle,
                keywords: ["open", "task", "space", "workspace"],
                command: .openTaskSpace(subject: item.id)
            ))
        }
        return descriptors
    }

    private static func releaseDescriptor(_ option: PaletteTaskReleaseOption) -> PaletteCommandDescriptor {
        let count = option.toShipCount
        return PaletteCommandDescriptor(
            id: "task.release.\(option.workspaceID.uuidString)",
            usageKey: "task.release:\(option.projectRoot)",
            title: "Release \(option.projectTitle)…",
            subtitle: count == 0 ? "Nothing to ship yet" : "\(count) \(count == 1 ? "task" : "tasks") to ship",
            keywords: ["release", "ship", "tag", "task", option.projectTitle],
            shortcut: nil,
            invocation: .task(.release(workspaceID: option.workspaceID))
        )
    }

    private static func descriptor(
        key: String,
        title: String,
        subtitle: String,
        keywords: [String],
        shortcut: PaletteShortcut? = nil,
        command: PaletteTaskCommand
    ) -> PaletteCommandDescriptor {
        PaletteCommandDescriptor(
            id: key,
            usageKey: key,
            title: title,
            subtitle: subtitle,
            keywords: Self.keywords + keywords,
            shortcut: shortcut,
            invocation: .task(command)
        )
    }

    private static func actionKeywords(_ action: TaskBoardPresentation.DetailAction) -> [String] {
        switch action {
        case .merge, .mergeWithoutChecks: ["pr", "pull", "request"]
        case .cancelMerge: ["cancel", "stop"]
        case .markDone: ["finish", "complete"]
        case .archive: ["close", "discard"]
        case .cleanUp: ["clean", "cleanup", "retry"]
        case .keepAsIs: ["keep", "cleanup"]
        }
    }
}

/// Finds the current task and the projects that can release, and runs the
/// palette's task commands through the same code as the Tasks view.
@MainActor
final class CommandPaletteTaskActions {
    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let fileManager: FileManager
    private let openURL: @MainActor (URL) -> Void
    private let presentFailure: @MainActor (String, String) -> Void
    private let confirmComplete: TaskActions.CompleteConfirmation
    /// Runs a task command once the palette has closed, so its alerts open
    /// over the window instead of the palette.
    private let afterPaletteCloses: @MainActor (@escaping @MainActor () -> Void) -> Void

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        fileManager: FileManager = .default,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        presentFailure: @escaping @MainActor (String, String) -> Void = { title, message in
            WorkspaceMergeCoordinator.presentAlert(title: title, message: message)
        },
        confirmComplete: @escaping TaskActions.CompleteConfirmation = TaskActions.confirmComplete,
        afterPaletteCloses: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        }
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.fileManager = fileManager
        self.openURL = openURL
        self.presentFailure = presentFailure
        self.confirmComplete = confirmComplete
        self.afterPaletteCloses = afterPaletteCloses
    }

    private var coordinator: TaskCoordinator? { sessionRuntimeStore?.taskCoordinator }
    private var board: TaskBoardStore? { coordinator?.board }

    // MARK: - Tasks view

    func canToggleTasksView(originWindowID: UUID) -> Bool {
        board?.isEnabled == true && store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func tasksViewTitle(originWindowID: UUID) -> String {
        ToasttyBuiltInCommand.toggleTasksViewTitle(
            tasksViewShown: store?.commandSelection(preferredWindowID: originWindowID)?.window.showsTasksView == true
        )
    }

    /// Shows the Tasks view, or hides it. The view covers the selected
    /// workspace without changing it, so hiding it returns to that workspace.
    func toggleTasksView(originWindowID: UUID) -> Bool {
        guard canToggleTasksView(originWindowID: originWindowID),
              let store,
              let selection = store.commandSelection(preferredWindowID: originWindowID) else { return false }
        return store.send(.setTasksViewShown(windowID: selection.windowID, shown: selection.window.showsTasksView == false))
    }

    // MARK: - Current task and releases

    func currentTask(originWindowID: UUID) -> TaskBoardCurrentTask? {
        guard let board, let sessionRuntimeStore,
              let selection = store?.commandSelection(preferredWindowID: originWindowID) else { return nil }
        return board.currentTask(in: selection) { sessionRuntimeStore.workspaceStatuses(for: $0) }
    }

    /// One option for each open project with a release skill or a
    /// `release_prompt` and no release under way, the origin window's
    /// projects first.
    func releaseOptions(originWindowID: UUID) -> [PaletteTaskReleaseOption] {
        guard let store, let coordinator, let board, let config = board.config else { return [] }
        let home = coordinator.homeDirectoryPath
        let releasableRoots = config.workspaces
            .filter { config.canRelease(projectRoot: $0.path, homeDirectoryPath: home) }
            .map { TasksConfigFile.normalizedPath($0.path, homeDirectoryPath: home) }
        // A `[defaults]` release skill makes every project releasable, so
        // any saved root qualifies.
        let anyRootReleases = config.defaults.releaseSkill != nil
        guard releasableRoots.isEmpty == false || anyRootReleases else { return [] }
        let state = store.state
        let originID = store.commandSelection(preferredWindowID: originWindowID)?.windowID
        let windows = state.windows.filter { $0.id == originID } + state.windows.filter { $0.id != originID }
        var options: [PaletteTaskReleaseOption] = []
        for window in windows {
            for workspaceID in state.topLevelWorkspaceIDs(in: window.id) {
                guard let workspace = state.workspacesByID[workspaceID],
                      let root = releasableRoot(
                          of: workspace,
                          among: releasableRoots,
                          anyRootReleases: anyRootReleases,
                          homeDirectoryPath: home
                      ),
                      options.contains(where: { $0.projectRoot == root }) == false,
                      coordinator.releaseUnderWay(projectRoot: root) == nil else { continue }
                options.append(PaletteTaskReleaseOption(
                    workspaceID: workspaceID,
                    projectTitle: workspace.title,
                    projectRoot: root,
                    toShipCount: 0
                ))
            }
        }
        guard options.isEmpty == false else { return [] }
        // The tasks Release would list, counted from one board snapshot.
        var toShipCounts: [String: Int] = [:]
        for item in board.items() where item.stage == .toShip && item.finishedThroughChildren == false {
            guard let record = item.record, record.release == nil, let projectRoot = record.projectRoot else { continue }
            toShipCounts[TasksConfigFile.normalizedPath(projectRoot, homeDirectoryPath: home), default: 0] += 1
        }
        return options.map { option in
            PaletteTaskReleaseOption(
                workspaceID: option.workspaceID,
                projectTitle: option.projectTitle,
                projectRoot: option.projectRoot,
                toShipCount: toShipCounts[option.projectRoot] ?? 0
            )
        }
    }

    /// `nil` when this Toastty has no coordinator to open.
    func coordinatorOption(originWindowID: UUID? = nil) -> PaletteCoordinatorOption? {
        guard let controller = coordinator?.coordinatorController else { return nil }
        let offersDock = originWindowID.map {
            CoordinatorDockPresentation.showsToggle(
                windowID: $0,
                coordinator: controller.location,
                chatAvailable: controller.chatIsAvailable
            )
        } ?? false
        return PaletteCoordinatorOption(
            isOpen: controller.location != nil,
            dockShows: offersDock ? originWindowID.map(controller.dockShows(in:)) : nil
        )
    }

    /// The releasable project that the workspace is: its saved root, or
    /// else the configured project holding its first terminal's directory.
    /// Release resolves a workspace without a saved root through git, which
    /// the palette cannot run on every keystroke. With `anyRootReleases`,
    /// every saved root is releasable.
    private func releasableRoot(
        of workspace: WorkspaceState,
        among roots: [String],
        anyRootReleases: Bool,
        homeDirectoryPath: String
    ) -> String? {
        if let saved = workspace.rootDirectory {
            let normalized = TasksConfigFile.normalizedPath(saved, homeDirectoryPath: homeDirectoryPath)
            return anyRootReleases || roots.contains(normalized) ? normalized : nil
        }
        guard let directory = TaskCoordinator.firstTerminalDirectory(in: workspace, fileManager: fileManager) else { return nil }
        let normalized = TasksConfigFile.normalizedPath(directory, homeDirectoryPath: homeDirectoryPath)
        return roots
            .filter { normalized == $0 || normalized.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    // MARK: - Running commands

    func execute(_ command: PaletteTaskCommand, originWindowID: UUID) -> Bool {
        guard let store, let sessionRuntimeStore, let coordinator, let board else { return false }
        switch command {
        case .toggleCoordinatorDock:
            guard let controller = coordinator.coordinatorController else { return false }
            afterPaletteCloses { controller.toggleDock() }
            return true

        case .openCoordinator, .restartCoordinator:
            guard let controller = coordinator.coordinatorController else { return false }
            let windowID = store.commandSelection(preferredWindowID: originWindowID)?.windowID
            let restarts = command == .restartCoordinator
            afterPaletteCloses { [presentFailure] in
                controller.perform(restarts ? .restart : .open, windowID: windowID, presentFailure: presentFailure)
            }
            return true

        case .action(let action, let subject):
            // The task may have moved on since the palette listed it.
            guard let item = board.items().first(where: { $0.id == subject }),
                  let record = item.record,
                  TaskBoardPresentation.detailActions(item).contains(action) else { return false }
            let failureTitle = "\(action.failureTitle) \(record.title)"
            afterPaletteCloses { [presentFailure, confirmComplete] in
                do {
                    try TaskActions.run(action, taskID: record.id, coordinator: coordinator, confirmComplete: confirmComplete)
                } catch {
                    presentFailure(failureTitle, error.localizedDescription)
                }
            }
            return true

        case .openPullRequest(let subject):
            guard let link = board.items().first(where: { $0.id == subject })?.pullRequest,
                  let url = URL(string: link.url) else { return false }
            openURL(url)
            return true

        case .openTaskSpace(let subject):
            guard let workspaceID = board.items().first(where: { $0.id == subject })?.taskSpaceWorkspaceID,
                  let windowID = store.commandSelection(preferredWindowID: originWindowID)?.windowID else { return false }
            TaskActions.openTaskSpace(
                workspaceID: workspaceID,
                fallbackWindowID: windowID,
                store: store,
                sessionRuntimeStore: sessionRuntimeStore
            )
            return true

        case .release(let workspaceID):
            guard store.state.workspacesByID[workspaceID] != nil else { return false }
            afterPaletteCloses { [presentFailure] in
                // As the Tasks view's Release… button does; release refuses
                // a second release of the same project.
                do {
                    _ = try coordinator.release(workspaceID: workspaceID, caller: .unmanaged)
                } catch {
                    presentFailure("Unable to Start the Release", error.localizedDescription)
                }
            }
            return true
        }
    }
}
