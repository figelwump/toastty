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
    func readVisibleText(panelID: UUID) -> String?
    func promptState(panelID: UUID) -> TerminalPromptState
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

@MainActor
final class AgentLaunchService: ManagedAgentLaunchPlanning {
    private static let asyncPromptReadinessTimeout: Duration = .seconds(1)
    private static let asyncPromptReadinessPollInterval: Duration = .milliseconds(25)

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private weak var terminalCommandRouter: (any TerminalCommandRouting)?
    private let agentCatalogProvider: any AgentCatalogProviding
    private let fileManager: FileManager
    private let managedLaunchPlanner: any ManagedAgentLaunchPlanning
    private let codexProcessPathProvider: @Sendable () -> String?
    private let codexProcessPathRefreshProvider: @Sendable () -> String?
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
        managedAgentLaunchArtifactStore: ManagedAgentLaunchArtifactStore? = nil
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalCommandRouter = terminalCommandRouter
        self.agentCatalogProvider = agentCatalogProvider
        self.fileManager = fileManager
        self.codexProcessPathProvider = codexProcessPathProvider
        self.codexProcessPathRefreshProvider = codexProcessPathRefreshProvider
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
        initialCommands: [String] = [],
        forkFromSessionID: String? = nil,
        additionalDirectories: [String] = [],
        inheritedScopedWorkspaceIDs: Set<UUID>? = nil,
        parentSessionID: String? = nil,
        focusPolicy: TerminalInputFocusPolicy = .focusTarget
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
            validatePromptState: false
        )
        guard let terminalCommandRouter else {
            throw AgentLaunchError.serviceUnavailable
        }
        try await ensurePanelBecomesInteractive(
            panelID: preparation.target.panelID,
            terminalCommandRouter: terminalCommandRouter
        )
        let plan = try await managedLaunchPlanner.prepareManagedLaunchAsync(
            preparation.request,
            inheritedScopedWorkspaceIDs: inheritedScopedWorkspaceIDs
        )
        return try completeLaunch(preparation, plan: plan)
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
                parentSessionID: parentSessionID ?? forkFromSessionID
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
        let commandLine = ShellCommandRenderer.render(
            argv: plan.argv,
            environment: commandEnvironment,
            workingDirectory: preparation.explicitCWD,
            initialCommands: preparation.initialCommands
        )

        guard terminalCommandRouter.sendManagedAgentCommand(
            commandLine,
            panelID: preparation.target.panelID,
            focusPolicy: preparation.focusPolicy
        ) else {
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw AgentLaunchError.terminalUnavailable(panelID: preparation.target.panelID)
        }
        store?.recordSuccessfulAgentLaunch()

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

    private static func supportsImplicitProfile(_ agent: AgentKind) -> Bool {
        agent == .codex
            || agent == .claude
            || agent == .cursor
            || agent == .mimocode
            || agent == .opencode
            || agent == .pi
    }

    private static func implicitProfile(for agent: AgentKind) -> AgentProfile {
        AgentProfile(
            id: agent.rawValue,
            displayName: agent.displayName,
            argv: [implicitExecutableName(for: agent)],
            initialPromptPlacement: (agent == .codex || agent == .claude || agent == .cursor)
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
        forkRecord: ManagedAgentResumeRecord? = nil,
        cwd: String? = nil,
        additionalDirectories: [String] = []
    ) throws -> [String] {
        let selectedArgv = try AgentLaunchArgumentOverrideAdapter.applying(
            model: model,
            reasoningEffort: reasoningEffort,
            to: profile.argv,
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
        if agent == .cursor,
           Self.argvIsDirectFirstPartyPromptCommand(profile.argv, for: agent),
           prompt.hasPrefix("-") {
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

    private static let maximumInitialPromptUTF8Count = 64 * 1024

    private func initialPromptPlacement(
        for profile: AgentProfile,
        agent: AgentKind
    ) -> AgentInitialPromptPlacement? {
        if let placement = profile.initialPromptPlacement {
            return placement
        }
        guard agent == .codex || agent == .claude || agent == .cursor else {
            return nil
        }
        return Self.argvIsDirectFirstPartyPromptCommand(profile.argv, for: agent) ? .trailing : nil
    }

    private static func argvIsDirectFirstPartyPromptCommand(_ argv: [String], for agent: AgentKind) -> Bool {
        guard argv.count == 1,
              let executable = argv.first else {
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
        guard terminalCommandRouter.promptState(panelID: panelID).isIdleAtPrompt else {
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
            switch terminalCommandRouter.promptState(panelID: panelID) {
            case .idleAtPrompt:
                return
            case .unavailable:
                guard clock.now < deadline else {
                    throw AgentLaunchError.panelBusy(runningCommand: nil)
                }
                try await Task.sleep(for: Self.asyncPromptReadinessPollInterval)
            case .busy, .exited:
                throw AgentLaunchError.panelBusy(runningCommand: nil)
            }
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
    let request: ManagedAgentLaunchRequest
}
