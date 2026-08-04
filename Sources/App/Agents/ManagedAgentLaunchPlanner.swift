import Combine
import CoreState
import Foundation

@MainActor
protocol ManagedAgentLaunchPlanning: AnyObject {
    func prepareManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>?
    ) throws -> ManagedAgentLaunchPlan
    func prepareManagedLaunchAsync(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>?
    ) async throws -> ManagedAgentLaunchPlan
    func prepareRestoredManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>?
    ) throws -> ManagedAgentLaunchPlan
    func discardManagedLaunch(sessionID: String)
    func cancelNativeSessionObservation(sessionID: String)
}

extension ManagedAgentLaunchPlanning {
    func prepareManagedLaunch(_ request: ManagedAgentLaunchRequest) throws -> ManagedAgentLaunchPlan {
        try prepareManagedLaunch(request, inheritedScopedWorkspaceIDs: nil)
    }

    func prepareManagedLaunchAsync(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) async throws -> ManagedAgentLaunchPlan {
        try prepareManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
    }

    func prepareRestoredManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) throws -> ManagedAgentLaunchPlan {
        try prepareManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
    }
}

@MainActor
final class ManagedAgentLaunchPlanner: ManagedAgentLaunchPlanning {
    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let fileManager: FileManager
    private let repositoryRootResolver: @MainActor (String?) -> RepositoryRootResolution
    private let nowProvider: @Sendable () -> Date
    private let cliExecutablePathProvider: @Sendable () -> String?
    private let socketPathProvider: @Sendable () -> String
    private let codexStatusTrackingSourceProvider: @MainActor () -> CodexStatusTrackingSource
    private let readVisibleText: @MainActor (UUID) -> String?
    private let promptState: @MainActor (UUID) -> TerminalPromptState
    private let nativeSessionObserverRegistry: any ManagedAgentNativeSessionObserving
    private let codexResumeResolver: any CodexManagedSessionResolving
    private let codexSkillsResolver: any CodexManagedLaunchSkillsResolving
    private let claudeSkillsBundleManager: any ClaudeSkillsBundleManaging
    private var sessionRegistryObservation: AnyCancellable?
    private var managedArtifactsBySessionID: [String: ManagedLaunchArtifacts] = [:]
    private var codexRolloutWatchersBySessionID: [String: CodexRolloutSessionLogWatcherRegistration] = [:]
    private var desiredCodexRolloutLogURLsBySessionID: [String: URL] = [:]
    private var codexRolloutWatcherTransitionsBySessionID: [String: CodexRolloutWatcherTransition] = [:]
    private var codexSessionLogCursorStatesByKey: [CodexSessionLogStreamKey: CodexSessionLogCursorStateRegistration] = [:]

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        fileManager: FileManager = .default,
        repositoryRootResolver: @escaping @MainActor (String?) -> RepositoryRootResolution = ManagedAgentLaunchPlanner.defaultRepositoryRootResolver,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String?,
        socketPathProvider: @escaping @Sendable () -> String,
        codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = ManagedAgentLaunchPlanner.defaultCodexStatusTrackingSource,
        readVisibleText: @escaping @MainActor (UUID) -> String?,
        promptState: @escaping @MainActor (UUID) -> TerminalPromptState,
        nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil,
        codexResumeResolver: (any CodexManagedSessionResolving)? = nil,
        codexSkillsResolver: (any CodexManagedLaunchSkillsResolving)? = nil,
        claudeSkillsBundleManager: (any ClaudeSkillsBundleManaging)? = nil
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.fileManager = fileManager
        self.repositoryRootResolver = repositoryRootResolver
        self.nowProvider = nowProvider
        self.cliExecutablePathProvider = cliExecutablePathProvider
        self.socketPathProvider = socketPathProvider
        self.codexStatusTrackingSourceProvider = codexStatusTrackingSourceProvider
        self.readVisibleText = readVisibleText
        self.promptState = promptState
        self.nativeSessionObserverRegistry = nativeSessionObserverRegistry
            ?? ManagedAgentNativeSessionObserverRegistry(
                store: store,
                sessionRuntimeStore: sessionRuntimeStore,
                fileManager: fileManager,
                nowProvider: nowProvider
            )
        self.codexResumeResolver = codexResumeResolver ?? CodexManagedSessionResolver()
        self.codexSkillsResolver = codexSkillsResolver
            ?? CodexManagedLaunchSkillsResolver(fileManager: fileManager)
        self.claudeSkillsBundleManager = claudeSkillsBundleManager
            ?? ClaudeSkillsBundleManager(fileManager: fileManager)
        sessionRegistryObservation = sessionRuntimeStore.$sessionRegistry.sink { [weak self] registry in
            Task { @MainActor in
                await self?.cleanupManagedArtifacts(forInactiveSessionsIn: registry)
            }
        }
        store.addActionAppliedObserver { [weak self] action, _, nextState in
            guard case .updateTerminalPanelResumeRecord = action else {
                return
            }
            self?.synchronizeCodexRolloutWatchers(with: nextState)
        }
    }

    func prepareManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) throws -> ManagedAgentLaunchPlan {
        let target = try resolveManagedLaunchTarget(panelID: request.panelID)
        let assessedWorkingDirectory = normalizedNonEmpty(request.cwd) ?? target.cwd
        let codexSkillsDecision = request.agent == .codex
            ? codexSkillsResolver.resolve(
                request: request,
                workingDirectory: assessedWorkingDirectory
            )
            : nil
        let claudeSkillsConfiguration = request.agent == .claude
            ? claudeSkillsBundleManager.existingVerifiedConfiguration()
            : nil
        return try prepareManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs,
            codexSkillsDecision: codexSkillsDecision,
            claudeSkillsConfiguration: claudeSkillsConfiguration,
            assessedWorkingDirectory: assessedWorkingDirectory
        )
    }

    func prepareManagedLaunchAsync(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) async throws -> ManagedAgentLaunchPlan {
        let target = try resolveManagedLaunchTarget(panelID: request.panelID)
        let assessedWorkingDirectory = normalizedNonEmpty(request.cwd) ?? target.cwd
        let codexSkillsDecision = request.agent == .codex
            ? await codexSkillsResolver.resolveForManagedLaunch(
                request: request,
                workingDirectory: assessedWorkingDirectory
            )
            : nil
        let claudeSkillsConfiguration = request.agent == .claude
            ? await claudeSkillsBundleManager.prepareForManagedLaunch()
            : nil
        let plan = try prepareManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs,
            codexSkillsDecision: codexSkillsDecision,
            claudeSkillsConfiguration: claudeSkillsConfiguration,
            assessedWorkingDirectory: assessedWorkingDirectory
        )
        postSkillsProvisionedNoticeIfNeeded(
            request: request,
            windowID: target.windowID,
            codexSkillsDecision: codexSkillsDecision,
            claudeSkillsConfiguration: claudeSkillsConfiguration
        )
        return plan
    }

    func prepareRestoredManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) throws -> ManagedAgentLaunchPlan {
        let target = try resolveManagedLaunchTarget(panelID: request.panelID)
        let assessedWorkingDirectory = normalizedNonEmpty(request.cwd) ?? target.cwd
        let codexSkillsDecision = request.agent == .codex
            ? codexSkillsResolver.resolveForRestoredManagedLaunch(
                request: request,
                workingDirectory: assessedWorkingDirectory
            )
            : nil
        let claudeSkillsConfiguration = request.agent == .claude
            ? claudeSkillsBundleManager.prepareForRestoredManagedLaunch()
            : nil
        let plan = try prepareManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs,
            codexSkillsDecision: codexSkillsDecision,
            claudeSkillsConfiguration: claudeSkillsConfiguration,
            assessedWorkingDirectory: assessedWorkingDirectory
        )
        postSkillsProvisionedNoticeIfNeeded(
            request: request,
            windowID: target.windowID,
            codexSkillsDecision: codexSkillsDecision,
            claudeSkillsConfiguration: claudeSkillsConfiguration
        )
        return plan
    }

    private func postSkillsProvisionedNoticeIfNeeded(
        request: ManagedAgentLaunchRequest,
        windowID: UUID,
        codexSkillsDecision: CodexManagedLaunchSkillsDecision?,
        claudeSkillsConfiguration: ClaudeSkillsLaunchConfiguration?
    ) {
        let isAvailable: Bool
        if request.agent == .codex {
            isAvailable = codexSkillsDecision?.configuration != nil
                && codexSkillsDecision?.status?.isReady == true
        } else if request.agent == .claude {
            isAvailable = claudeSkillsConfiguration != nil
        } else {
            isAvailable = false
        }
        guard isAvailable else { return }
        NotificationCenter.default.post(
            name: .toasttyManagedAgentSkillsProvisioned,
            object: ManagedAgentSkillsProvisionedNotice(
                windowID: windowID,
                agent: request.agent
            )
        )
    }

    private func prepareManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>?,
        codexSkillsDecision: CodexManagedLaunchSkillsDecision?,
        claudeSkillsConfiguration: ClaudeSkillsLaunchConfiguration?,
        assessedWorkingDirectory: String?
    ) throws -> ManagedAgentLaunchPlan {
        guard let sessionRuntimeStore else {
            throw AgentLaunchError.serviceUnavailable
        }

        let target = try resolveManagedLaunchTarget(panelID: request.panelID)
        let resolvedCWD = normalizedNonEmpty(request.cwd) ?? target.cwd
        let effectiveCodexSkillsConfiguration: CodexSkillsLaunchConfiguration? = if request.agent == .codex,
                                                                                    resolvedCWD != assessedWorkingDirectory {
            nil
        } else {
            codexSkillsDecision?.configuration
        }
        let repoRootResolution = repositoryRootResolver(resolvedCWD)
        let repoRoot = repoRootResolution.repoRoot
        logRepositoryRootResolutionIfNeeded(
            repoRootResolution,
            cwd: resolvedCWD,
            agent: request.agent,
            panelID: target.panelID
        )
        let cliExecutablePath = try resolveCLIExecutablePath()
        let sessionID = UUID().uuidString
        let codexStatusTrackingSource = statusTrackingSource(for: request.agent)
        let preparedLaunch = prepareLaunch(
            agent: request.agent,
            argv: request.argv,
            cliExecutablePath: cliExecutablePath,
            sessionID: sessionID,
            workingDirectory: resolvedCWD,
            launchEnvironment: request.environment,
            codexStatusTrackingSource: codexStatusTrackingSource,
            codexSkillsIntegration: effectiveCodexSkillsConfiguration,
            claudeSkillsIntegration: claudeSkillsConfiguration
        )
        let launchStart = nowProvider()
        let parentSessionID = resolvedParentSessionID(
            for: request,
            panelID: target.panelID,
            sessionRuntimeStore: sessionRuntimeStore,
            at: launchStart
        )

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: request.agent,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            parentSessionID: parentSessionID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: request.agent == .codex ? codexStatusTrackingSource : nil,
            cwd: resolvedCWD,
            repoRoot: repoRoot,
            scopedWorkspaceIDs: inheritedScopedWorkspaceIDs,
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
                    launchStart: launchStart,
                    expectedNativeSessionID: ManagedAgentResumeResolver.expectedNativeSessionID(
                        agent: request.agent,
                        argv: request.argv
                    )
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

        var environment = request.environment
        for (key, value) in AgentLaunchInstrumentation.baselineEnvironment(for: request.agent) {
            environment[key] = value
        }
        for (key, value) in preparedLaunch.environment {
            environment[key] = value
        }
        environment[ToasttyLaunchContextEnvironment.sessionIDKey] = sessionID
        environment[ToasttyLaunchContextEnvironment.agentKey] = request.agent.rawValue
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

    private static func defaultRepositoryRootResolver(_ cwd: String?) -> RepositoryRootResolution {
        RepositoryRootLocator.inferRepoRootBestEffort(from: cwd)
    }

    private func logRepositoryRootResolutionIfNeeded(
        _ resolution: RepositoryRootResolution,
        cwd: String?,
        agent: AgentKind,
        panelID: UUID
    ) {
        let metadata = [
            "agent": agent.rawValue,
            "panel_id": panelID.uuidString,
            "cwd_present": normalizedNonEmpty(cwd) == nil ? "false" : "true",
            "repo_root_found": resolution.repoRoot == nil ? "false" : "true",
            "duration_seconds": Self.formattedSeconds(resolution.duration),
            "timeout_seconds": Self.formattedSeconds(RepositoryRootLocator.defaultBestEffortTimeout),
        ]

        if resolution.timedOut {
            ToasttyLog.warning(
                "Timed out inferring repository root for managed agent launch",
                category: .terminal,
                metadata: metadata
            )
            return
        }

        guard resolution.duration >= RepositoryRootLocator.slowInferenceThreshold else {
            return
        }

        ToasttyLog.info(
            "Repository root inference was slow for managed agent launch",
            category: .terminal,
            metadata: metadata
        )
    }

    private static func formattedSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    func discardManagedLaunch(sessionID: String) {
        guard let sessionRuntimeStore else {
            return
        }
        nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
        sessionRuntimeStore.stopSession(sessionID: sessionID, at: nowProvider())
        Task { @MainActor in
            await cleanupManagedArtifacts(for: sessionID)
            await cleanupCodexRolloutWatcher(for: sessionID)
            removeCodexSessionLogCursorStates(for: sessionID)
        }
    }

    func cancelNativeSessionObservation(sessionID: String) {
        nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
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
        launchEnvironment: [String: String],
        codexStatusTrackingSource: CodexStatusTrackingSource,
        codexSkillsIntegration: CodexSkillsLaunchConfiguration?,
        claudeSkillsIntegration: ClaudeSkillsLaunchConfiguration?
    ) -> PreparedAgentLaunchCommand {
        do {
            return try AgentLaunchInstrumentation.prepare(
                agent: agent,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                launchEnvironment: launchEnvironment,
                codexStatusTrackingSource: codexStatusTrackingSource,
                codexSkillsIntegration: codexSkillsIntegration,
                claudeSkillsIntegration: claudeSkillsIntegration
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
            if agent == .codex, codexSkillsIntegration != nil,
               let fallback = try? AgentLaunchInstrumentation.prepare(
                    agent: agent,
                    argv: argv,
                    cliExecutablePath: cliExecutablePath,
                    sessionID: sessionID,
                    workingDirectory: workingDirectory,
                    fileManager: fileManager,
                    launchEnvironment: launchEnvironment,
                    codexStatusTrackingSource: codexStatusTrackingSource,
                    codexSkillsIntegration: nil
               ) {
                return fallback
            }
            return PreparedAgentLaunchCommand(argv: argv, environment: [:], artifacts: nil)
        }
    }

    private func statusTrackingSource(for agent: AgentKind) -> CodexStatusTrackingSource {
        guard agent == .codex else {
            return .hooks
        }
        return codexStatusTrackingSourceProvider()
    }

    private func resolvedParentSessionID(
        for request: ManagedAgentLaunchRequest,
        panelID: UUID,
        sessionRuntimeStore: SessionRuntimeStore,
        at now: Date
    ) -> String? {
        if let parentSessionID = request.parentSessionID {
            sessionRuntimeStore.discardPendingPanelParentSessionID(forPanelID: panelID)
            return parentSessionID
        }
        return sessionRuntimeStore.consumePendingPanelParentSessionID(
            forPanelID: panelID,
            at: now
        )
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
        synchronizeCodexRolloutWatcherForActiveSession(sessionID: sessionID)
    }

    private func makeCodexSessionLogWatcher(
        sessionID: String,
        logURL: URL,
        codexStatusTrackingSource: CodexStatusTrackingSource
    ) -> CodexSessionLogWatcher {
        // TODO: Remove this watcher once Codex exposes stable start/approval hooks.
        CodexSessionLogWatcher(
            logURL: logURL,
            cursorState: codexSessionLogCursorState(
                sessionID: sessionID,
                stream: .launchLog,
                logURL: logURL
            )
        ) { [weak self] event in
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

        var scopedRecord = record
        scopedRecord.scopedWorkspaceIDs = currentActiveSession.scopedWorkspaceIDs
        guard shouldAcceptCodexSessionLogResumeRecord(
            scopedRecord,
            activeSession: currentActiveSession,
            sessionID: sessionID
        ) else {
            return
        }
        nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
        let didUpdate = store.send(
            .updateTerminalPanelResumeRecord(panelID: currentActiveSession.panelID, resumeRecord: scopedRecord)
        )
        guard didUpdate else { return }
        ToasttyLog.info(
            "Captured Codex native resume record from session log",
            category: .terminal,
            metadata: [
                "session_id": sessionID,
                "panel_id": currentActiveSession.panelID.uuidString,
                "native_session_id": scopedRecord.nativeSessionID,
                "workspace_scope": workspaceScopeMetadata(currentActiveSession.scopedWorkspaceIDs),
            ]
        )
    }

    private func shouldAcceptCodexSessionLogResumeRecord(
        _ resumeRecord: ManagedAgentResumeRecord,
        activeSession: SessionRecord,
        sessionID: String
    ) -> Bool {
        guard let store,
              let sessionRuntimeStore,
              let ownerPanelID = store.state.panelIDOwningManagedAgentResumeRecord(
                agent: resumeRecord.agent,
                nativeSessionID: resumeRecord.nativeSessionID
              ),
              ownerPanelID != activeSession.panelID,
              let ownerSession = sessionRuntimeStore.sessionRegistry.activeSession(for: ownerPanelID),
              ownerSession.agent == resumeRecord.agent else {
            return true
        }

        ToasttyLog.info(
            "Refused Codex session log resume record because native session is owned by an active panel",
            category: .terminal,
            metadata: [
                "session_id": sessionID,
                "agent": resumeRecord.agent.rawValue,
                "panel_id": activeSession.panelID.uuidString,
                "owner_panel_id": ownerPanelID.uuidString,
                "owner_session_id": ownerSession.sessionID,
                "native_session_id": resumeRecord.nativeSessionID,
                "session_file_basename": (resumeRecord.sessionFilePath as NSString).lastPathComponent,
                "cwd": resumeRecord.cwd,
                "workspace_scope": workspaceScopeMetadata(activeSession.scopedWorkspaceIDs),
                "owner_workspace_scope": workspaceScopeMetadata(ownerSession.scopedWorkspaceIDs),
            ]
        )
        return false
    }

    private func workspaceScopeMetadata(_ scope: Set<UUID>?) -> String {
        guard let scope else { return "unrestricted" }
        if scope.isEmpty { return "own_workspace_only" }
        return scope
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }

    private func handleCodexSessionStatusEvent(
        _ event: CodexSessionLogEvent,
        sessionID: String,
        codexStatusTrackingSource: CodexStatusTrackingSource
    ) {
        guard let sessionRuntimeStore else {
            return
        }

        switch event.kind {
        case .sessionConfigured:
            return
        case .backgroundActivityStarted:
            forwardCodexBackgroundActivityObservation(event, sessionID: sessionID)
            return
        case .backgroundActivityFinished:
            forwardCodexBackgroundActivityObservation(event, sessionID: sessionID)
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
                    approvalPolicyField: event.approvalPolicyField,
                    approvalsReviewerField: event.approvalsReviewerField
                )
            }
            _ = sessionRuntimeStore.handleCodexSessionLogRootProgressObservation(
                sessionID: sessionID,
                observation: .sessionLogWorking(detail: event.detail),
                at: nowProvider()
            )
            return
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
            _ = sessionRuntimeStore.handleCodexSessionLogApproval(
                sessionID: sessionID,
                detail: event.detail,
                threadID: event.rootThreadID,
                turnID: event.rootTurnID,
                callID: event.callID,
                approvalID: event.approvalID,
                at: nowProvider()
            )
            return
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
            _ = sessionRuntimeStore.handleCodexSessionLogRootProgressObservation(
                sessionID: sessionID,
                observation: .sessionLogTurnAborted(detail: event.detail),
                at: nowProvider()
            )
            return
        }
    }

    private func forwardCodexBackgroundActivityObservation(
        _ event: CodexSessionLogEvent,
        sessionID: String
    ) {
        guard let sessionRuntimeStore,
              let activity = event.backgroundActivity else {
            return
        }

        let observation: CodexSubagentRolloutObservation
        switch event.kind {
        case .backgroundActivityStarted:
            observation = .started(activity)
        case .backgroundActivityFinished:
            observation = .finished(activity)
        default:
            return
        }
        _ = sessionRuntimeStore.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: observation,
            at: nowProvider()
        )
    }

    private func synchronizeCodexRolloutWatchers(with state: AppState) {
        guard let sessionRuntimeStore else {
            return
        }

        let activeSessions = sessionRuntimeStore.sessionRegistry.sessionsByID.values.compactMap { record in
            sessionRuntimeStore.sessionRegistry.activeSession(sessionID: record.sessionID)
        }
        let activeSessionIDs = Set(activeSessions.map(\.sessionID))
        for sessionID in Array(codexRolloutWatchersBySessionID.keys) where activeSessionIDs.contains(sessionID) == false {
            detachCodexRolloutWatcher(sessionID: sessionID)
        }
        for activeSession in activeSessions {
            synchronizeCodexRolloutWatcher(for: activeSession, state: state)
        }
    }

    private func synchronizeCodexRolloutWatcherForActiveSession(sessionID: String) {
        guard let store,
              let sessionRuntimeStore,
              let activeSession = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID) else {
            return
        }
        synchronizeCodexRolloutWatcher(for: activeSession, state: store.state)
    }

    private func synchronizeCodexRolloutWatcher(
        for activeSession: SessionRecord,
        state: AppState
    ) {
        guard activeSession.agent == .codex else {
            detachCodexRolloutWatcher(sessionID: activeSession.sessionID)
            return
        }
        guard case .terminal(let terminalState)? = state
            .workspaceSelection(containingPanelID: activeSession.panelID)?
            .workspace
            .panelState(for: activeSession.panelID),
            let resumeRecord = terminalState.resumeRecord,
            resumeRecord.agent == .codex,
            resumeRecord.capturedAt >= activeSession.startedAt,
            let rolloutPath = normalizedNonEmpty(resumeRecord.sessionFilePath) else {
            detachCodexRolloutWatcher(sessionID: activeSession.sessionID)
            return
        }

        attachCodexRolloutWatcher(
            sessionID: activeSession.sessionID,
            logURL: URL(fileURLWithPath: rolloutPath)
        )
    }

    private func attachCodexRolloutWatcher(sessionID: String, logURL: URL) {
        let previousLogURL = codexRolloutWatchersBySessionID[sessionID]?.logURL
        desiredCodexRolloutLogURLsBySessionID[sessionID] = logURL
        if previousLogURL != nil,
           previousLogURL != logURL {
            // A replaced rollout claim means every subagent row sourced from the
            // old file is stale in fallback mode. Hook authority retains its
            // projected rows and correlation state across watcher replacement.
            _ = sessionRuntimeStore?.handleCodexSubagentRolloutObservation(
                sessionID: sessionID,
                observation: .streamReset,
                at: nowProvider()
            )
        }
        reconcileCodexRolloutWatcher(sessionID: sessionID)
    }

    private func detachCodexRolloutWatcher(sessionID: String) {
        desiredCodexRolloutLogURLsBySessionID.removeValue(forKey: sessionID)
        reconcileCodexRolloutWatcher(sessionID: sessionID)
    }

    /// Replacements are serialized so two watchers never parse or checkpoint
    /// the same managed-session stream concurrently. Requests received while a
    /// watcher is stopping are coalesced to the latest desired URL.
    private func reconcileCodexRolloutWatcher(sessionID: String) {
        guard codexRolloutWatcherTransitionsBySessionID[sessionID] == nil else {
            return
        }
        let desiredLogURL = desiredCodexRolloutLogURLsBySessionID[sessionID]
        guard let registration = codexRolloutWatchersBySessionID[sessionID] else {
            guard let desiredLogURL else {
                return
            }
            startCodexRolloutWatcher(sessionID: sessionID, logURL: desiredLogURL)
            return
        }
        guard registration.logURL != desiredLogURL else {
            return
        }

        let transitionID = UUID()
        let task = Task { @MainActor [weak self] in
            await registration.watcher.stop()
            guard let self else { return }
            if self.codexRolloutWatchersBySessionID[sessionID]?.id == registration.id {
                self.codexRolloutWatchersBySessionID.removeValue(forKey: sessionID)
            }
            guard self.codexRolloutWatcherTransitionsBySessionID[sessionID]?.id == transitionID else {
                return
            }
            self.codexRolloutWatcherTransitionsBySessionID.removeValue(forKey: sessionID)
            self.reconcileCodexRolloutWatcher(sessionID: sessionID)
        }
        codexRolloutWatcherTransitionsBySessionID[sessionID] = CodexRolloutWatcherTransition(
            id: transitionID,
            task: task
        )
    }

    private func startCodexRolloutWatcher(sessionID: String, logURL: URL) {
        let registrationID = UUID()
        let watcher = makeCodexRolloutSessionLogWatcher(
            sessionID: sessionID,
            logURL: logURL,
            registrationID: registrationID
        )
        codexRolloutWatchersBySessionID[sessionID] = CodexRolloutSessionLogWatcherRegistration(
            id: registrationID,
            logURL: logURL,
            watcher: watcher
        )
        watcher.start()
    }

    private func makeCodexRolloutSessionLogWatcher(
        sessionID: String,
        logURL: URL,
        registrationID: UUID
    ) -> CodexSessionLogWatcher {
        // Rollout files can be re-claimed across launches (workspace restore);
        // collab lifecycle entries older than this managed session belong to a
        // process that no longer exists.
        let multiAgentEventCutoff = sessionRuntimeStore?.sessionRegistry
            .activeSession(sessionID: sessionID)?
            .startedAt
        return CodexSessionLogWatcher(
            logURL: logURL,
            multiAgentEventCutoff: multiAgentEventCutoff,
            cursorState: codexSessionLogCursorState(
                sessionID: sessionID,
                stream: .canonicalRollout,
                logURL: logURL
            )
        ) { [weak self] event in
            await self?.handleCodexRolloutSessionLogEvent(
                event,
                sessionID: sessionID,
                logURL: logURL,
                registrationID: registrationID
            )
        }
    }

    private func handleCodexRolloutSessionLogEvent(
        _ event: CodexSessionLogEvent,
        sessionID: String,
        logURL: URL,
        registrationID: UUID
    ) {
        guard let registration = codexRolloutWatchersBySessionID[sessionID],
              registration.id == registrationID,
              registration.logURL == logURL,
              desiredCodexRolloutLogURLsBySessionID[sessionID] == logURL else {
            return
        }
        switch event.kind {
        case .backgroundActivityStarted, .backgroundActivityFinished:
            forwardCodexBackgroundActivityObservation(event, sessionID: sessionID)
        default:
            return
        }
    }

    private func cleanupManagedArtifacts(forInactiveSessionsIn registry: SessionRegistry) async {
        let trackedSessionIDs = Set(managedArtifactsBySessionID.keys)
            .union(codexRolloutWatchersBySessionID.keys)
            .union(desiredCodexRolloutLogURLsBySessionID.keys)
            .union(codexRolloutWatcherTransitionsBySessionID.keys)
        let inactiveSessionIDs = trackedSessionIDs.filter { sessionID in
            registry.activeSession(sessionID: sessionID) == nil
        }
        for sessionID in inactiveSessionIDs {
            guard sessionRuntimeStore?.sessionRegistry.activeSession(sessionID: sessionID) == nil else {
                continue
            }
            nativeSessionObserverRegistry.cancelObservation(sessionID: sessionID)
            await cleanupManagedArtifacts(for: sessionID)
            await cleanupCodexRolloutWatcher(for: sessionID)
            removeCodexSessionLogCursorStates(for: sessionID)
        }
    }

    private func cleanupManagedArtifacts(for sessionID: String) async {
        guard let managedArtifacts = managedArtifactsBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        await cleanup(managedArtifacts)
    }

    private func cleanupCodexRolloutWatcher(for sessionID: String) async {
        desiredCodexRolloutLogURLsBySessionID.removeValue(forKey: sessionID)
        if let transition = codexRolloutWatcherTransitionsBySessionID[sessionID] {
            await transition.task.value
        }
        if let registration = codexRolloutWatchersBySessionID.removeValue(forKey: sessionID) {
            await registration.watcher.stop()
        }
        codexRolloutWatcherTransitionsBySessionID.removeValue(forKey: sessionID)
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

    private func codexSessionLogCursorState(
        sessionID: String,
        stream: CodexSessionLogStream,
        logURL: URL
    ) -> CodexSessionLogCursorState {
        let key = CodexSessionLogStreamKey(
            sessionID: sessionID,
            stream: stream
        )
        let standardizedPath = logURL.standardizedFileURL.path
        if let registration = codexSessionLogCursorStatesByKey[key],
           registration.standardizedPath == standardizedPath {
            return registration.cursorState
        }
        let cursorState = CodexSessionLogCursorState()
        codexSessionLogCursorStatesByKey[key] = CodexSessionLogCursorStateRegistration(
            standardizedPath: standardizedPath,
            cursorState: cursorState
        )
        return cursorState
    }

    private func removeCodexSessionLogCursorStates(for sessionID: String) {
        codexSessionLogCursorStatesByKey = codexSessionLogCursorStatesByKey.filter { key, _ in
            key.sessionID != sessionID
        }
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

    var codexRolloutWatcherPathsForTesting: [String: String] {
        codexRolloutWatchersBySessionID.mapValues { registration in
            registration.logURL.path
        }
    }

    var codexSessionLogCursorStateCountForTesting: Int {
        codexSessionLogCursorStatesByKey.count
    }

    var codexRolloutWatcherTransitionCountForTesting: Int {
        codexRolloutWatcherTransitionsBySessionID.count
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

private struct CodexRolloutSessionLogWatcherRegistration {
    let id: UUID
    let logURL: URL
    let watcher: CodexSessionLogWatcher
}

private struct CodexRolloutWatcherTransition {
    let id: UUID
    let task: Task<Void, Never>
}

private enum CodexSessionLogStream: Hashable {
    case launchLog
    case canonicalRollout
}

private struct CodexSessionLogStreamKey: Hashable {
    let sessionID: String
    let stream: CodexSessionLogStream
}

private struct CodexSessionLogCursorStateRegistration {
    let standardizedPath: String
    let cursorState: CodexSessionLogCursorState
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
