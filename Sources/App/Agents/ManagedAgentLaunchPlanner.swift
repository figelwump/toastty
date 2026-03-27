import Combine
import CoreState
import Foundation

@MainActor
protocol ManagedAgentLaunchPlanning: AnyObject {
    func prepareManagedLaunch(_ request: ManagedAgentLaunchRequest) throws -> ManagedAgentLaunchPlan
    func discardManagedLaunch(sessionID: String)
}

@MainActor
final class ManagedAgentLaunchPlanner: ManagedAgentLaunchPlanning {
    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let cliExecutablePathProvider: @Sendable () -> String?
    private let socketPathProvider: @Sendable () -> String
    private let readVisibleText: @MainActor (UUID) -> String?
    private var sessionRegistryObservation: AnyCancellable?
    private var managedArtifactsBySessionID: [String: ManagedLaunchArtifacts] = [:]

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String?,
        socketPathProvider: @escaping @Sendable () -> String,
        readVisibleText: @escaping @MainActor (UUID) -> String?
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.cliExecutablePathProvider = cliExecutablePathProvider
        self.socketPathProvider = socketPathProvider
        self.readVisibleText = readVisibleText
        sessionRegistryObservation = sessionRuntimeStore.$sessionRegistry.sink { [weak self] registry in
            Task { @MainActor in
                await self?.cleanupManagedArtifacts(forInactiveSessionsIn: registry)
            }
        }
    }

    func prepareManagedLaunch(_ request: ManagedAgentLaunchRequest) throws -> ManagedAgentLaunchPlan {
        guard let sessionRuntimeStore else {
            throw AgentLaunchError.serviceUnavailable
        }

        let target = try resolveManagedLaunchTarget(panelID: request.panelID)
        let resolvedCWD = normalizedNonEmpty(request.cwd) ?? target.cwd
        let repoRoot = RepositoryRootLocator.inferRepoRoot(from: resolvedCWD, fileManager: fileManager)
        let cliExecutablePath = try resolveCLIExecutablePath()
        let sessionID = UUID().uuidString
        let preparedLaunch = prepareLaunch(
            agent: request.agent,
            argv: request.argv,
            cliExecutablePath: cliExecutablePath,
            sessionID: sessionID,
            workingDirectory: resolvedCWD
        )
        let now = nowProvider()

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: request.agent,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: resolvedCWD,
            repoRoot: repoRoot,
            at: now
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: now
        )
        registerManagedArtifacts(preparedLaunch.artifacts, sessionID: sessionID)

        var environment = preparedLaunch.environment
        environment[ToasttyLaunchContextEnvironment.sessionIDKey] = sessionID
        environment[ToasttyLaunchContextEnvironment.panelIDKey] = target.panelID.uuidString
        environment[ToasttyLaunchContextEnvironment.socketPathKey] = socketPathProvider()
        environment[ToasttyLaunchContextEnvironment.cliPathKey] = cliExecutablePath
        if let resolvedCWD {
            environment[ToasttyLaunchContextEnvironment.cwdKey] = resolvedCWD
        }
        if let repoRoot {
            environment[ToasttyLaunchContextEnvironment.repoRootKey] = repoRoot
        }

        return ManagedAgentLaunchPlan(
            sessionID: sessionID,
            agent: request.agent,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            cwd: resolvedCWD,
            repoRoot: repoRoot,
            argv: preparedLaunch.argv,
            environment: environment
        )
    }

    func discardManagedLaunch(sessionID: String) {
        guard let sessionRuntimeStore else {
            return
        }
        sessionRuntimeStore.stopSession(sessionID: sessionID, at: nowProvider())
        Task { @MainActor in
            await cleanupManagedArtifacts(for: sessionID)
        }
    }

    private func resolveManagedLaunchTarget(panelID: UUID) throws -> ManagedLaunchTarget {
        guard let store else {
            throw AgentLaunchError.serviceUnavailable
        }

        let state = store.state
        guard let location = Self.locatePanel(panelID, in: state) else {
            throw AgentLaunchError.panelDoesNotExist
        }
        guard let workspace = state.workspacesByID[location.workspaceID] else {
            throw AgentLaunchError.workspaceDoesNotExist
        }
        guard case .terminal(let terminalState)? = workspace.panels[panelID] else {
            throw AgentLaunchError.panelIsNotTerminal
        }
        return ManagedLaunchTarget(
            windowID: location.windowID,
            workspaceID: location.workspaceID,
            panelID: panelID,
            cwd: normalizedNonEmpty(terminalState.cwd)
        )
    }

    private func resolveCLIExecutablePath() throws -> String {
        guard let candidatePath = normalizedNonEmpty(cliExecutablePathProvider()) else {
            throw AgentLaunchError.cliUnavailable(path: nil)
        }
        guard fileManager.isExecutableFile(atPath: candidatePath) else {
            throw AgentLaunchError.cliUnavailable(path: candidatePath)
        }
        return candidatePath
    }

    private func prepareLaunch(
        agent: AgentKind,
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?
    ) -> PreparedAgentLaunchCommand {
        do {
            return try AgentLaunchInstrumentation.prepare(
                agent: agent,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            )
        } catch {
            ToasttyLog.warning(
                "Launching agent without instrumentation after launch preparation failed",
                category: .automation,
                metadata: [
                    "agent": agent.rawValue,
                    "session_id": sessionID,
                    "error": error.localizedDescription,
                ]
            )
            return PreparedAgentLaunchCommand(argv: argv, environment: [:], artifacts: nil)
        }
    }

    private func registerManagedArtifacts(
        _ preparedArtifacts: PreparedAgentLaunchArtifacts?,
        sessionID: String
    ) {
        guard let preparedArtifacts else { return }

        let watcher: CodexSessionLogWatcher?
        if let logURL = preparedArtifacts.codexSessionLogURL {
            watcher = makeCodexSessionLogWatcher(sessionID: sessionID, logURL: logURL)
        } else {
            watcher = nil
        }

        let managedArtifacts = ManagedLaunchArtifacts(
            directoryURL: preparedArtifacts.directoryURL,
            codexSessionLogWatcher: watcher
        )
        watcher?.start()
        managedArtifactsBySessionID[sessionID] = managedArtifacts
    }

    private func makeCodexSessionLogWatcher(sessionID: String, logURL: URL) -> CodexSessionLogWatcher {
        // TODO: Remove this watcher once Codex exposes stable start/approval hooks.
        CodexSessionLogWatcher(logURL: logURL) { [weak self] event in
            await MainActor.run {
                guard let self, let sessionRuntimeStore = self.sessionRuntimeStore else {
                    return
                }

                let status: SessionStatus
                switch event.kind {
                case .turnStarted:
                    status = SessionStatus(kind: .working, summary: "Working", detail: event.detail)
                case .historyUpdated:
                    guard let panelID = sessionRuntimeStore
                        .sessionRegistry
                        .activeSession(sessionID: sessionID)?
                        .panelID,
                          let visibleText = self.readVisibleText(panelID) else {
                        return
                    }
                    _ = sessionRuntimeStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
                        panelID: panelID,
                        visibleText: visibleText,
                        at: self.nowProvider()
                    )
                    return
                case .approvalNeeded:
                    status = SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: event.detail)
                case .taskCompleted:
                    status = SessionStatus(kind: .ready, summary: "Ready", detail: event.detail)
                case .turnAborted:
                    guard let currentKind = sessionRuntimeStore
                        .sessionRegistry
                        .activeSession(sessionID: sessionID)?
                        .status?
                        .kind,
                          currentKind == .working || currentKind == .needsApproval else {
                        return
                    }
                    status = SessionStatus(kind: .idle, summary: "Waiting", detail: event.detail)
                }

                sessionRuntimeStore.updateStatus(
                    sessionID: sessionID,
                    status: status,
                    at: self.nowProvider()
                )
            }
        }
    }

    private func cleanupManagedArtifacts(forInactiveSessionsIn registry: SessionRegistry) async {
        let inactiveSessionIDs = managedArtifactsBySessionID.keys.filter { sessionID in
            registry.activeSession(sessionID: sessionID) == nil
        }
        for sessionID in inactiveSessionIDs {
            await cleanupManagedArtifacts(for: sessionID)
        }
    }

    private func cleanupManagedArtifacts(for sessionID: String) async {
        guard let managedArtifacts = managedArtifactsBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        await cleanup(managedArtifacts)
    }

    private func cleanup(_ managedArtifacts: ManagedLaunchArtifacts) async {
        await managedArtifacts.codexSessionLogWatcher?.stop()
        try? fileManager.removeItem(at: managedArtifacts.directoryURL)
    }

    private static func locatePanel(
        _ panelID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspaceID: UUID)? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.panels[panelID] != nil {
                    return (window.id, workspaceID)
                }
            }
        }
        return nil
    }
}

private struct ManagedLaunchTarget {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let cwd: String?
}

private struct ManagedLaunchArtifacts {
    let directoryURL: URL
    let codexSessionLogWatcher: CodexSessionLogWatcher?
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
