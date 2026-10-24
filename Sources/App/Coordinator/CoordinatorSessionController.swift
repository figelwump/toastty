import Combine
import CoreState
import Foundation

/// Retained once by ToasttyApp and shared by every window. Chat clients and
/// automatic review inputs belong to the app's conversation authority.
@MainActor
final class CoordinatorSessionController: ObservableObject {
    @Published private(set) var status: CoordinatorSessionStatus = .stopped
    @Published private(set) var configuration: CoordinatorSessionConfiguration
    @Published private(set) var identity: CoordinatorSessionIdentity?
    @Published private(set) var managedSessionID: String?

    private let store: AppStore
    private let launcher: any TaskAgentLaunching
    private let sessionRuntimeStore: SessionRuntimeStore
    private let stateURL: URL
    private let directoryURL: URL
    private let terminalReadinessTimeout: Duration
    private var savedState: CoordinatorSessionState
    private var storageFailure: String?
    private var startTask: Task<Void, Never>?
    private var sessionSubscription: AnyCancellable?
    private var actionObserver: UUID?
    private var restoreWaitTask: Task<Void, Never>?
    private var restoreWaitExpired = false
    private var launchBlocked = true
    private var lastStartFailure: String?

    init(
        store: AppStore,
        launcher: any TaskAgentLaunching,
        sessionRuntimeStore: SessionRuntimeStore,
        runtimePaths: ToasttyRuntimePaths,
        defaultsProvider: () -> TasksConfig.Defaults = { .init() },
        terminalReadinessTimeout: Duration = .seconds(10)
    ) {
        self.store = store
        self.launcher = launcher
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalReadinessTimeout = terminalReadinessTimeout
        stateURL = runtimePaths.configDirectoryURL.appendingPathComponent("coordinator-session.json")
        directoryURL = runtimePaths.configDirectoryURL.appendingPathComponent("coordinator", isDirectory: true)
        let defaults = defaultsProvider()
        let profiles = launcher.launchProfileSummaries().filter(Self.supportsCoordinator)
        let selected = profiles.first { $0.profileID == defaults.agent }
            ?? profiles.first { $0.isInstalled && $0.acceptsInitialPrompt }
            ?? profiles.first
        let usesDefaults = selected?.profileID == defaults.agent && defaults.agent != nil
        var initial = CoordinatorSessionState(configuration: CoordinatorSessionConfiguration(
            profileID: selected?.profileID,
            model: usesDefaults && selected?.supportsModel == true ? defaults.model : nil,
            reasoningEffort: usesDefaults && selected?.supportsReasoningEffort == true ? defaults.effort : nil
        ))
        do {
            if let stored = try CoordinatorSessionState.load(from: stateURL) { initial = stored }
        } catch {
            storageFailure = "Coordinator settings could not be read. Repair \(stateURL.path) before starting a session."
        }
        savedState = initial
        configuration = initial.configuration
        identity = initial.identity
        managedSessionID = nil
        // Published values are sent before SessionRuntimeStore stores them.
        sessionSubscription = sessionRuntimeStore.$sessionRegistry.sink { [weak self] registry in
            self?.reconcile(registry: registry)
        }
        actionObserver = store.addActionAppliedObserver { [weak self] _, _, _ in self?.reconcile() }
        reconcile()
    }

    deinit {
        restoreWaitTask?.cancel()
        if let actionObserver {
            let store = store
            Task { @MainActor in store.removeActionAppliedObserver(actionObserver) }
        }
    }

    var availableProfiles: [AgentLaunchProfileSummary] {
        launcher.launchProfileSummaries().filter(Self.supportsCoordinator)
    }

    var automaticWorkEnabled: Bool { configuration.automaticWorkEnabled }

    /// Configuration applies to the next session. Existing work is never killed.
    func configure(profileID: String, model: String?, reasoningEffort: String?) throws {
        guard startTask == nil else { throw ConfigurationError.startInProgress }
        guard let profile = availableProfiles.first(where: { $0.profileID == profileID }),
              model == nil || profile.supportsModel,
              reasoningEffort == nil || profile.supportsReasoningEffort else {
            throw ConfigurationError.unsupportedProfile
        }
        var next = savedState
        next.configuration.profileID = profileID
        next.configuration.model = model
        next.configuration.reasoningEffort = reasoningEffort
        try persist(next)
        reconcile()
    }

