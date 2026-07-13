import Combine
import CoreState
import Foundation

@MainActor
protocol ManagedAgentLaunchPlanning: AnyObject {
    func prepareManagedLaunch(
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
    private var sessionRegistryObservation: AnyCancellable?
    private var managedArtifactsBySessionID: [String: ManagedLaunchArtifacts] = [:]
    private var codexRolloutWatchersBySessionID: [String: CodexRolloutSessionLogWatcherRegistration] = [:]

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
        codexResumeResolver: (any CodexManagedSessionResolving)? = nil
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
        guard let sessionRuntimeStore else {
            throw AgentLaunchError.serviceUnavailable
        }

        let target = try resolveManagedLaunchTarget(panelID: request.panelID)
        let resolvedCWD = normalizedNonEmpty(request.cwd) ?? target.cwd
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
            codexStatusTrackingSource: codexStatusTrackingSource
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
                launchEnvironment: launchEnvironment,
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

        let status: SessionStatus
        switch event.kind {
        case .sessionConfigured:
            return
        case .backgroundActivityStarted:
            handleCodexBackgroundActivityEvent(event, sessionID: sessionID)
            return
        case .backgroundActivityFinished:
            handleCodexBackgroundActivityEvent(event, sessionID: sessionID)
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
            _ = sessionRuntimeStore.handleCodexSessionLogApproval(
                sessionID: sessionID,
                detail: event.detail,
                threadID: event.rootThreadID,
                turnID: event.rootTurnID,
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

    private func handleCodexBackgroundActivityEvent(
        _ event: CodexSessionLogEvent,
        sessionID: String
    ) {
        guard let sessionRuntimeStore else {
            return
        }

        if sessionRuntimeStore.codexSessionLogFallbackEventsAreEnabled(sessionID: sessionID) == false {
            enrichCodexHookBackgroundActivity(
                from: event,
                sessionID: sessionID,
                sessionRuntimeStore: sessionRuntimeStore
            )
            return
        }

        switch event.kind {
        case .backgroundActivityStarted:
            guard let activity = event.backgroundActivity else {
                return
            }
            let now = nowProvider()
            _ = sessionRuntimeStore.updateBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: activity.activityID,
                    kind: activity.kind,
                    displayName: activity.displayName,
                    command: activity.command,
                    startedAt: now,
                    lastUpdatedAt: now
                ),
                at: now
            )

        case .backgroundActivityFinished:
            guard let activity = event.backgroundActivity else {
                return
            }
            _ = sessionRuntimeStore.finishBackgroundActivity(
                sessionID: sessionID,
                activityID: activity.activityID,
                at: nowProvider()
            )

        default:
            return
        }
    }

    private func enrichCodexHookBackgroundActivity(
        from event: CodexSessionLogEvent,
        sessionID: String,
        sessionRuntimeStore: SessionRuntimeStore
    ) {
        guard event.kind == .backgroundActivityStarted,
              let activity = event.backgroundActivity,
              let toolUseID = normalizedNonEmpty(activity.spawnToolUseID),
              let agentID = normalizedNonEmpty(activity.hookActivityID) else {
            return
        }

        _ = sessionRuntimeStore.recordCodexSubagentRolloutMetadata(
            sessionID: sessionID,
            toolUseID: toolUseID,
            agentID: agentID,
            displayName: meaningfulCodexSubagentDisplayName(activity.displayName),
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
        if codexRolloutWatchersBySessionID[sessionID]?.logURL == logURL {
            return
        }

        let previousWatcher = codexRolloutWatchersBySessionID[sessionID]?.watcher
        if previousWatcher != nil,
           sessionRuntimeStore?.codexSessionLogFallbackEventsAreEnabled(sessionID: sessionID) == true {
            // A replaced rollout claim means every subagent row sourced from the
            // old file is stale (e.g. a restored pane briefly claimed the prior
            // launch's rollout). The new file's replay rebuilds current state.
            _ = sessionRuntimeStore?.syncBackgroundActivities(
                sessionID: sessionID,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 0,
                at: nowProvider()
            )
        }
        let watcher = makeCodexRolloutSessionLogWatcher(sessionID: sessionID, logURL: logURL)
        codexRolloutWatchersBySessionID[sessionID] = CodexRolloutSessionLogWatcherRegistration(
            logURL: logURL,
            watcher: watcher
        )
        watcher.start()
        if let previousWatcher {
            Task { @MainActor in
                await previousWatcher.stop()
            }
        }
    }

    private func detachCodexRolloutWatcher(sessionID: String) {
        guard let registration = codexRolloutWatchersBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        Task { @MainActor in
            await registration.watcher.stop()
        }
    }

    private func makeCodexRolloutSessionLogWatcher(
        sessionID: String,
        logURL: URL
    ) -> CodexSessionLogWatcher {
        // Rollout files can be re-claimed across launches (workspace restore);
        // collab lifecycle entries older than this managed session belong to a
        // process that no longer exists.
        let multiAgentEventCutoff = sessionRuntimeStore?.sessionRegistry
            .activeSession(sessionID: sessionID)?
            .startedAt
        return CodexSessionLogWatcher(
            logURL: logURL,
            multiAgentEventCutoff: multiAgentEventCutoff
        ) { [weak self] event in
            await self?.handleCodexRolloutSessionLogEvent(
                event,
                sessionID: sessionID,
                logURL: logURL
            )
        }
    }

    private func handleCodexRolloutSessionLogEvent(
        _ event: CodexSessionLogEvent,
        sessionID: String,
        logURL: URL
    ) {
        guard codexRolloutWatchersBySessionID[sessionID]?.logURL == logURL else {
            return
        }
        switch event.kind {
        case .backgroundActivityStarted, .backgroundActivityFinished:
            handleCodexBackgroundActivityEvent(event, sessionID: sessionID)
        default:
            return
        }
    }

    private func cleanupManagedArtifacts(forInactiveSessionsIn registry: SessionRegistry) async {
        let trackedSessionIDs = Set(managedArtifactsBySessionID.keys)
            .union(codexRolloutWatchersBySessionID.keys)
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
        }
    }

    private func cleanupManagedArtifacts(for sessionID: String) async {
        guard let managedArtifacts = managedArtifactsBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        await cleanup(managedArtifacts)
    }

    private func cleanupCodexRolloutWatcher(for sessionID: String) async {
        guard let registration = codexRolloutWatchersBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        await registration.watcher.stop()
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

    var codexRolloutWatcherPathsForTesting: [String: String] {
        codexRolloutWatchersBySessionID.mapValues { registration in
            registration.logURL.path
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

private struct CodexRolloutSessionLogWatcherRegistration {
    let logURL: URL
    let watcher: CodexSessionLogWatcher
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}

private func meaningfulCodexSubagentDisplayName(_ value: String?) -> String? {
    guard let normalized = normalizedNonEmpty(value),
          normalized.caseInsensitiveCompare("default") != .orderedSame else {
        return nil
    }
    return normalized
}
