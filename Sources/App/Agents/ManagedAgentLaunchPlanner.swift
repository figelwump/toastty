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
    private let codexStatusTrackingSourceProvider: @MainActor () -> CodexStatusTrackingSource
    private let readVisibleText: @MainActor (UUID) -> String?
    private let promptState: @MainActor (UUID) -> TerminalPromptState
    private let nativeSessionObserverRegistry: any ManagedAgentNativeSessionObserving
    private let codexResumeResolver: any CodexManagedSessionResolving
    private var sessionRegistryObservation: AnyCancellable?
    private var managedArtifactsBySessionID: [String: ManagedLaunchArtifacts] = [:]

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String?,
        socketPathProvider: @escaping @Sendable () -> String,
        codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = ManagedAgentLaunchPlanner.defaultCodexStatusTrackingSource,
        readVisibleText: @escaping @MainActor (UUID) -> String?,
        promptState: @escaping @MainActor (UUID) -> TerminalPromptState,
        nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil,
        codexResumeResolver: (any CodexManagedSessionResolving)? = nil
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.cliExecutablePathProvider = cliExecutablePathProvider
        self.socketPathProvider = socketPathProvider
        self.codexStatusTrackingSourceProvider = codexStatusTrackingSourceProvider
        self.readVisibleText = readVisibleText
        self.promptState = promptState
        self.nativeSessionObserverRegistry = nativeSessionObserverRegistry
            ?? ManagedAgentNativeSessionObserverRegistry(
                store: store,
                fileManager: fileManager,
                nowProvider: nowProvider
            )
        self.codexResumeResolver = codexResumeResolver ?? CodexManagedSessionResolver()
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
        let codexStatusTrackingSource = statusTrackingSource(for: request.agent)
        let preparedLaunch = prepareLaunch(
            agent: request.agent,
            argv: request.argv,
            cliExecutablePath: cliExecutablePath,
            sessionID: sessionID,
            workingDirectory: resolvedCWD,
            codexStatusTrackingSource: codexStatusTrackingSource
        )
        let launchStart = nowProvider()

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: request.agent,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: request.agent == .codex ? codexStatusTrackingSource : nil,
            cwd: resolvedCWD,
            repoRoot: repoRoot,
            at: launchStart
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: launchStart
        )
        logCodexStatusTrackingSourceIfNeeded(
            agent: request.agent,
            source: codexStatusTrackingSource,
            sessionID: sessionID,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID
        )
        registerManagedArtifacts(
            preparedLaunch.artifacts,
            sessionID: sessionID,
            codexStatusTrackingSource: codexStatusTrackingSource
        )
        if let resolvedCWD {
            nativeSessionObserverRegistry.startObservation(
                ManagedAgentNativeSessionObservationContext(
                    managedSessionID: sessionID,
                    agent: request.agent,
                    panelID: target.panelID,
                    cwd: resolvedCWD,
                    launchStart: launchStart
                )
            )
        } else {
            ToasttyLog.warning(
                "Skipping managed agent native session observation because launch cwd is unavailable",
                category: .terminal,
                metadata: [
                    "session_id": sessionID,
                    "agent": request.agent.rawValue,
                    "panel_id": target.panelID.uuidString,
                ]
            )
        }

        var environment = AgentLaunchInstrumentation.baselineEnvironment(for: request.agent)
        for (key, value) in preparedLaunch.environment {
            environment[key] = value
        }
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
        nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
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
        guard case .terminal(let terminalState)? = workspace.panelState(for: panelID) else {
            throw AgentLaunchError.panelIsNotTerminal
        }
        return ManagedLaunchTarget(
            windowID: location.windowID,
            workspaceID: location.workspaceID,
            panelID: panelID,
            cwd: terminalState.agentLaunchWorkingDirectory
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
        workingDirectory: String?,
        codexStatusTrackingSource: CodexStatusTrackingSource
    ) -> PreparedAgentLaunchCommand {
        do {
            return try AgentLaunchInstrumentation.prepare(
                agent: agent,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                codexStatusTrackingSource: codexStatusTrackingSource
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

    private func statusTrackingSource(for agent: AgentKind) -> CodexStatusTrackingSource {
        guard agent == .codex else {
            return .hooks
        }
        return codexStatusTrackingSourceProvider()
    }

    private func logCodexStatusTrackingSourceIfNeeded(
        agent: AgentKind,
        source: CodexStatusTrackingSource,
        sessionID: String,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID
    ) {
        guard agent == .codex else {
            return
        }

        ToasttyLog.info(
            "Selected Codex status tracking source",
            category: .terminal,
            metadata: [
                "session_id": sessionID,
                "panel_id": panelID.uuidString,
                "window_id": windowID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "source": source.code,
                "fallback_reason": source.fallbackReason ?? "none",
            ]
        )
    }

    private func registerManagedArtifacts(
        _ preparedArtifacts: PreparedAgentLaunchArtifacts?,
        sessionID: String,
        codexStatusTrackingSource: CodexStatusTrackingSource
    ) {
        guard let preparedArtifacts else { return }

        let watcher: CodexSessionLogWatcher?
        if let logURL = preparedArtifacts.codexSessionLogURL {
            watcher = makeCodexSessionLogWatcher(
                sessionID: sessionID,
                logURL: logURL,
                codexStatusTrackingSource: codexStatusTrackingSource
            )
        } else {
            watcher = nil
        }

        let managedArtifacts = ManagedLaunchArtifacts(
            directoryURL: preparedArtifacts.directoryURL,
            codexSessionLogWatcher: watcher,
            cleanupPolicy: preparedArtifacts.cleanupPolicy
        )
        watcher?.start()
        managedArtifactsBySessionID[sessionID] = managedArtifacts
    }

    private func makeCodexSessionLogWatcher(
        sessionID: String,
        logURL: URL,
        codexStatusTrackingSource: CodexStatusTrackingSource
    ) -> CodexSessionLogWatcher {
        // TODO: Remove this watcher once Codex exposes stable start/approval hooks.
        CodexSessionLogWatcher(logURL: logURL) { [weak self] event in
            guard let self else { return }
            if event.kind == .sessionConfigured {
                await self.handleCodexSessionConfiguredEvent(event, sessionID: sessionID)
                return
            }
            await self.handleCodexSessionStatusEvent(
                event,
                sessionID: sessionID,
                codexStatusTrackingSource: codexStatusTrackingSource
            )
        }
    }

    private func handleCodexSessionConfiguredEvent(
        _ event: CodexSessionLogEvent,
        sessionID: String
    ) async {
        guard let store,
              let sessionRuntimeStore,
              let nativeSessionID = event.nativeSessionID,
              let activeSession = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID),
              let cwd = normalizedNonEmpty(activeSession.cwd) else {
            return
        }
        sessionRuntimeStore.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: nil,
            threadID: nativeSessionID
        )

        guard let record = await codexResumeResolver.resumeRecord(
            threadID: nativeSessionID,
            rolloutPath: event.nativeSessionFilePath,
            expectedCWD: cwd,
            capturedAt: nowProvider()
        ) else {
            ToasttyLog.debug(
                "Codex session_configured event did not match a resumable native session",
                category: .terminal,
                metadata: [
                    "session_id": sessionID,
                    "native_session_id": nativeSessionID,
                    "native_session_file": event.nativeSessionFilePath ?? "none",
                ]
            )
            return
        }
        guard let currentActiveSession = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID),
              normalizedNonEmpty(currentActiveSession.cwd) == cwd else {
            return
        }

        nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
        let didUpdate = store.send(
            .updateTerminalPanelResumeRecord(panelID: currentActiveSession.panelID, resumeRecord: record)
        )
        guard didUpdate else { return }
        ToasttyLog.info(
            "Captured Codex native resume record from session log",
            category: .terminal,
            metadata: [
                "session_id": sessionID,
                "panel_id": currentActiveSession.panelID.uuidString,
                "native_session_id": record.nativeSessionID,
            ]
        )
    }

    private func handleCodexSessionStatusEvent(
        _ event: CodexSessionLogEvent,
        sessionID: String,
        codexStatusTrackingSource: CodexStatusTrackingSource
    ) {
        guard let sessionRuntimeStore else {
            return
        }

        let status: SessionStatus
        switch event.kind {
        case .sessionConfigured:
            return
        case .turnContextUpdated:
            sessionRuntimeStore.recordCodexOverrideTurnContext(
                sessionID: sessionID,
                approvalPolicy: event.approvalPolicyField,
                approvalsReviewer: event.approvalsReviewerField
            )
            return
        case .turnStarted:
            if event.hasRootTurnContext {
                sessionRuntimeStore.recordCodexRootTurnInput(
                    sessionID: sessionID,
                    fingerprint: event.rootInputFingerprint,
                    threadID: event.rootThreadID,
                    turnID: event.rootTurnID,
                    approvalPolicy: event.approvalPolicy,
                    approvalsReviewer: event.approvalsReviewer
                )
            }
            guard codexStatusTrackingSource != .hooks else {
                return
            }
            status = SessionStatus(kind: .working, summary: "Working", detail: event.detail)
        case .historyUpdated:
            guard codexStatusTrackingSource != .hooks else {
                return
            }
            guard let panelID = sessionRuntimeStore
                .sessionRegistry
                .activeSession(sessionID: sessionID)?
                .panelID,
                  let visibleText = readVisibleText(panelID) else {
                return
            }
            _ = sessionRuntimeStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
                panelID: panelID,
                visibleText: visibleText,
                promptState: promptState(panelID),
                at: nowProvider()
            )
            return
        case .approvalNeeded:
            guard codexStatusTrackingSource != .hooks else {
                return
            }
            status = SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: event.detail)
        case .taskCompleted:
            guard codexStatusTrackingSource != .hooks else {
                return
            }
            _ = sessionRuntimeStore.handleCodexSessionLogCompletion(
                sessionID: sessionID,
                detail: event.detail,
                threadID: event.completionThreadID,
                turnID: event.completionTurnID,
                at: nowProvider()
            )
            return
        case .turnAborted:
            guard codexStatusTrackingSource != .hooks else {
                return
            }
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
            at: nowProvider()
        )
    }

    private func cleanupManagedArtifacts(forInactiveSessionsIn registry: SessionRegistry) async {
        let inactiveSessionIDs = managedArtifactsBySessionID.keys.filter { sessionID in
            registry.activeSession(sessionID: sessionID) == nil
        }
        for sessionID in inactiveSessionIDs {
            guard sessionRuntimeStore?.sessionRegistry.activeSession(sessionID: sessionID) == nil else {
                continue
            }
            nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
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
        // Claude hook files need to outlive session bookkeeping so late stop
        // hooks turn into no-op telemetry delivery instead of missing-file
        // shell errors.
        guard managedArtifacts.cleanupPolicy == .deleteImmediately else {
            return
        }
        try? fileManager.removeItem(at: managedArtifacts.directoryURL)
    }

    private static func locatePanel(
        _ panelID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspaceID: UUID)? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.panelState(for: panelID) != nil {
                    return (window.id, workspaceID)
                }
            }
        }
        return nil
    }

    static func defaultCodexStatusTrackingSource() -> CodexStatusTrackingSource {
        do {
            let status = try CodexStatusHookInstaller().installationStatus()
            guard status.isInstalled else {
                return .sessionLogFallback(reason: "hooks_\(status.state.rawValue)")
            }
            return .hooks
        } catch {
            return .sessionLogFallback(reason: "hook_status_unavailable")
        }
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
    let cleanupPolicy: LaunchArtifactsCleanupPolicy
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
