import CoreState
import Foundation

/// Keeps the coordinator's agent running: starts it at launch in the hidden
/// coordinator workspace, and starts a fresh session there whenever the
/// last one exits. The agent keeps no state of its own; it rebuilds from
/// task records and `routing.md`, so a restart loses nothing.
@MainActor
final class CoordinatorSessionController {
    enum Status: Equatable {
        /// `[coordinator] agent = "none"`, or not started.
        case off
        /// No window is open to hold the coordinator workspace.
        case waitingForWindow
        /// A restored terminal is resuming the previous session.
        case waitingForRestore
        case starting
        case running(sessionID: String)
        /// Toastty stopped starting new sessions; the reason says why.
        case failed(String)
    }

    static let initialPrompt = "Use the toastty-coordinator skill."

    private(set) var status: Status = .off {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    /// The coordinator's terminal, once its workspace exists.
    private(set) var panelID: UUID? {
        didSet { if panelID != oldValue { onPanelChange?(panelID) } }
    }
    var onStatusChange: ((Status) -> Void)?
    let files: CoordinatorFiles

    var workspaceID: UUID? { store.state.coordinatorWorkspaceID }
    var onPanelChange: ((UUID?) -> Void)?

    private let store: AppStore
    private let launcher: any TaskAgentLaunching
    private let sessions: any TaskSessionProviding
    private let configLoader: () throws -> TasksConfig
    /// Whether the terminal still has to type the command that resumes its
    /// restored agent.
    private let isRestorePending: (UUID) -> Bool
    private let homeDirectoryPath: String
    private let now: () -> Date
    private let relaunchDelay: Duration
    private let restoreGrace: Duration
    private let registrationGrace: TimeInterval
    private let terminalReadinessTimeout: Duration
    /// A session that ran at least this long counts as a normal exit.
    private let stableRunDuration: TimeInterval
    /// Short runs or failed starts in a row before Toastty stops trying.
    private let maximumQuickExits: Int

    private var isStarted = false
    private var config = TasksConfig.Coordinator()
    /// The session this controller last saw running or launched.
    private var currentSessionID: String?
    private var currentSessionStartedAt: Date?
    private var quickExits = 0
    private var launchTask: Task<Void, Never>?
    private var scheduledLaunch: Task<Void, Never>?
    private var scheduledReconcile: Task<Void, Never>?
    private var restoreDeadline: Date?
    private var hasLaunchedThisRun = false

    init(
        store: AppStore,
        launcher: any TaskAgentLaunching,
        sessions: any TaskSessionProviding,
        configLoader: @escaping () throws -> TasksConfig,
        files: CoordinatorFiles,
        isRestorePending: @escaping (UUID) -> Bool = { _ in false },
        homeDirectoryPath: String = NSHomeDirectory(),
        now: @escaping () -> Date = Date.init,
        relaunchDelay: Duration = .seconds(2),
        restoreGrace: Duration = .seconds(20),
        registrationGrace: TimeInterval = 10,
        terminalReadinessTimeout: Duration = .seconds(10),
        stableRunDuration: TimeInterval = 60,
        maximumQuickExits: Int = 3
    ) {
        self.store = store
        self.launcher = launcher
        self.sessions = sessions
        self.configLoader = configLoader
        self.files = files
        self.isRestorePending = isRestorePending
        self.homeDirectoryPath = homeDirectoryPath
        self.now = now
        self.relaunchDelay = relaunchDelay
        self.restoreGrace = restoreGrace
        self.registrationGrace = registrationGrace
        self.terminalReadinessTimeout = terminalReadinessTimeout
        self.stableRunDuration = stableRunDuration
        self.maximumQuickExits = maximumQuickExits
    }

    /// Reads `[coordinator]` and starts the agent unless it is turned off.
    /// Runs before terminals start, so a coordinator that is off closes its
    /// saved workspace before that terminal could resume the agent.
    func start() {
        isStarted = true
        restoreDeadline = now().addingTimeInterval(restoreGrace.timeInterval)
        reloadConfiguration()
        if config.agent == nil {
            closeSavedWorkspace()
        }
    }

    /// For a run that does not start the coordinator: closes a workspace
    /// saved by an earlier run, so its agent does not resume.
    func closeSavedWorkspace() {
        guard launchTask == nil, let workspaceID = store.state.coordinatorWorkspaceID else { return }
        _ = store.send(.closeWorkspace(workspaceID: workspaceID))
        panelID = nil
        ToasttyLog.info("Closed the saved coordinator workspace because the coordinator is off", category: .tasks)
    }

    /// Applies an edited `tasks.toml` to the next session, and clears a
    /// stop after repeated exits. A running session keeps going.
    func reloadConfiguration() {
        guard isStarted else { return }
        do {
            config = try configLoader().coordinator
        } catch {
            config = TasksConfig.Coordinator(agent: nil)
            status = .failed("tasks.toml could not be read: \(error.localizedDescription)")
            ToasttyLog.warning("Coordinator is off because tasks.toml could not be read", category: .tasks, metadata: [
                "error": error.localizedDescription,
            ])
            return
        }
        quickExits = 0
        if case .failed = status { status = .off }
        reconcile()
    }

    /// Coalesces calls from store and session changes into one pass after
    /// the current change finishes, so a pass never sends an action from
    /// inside another action's observer.
    func setNeedsReconcile() {
        guard isStarted, scheduledReconcile == nil else { return }
        scheduledReconcile = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.scheduledReconcile = nil
            self.reconcile()
        }
    }

