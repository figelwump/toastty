import CoreState
import Foundation

@MainActor
protocol TerminalCommandRouting: AnyObject {
    @discardableResult
    func sendText(_ text: String, submit: Bool, panelID: UUID) -> Bool
    @discardableResult
    func sendText(
        _ text: String,
        submit: Bool,
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
    case profileNotFound(profileID: String)
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
    case initialPromptUnsupported(profileID: String)
    case invalidInitialPrompt(message: String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Agent launch is unavailable."
        case .noProfilesConfigured:
            return "No agents are configured. Edit ~/.toastty/agents.toml and try again."
        case .profileNotFound(let profileID):
            return "Toastty could not find an agent profile named '\(profileID)' in ~/.toastty/agents.toml."
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
        case .initialPromptUnsupported(let profileID):
            return "Agent profile '\(profileID)' does not support initialPrompt."
        case .invalidInitialPrompt(let message):
            return "Agent launch initialPrompt is invalid: \(message)"
        }
    }
}

@MainActor
final class AgentLaunchService: ManagedAgentLaunchPlanning {
    private weak var store: AppStore?
    private weak var terminalCommandRouter: (any TerminalCommandRouting)?
    private let agentCatalogProvider: any AgentCatalogProviding
    private let fileManager: FileManager
    private let managedLaunchPlanner: any ManagedAgentLaunchPlanning

    init(
        store: AppStore,
        terminalCommandRouter: any TerminalCommandRouting,
        sessionRuntimeStore: SessionRuntimeStore,
        agentCatalogProvider: any AgentCatalogProviding,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = AgentLaunchService.defaultCLIExecutablePath,
        socketPathProvider: @escaping @Sendable () -> String = AgentLaunchService.defaultSocketPath,
        codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = ManagedAgentLaunchPlanner.defaultCodexStatusTrackingSource,
        nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil
    ) {
        self.store = store
        self.terminalCommandRouter = terminalCommandRouter
        self.agentCatalogProvider = agentCatalogProvider
        self.fileManager = fileManager
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
            nativeSessionObserverRegistry: nativeSessionObserverRegistry
        )
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
        initialPrompt: String? = nil,
        focusPolicy: TerminalInputFocusPolicy = .focusTarget
    ) throws -> AgentLaunchResult {
        guard let terminalCommandRouter else {
            throw AgentLaunchError.serviceUnavailable
        }
        guard let launchProfile = resolvedLaunchProfile(profileID: profileID) else {
            if agentCatalogProvider.catalog.profiles.isEmpty {
                throw AgentLaunchError.noProfilesConfigured
            }
            throw AgentLaunchError.profileNotFound(profileID: profileID)
        }

        let target = try resolveLaunchTarget(workspaceID: workspaceID, panelID: panelID)
        try ensurePanelAppearsInteractive(panelID: target.panelID, terminalCommandRouter: terminalCommandRouter)

        guard let agent = AgentKind(rawValue: launchProfile.id) else {
            throw AgentLaunchError.profileNotFound(profileID: launchProfile.id)
        }
        let explicitCWD = try normalizedExplicitWorkingDirectory(cwd)
        let launchEnvironment = try validatedLaunchEnvironment(environment)
        let launchArgv = try argv(
            for: launchProfile,
            agent: agent,
            applyingInitialPrompt: initialPrompt
        )
        let plan = try managedLaunchPlanner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: agent,
                panelID: target.panelID,
                argv: launchArgv,
                cwd: explicitCWD ?? target.cwd,
                environment: launchEnvironment
            )
        )
        var commandEnvironment = plan.environment
        commandEnvironment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = "1"
        let commandLine = ShellCommandRenderer.render(
            argv: plan.argv,
            environment: commandEnvironment,
            workingDirectory: explicitCWD
        )

        guard terminalCommandRouter.sendText(
            commandLine,
            submit: true,
            panelID: target.panelID,
            focusPolicy: focusPolicy
        ) else {
            managedLaunchPlanner.discardManagedLaunch(sessionID: plan.sessionID)
            throw AgentLaunchError.terminalUnavailable(panelID: target.panelID)
        }
        store?.recordSuccessfulAgentLaunch()

        return AgentLaunchResult(
            agent: agent,
            displayName: launchProfile.displayName,
            sessionID: plan.sessionID,
            windowID: plan.windowID,
            workspaceID: plan.workspaceID,
            panelID: plan.panelID,
            cwd: plan.cwd,
            repoRoot: plan.repoRoot,
            commandLine: commandLine
        )
    }

    func prepareManagedLaunch(_ request: ManagedAgentLaunchRequest) throws -> ManagedAgentLaunchPlan {
        try managedLaunchPlanner.prepareManagedLaunch(request)
    }

    func discardManagedLaunch(sessionID: String) {
        managedLaunchPlanner.discardManagedLaunch(sessionID: sessionID)
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

    private static func supportsImplicitProfile(_ agent: AgentKind) -> Bool {
        agent == .codex || agent == .claude || agent == .pi
    }

    private static func implicitProfile(for agent: AgentKind) -> AgentProfile {
        AgentProfile(
            id: agent.rawValue,
            displayName: agent.displayName,
            argv: [agent.rawValue],
            initialPromptPlacement: (agent == .codex || agent == .claude) ? .trailing : nil
        )
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
        ToasttyLaunchContextEnvironment.panelIDKey,
        ToasttyLaunchContextEnvironment.socketPathKey,
        ToasttyLaunchContextEnvironment.cliPathKey,
        ToasttyLaunchContextEnvironment.cwdKey,
        ToasttyLaunchContextEnvironment.repoRootKey,
        ToasttyLaunchContextEnvironment.managedAgentShimBypassKey,
        "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT",
        "CODEX_TUI_RECORD_SESSION",
        "CODEX_TUI_SESSION_LOG_PATH",
        "TOASTTY_PI_TELEMETRY_LOG_PATH",
    ]

    private func argv(
        for profile: AgentProfile,
        agent: AgentKind,
        applyingInitialPrompt initialPrompt: String?
    ) throws -> [String] {
        guard let prompt = try normalizedInitialPrompt(initialPrompt) else {
            return profile.argv
        }
        guard initialPromptPlacement(for: profile, agent: agent) == .trailing else {
            throw AgentLaunchError.initialPromptUnsupported(profileID: profile.id)
        }
        return profile.argv + [prompt]
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
        guard agent == .codex || agent == .claude else {
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
