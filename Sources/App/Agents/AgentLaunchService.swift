import Combine
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
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let agentCatalogProvider: any AgentCatalogProviding
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let cliExecutablePathProvider: @Sendable () -> String?
    private let socketPathProvider: @Sendable () -> String
    private var sessionRegistryObservation: AnyCancellable?
    private var managedArtifactsBySessionID: [String: ManagedLaunchArtifacts] = [:]

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
        self.sessionRuntimeStore = sessionRuntimeStore
        self.agentCatalogProvider = agentCatalogProvider
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.cliExecutablePathProvider = cliExecutablePathProvider
        self.socketPathProvider = socketPathProvider
        sessionRegistryObservation = sessionRuntimeStore.$sessionRegistry.sink { [weak self] registry in
            Task { @MainActor in
                self?.cleanupManagedArtifacts(forInactiveSessionsIn: registry)
            }
        }
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
        let socketPath = socketPathProvider()
        let preparedLaunch = prepareLaunch(
            agent: agent,
            argv: launchProfile.argv,
            cliExecutablePath: cliExecutablePath,
            sessionID: sessionID,
            workingDirectory: target.cwd
        )
        let commandLine = ShellCommandRenderer.render(
            agentID: launchProfile.id,
            argv: preparedLaunch.argv,
            cliExecutablePath: cliExecutablePath,
            socketPath: socketPath,
            sessionID: sessionID,
            panelID: target.panelID,
            cwd: target.cwd,
            repoRoot: repoRoot,
            additionalEnvironment: preparedLaunch.environment
        )
        let now = nowProvider()

        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: target.panelID,
            windowID: target.windowID,
            workspaceID: target.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: target.cwd,
            repoRoot: repoRoot,
            at: now
        )
        sessionRuntimeStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: now
        )

        guard terminalCommandRouter.sendText(commandLine, submit: true, panelID: target.panelID) else {
            cleanup(preparedLaunch.artifacts)
            sessionRuntimeStore.stopSession(sessionID: sessionID, at: now)
            throw AgentLaunchError.terminalUnavailable(panelID: target.panelID)
        }
        registerManagedArtifacts(preparedLaunch.artifacts, sessionID: sessionID)
        store?.recordSuccessfulAgentLaunch()

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

    private func registerManagedArtifacts(_ preparedArtifacts: PreparedAgentLaunchArtifacts?, sessionID: String) {
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

    private func cleanupManagedArtifacts(forInactiveSessionsIn registry: SessionRegistry) {
        let inactiveSessionIDs = managedArtifactsBySessionID.keys.filter { sessionID in
            registry.activeSession(sessionID: sessionID) == nil
        }
        for sessionID in inactiveSessionIDs {
            cleanupManagedArtifacts(for: sessionID)
        }
    }

    private func cleanupManagedArtifacts(for sessionID: String) {
        guard let managedArtifacts = managedArtifactsBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        cleanup(managedArtifacts)
    }

    private func cleanup(_ preparedArtifacts: PreparedAgentLaunchArtifacts?) {
        guard let preparedArtifacts else { return }
        cleanup(
            ManagedLaunchArtifacts(
                directoryURL: preparedArtifacts.directoryURL,
                codexSessionLogWatcher: nil
            )
        )
    }

    private func cleanup(_ managedArtifacts: ManagedLaunchArtifacts) {
        managedArtifacts.codexSessionLogWatcher?.stop()
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

    private static func windowID(containing workspaceID: UUID, in state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }

    nonisolated static func defaultCLIExecutablePath() -> String? {
        resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL
        )
    }

    nonisolated static func resolvedDefaultCLIExecutablePath(
        fileManager: FileManager,
        bundleURL: URL,
        executableURL: URL?
    ) -> String? {
        let candidates = defaultCLIExecutablePathCandidates(
            bundleURL: bundleURL,
            executableURL: executableURL
        )
        return candidates.first(where: { isUsableCLIExecutable(atPath: $0, fileManager: fileManager) }) ?? candidates.first
    }

    nonisolated static func defaultCLIExecutablePathCandidates(
        bundleURL: URL,
        executableURL: URL?
    ) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ path: String) {
            guard candidates.contains(path) == false else { return }
            candidates.append(path)
        }

        appendCandidate(
            bundleURL
                .appendingPathComponent("Contents/Helpers", isDirectory: true)
                .appendingPathComponent("toastty", isDirectory: false)
                .path
        )

        if let executableURL {
            appendCandidate(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("toastty")
                    .path
            )
        }

        appendCandidate(
            bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("toastty")
                .path
        )

        return candidates
    }

    nonisolated private static func isUsableCLIExecutable(
        atPath path: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: path) else {
            return false
        }

        let url = URL(fileURLWithPath: path)
        guard let siblingNames = try? fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) else {
            return false
        }

        return siblingNames.contains(url.lastPathComponent)
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

private struct ManagedLaunchArtifacts {
    let directoryURL: URL
    let codexSessionLogWatcher: CodexSessionLogWatcher?
}

private enum ShellCommandRenderer {
    static func render(
        agentID: String,
        argv: [String],
        cliExecutablePath: String,
        socketPath: String,
        sessionID: String,
        panelID: UUID,
        cwd: String?,
        repoRoot: String?,
        additionalEnvironment: [String: String]
    ) -> String {
        var command = [
            assignment(ToasttyLaunchContextEnvironment.sessionIDKey, sessionID),
            assignment(ToasttyLaunchContextEnvironment.panelIDKey, panelID.uuidString),
            assignment(ToasttyLaunchContextEnvironment.socketPathKey, socketPath),
            assignment(ToasttyLaunchContextEnvironment.cliPathKey, cliExecutablePath),
        ]

        if let cwd {
            command.append(assignment(ToasttyLaunchContextEnvironment.cwdKey, cwd))
        }
        if let repoRoot {
            command.append(assignment(ToasttyLaunchContextEnvironment.repoRootKey, repoRoot))
        }
        command.append(
            contentsOf: additionalEnvironment
                .sorted(by: { $0.key < $1.key })
                .map { assignment($0.key, $0.value) }
        )

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