    func reconcile() {
        guard isStarted, config.agent != nil else {
            if case .failed = status { return }
            status = .off
            return
        }
        guard launchTask == nil, scheduledLaunch == nil else { return }
        if case .failed = status { return }

        let target = existingTarget()
        panelID = target?.panelID
        if let target, let active = sessions.activeSession(panelID: target.panelID) {
            noteRunning(active.sessionID)
            return
        }
        if let currentSessionID {
            if let info = sessions.session(currentSessionID), info.isActive {
                status = .running(sessionID: currentSessionID)
                return
            }
            if sessions.session(currentSessionID) == nil,
               let startedAt = currentSessionStartedAt,
               now().timeIntervalSince(startedAt) < registrationGrace {
                // The launch returned before the registry showed the session.
                status = .starting
                scheduleReconcile(after: .seconds(1))
                return
            }
            noteExit(currentSessionID)
            if case .failed = status { return }
        }
        if let target, terminal(target)?.resumeRecord != nil, hasLaunchedThisRun == false,
           isRestorePending(target.panelID) || restoreDeadline.map({ now() < $0 }) == true {
            // Toastty resumes a restored agent when the terminal starts.
            // Launching now could type a second agent into that terminal.
            status = .waitingForRestore
            scheduleReconcile(after: .seconds(1))
            return
        }
        guard store.state.windows.isEmpty == false else {
            status = .waitingForWindow
            return
        }
        scheduleLaunch(after: hasLaunchedThisRun ? relaunchDelay : .zero)
    }

    /// Selects the coordinator workspace with its raw terminal showing.
    /// Returns false when it does not exist yet.
    @discardableResult
    func showTerminal() -> Bool {
        select(showingTerminal: true)
    }

    /// Selects the coordinator workspace with the chat covering its
    /// terminal. Returns false when it does not exist yet.
    @discardableResult
    func showChat() -> Bool {
        select(showingTerminal: false)
    }

    private func select(showingTerminal: Bool) -> Bool {
        guard let workspaceID = store.state.coordinatorWorkspaceID,
              let windowID = store.state.workspaceSelection(containingWorkspaceID: workspaceID)?.windowID else {
            return false
        }
        _ = store.send(.selectWindow(windowID: windowID))
        _ = store.send(.setCoordinatorTerminalShown(windowID: windowID, shown: showingTerminal))
        _ = store.send(.setTasksViewShown(windowID: windowID, shown: false))
        guard store.state.window(id: windowID)?.selectedWorkspaceID != workspaceID else { return true }
        return store.sendNavigation(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
    }

    // MARK: - Sessions

    private func noteRunning(_ sessionID: String) {
        if currentSessionID != sessionID {
            currentSessionID = sessionID
            currentSessionStartedAt = now()
        }
        status = .running(sessionID: sessionID)
    }

    private func noteExit(_ sessionID: String) {
        let ranFor = currentSessionStartedAt.map { now().timeIntervalSince($0) } ?? 0
        currentSessionID = nil
        currentSessionStartedAt = nil
        if ranFor >= stableRunDuration {
            quickExits = 0
        } else {
            quickExits += 1
        }
        ToasttyLog.info("Coordinator session ended", category: .tasks, metadata: [
            "session_id": sessionID,
            "ran_seconds": String(Int(ranFor)),
            "quick_exits": String(quickExits),
        ])
        stopIfExitingRepeatedly()
    }

    private func stopIfExitingRepeatedly() {
        guard quickExits >= maximumQuickExits else { return }
        status = .failed(
            "The coordinator stopped \(quickExits) times in a row soon after it started. Check its terminal, then reload configuration to try again."
        )
        ToasttyLog.warning("Coordinator stopped restarting after repeated short runs", category: .tasks, metadata: [
            "quick_exits": String(quickExits),
        ])
    }

    // MARK: - Launch

    private func scheduleLaunch(after delay: Duration) {
        status = .starting
        scheduledLaunch = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
            guard let self, Task.isCancelled == false else { return }
            self.scheduledLaunch = nil
            self.launch()
        }
    }

