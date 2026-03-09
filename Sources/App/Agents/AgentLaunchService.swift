import CoreState
import Foundation

@MainActor
protocol TerminalCommandRouting: AnyObject {
    @discardableResult
    func sendText(_ text: String, submit: Bool, panelID: UUID) -> Bool
    func readVisibleText(panelID: UUID) -> String?
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
                return "Toastty could not find its CLI at \(path). Build the toastty target alongside the app and try again."
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
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let agentCatalogProvider: any AgentCatalogProviding
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let cliExecutablePathProvider: @Sendable () -> String?

    init(
        store: AppStore,
        terminalCommandRouter: any TerminalCommandRouting,
        sessionRuntimeStore: SessionRuntimeStore,
        agentCatalogProvider: any AgentCatalogProviding,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = AgentLaunchService.defaultCLIExecutablePath
    ) {
        self.store = store
        self.terminalCommandRouter = terminalCommandRouter
        self.sessionRuntimeStore = sessionRuntimeStore
        self.agentCatalogProvider = agentCatalogProvider
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.cliExecutablePathProvider = cliExecutablePathProvider
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
        guard let terminalCommandRouter, let sessionRuntimeStore else {
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

        let sessionID = UUID().uuidString
        guard let agent = AgentKind(rawValue: launchProfile.id) else {
            throw AgentLaunchError.profileNotFound(profileID: launchProfile.id)
        }
        let repoRoot = RepositoryRootLocator.inferRepoRoot(from: target.cwd, fileManager: fileManager)
        let cliExecutablePath = try resolveCLIExecutablePath()
        let commandLine = ShellCommandRenderer.render(
            cliExecutablePath: cliExecutablePath,
            profileID: launchProfile.id,
            sessionID: sessionID,
            panelID: target.panelID
        )
        let now = nowProvider()

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            cwd: target.cwd,
            repoRoot: repoRoot,
            at: now
        )

        guard terminalCommandRouter.sendText(commandLine, submit: true, panelID: target.panelID) else {
            sessionRuntimeStore.stopSession(sessionID: sessionID, at: now)
            throw AgentLaunchError.terminalUnavailable(panelID: target.panelID)
        }

        return AgentLaunchResult(
            agent: agent,
            displayName: launchProfile.displayName,
            sessionID: sessionID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            panelID: target.panelID,
            cwd: target.cwd,
            repoRoot: repoRoot,
            commandLine: commandLine
        )
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
            guard case .terminal(let terminalState)? = workspace.panels[panelID] else {
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
           case .terminal(let terminalState)? = workspace.panels[focusedPanelID] {
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
        guard let visibleText = terminalCommandRouter.readVisibleText(panelID: panelID) else {
            return
        }

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)
        guard assessment.requiresConfirmation == false else {
            throw AgentLaunchError.panelBusy(runningCommand: assessment.runningCommand)
        }
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

    private static func windowID(containing workspaceID: UUID, in state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }

    nonisolated private static func defaultCLIExecutablePath() -> String? {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("toastty")
            .path
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
        cliExecutablePath: String,
        profileID: String,
        sessionID: String,
        panelID: UUID
    ) -> String {
        let command = [
            quote(cliExecutablePath),
            "agent",
            "run",
            quote(profileID),
            "--session",
            quote(sessionID),
            "--panel",
            quote(panelID.uuidString),
        ]
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
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
