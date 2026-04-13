import CoreState
import Foundation

@MainActor
protocol TerminalCommandRouting: AnyObject {
    @discardableResult
    func sendText(_ text: String, submit: Bool, panelID: UUID) -> Bool
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
        }
    }
}

@MainActor
final class AgentLaunchService {
    private weak var store: AppStore?
    private weak var terminalCommandRouter: (any TerminalCommandRouting)?
    private let agentCatalogProvider: any AgentCatalogProviding
    private let managedLaunchPlanner: any ManagedAgentLaunchPlanning

    init(
        store: AppStore,
        terminalCommandRouter: any TerminalCommandRouting,
        sessionRuntimeStore: SessionRuntimeStore,
        agentCatalogProvider: any AgentCatalogProviding,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = AgentLaunchService.defaultCLIExecutablePath,
        socketPathProvider: @escaping @Sendable () -> String = AgentLaunchService.defaultSocketPath
    ) {
        self.store = store
        self.terminalCommandRouter = terminalCommandRouter
        self.agentCatalogProvider = agentCatalogProvider
        managedLaunchPlanner = ManagedAgentLaunchPlanner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            fileManager: fileManager,
            nowProvider: nowProvider,
            cliExecutablePathProvider: cliExecutablePathProvider,
            socketPathProvider: socketPathProvider,
            readVisibleText: { [weak terminalCommandRouter] panelID in
                terminalCommandRouter?.readVisibleText(panelID: panelID)
            },
            promptState: { [weak terminalCommandRouter] panelID in
                terminalCommandRouter?.promptState(panelID: panelID) ?? .unavailable
            }
        )
    }

    func canLaunchAgent(profileID: String? = nil, workspaceID: UUID? = nil, panelID: UUID? = nil) -> Bool {
        if let profileID {
            guard agentCatalogProvider.catalog.profile(id: profileID) != nil else {
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
        panelID: UUID? = nil
    ) throws -> AgentLaunchResult {
        guard let terminalCommandRouter else {
            throw AgentLaunchError.serviceUnavailable
        }
        guard agentCatalogProvider.catalog.profiles.isEmpty == false else {
            throw AgentLaunchError.noProfilesConfigured
        }
        guard let launchProfile = agentCatalogProvider.catalog.profile(id: profileID) else {
            throw AgentLaunchError.profileNotFound(profileID: profileID)
        }

        let target = try resolveLaunchTarget(workspaceID: workspaceID, panelID: panelID)
        try ensurePanelAppearsInteractive(panelID: target.panelID, terminalCommandRouter: terminalCommandRouter)

        guard let agent = AgentKind(rawValue: launchProfile.id) else {
            throw AgentLaunchError.profileNotFound(profileID: launchProfile.id)
        }
        let plan = try managedLaunchPlanner.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: agent,
                panelID: target.panelID,
                argv: launchProfile.argv,
                cwd: target.cwd
            )
        )
        var commandEnvironment = plan.environment
        commandEnvironment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = "1"
        let commandLine = ShellCommandRenderer.render(
            argv: plan.argv,
            environment: commandEnvironment
        )

        guard terminalCommandRouter.sendText(commandLine, submit: true, panelID: target.panelID) else {
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
                cwd: normalizedNonEmpty(terminalState.cwd)
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
                cwd: normalizedNonEmpty(terminalState.cwd)
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
                cwd: normalizedNonEmpty(terminalState.cwd)
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

private enum ShellCommandRenderer {
    static func render(
        argv: [String],
        environment: [String: String]
    ) -> String {
        var command = environment
            .sorted(by: { $0.key < $1.key })
            .map { assignment($0.key, $0.value) }

        command.append(contentsOf: argv.map(quote))
        return command.joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%+,-./:=@_")
        if value.unicodeScalars.allSatisfy(allowed.contains) {
            return value
        }

        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private static func assignment(_ key: String, _ value: String) -> String {
        "\(key)=\(quote(value))"
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