    func setAutomaticWorkEnabled(_ enabled: Bool) throws {
        var next = savedState
        next.configuration.automaticWorkEnabled = enabled
        try persist(next)
    }

    /// User action; works even when automatic inputs are paused. Repeated calls
    /// from different windows await the same launch and never change selection.
    func start() async { await start(automatic: false) }

    func startIfAutomaticWorkEnabled() async { await start(automatic: true) }

    func reconcile() { reconcile(registry: sessionRuntimeStore.sessionRegistry) }

    private func reconcile(registry: SessionRegistry) {
        guard startTask == nil else { return }
        launchBlocked = true
        if let storageFailure { status = .error(storageFailure); return }
        guard let identity, let terminal = terminal(for: identity) else {
            clearRestoreWait()
            managedSessionID = nil
            showStoppedState()
            return
        }
        if let active = registry.activeSession(for: identity.panelID),
           active.workspaceID == identity.workspaceID {
            guard active.agent == .claude || active.agent == .codex else {
                clearRestoreWait()
                managedSessionID = nil
                status = .unavailable("The Coordinator terminal is occupied by another agent.")
                return
            }
            clearRestoreWait()
            lastStartFailure = nil
            managedSessionID = active.sessionID
            if savedState.lastManagedSessionID != active.sessionID || savedState.launchNeedsInspection {
                var next = savedState
                next.lastManagedSessionID = active.sessionID
                next.launchNeedsInspection = false
                do { try persist(next) }
                catch { status = .error("Coordinator session identity could not be saved."); return }
            }
            status = .running
            return
        }
        // An older stopped session cannot prove that a later uncertain command
        // did not reach this shell. Preserve the inspection block until close.
        if savedState.launchNeedsInspection {
            clearRestoreWait()
            managedSessionID = nil
            status = .error("The previous launch was not confirmed. Inspect the Coordinator terminal, then close its workspace before starting a new session.")
        } else if terminal.resumeRecord != nil {
            managedSessionID = nil
            status = restoreWaitExpired
                ? .error("The Coordinator terminal has not resumed. Inspect its terminal. To start a new session, close its workspace first.")
                : .waitingForRestore
            if restoreWaitTask == nil && !restoreWaitExpired {
                restoreWaitTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.restoreWaitExpired = true
                    self.restoreWaitTask = nil
                    self.reconcile()
                }
            }
        } else {
            clearRestoreWait()
            managedSessionID = savedState.lastManagedSessionID.flatMap { id in
                registry.sessionsByID[id]?.isActive == false ? id : nil
            }
            showStoppedState()
        }
    }

    private func showStoppedState() {
        launchBlocked = availableProfile == nil
        if launchBlocked { status = .unavailable("Choose an installed Claude or Codex profile.") }
        else if let lastStartFailure { status = .error(lastStartFailure) }
        else { status = .stopped }
    }

    private func start(automatic: Bool) async {
        guard !automatic || automaticWorkEnabled else { return }
        if let startTask { await startTask.value; return }
        reconcile()
        guard !launchBlocked else { return }
        lastStartFailure = nil
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart(automatic: automatic)
            self.startTask = nil
            // Registry events received during the launch were suppressed. Read
            // current state once so an immediate exit cannot remain Running.
            self.reconcile()
        }
        startTask = task
        status = .starting
        await task.value
    }

    private func performStart(automatic: Bool) async {
        guard let profile = availableProfile else {
            status = .unavailable("Choose an installed Claude or Codex profile.")
            return
        }
        do {
            let target = try ensureBackingTerminal()
            let selection = configuration
            let result = try await TaskCoordinator.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                try await self.launcher.launchTask(
                    profileID: profile.profileID,
                    workspaceID: target.workspaceID,
                    panelID: target.panelID,
                    cwd: self.directoryURL.path,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    initialPrompt: "Use the toastty-coordinator skill. Read Toastty's authoritative task and review records before making recommendations. Do not merge or approve work on the user's behalf.",
                    parentSessionID: nil,
                    forkFromSessionID: nil,
                    scopedWorkspaceIDs: nil,
                    beforeDispatch: { [weak self] in
                        guard let self, !automatic || self.automaticWorkEnabled else { throw CancellationError() }
                        guard self.terminal(for: target) != nil else { throw AgentLaunchError.panelDoesNotExist }
                        var next = self.savedState
                        next.launchNeedsInspection = true
                        try self.persist(next)
                    }
                )
            }
            var next = savedState
            next.lastManagedSessionID = result.sessionID
            next.launchNeedsInspection = false
            try persist(next)
            managedSessionID = result.sessionID
            status = .running
        } catch {
            lastStartFailure = error is CancellationError ? nil : error.localizedDescription
            if case .commandDeliveryUncertain? = error as? AgentLaunchError {
                status = .error("The launch was not confirmed. Inspect the Coordinator terminal before starting another session.")
            } else {
                // These failures are known not to have dispatched a command.
                // A storage failure after a successful dispatch stays blocked.
                if error is AgentLaunchError || error is CancellationError {
                    var next = savedState
                    next.launchNeedsInspection = false
                    do { try persist(next) } catch { lastStartFailure = error.localizedDescription; status = .error(error.localizedDescription); return }
                }
                status = error is CancellationError ? .stopped : .error(error.localizedDescription)
            }
        }
    }

    private func ensureBackingTerminal() throws -> CoordinatorSessionIdentity {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = identity ?? CoordinatorSessionIdentity(workspaceID: UUID(), panelID: UUID())
        if terminal(for: target) != nil { return target }
        var next = savedState
        next.identity = target
        next.lastManagedSessionID = nil
        next.launchNeedsInspection = false
        try persist(next)
        if store.state.workspacesByID[target.workspaceID] != nil {
            guard store.send(.createBackgroundTerminalTab(workspaceID: target.workspaceID, tabID: UUID(), panelID: target.panelID, terminalCWD: directoryURL.path)) else {
                throw AgentLaunchError.panelDoesNotExist
            }
        } else {
            // reopenWorkspace uses the user's default terminal profile. Replace
            // that placeholder synchronously with an unprofiled terminal so its
            // startup command cannot compete with the managed Coordinator.
            let placeholderPanelID = UUID()
            guard let windowID = store.state.selectedWindowID ?? store.state.windows.first?.id,
                  store.send(.reopenWorkspace(windowID: windowID, workspaceID: target.workspaceID, panelID: placeholderPanelID, title: "Coordinator", rootDirectory: directoryURL.path)) else {
                throw AgentLaunchError.noSelectedWorkspace
            }
            let placeholderTabID = store.state.workspacesByID[target.workspaceID]?.resolvedSelectedTabID
            guard store.send(.createBackgroundTerminalTab(workspaceID: target.workspaceID, tabID: UUID(), panelID: target.panelID, terminalCWD: directoryURL.path)) else {
                // This workspace was made synchronously by this attempt. Do
                // not leave its profiled placeholder to launch after failure.
                _ = store.send(.closeWorkspace(workspaceID: target.workspaceID))
                throw AgentLaunchError.panelDoesNotExist
            }
            if let placeholderTabID {
                _ = store.send(.closeWorkspaceTab(workspaceID: target.workspaceID, tabID: placeholderTabID))
            }
        }
        return target
    }

    private var availableProfile: AgentLaunchProfileSummary? {
        availableProfiles.first { $0.profileID == configuration.profileID && $0.isInstalled && $0.acceptsInitialPrompt }
    }

    private static func supportsCoordinator(_ profile: AgentLaunchProfileSummary) -> Bool {
        profile.agent == .codex || profile.agent == .claude
    }

    private func terminal(for identity: CoordinatorSessionIdentity) -> TerminalPanelState? {
        guard case .terminal(let terminal)? = store.state.workspacesByID[identity.workspaceID]?.panelState(for: identity.panelID) else { return nil }
        return terminal
    }

    private func clearRestoreWait() {
        restoreWaitTask?.cancel()
        restoreWaitTask = nil
        restoreWaitExpired = false
    }

    private func persist(_ next: CoordinatorSessionState) throws {
        guard storageFailure == nil else { throw CocoaError(.fileReadCorruptFile) }
        try next.save(to: stateURL)
        savedState = next
        configuration = next.configuration
        identity = next.identity
    }

    enum ConfigurationError: LocalizedError {
        case startInProgress
        case unsupportedProfile
        var errorDescription: String? {
            switch self {
            case .startInProgress: "Wait for the Coordinator session to start before changing its configuration."
            case .unsupportedProfile: "Choose a Claude or Codex profile that supports these launch options."
            }
        }
    }
}
