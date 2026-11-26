import RemoteProtocol
import CoreState
import Foundation

@MainActor
protocol TerminalCommandRouting: AnyObject {
    @discardableResult
    func sendManagedAgentCommand(
        _ commandLine: String,
        panelID: UUID,
        focusPolicy: TerminalInputFocusPolicy
    ) -> Bool
    /// The same delivery, reporting whether a failure happened before any
    /// text reached the terminal (`unavailable`) or possibly after
    /// (`uncertain`).
    func sendManagedAgentCommandResult(
        _ commandLine: String,
        panelID: UUID,
        focusPolicy: TerminalInputFocusPolicy
    ) -> TerminalInputDeliveryResult
    func isReadyForManagedAgentCommand(panelID: UUID) -> Bool
    func managedAgentRestoreState(panelID: UUID) -> TerminalManagedAgentRestoreState
    func readVisibleText(panelID: UUID) -> String?
    func promptState(panelID: UUID) -> TerminalPromptState
}

extension TerminalCommandRouting {
    func managedAgentRestoreState(panelID: UUID) -> TerminalManagedAgentRestoreState { .inactive }
}

extension TerminalRuntimeRegistry: TerminalCommandRouting {}

struct AgentLaunchResult: Equatable {
    let agent: AgentKind
    let displayName: String
    let sessionID: String
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let cwd: String?
    let repoRoot: String?
    let commandLine: String
}

enum AgentLaunchError: LocalizedError, Equatable {
    case serviceUnavailable
    case noProfilesConfigured
    case profileNotFound(profileID: String, availableProfileIDs: [String])
    case noSelectedWorkspace
    case workspaceDoesNotExist
    case workspaceHasNoTerminalPanel
    case panelDoesNotExist
    case panelOutsideWorkspace
    case panelIsNotTerminal
    case panelBusy(runningCommand: String?)
    case cliUnavailable(path: String?)
    case terminalUnavailable(panelID: UUID)
    /// Part of the command may be in the terminal, so sending it again
    /// could run it twice.
    case commandDeliveryUncertain(panelID: UUID)
    case invalidWorkingDirectory(path: String)
    case invalidLaunchEnvironment(message: String)
    case launchOverrideUnsupported(parameter: String, profileID: String)
    case invalidLaunchOverride(parameter: String, message: String)
    case unsafeLaunchOverrideArgv(profileID: String, message: String)
    case initialPromptUnsupported(profileID: String)
    case invalidInitialPrompt(message: String)
    case invalidInitialCommands(message: String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Agent launch is unavailable."
        case .noProfilesConfigured:
            return "No agents are configured. Edit ~/.toastty/agents.toml and try again."
        case .profileNotFound(let profileID, let availableProfileIDs):
            let availableProfiles: String
            if availableProfileIDs.isEmpty {
                availableProfiles = "No profiles are configured."
            } else {
                availableProfiles = "Available profiles: \(availableProfileIDs.joined(separator: ", "))."
            }
            return "Toastty could not find an agent profile named '\(profileID)' in ~/.toastty/agents.toml. \(availableProfiles)"
        case .noSelectedWorkspace:
            return "Select a workspace with a terminal panel before launching an agent."
        case .workspaceDoesNotExist:
            return "The target workspace no longer exists."
        case .workspaceHasNoTerminalPanel:
            return "The target workspace has no terminal panel to launch into."
        case .panelDoesNotExist:
            return "The target panel no longer exists."
        case .panelOutsideWorkspace:
            return "The target panel is not in the requested workspace."
        case .panelIsNotTerminal:
            return "Agents can only be launched in terminal panels."
        case .panelBusy(let runningCommand):
            if let runningCommand {
                return "The target terminal is still busy: \(runningCommand)"
            }
            return "The target terminal is not at an interactive prompt."
        case .cliUnavailable(let path):
            if let path {
                return "Toastty could not find its CLI at \(path). Reinstall the app or rebuild the toastty target and try again."
            }
            return "Toastty could not resolve its CLI path."
        case .commandDeliveryUncertain(let panelID):
            return "terminal surface did not confirm the launch command for panel \(panelID.uuidString)"
        case .terminalUnavailable(let panelID):
            return "The target terminal is unavailable for panel \(panelID.uuidString)."
        case .invalidWorkingDirectory(let path):
            return "Agent launch cwd must be an existing directory: \(path)"
        case .invalidLaunchEnvironment(let message):
            return "Agent launch environment is invalid: \(message)"
        case .launchOverrideUnsupported(let parameter, let profileID):
            return "Agent profile '\(profileID)' does not support \(parameter)."
        case .invalidLaunchOverride(let parameter, let message):
            return "Agent launch \(parameter) is invalid: \(message)"
        case .unsafeLaunchOverrideArgv(let profileID, let message):
            return "Agent profile '\(profileID)' argv cannot safely apply launch overrides: \(message)."
        case .initialPromptUnsupported(let profileID):
            return "Agent profile '\(profileID)' does not support initialPrompt."
        case .invalidInitialPrompt(let message):
            return "Agent launch initialPrompt is invalid: \(message)"
        case .invalidInitialCommands(let message):
            return "Agent launch initialCommands is invalid: \(message)"
        }
    }
}

/// A configured profile as a launch would resolve it.
struct AgentLaunchProfileSummary: Equatable, Sendable {
    var profileID: String
    var displayName: String
    var agent: AgentKind
    /// The profile's command resolves to an executable.
    var isInstalled: Bool
    /// A first prompt can be passed on the command line.
    var acceptsInitialPrompt: Bool
    /// A first prompt that starts with a dash is passed as text. False for a
    /// wrapper command, where the launcher cannot know how to mark the end
    /// of options.
    var acceptsLeadingDashPrompt: Bool
    var supportsModel: Bool
    var supportsReasoningEffort: Bool
}

@MainActor
final class AgentLaunchService: ManagedAgentLaunchPlanning {
    weak var quotaRecoveryConversationAccess: (any LocalConversationAccess)?

    private static let asyncPromptReadinessTimeout: Duration = .seconds(1)
    private static let asyncPromptReadinessPollInterval: Duration = .milliseconds(25)

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private weak var terminalCommandRouter: (any TerminalCommandRouting)?
    private let agentCatalogProvider: any AgentCatalogProviding
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let managedLaunchPlanner: any ManagedAgentLaunchPlanning
    private let codexProcessPathProvider: @Sendable () -> String?
    private let codexProcessPathRefreshProvider: @Sendable () -> String?
    /// The environment managed agents launch into, plus the shim directory to skip
    /// when resolving what a profile's command actually runs.
    private let managedAgentResolutionContextProvider: @Sendable () -> ManagedAgentResolutionContext
    /// App-scoped skills managers. Production creates exactly one of each in
    /// `ToasttyApp` and injects them here; the skills-management sheet must use
    /// these same instances so Repair/Uninstall act on the state the launch
    /// path reads.
    let codexSkillsManager: CodexSkillsManager
    let claudeSkillsBundleManager: any ClaudeSkillsBundleManaging
    let codexSkillsResolver: any CodexManagedLaunchSkillsResolving
    /// App-scoped user skill catalog, shared with the launch planner. The
    /// later management UI's Rescan goes through
    /// `userSkillCatalog.refreshUserSkills()` on this same instance.
    let userSkillCatalog: ToasttyUserSkillCatalog