    private func scheduleReconcile(after delay: Duration) {
        guard scheduledReconcile == nil else { return }
        scheduledReconcile = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.scheduledReconcile = nil
            self.reconcile()
        }
    }

    private func launch() {
        guard isStarted, let agent = config.agent, launchTask == nil else { return }
        guard let profile = launcher.launchProfileSummaries().first(where: { $0.profileID == agent }) else {
            status = .failed("No agent profile is named \"\(agent)\". Set [coordinator] agent in tasks.toml to one of your profiles.")
            return
        }
        guard profile.isInstalled, profile.acceptsInitialPrompt else {
            status = .failed("The coordinator's agent \"\(agent)\" is not installed, or cannot take a first message.")
            return
        }
        let target: Target
        do {
            try files.prepare()
            guard let ensured = ensureTarget() else {
                status = .waitingForWindow
                return
            }
            target = ensured
        } catch {
            status = .failed("Toastty could not set up the coordinator: \(error.localizedDescription)")
            return
        }
        panelID = target.panelID
        status = .starting
        hasLaunchedThisRun = true
        let model = profile.supportsModel ? config.model : nil
        let effort = profile.supportsReasoningEffort ? config.effort : nil
        let cwd = homeDirectoryPath
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await TaskCoordinator.launchWhenTerminalIsReady(timeout: self.terminalReadinessTimeout) {
                    try await self.launcher.launchTask(
                        profileID: profile.profileID,
                        workspaceID: target.workspaceID,
                        panelID: target.panelID,
                        cwd: cwd,
                        model: model,
                        reasoningEffort: effort,
                        initialPrompt: Self.initialPrompt,
                        parentSessionID: nil,
                        forkFromSessionID: nil,
                        scopedWorkspaceIDs: nil,
                        beforeDispatch: { [weak self] in
                            // A restored agent may be resuming in the
                            // meantime; reconcile then waits for it. (The
                            // launch registers its own session before this
                            // runs, so the registry cannot tell.)
                            guard let self, self.isStarted, self.config.agent != nil, self.terminal(target) != nil,
                                  self.isRestorePending(target.panelID) == false else {
                                throw CancellationError()
                            }
                        }
                    )
                }
                self.currentSessionID = result.sessionID
                self.currentSessionStartedAt = self.now()
                self.status = .running(sessionID: result.sessionID)
                ToasttyLog.info("Started the coordinator", category: .tasks, metadata: [
                    "session_id": result.sessionID,
                    "profile_id": profile.profileID,
                ])
            } catch is CancellationError {
                self.status = .off
                // Counted like a failed start, so a cancel that repeats
                // cannot loop.
                if self.isStarted, self.config.agent != nil {
                    self.quickExits += 1
                    self.stopIfExitingRepeatedly()
                }
            } catch AgentLaunchError.commandDeliveryUncertain {
                // Part of the command may be in the terminal; typing it again
                // could run two agents.
                self.status = .failed("The coordinator's start command may not have reached its terminal. Check the terminal, then reload configuration to try again.")
            } catch {
                self.quickExits += 1
                ToasttyLog.warning("Coordinator did not start", category: .tasks, metadata: [
                    "error": error.localizedDescription,
                    "quick_exits": String(self.quickExits),
                ])
                self.stopIfExitingRepeatedly()
            }
            self.launchTask = nil
            self.reconcile()
        }
    }

    // MARK: - Workspace

    struct Target: Equatable {
        var workspaceID: UUID
        var panelID: UUID
    }

    /// The coordinator workspace's terminal, if the workspace is open. The
    /// terminal last used is kept while it exists.
    private func existingTarget() -> Target? {
        guard let workspaceID = store.state.coordinatorWorkspaceID,
              let workspace = store.state.workspacesByID[workspaceID] else { return nil }
        if let panelID, case .terminal? = workspace.panelState(for: panelID) {
            return Target(workspaceID: workspaceID, panelID: panelID)
        }
        for tab in workspace.orderedTabs {
            for slot in tab.layoutTree.allSlotInfos {
                if case .terminal? = tab.panels[slot.panelID] {
                    return Target(workspaceID: workspaceID, panelID: slot.panelID)
                }
            }
        }
        return nil
    }

    /// The existing target, else a new terminal in the coordinator
    /// workspace, else a new coordinator workspace in the first window.
    private func ensureTarget() -> Target? {
        if let target = existingTarget() { return target }
        let panelID = UUID()
        if let workspaceID = store.state.coordinatorWorkspaceID {
            guard store.send(.createBackgroundTerminalTab(
                workspaceID: workspaceID,
                tabID: UUID(),
                panelID: panelID,
                terminalCWD: homeDirectoryPath
            )) else { return nil }
            return Target(workspaceID: workspaceID, panelID: panelID)
        }
        guard let windowID = store.state.windows.first?.id else { return nil }
        let workspaceID = UUID()
        guard store.send(.createCoordinatorWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            terminalCWD: homeDirectoryPath
        )) else { return nil }
        return Target(workspaceID: workspaceID, panelID: panelID)
    }

    private func terminal(_ target: Target) -> TerminalPanelState? {
        guard case .terminal(let terminal)? = store.state.workspacesByID[target.workspaceID]?.panelState(for: target.panelID) else {
            return nil
        }
        return terminal
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
