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
    case noSelectedWorkspace
    case workspaceDoesNotExist
    case workspaceHasNoTerminalPanel
    case panelDoesNotExist
    case panelOutsideWorkspace
    case panelIsNotTerminal
    case panelBusy(runningCommand: String?)
    case launcherUnavailable(path: String?)
    case terminalUnavailable(panelID: UUID)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Agent launch is unavailable."
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
        case .launcherUnavailable(let path):
            if let path {
                return "Toastty could not find its helper CLI at \(path). Build the toastty target alongside the app and try again."
            }
            return "Toastty could not resolve its helper CLI path."
        case .terminalUnavailable(let panelID):
            return "The target terminal is unavailable for panel \(panelID.uuidString)."
        }
    }
}

@MainActor
final class AgentLaunchService {
    private weak var store: AppStore?
    private weak var terminalCommandRouter: (any TerminalCommandRouting)?
    private let socketPath: String
    private let fileManager: FileManager
    private let cliExecutablePathProvider: @Sendable () -> String?

    init(
        store: AppStore,
        terminalCommandRouter: any TerminalCommandRouting,
        socketPath: String,
        fileManager: FileManager = .default,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = AgentLaunchService.defaultCLIExecutablePath
    ) {
        self.store = store
        self.terminalCommandRouter = terminalCommandRouter
        self.socketPath = socketPath
        self.fileManager = fileManager
        self.cliExecutablePathProvider = cliExecutablePathProvider
    }

    func canLaunchAgent(workspaceID: UUID? = nil, panelID: UUID? = nil) -> Bool {
        (try? resolveLaunchTarget(workspaceID: workspaceID, panelID: panelID)) != nil
    }

    func launch(
        agent: AgentKind,
        workspaceID: UUID? = nil,
        panelID: UUID? = nil
    ) throws -> AgentLaunchResult {
        guard let terminalCommandRouter else {
            throw AgentLaunchError.serviceUnavailable
        }

        let target = try resolveLaunchTarget(workspaceID: workspaceID, panelID: panelID)
        try ensurePanelAppearsInteractive(panelID: target.panelID, terminalCommandRouter: terminalCommandRouter)

        let sessionID = UUID().uuidString
        let launchProfile = AgentLaunchProfile.builtin(for: agent)
        let repoRoot = Self.inferRepoRoot(from: target.cwd, fileManager: fileManager)
        let cliExecutablePath = try resolveCLIExecutablePath()
        let commandLine = ShellCommandRenderer.render(
            argv: launcherCommandArguments(
                cliExecutablePath: cliExecutablePath,
                agent: agent,
                sessionID: sessionID,
                target: target,
                repoRoot: repoRoot,
                launchProfile: launchProfile
            )
        )

        guard terminalCommandRouter.sendText(commandLine, submit: true, panelID: target.panelID) else {
            throw AgentLaunchError.terminalUnavailable(panelID: target.panelID)
        }

        return AgentLaunchResult(
            agent: agent,
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

    private func launcherCommandArguments(
        cliExecutablePath: String,
        agent: AgentKind,
        sessionID: String,
        target: LaunchTarget,
        repoRoot: String?,
        launchProfile: AgentLaunchProfile
    ) -> [String] {
        var arguments = [
            cliExecutablePath,
            ToasttyInternalCommand.agentLaunch,
            "--session", sessionID,
            "--agent", agent.rawValue,
            "--panel", target.panelID.uuidString,
            "--window", target.windowID.uuidString,
            "--workspace", target.workspaceID.uuidString,
            "--socket-path", socketPath,
        ]
        if let cwd = target.cwd {
            arguments.append(contentsOf: ["--cwd", cwd])
        }
        if let repoRoot {
            arguments.append(contentsOf: ["--repo-root", repoRoot])
        }
        arguments.append("--")
        arguments.append(contentsOf: launchProfile.argv)
        return arguments
    }

    private func resolveCLIExecutablePath() throws -> String {
        guard let candidatePath = normalizedNonEmpty(cliExecutablePathProvider()) else {
            throw AgentLaunchError.launcherUnavailable(path: nil)
        }
        guard fileManager.isExecutableFile(atPath: candidatePath) else {
            throw AgentLaunchError.launcherUnavailable(path: candidatePath)
        }
        return candidatePath
    }

    private static func inferRepoRoot(from cwd: String?, fileManager: FileManager) -> String? {
        guard let cwd = normalizedNonEmpty(cwd) else { return nil }

        var candidateURL = URL(fileURLWithPath: cwd, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        while true {
            let gitURL = candidateURL.appendingPathComponent(".git", isDirectory: false)
            if fileManager.fileExists(atPath: gitURL.path) {
                return candidateURL.path
            }

            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path {
                return nil
            }
            candidateURL = parentURL
        }
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

private struct AgentLaunchProfile {
    let argv: [String]

    static func builtin(for agent: AgentKind) -> Self {
        switch agent {
        case .claude:
            return Self(argv: ["claude"])
        case .codex:
            return Self(argv: ["codex"])
        }
    }
}

private enum ShellCommandRenderer {
    // Launch profiles stay argv-based internally. We only render a single shell
    // command line at the terminal-injection boundary because the target shell
    // is already running inside the panel.
    static func render(argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
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