    init(
        store: AppStore,
        terminalCommandRouter: any TerminalCommandRouting,
        sessionRuntimeStore: SessionRuntimeStore,
        agentCatalogProvider: any AgentCatalogProviding,
        codexSkillsManager: CodexSkillsManager? = nil,
        claudeSkillsBundleManager: (any ClaudeSkillsBundleManaging)? = nil,
        userSkillCatalog: ToasttyUserSkillCatalog? = nil,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = AgentLaunchService.defaultCLIExecutablePath,
        socketPathProvider: @escaping @Sendable () -> String = AgentLaunchService.defaultSocketPath,
        codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = ManagedAgentLaunchPlanner.defaultCodexStatusTrackingSource,
        nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil,
        codexSkillsResolver: (any CodexManagedLaunchSkillsResolving)? = nil,
        codexProcessPathProvider: @escaping @Sendable () -> String? = { nil },
        codexProcessPathRefreshProvider: @escaping @Sendable () -> String? = { nil },
        managedAgentResolutionContextProvider: @escaping @Sendable () -> ManagedAgentResolutionContext = {
            ManagedAgentResolutionContext(environment: ProcessInfo.processInfo.environment, shimDirectoryPaths: [])
        },
        managedAgentLaunchArtifactStore: ManagedAgentLaunchArtifactStore? = nil
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalCommandRouter = terminalCommandRouter
        self.agentCatalogProvider = agentCatalogProvider
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.codexProcessPathProvider = codexProcessPathProvider
        self.codexProcessPathRefreshProvider = codexProcessPathRefreshProvider
        self.managedAgentResolutionContextProvider = managedAgentResolutionContextProvider
        let resolvedCodexSkillsManager = codexSkillsManager
            ?? CodexSkillsManager(fileManager: fileManager)
        self.codexSkillsManager = resolvedCodexSkillsManager
        let resolvedClaudeSkillsBundleManager = claudeSkillsBundleManager
            ?? ClaudeSkillsBundleManager(fileManager: fileManager)
        self.claudeSkillsBundleManager = resolvedClaudeSkillsBundleManager
        let resolvedUserSkillCatalog = userSkillCatalog
            ?? ToasttyUserSkillCatalog(fileManager: fileManager)
        self.userSkillCatalog = resolvedUserSkillCatalog
        let resolvedCodexSkillsResolver = codexSkillsResolver
            ?? CodexManagedLaunchSkillsResolver(
                fileManager: fileManager,
                manager: resolvedCodexSkillsManager,
                processPathProvider: codexProcessPathProvider
            )
        self.codexSkillsResolver = resolvedCodexSkillsResolver
        managedLaunchPlanner = ManagedAgentLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            fileManager: fileManager,
            nowProvider: nowProvider,
            cliExecutablePathProvider: cliExecutablePathProvider,
            socketPathProvider: socketPathProvider,
            codexStatusTrackingSourceProvider: codexStatusTrackingSourceProvider,
            readVisibleText: { [weak terminalCommandRouter] panelID in
                terminalCommandRouter?.readVisibleText(panelID: panelID)
            },
            promptState: { [weak terminalCommandRouter] panelID in
                terminalCommandRouter?.promptState(panelID: panelID) ?? .unavailable
            },
            nativeSessionObserverRegistry: nativeSessionObserverRegistry,
            codexSkillsResolver: resolvedCodexSkillsResolver,
            claudeSkillsBundleManager: resolvedClaudeSkillsBundleManager,
            userSkillSnapshotProvider: resolvedUserSkillCatalog,
            managedAgentLaunchArtifactStore: managedAgentLaunchArtifactStore
        )
    }

    var codexProcessPathSnapshotProvider: @Sendable () -> String? {
        codexProcessPathProvider
    }

    var codexProcessPathRefresher: @Sendable () -> String? {
        codexProcessPathRefreshProvider
    }

    func canLaunchAgent(profileID: String? = nil, workspaceID: UUID? = nil, panelID: UUID? = nil) -> Bool {
        if let profileID {
            guard resolvedLaunchProfile(profileID: profileID) != nil else {
                return false
            }
        } else if agentCatalogProvider.catalog.profiles.isEmpty {
            return false
        }
        return (try? resolveLaunchTarget(workspaceID: workspaceID, panelID: panelID)) != nil
    }

    func launch(
        profileID: String,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil,
        cwd: String? = nil,
        environment: [String: String] = [:],
        model: String? = nil,
        reasoningEffort: String? = nil,
        initialPrompt: String? = nil,
        initialCommands: [String] = [],
        forkFromSessionID: String? = nil,
        additionalDirectories: [String] = [],
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil,
        parentSessionID: String? = nil,
        focusPolicy: TerminalInputFocusPolicy = .focusTarget
    ) throws -> AgentLaunchResult {
        let preparation = try makeLaunchPreparation(
            profileID: profileID,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            environment: environment,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            initialCommands: initialCommands,
            forkFromSessionID: forkFromSessionID,
            additionalDirectories: additionalDirectories,
            parentSessionID: parentSessionID,
            focusPolicy: focusPolicy
        )
        let plan = try managedLaunchPlanner.prepareManagedLaunch(
            preparation.request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
        return try completeLaunch(preparation, plan: plan)
    }

    func launchAsync(
        profileID: String,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil,
        cwd: String? = nil,
        environment: [String: String] = [:],
        model: String? = nil,
        reasoningEffort: String? = nil,
        initialPrompt: String? = nil,
        initialPromptWithoutSkills: String? = nil,
        initialCommands: [String] = [],
        forkFromSessionID: String? = nil,
        additionalDirectories: [String] = [],
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil,
        parentSessionID: String? = nil,
        focusPolicy: TerminalInputFocusPolicy = .focusTarget,
        codexProjectDocMaxBytes: Int? = nil,
        beforeDispatch: (@MainActor () throws -> Void)? = nil
    ) async throws -> AgentLaunchResult {
        let preparation = try makeLaunchPreparation(
            profileID: profileID,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            environment: environment,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            initialCommands: initialCommands,
            forkFromSessionID: forkFromSessionID,
            additionalDirectories: additionalDirectories,
            parentSessionID: parentSessionID,
            focusPolicy: focusPolicy,
            codexProjectDocMaxBytes: codexProjectDocMaxBytes,
            validatePromptState: false
        )
        guard let terminalCommandRouter else {
            throw AgentLaunchError.serviceUnavailable
        }
        try await ensurePanelBecomesInteractive(
            panelID: preparation.target.panelID,
            terminalCommandRouter: terminalCommandRouter
        )
        var plan = try await managedLaunchPlanner.prepareManagedLaunchAsync(
            preparation.request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
        // An agent that Toastty knows did not get its skills gets the first
        // message that says where they are.
        if plan.lacksShippedSkills, let initialPrompt, let initialPromptWithoutSkills,
           (try? normalizedInitialPrompt(initialPromptWithoutSkills)) != nil {
            plan = plan.replacingLastArgument(initialPrompt, with: initialPromptWithoutSkills)
        }
        // The caller's last check runs here, after the final suspension, so
        // nothing can change between it and the command reaching the shell.
        if let beforeDispatch {
            do {
                try beforeDispatch()
            } catch {
                managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
                throw error
            }
        }
        return try completeLaunch(preparation, plan: plan)
    }

    /// Prepare the new CLI before retiring the old process. Recheck the
    /// caller's turn and input facts after the last suspension. No input
    /// goes to the Claude process that is being replaced.
    func resumeClaudeAfterQuota(
        source: SessionRecord,
        nativeID: UUID,
        model: String,
        effort: String?,
        environment: [String: String] = [:],
        isStillEligible: @MainActor () -> Bool,
        adoptPanel: @MainActor (UUID, String) throws -> Void
    ) async throws -> AgentLaunchResult {
        guard let store, let terminalCommandRouter,
              let workspace = store.state.workspacesByID[source.workspaceID],
              let tabID = workspace.tabID(containingPanelID: source.panelID),
              let tab = workspace.tab(id: tabID),
              case .terminal(let previous)? = tab.panels[source.panelID],
              let resumeRecord = previous.resumeRecord,
              resumeRecord.agent == .claude, UUID(uuidString: resumeRecord.nativeSessionID) == nativeID,
              let binding = sessionRuntimeStore?.nativeSessionBindingConfirmation(for: source.sessionID),
              binding.panelID == source.panelID, binding.sessionFilePath == resumeRecord.sessionFilePath,
              let cwd = try normalizedExplicitWorkingDirectory(resumeRecord.cwd),
              FileManager.default.fileExists(atPath: resumeRecord.sessionFilePath),
              let permissionMode = claudeRecoveryPermissionMode(source: source),
              isStillEligible() else {
            throw TaskError("Claude's stopped conversation is not ready for model recovery.")
        }
        guard store.send(.splitPanel(
            workspaceID: source.workspaceID, tabID: tabID, panelID: source.panelID,
            direction: .right, profileBinding: nil, activate: false, useDefaultProfile: false
        )), let currentTab = store.state.workspacesByID[source.workspaceID]?.tab(id: tabID),
            let panelID = currentTab.panels.keys.first(where: { tab.panels[$0] == nil }) else {
            throw AgentLaunchError.workspaceHasNoTerminalPanel
        }
        var preparedSessionID: String?
        var adopted = false
        defer {
            if !adopted {
                if let preparedSessionID { managedLaunchPlanner.discardManagedLaunch(sessionID: preparedSessionID) }
                if sessionRuntimeStore?.lastLocalInputAt(panelID: panelID) == nil,
                   sessionRuntimeStore?.sessionRegistry.activeSession(for: panelID) == nil,
                   terminalCommandRouter.promptState(panelID: panelID).isIdleAtPrompt {
                    _ = store.send(.closePanel(panelID: panelID, preservesTabSelection: true))
                }
            }
        }
        var launchEnvironment = environment
        if model == ClaudeFableQuota.fallbackModel {
            // Claude Code reads this ahead of --effort. Keep the override
            // local to the fallback process, including when the shell has
            // a different default.
            launchEnvironment["CLAUDE_CODE_EFFORT_LEVEL"] = ClaudeFableQuota.fallbackEffort
        }
        var preparation = try makeLaunchPreparation(
            profileID: AgentKind.claude.rawValue, workspaceID: source.workspaceID, panelID: panelID,
            cwd: cwd, environment: launchEnvironment, model: model, reasoningEffort: effort,
            initialPrompt: nil, initialCommands: [], forkFromSessionID: nil, additionalDirectories: [],
            parentSessionID: source.parentSessionID, focusPolicy: .preserveFirstResponder,
            validatePromptState: false
        )
        let request = preparation.request
        preparation.request = ManagedAgentLaunchRequest(
            agent: request.agent, panelID: request.panelID,
            argv: try AgentLaunchArgumentOverrideAdapter.applyingClaudeQuotaResume(
                nativeID: nativeID, permissionMode: permissionMode, to: request.argv
            ),
            cwd: request.cwd, environment: request.environment, parentSessionID: request.parentSessionID
        )
        try await ensurePanelBecomesInteractive(panelID: panelID, terminalCommandRouter: terminalCommandRouter)
        let plan = try await managedLaunchPlanner.prepareManagedLaunchAsync(
            preparation.request, inheritedScopedWorkspaceIDs: source.scopedWorkspaceIDs
        )
        preparedSessionID = plan.sessionID
        try Task.checkCancellation()
        try ensurePanelAppearsInteractive(panelID: panelID, terminalCommandRouter: terminalCommandRouter)
        guard let currentSource = sessionRuntimeStore?.sessionRegistry.activeSession(for: source.panelID),
              currentSource.sessionID == source.sessionID, currentSource.scopedWorkspaceIDs == source.scopedWorkspaceIDs,
              sessionRuntimeStore?.lastLocalInputAt(panelID: panelID) == nil,
              sessionRuntimeStore?.sessionRegistry.activeSession(for: panelID)?.sessionID == plan.sessionID,
              sessionRuntimeStore?.nativeSessionBindingConfirmation(for: source.sessionID) == binding,
              let currentTab = store.state.workspacesByID[source.workspaceID]?.tab(id: tabID),
              case .terminal(let latest)? = currentTab.panels[source.panelID],
              latest.resumeRecord == resumeRecord, currentTab.panels[panelID] != nil,
              claudeRecoveryPermissionMode(source: source) == permissionMode,
              isStillEligible() else {
            throw TaskError("Claude's session or prompt changed while preparing model recovery.")
        }
        try adoptPanel(panelID, plan.sessionID)
        adopted = true
        guard store.send(.closePanel(panelID: source.panelID, preservesTabSelection: true)) else {
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw TaskError("Toastty could not retire the original Claude terminal.")
        }
        _ = store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord))
        _ = store.send(.updateTerminalPanelRemoteConversationID(panelID: panelID, remoteConversationID: latest.remoteConversationID))
        // Keep the adopted pane and resume record even if launch fails.
        return try completeLaunch(preparation, plan: plan)
    }

    func claudeRecoverySource(sessionID: String) -> SessionRecord? {
        guard let source = sessionRuntimeStore?.sessionRegistry.activeSession(sessionID: sessionID),
              source.agent == .claude else { return nil }
        return source
    }

    /// A failed turn can be followed by a Claude dialog. Require the
    /// conversation and the terminal to agree that the composer is empty.
    func claudeRecoveryPromptIsFree(source: SessionRecord) -> Bool {
        claudeRecoveryPermissionMode(source: source) != nil
    }

    private func claudeRecoveryPermissionMode(
        source: SessionRecord
    ) -> AgentLaunchArgumentOverrideAdapter.ClaudeQuotaRecoveryMode? {
        guard let runtime = sessionRuntimeStore,
              let session = runtime.sessionRegistry.activeSession(for: source.panelID),
              session.sessionID == source.sessionID,
              session.lastTurnEndedAt == source.lastTurnEndedAt,
              session.turnStartedAt == nil,
              session.status == source.status,
              session.backgroundActivitiesByID.isEmpty, session.pendingBackgroundTaskCount == 0,
              runtime.panelStatus(for: source.panelID)?.projection == SessionStatusProjection.none,
              let turnEnd = session.lastTurnEndedAt,
              (runtime.lastPromptInputAt(panelID: source.panelID) ?? .distantPast) <= turnEnd,
              case .openPrompt? = quotaRecoveryConversationAccess?.inputAvailability(
                  panelID: source.panelID, sessionID: source.sessionID
              ),
              let screen = terminalCommandRouter?.readVisibleText(panelID: source.panelID) else { return nil }
        return Self.claudeRecoveryPermissionMode(screen: screen)
    }

    nonisolated static func claudeRecoveryPermissionMode(
        screen: String
    ) -> AgentLaunchArgumentOverrideAdapter.ClaudeQuotaRecoveryMode? {
        let lines = TerminalVisibleTextSanitizer.sanitizedLines(screen)
        guard let index = lines.lastIndex(where: { $0 == "❯" || $0 == ">" }),
              lines.count - index <= 5, index > 0, index + 2 < lines.count else { return nil }
        let top = lines[index - 1], bottom = lines[index + 1]
        guard top.count >= 4, bottom.count >= 4,
              top.allSatisfy({ $0 == "─" || $0 == "━" }),
              bottom.allSatisfy({ $0 == "─" || $0 == "━" }) else { return nil }
        guard lines.dropFirst(index + 2).allSatisfy({
            !$0.localizedCaseInsensitiveContains("enter")
                && !$0.localizedCaseInsensitiveContains("esc to")
                && !$0.localizedCaseInsensitiveContains("background")
                && !$0.localizedCaseInsensitiveContains("jump to bottom")
        }) else { return nil }
        // Hook payloads cannot select permissions. The live composer tells
        // us when Plan must be carried forward. Every supported editing
        // mode resumes in Manual, where Claude can still ask for approval.
        let footer = lines[index + 2]
        if footer.hasPrefix("⏸ plan mode on") { return .plan }
        let manualOrEditingModes = ["⏸ manual mode on", "⏵⏵ accept edits on", "⏵⏵ auto mode on", "⏵⏵ don't ask on"]
        return manualOrEditingModes.contains(where: { footer.hasPrefix($0) }) ? .manual : nil
    }

    func waitForRecoveredClaude(
        _ launch: AgentLaunchResult, nativeID: UUID, model: String
    ) async throws -> (any LocalConversationSubscription, RemoteConversationSummary) {
        guard let subscription = quotaRecoveryConversationAccess?.subscribeToConversation(inPanel: launch.panelID) else {
            throw TaskError("Toastty cannot follow Claude's recovered conversation.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(25))
        var confirmed = false
        defer { if !confirmed { subscription.cancel() } }
        while clock.now < deadline {
            try Task.checkCancellation()
            guard let current = claudeRecoverySource(sessionID: launch.sessionID) else { break }
            if current.status?.kind == .error { break }
            if let binding = sessionRuntimeStore?.nativeSessionBindingConfirmation(for: launch.sessionID),
               binding.panelID == launch.panelID, UUID(uuidString: binding.nativeSessionID) == nativeID,
               let feed = sessionRuntimeStore?.providerConversationFeed(managedSessionID: launch.sessionID),
               feed.observations.contains(where: { observation in
                   guard observation.fingerprint.hasPrefix("managed:claude:session-model:"),
                         case .executionProfileReported(let profile) = observation.payload else { return false }
                   return profile.modelIdentifier == model
               }),
               let summary = subscription.snapshot(at: nowProvider())?.summary,
               summary.executionProfile?.modelIdentifier == model,
               case .openPrompt = summary.inputAvailability {
                confirmed = true
                return (subscription, summary)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TaskError("Claude did not confirm the resumed conversation, model and open prompt.")
    }

    private func makeLaunchPreparation(
        profileID: String,
        workspaceID: UUID?,
        panelID: UUID?,
        cwd: String?,
        environment: [String: String],
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String?,
        initialCommands: [String],
        forkFromSessionID: String?,
        additionalDirectories: [String],
        parentSessionID: String?,
        focusPolicy: TerminalInputFocusPolicy,
        codexProjectDocMaxBytes: Int? = nil,
        validatePromptState: Bool = true
    ) throws -> AgentLaunchPreparation {
        guard let terminalCommandRouter else {
            throw AgentLaunchError.serviceUnavailable
        }
        guard let launchProfile = resolvedLaunchProfile(profileID: profileID) else {
            if agentCatalogProvider.catalog.profiles.isEmpty {
                throw AgentLaunchError.noProfilesConfigured
            }
            throw AgentLaunchError.profileNotFound(
                profileID: profileID,
                availableProfileIDs: availableProfileIDs()
            )
        }
        guard let agent = AgentKind(rawValue: launchProfile.id) else {
            throw AgentLaunchError.profileNotFound(
                profileID: launchProfile.id,
                availableProfileIDs: availableProfileIDs()
            )
        }
        if forkFromSessionID != nil, agent != .codex && agent != .claude {
            throw AgentLaunchError.launchOverrideUnsupported(parameter: "forkFromSessionID", profileID: launchProfile.id)
        }
        let explicitCWD = try normalizedExplicitWorkingDirectory(cwd)
        let forkRecord = try forkFromSessionID.map { try resolveForkRecord(sessionID: $0, agent: agent) }
        let directories = try additionalDirectories.map { path -> String in
            guard let normalized = try normalizedExplicitWorkingDirectory(path) else {
                throw AgentLaunchError.invalidWorkingDirectory(path: path)
            }
            return normalized
        }
        if forkRecord != nil, !initialCommands.isEmpty {
            throw AgentLaunchError.invalidLaunchOverride(parameter: "forkFromSessionID", message: "initialCommands cannot change the explicit fork working directory")
        }
        let launchArgv = try argv(
            for: launchProfile,
            agent: agent,
            applyingModel: model,
            applyingReasoningEffort: reasoningEffort,
            applyingInitialPrompt: initialPrompt,
            applyingCodexProjectDocMaxBytes: codexProjectDocMaxBytes,
            forkRecord: forkRecord,
            cwd: explicitCWD,
            additionalDirectories: directories
        )
        let validatedEnvironment = try validatedLaunchEnvironment(environment)
        let validatedCommands = try validatedInitialCommands(initialCommands)
        let target = try resolveLaunchTarget(workspaceID: workspaceID, panelID: panelID)
        if let forkFromSessionID,
           sessionRuntimeStore?.sessionRegistry.activeSession(sessionID: forkFromSessionID)?.panelID == target.panelID {
            throw AgentLaunchError.invalidLaunchOverride(parameter: "forkFromSessionID", message: "the fork must use a different terminal panel from its source")
        }
        if validatePromptState {
            try ensurePanelAppearsInteractive(
                panelID: target.panelID,
                terminalCommandRouter: terminalCommandRouter
            )
        }
        return AgentLaunchPreparation(
            agent: agent,
            displayName: launchProfile.displayName,
            target: target,
            explicitCWD: explicitCWD,
            initialCommands: validatedCommands,
            focusPolicy: focusPolicy,
            forkFromSessionID: forkFromSessionID,
            forkRecord: forkRecord,
            request: ManagedAgentLaunchRequest(
                agent: agent,
                panelID: target.panelID,
                argv: launchArgv,
                cwd: explicitCWD ?? target.cwd,
                environment: validatedEnvironment,
                parentSessionID: parentSessionID ?? forkFromSessionID,
                startsWithPrompt: try normalizedInitialPrompt(initialPrompt) != nil
            )
        )
    }

    private func completeLaunch(
        _ preparation: AgentLaunchPreparation,
        plan: ManagedAgentLaunchPlan
    ) throws -> AgentLaunchResult {
        guard let terminalCommandRouter else {
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw AgentLaunchError.serviceUnavailable
        }
        do {
            if let sourceID = preparation.forkFromSessionID {
                let current = try resolveForkRecord(sessionID: sourceID, agent: preparation.agent)
                guard current.nativeSessionID == preparation.forkRecord?.nativeSessionID,
                      current.sessionFilePath == preparation.forkRecord?.sessionFilePath else {
                    throw AgentLaunchError.invalidLaunchOverride(parameter: "forkFromSessionID", message: "the source conversation changed during launch; retry")
                }
            }
            try ensurePanelAppearsInteractive(
                panelID: preparation.target.panelID,
                terminalCommandRouter: terminalCommandRouter
            )
        } catch {
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw error
        }
        var commandEnvironment = plan.environment
        commandEnvironment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = "1"
        let dispatchArgv = preparation.agent == .grok
            ? GrokLaunchInstrumentation.argvForDispatch(plan.argv, environment: plan.environment)
            : plan.argv
        let commandLine = ShellCommandRenderer.render(
            argv: dispatchArgv,
            environment: commandEnvironment,
            workingDirectory: preparation.explicitCWD,
            initialCommands: preparation.initialCommands
        )

        switch terminalCommandRouter.sendManagedAgentCommandResult(
            commandLine,
            panelID: preparation.target.panelID,
            focusPolicy: preparation.focusPolicy
        ) {
        case .delivered:
            // The session exists before the shell starts the typed command.
            // Until the shell does, its prompt must not end the new session.
            sessionRuntimeStore?.noteManagedLaunchCommandSubmitted(
                sessionID: plan.sessionID,
                shellWasAtPrompt: true,
                at: nowProvider()
            )
        case .unavailable:
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw AgentLaunchError.terminalUnavailable(panelID: preparation.target.panelID)
        case .uncertain:
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw AgentLaunchError.commandDeliveryUncertain(panelID: preparation.target.panelID)
        }
        return AgentLaunchResult(
            agent: preparation.agent,
            displayName: preparation.displayName,
            sessionID: plan.sessionID,
            windowID: plan.windowID,
            workspaceID: plan.workspaceID,
            panelID: plan.panelID,
            cwd: plan.cwd,
            repoRoot: plan.repoRoot,
            commandLine: commandLine
        )
    }

    func prepareManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) throws -> ManagedAgentLaunchPlan {
        try managedLaunchPlanner.prepareManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
    }

    func prepareManagedLaunchAsync(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) async throws -> ManagedAgentLaunchPlan {
        try await managedLaunchPlanner.prepareManagedLaunchAsync(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
    }

    func prepareRestoredManagedLaunch(
        _ request: ManagedAgentLaunchRequest,
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil
    ) throws -> ManagedAgentLaunchPlan {
        try managedLaunchPlanner.prepareRestoredManagedLaunch(
            request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
    }

    func discardManagedLaunch(sessionID: String) {
        managedLaunchPlanner.discardManagedLaunch(sessionID: sessionID)
    }

    func cancelNativeSessionObservation(sessionID: String) {
        managedLaunchPlanner.cancelNativeSessionObservation(sessionID: sessionID)
    }

    func lacksShippedSkills(sessionID: String) -> Bool {
        managedLaunchPlanner.lacksShippedSkills(sessionID: sessionID)
    }

    /// The argv of a Codex profile whose arguments cannot take the raised
    /// `project_doc_max_bytes` that the coordinator's start and resume
    /// add. `nil` when they can, or when the profile is not Codex's.
    func codexArgvLackingProjectDocMaxBytes(profileID: String) -> [String]? {
        guard let profile = resolvedLaunchProfile(profileID: profileID),
              AgentKind(rawValue: profile.id) == .codex,
              AgentLaunchArgumentOverrideAdapter.canApplyCodexProjectDocMaxBytes(to: profile.argv, profileID: profile.id) == false
        else { return nil }
        return profile.argv
    }

    private func resolvedLaunchProfile(profileID: String) -> AgentProfile? {
        if let profile = agentCatalogProvider.catalog.profile(id: profileID) {
            return profile
        }
        guard let agent = AgentKind(rawValue: profileID),
              Self.supportsImplicitProfile(agent) else {
            return nil
        }
        return Self.implicitProfile(for: agent)
    }

    private func availableProfileIDs() -> [String] {
        agentCatalogProvider.catalog.profiles.map(\.id)
    }

    /// Reports the executable `profileID` would run, without launching anything.
    ///
    /// Uses the same profile resolution as `launch`, so a caller checking a provider
    /// CLI verifies the binary a launch would actually exec rather than whatever its
    /// own PATH resolves. Throws only when the profile itself is unknown; a command
    /// that cannot be resolved is reported in the returned state.
    func profileExecutableState(profileID: String) throws -> AgentProfileExecutableState {
        guard let profile = resolvedLaunchProfile(profileID: profileID) else {
            if agentCatalogProvider.catalog.profiles.isEmpty {
                throw AgentLaunchError.noProfilesConfigured
            }
            throw AgentLaunchError.profileNotFound(
                profileID: profileID,
                availableProfileIDs: availableProfileIDs()
            )
        }
        let source: AgentProfileSource = agentCatalogProvider.catalog.profile(id: profileID) == nil
            ? .implicit
            : .configured
        let argumentCount = max(profile.argv.count - 1, 0)
        func state(
            command: String,
            commandIsExplicitPath: Bool,
            executablePath: String?,
            failure: AgentProfileExecutableFailure?,
            fallbackProbeUsed: Bool = false,
            directExecutableProbeUsed: Bool = false
        ) -> AgentProfileExecutableState {
            AgentProfileExecutableState(
                profileID: profile.id,
                displayName: profile.displayName,
                command: command,
                argumentCount: argumentCount,
                source: source,
                commandIsExplicitPath: commandIsExplicitPath,
                executablePath: executablePath,
                failure: failure,
                fallbackProbeUsed: fallbackProbeUsed,
                directExecutableProbeUsed: directExecutableProbeUsed
            )
        }

        guard let command = profile.argv.first, command.isEmpty == false else {
            return state(command: "", commandIsExplicitPath: false, executablePath: nil, failure: .commandNotFound)
        }

        // An argv[0] containing a separator is run as-is, so no PATH lookup applies
        // and no shim stands in front of it. Toastty quotes argv, so the shell never
        // expands a tilde and a relative path depends on the launch directory; both
        // are reported rather than resolved against this process.
        if command.contains("/") {
            guard command.hasPrefix("/") else {
                return state(
                    command: command,
                    commandIsExplicitPath: true,
                    executablePath: nil,
                    failure: .explicitPathNotAbsolute
                )
            }
            let isExecutable = fileManager.isExecutableFile(atPath: command)
            return state(
                command: command,
                commandIsExplicitPath: true,
                executablePath: isExecutable ? command : nil,
                failure: isExecutable ? nil : .explicitPathNotExecutable
            )
        }

        let context = managedAgentResolutionContextProvider()
        // Runs on the main actor, so the login-shell probes are off: the app already
        // probed the base path at startup and this context carries the result.
        let resolution = ManagedAgentExecutableResolver.resolve(
            commandName: command,
            environment: context.environment,
            excludedDirectoryPaths: context.excludedDirectoryPaths,
            allowsLoginShellProbe: false
        )
        return state(
            command: command,
            commandIsExplicitPath: false,
            executablePath: resolution?.executablePath,
            failure: resolution == nil ? .commandNotFound : nil,
            fallbackProbeUsed: resolution?.fallbackProbeUsed ?? false,
            directExecutableProbeUsed: resolution?.directExecutableProbeUsed ?? false
        )
    }

    /// What a caller that offers profiles to a person needs to know about
    /// each configured profile, resolved the same way a launch resolves it.
    /// With no profile in agents.toml, as on a fresh install, these are the
    /// built-in agents that are installed, which a launch accepts by name.
    func launchProfileSummaries() -> [AgentLaunchProfileSummary] {
        let configured = agentCatalogProvider.catalog.profiles
        let profiles = configured.isEmpty ? Self.implicitProfileAgents.map(Self.implicitProfile(for:)) : configured
        return profiles.compactMap { profile in
            guard let agent = AgentKind(rawValue: profile.id) else { return nil }
            let executable = try? profileExecutableState(profileID: profile.id)
            let isInstalled = executable?.executablePath != nil
            // A configured profile shows even when its command is missing, so
            // the user sees it; a built-in agent shows only when installed.
            guard isInstalled || configured.isEmpty == false else { return nil }
            return AgentLaunchProfileSummary(
                profileID: profile.id,
                displayName: profile.displayName,
                agent: agent,
                isInstalled: isInstalled,
                acceptsInitialPrompt: initialPromptPlacement(for: profile, agent: agent) == .trailing,
                acceptsLeadingDashPrompt: Self.argvRunsFirstPartyPromptCommand(profile.argv, for: agent),
                supportsModel: AgentLaunchArgumentOverrideAdapter.modelSupportedAgents.contains(agent),
                supportsReasoningEffort: AgentLaunchArgumentOverrideAdapter.reasoningEffortSupportedAgents.contains(agent)
            )
        }
    }

    /// The built-in agents a launch accepts without a profile, in the order
    /// Toastty offers them. Claude Code is first because the coordinator
    /// runs it by default.
    private static let implicitProfileAgents: [AgentKind] = [.claude, .codex, .cursor, .grok, .mimocode, .opencode, .pi]

    private static func supportsImplicitProfile(_ agent: AgentKind) -> Bool {
        implicitProfileAgents.contains(agent)
    }

    private static func implicitProfile(for agent: AgentKind) -> AgentProfile {
        AgentProfile(
            id: agent.rawValue,
            displayName: agent.displayName,
            argv: [implicitExecutableName(for: agent)],
            initialPromptPlacement: (agent == .codex || agent == .claude || agent == .cursor || agent == .grok || agent == .pi)
                ? .trailing
                : nil
        )
    }

    private static func implicitExecutableName(for agent: AgentKind) -> String {
        switch agent {
        case .cursor:
            return "cursor-agent"
        case .mimocode:
            return "mimo"
        default:
            return agent.rawValue
        }
    }

    private func normalizedExplicitWorkingDirectory(_ cwd: String?) throws -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard trimmed.contains("\u{0}") == false else {
            throw AgentLaunchError.invalidWorkingDirectory(path: cwd)
        }
        let normalized = ((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath
        guard (normalized as NSString).isAbsolutePath else {
            throw AgentLaunchError.invalidWorkingDirectory(path: normalized)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentLaunchError.invalidWorkingDirectory(path: normalized)
        }
        return normalized
    }

    private func resolveForkRecord(sessionID: String, agent: AgentKind) throws -> ManagedAgentResumeRecord {
        func unavailable(_ message: String) -> AgentLaunchError {
            .invalidLaunchOverride(parameter: "forkFromSessionID", message: message)
        }
        guard let sessionRuntimeStore,
              let source = sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID) else {
            throw unavailable("the source managed session is not active")
        }
        guard source.agent == agent else { throw unavailable("the source and target must use the same provider") }
        guard let store,
              case .terminal(let terminal)? = store.state.workspaceSelection(containingPanelID: source.panelID)?.workspace.panelState(for: source.panelID),
              let record = terminal.resumeRecord,
              let confirmation = sessionRuntimeStore.nativeSessionBindingConfirmation(for: sessionID),
              record.agent == source.agent,
              confirmation.agent == source.agent,
              confirmation.panelID == source.panelID,
              confirmation.nativeSessionID == record.nativeSessionID,
              confirmation.sessionFilePath == record.sessionFilePath,
              record.capturedAt >= source.startedAt,
              UUID(uuidString: record.nativeSessionID) != nil else {
            throw unavailable("the source has no current confirmed native conversation; wait for session discovery and retry")
        }
        var isDirectory: ObjCBool = false
        guard (record.sessionFilePath as NSString).isAbsolutePath,
              fileManager.fileExists(atPath: record.sessionFilePath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw unavailable("the source native transcript is missing")
        }
        return record
    }

    private func validatedLaunchEnvironment(_ environment: [String: String]) throws -> [String: String] {
        for (key, value) in environment {
            guard Self.isValidEnvironmentKey(key) else {
                throw AgentLaunchError.invalidLaunchEnvironment(
                    message: "'\(key)' is not a valid environment variable name"
                )
            }
            guard Self.reservedLaunchEnvironmentKeys.contains(key) == false else {
                throw AgentLaunchError.invalidLaunchEnvironment(
                    message: "'\(key)' is managed by Toastty"
                )
            }
            guard value.contains("\u{0}") == false else {
                throw AgentLaunchError.invalidLaunchEnvironment(
                    message: "'\(key)' contains a NUL byte"
                )
            }
        }
        return environment
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let firstAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let restAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard firstAllowed.contains(first) else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy(restAllowed.contains)
    }

    private static let reservedLaunchEnvironmentKeys: Set<String> = [
        ToasttyLaunchContextEnvironment.sessionIDKey,
        ToasttyLaunchContextEnvironment.agentKey,
        ToasttyLaunchContextEnvironment.panelIDKey,
        ToasttyLaunchContextEnvironment.socketPathKey,
        ToasttyLaunchContextEnvironment.cliPathKey,
        ToasttyLaunchContextEnvironment.cwdKey,
        ToasttyLaunchContextEnvironment.repoRootKey,
        ToasttyLaunchContextEnvironment.managedAgentShimBypassKey,
        ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey,
        ToasttyLaunchContextEnvironment.skillsRootKey,
        ToasttyLaunchContextEnvironment.grokSkillsOverlayKey,
        ToasttyLaunchContextEnvironment.userSkillsRootKey,
        "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT",
        "CODEX_TUI_RECORD_SESSION",
        "CODEX_TUI_SESSION_LOG_PATH",
        "TOASTTY_PI_TELEMETRY_LOG_PATH",
    ]

    private func validatedInitialCommands(_ commands: [String]) throws -> [String] {
        guard commands.count <= Self.maximumInitialCommandCount else {
            throw AgentLaunchError.invalidInitialCommands(
                message: "at most \(Self.maximumInitialCommandCount) commands are supported"
            )
        }

        for (index, command) in commands.enumerated() {
            guard command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw AgentLaunchError.invalidInitialCommands(
                    message: "command \(index + 1) must not be blank"
                )
            }
            guard command.contains("\u{0}") == false else {
                throw AgentLaunchError.invalidInitialCommands(
                    message: "command \(index + 1) contains a NUL byte"
                )
            }
            guard command.contains("\n") == false, command.contains("\r") == false else {
                throw AgentLaunchError.invalidInitialCommands(
                    message: "command \(index + 1) must be a single line"
                )
            }
            guard command.utf8.count <= Self.maximumInitialCommandUTF8Count else {
                throw AgentLaunchError.invalidInitialCommands(
                    message: "command \(index + 1) exceeds \(Self.maximumInitialCommandUTF8Count) UTF-8 bytes"
                )
            }
        }

        return commands
    }

    private static let maximumInitialCommandCount = 16
    private static let maximumInitialCommandUTF8Count = 4096

    private func argv(
        for profile: AgentProfile,
        agent: AgentKind,
        applyingModel model: String?,
        applyingReasoningEffort reasoningEffort: String?,
        applyingInitialPrompt initialPrompt: String?,
        applyingCodexProjectDocMaxBytes codexProjectDocMaxBytes: Int? = nil,
        forkRecord: ManagedAgentResumeRecord? = nil,
        cwd: String? = nil,
        additionalDirectories: [String] = []
    ) throws -> [String] {
        let selectedArgv = AgentLaunchArgumentOverrideAdapter.applying(
            codexProjectDocMaxBytes: codexProjectDocMaxBytes,
            to: try AgentLaunchArgumentOverrideAdapter.applying(
                model: model,
                reasoningEffort: reasoningEffort,
                to: profile.argv,
                agent: agent,
                profileID: profile.id
            ),
            agent: agent,
            profileID: profile.id
        )
        let overrideArgv = try AgentLaunchArgumentOverrideAdapter.applyingConversationOptions(
            forkRecord: forkRecord, cwd: cwd, additionalDirectories: additionalDirectories,
            to: selectedArgv, agent: agent, profileID: profile.id
        )
        guard let prompt = try normalizedInitialPrompt(initialPrompt) else {
            return overrideArgv
        }
        guard initialPromptPlacement(for: profile, agent: agent) == .trailing else {
            throw AgentLaunchError.initialPromptUnsupported(profileID: profile.id)
        }
        // Claude's --add-dir consumes multiple values. Delimit the prompt so
        // it cannot become another directory (or a provider option).
        if forkRecord != nil || !additionalDirectories.isEmpty {
            return overrideArgv + ["--", prompt]
        }
        // A prompt that starts with a dash would be read as an option, so it
        // goes after the standard end-of-options marker. Only the first-party
        // commands are known to accept the marker.
        if prompt.hasPrefix("-"),
           Self.argvRunsFirstPartyPromptCommand(profile.argv, for: agent),
           // A configured marker already ends the options; a second one
           // would itself be read as the prompt.
           overrideArgv.contains("--") == false {
            return overrideArgv + ["--", prompt]
        }
        return overrideArgv + [prompt]
    }

    private func normalizedInitialPrompt(_ initialPrompt: String?) throws -> String? {
        guard let initialPrompt else { return nil }
        guard initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        guard initialPrompt.contains("\u{0}") == false else {
            throw AgentLaunchError.invalidInitialPrompt(message: "NUL bytes are not supported")
        }
        guard initialPrompt.utf8.count <= Self.maximumInitialPromptUTF8Count else {
            throw AgentLaunchError.invalidInitialPrompt(
                message: "value exceeds \(Self.maximumInitialPromptUTF8Count) UTF-8 bytes"
            )
        }
        return initialPrompt
    }

    static let maximumInitialPromptUTF8Count = 64 * 1024

    private func initialPromptPlacement(
        for profile: AgentProfile,
        agent: AgentKind
    ) -> AgentInitialPromptPlacement? {
        if let placement = profile.initialPromptPlacement {
            return placement
        }
        guard agent == .codex || agent == .claude || agent == .cursor || agent == .grok || agent == .pi else {
            return nil
        }
        return Self.argvIsDirectFirstPartyPromptCommand(profile.argv, for: agent) ? .trailing : nil
    }

    private static func argvIsDirectFirstPartyPromptCommand(_ argv: [String], for agent: AgentKind) -> Bool {
        argv.count == 1 && argvRunsFirstPartyPromptCommand(argv, for: agent)
    }

    /// Whether argv[0] is the provider's own command, with or without
    /// configured arguments after it.
    private static func argvRunsFirstPartyPromptCommand(_ argv: [String], for agent: AgentKind) -> Bool {
        guard let executable = argv.first else {
            return false
        }
        let commandNames: Set<String>
        switch agent {
        case .codex:
            commandNames = ["codex", "cdx"]
        case .claude:
            commandNames = ["claude"]
        case .cursor:
            commandNames = ["cursor-agent"]
        case .grok:
            commandNames = ["grok"]
        case .pi:
            commandNames = ["pi"]
        default:
            return false
        }
        return commandNames.contains(URL(fileURLWithPath: executable).lastPathComponent)
    }

    private func resolveLaunchTarget(
        workspaceID: UUID?,
        panelID: UUID?
    ) throws -> LaunchTarget {
        guard let store else {
            throw AgentLaunchError.serviceUnavailable
        }

        let state = store.state

        if let panelID {
            guard let location = Self.locatePanel(panelID, in: state) else {
                throw AgentLaunchError.panelDoesNotExist
            }
            if let workspaceID, workspaceID != location.workspaceID {
                throw AgentLaunchError.panelOutsideWorkspace
            }
            guard let workspace = state.workspacesByID[location.workspaceID] else {
                throw AgentLaunchError.workspaceDoesNotExist
            }
            guard case .terminal(let terminalState)? = workspace.panelState(for: panelID) else {
                throw AgentLaunchError.panelIsNotTerminal
            }
            return LaunchTarget(
                windowID: location.windowID,
                workspaceID: location.workspaceID,
                panelID: panelID,
                cwd: terminalState.agentLaunchWorkingDirectory
            )
        }

        let resolvedWorkspaceID: UUID
        if let workspaceID {
            resolvedWorkspaceID = workspaceID
        } else if let selectedWorkspaceID = store.selectedWorkspace?.id {
            resolvedWorkspaceID = selectedWorkspaceID
        } else {
            throw AgentLaunchError.noSelectedWorkspace
        }

        guard let workspace = state.workspacesByID[resolvedWorkspaceID] else {
            throw AgentLaunchError.workspaceDoesNotExist
        }
        guard let windowID = Self.windowID(containing: resolvedWorkspaceID, in: state) else {
            throw AgentLaunchError.workspaceDoesNotExist
        }

        if let focusedPanelID = workspace.focusedPanelID,
           case .terminal(let terminalState)? = workspace.panelState(for: focusedPanelID) {
            return LaunchTarget(
                windowID: windowID,
                workspaceID: resolvedWorkspaceID,
                panelID: focusedPanelID,
                cwd: terminalState.agentLaunchWorkingDirectory
            )
        }

        for slot in workspace.layoutTree.allSlotInfos {
            let panelID = slot.panelID
            guard case .terminal(let terminalState)? = workspace.panels[panelID] else {
                continue
            }
            return LaunchTarget(
                windowID: windowID,
                workspaceID: resolvedWorkspaceID,
                panelID: panelID,
                cwd: terminalState.agentLaunchWorkingDirectory
            )
        }

        throw AgentLaunchError.workspaceHasNoTerminalPanel
    }

    private func ensurePanelAppearsInteractive(
        panelID: UUID,
        terminalCommandRouter: any TerminalCommandRouting
    ) throws {
        guard terminalCommandRouter.managedAgentRestoreState(panelID: panelID) == .inactive,
              terminalCommandRouter.promptState(panelID: panelID).isIdleAtPrompt else {
            throw AgentLaunchError.panelBusy(runningCommand: nil)
        }
    }

    private func ensurePanelBecomesInteractive(
        panelID: UUID,
        terminalCommandRouter: any TerminalCommandRouting
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.asyncPromptReadinessTimeout)

        while true {
            guard let store else {
                throw AgentLaunchError.serviceUnavailable
            }
            guard Self.locatePanel(panelID, in: store.state) != nil else {
                throw AgentLaunchError.panelDoesNotExist
            }
            let promptState = terminalCommandRouter.promptState(panelID: panelID)
            guard promptState != .exited else {
                throw AgentLaunchError.panelBusy(runningCommand: nil)
            }
            if promptState == .unavailable ||
                terminalCommandRouter.isReadyForManagedAgentCommand(panelID: panelID) == false {
                guard clock.now < deadline else {
                    throw AgentLaunchError.panelBusy(runningCommand: nil)
                }
                try await Task.sleep(for: Self.asyncPromptReadinessPollInterval)
                continue
            }
            try ensurePanelAppearsInteractive(panelID: panelID, terminalCommandRouter: terminalCommandRouter)
            return
        }
    }

    private static func locatePanel(
        _ panelID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspaceID: UUID)? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID) else {
            return nil
        }
        return (selection.windowID, selection.workspaceID)
    }

    private static func windowID(containing workspaceID: UUID, in state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }

    nonisolated static func defaultCLIExecutablePath() -> String? {
        ToasttyBundledExecutableLocator.defaultCLIExecutablePath()
    }

    nonisolated static func resolvedDefaultCLIExecutablePath(
        fileManager: FileManager,
        bundleURL: URL,
        executableURL: URL?
    ) -> String? {
        ToasttyBundledExecutableLocator.resolvedCLIExecutablePath(
            fileManager: fileManager,
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    nonisolated static func defaultCLIExecutablePathCandidates(
        bundleURL: URL,
        executableURL: URL?
    ) -> [String] {
        ToasttyBundledExecutableLocator.executablePathCandidates(
            named: "toastty",
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    nonisolated private static func defaultSocketPath() -> String {
        AutomationConfig.resolveServerSocketPath(environment: ProcessInfo.processInfo.environment)
    }
}

private struct LaunchTarget {
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID
    let cwd: String?
}

private struct AgentLaunchPreparation {
    let agent: AgentKind
    let displayName: String
    let target: LaunchTarget
    let explicitCWD: String?
    let initialCommands: [String]
    let focusPolicy: TerminalInputFocusPolicy
    let forkFromSessionID: String?
    let forkRecord: ManagedAgentResumeRecord?
    var request: ManagedAgentLaunchRequest
}
