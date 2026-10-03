import CoreState
import Foundation
import RemoteProtocol

/// The part of the agent launcher that a remote start uses. A protocol so
/// tests can run the start flow without a terminal.
@MainActor
protocol RemoteSessionLaunching: AnyObject {
    func launchProfileSummaries() -> [AgentLaunchProfileSummary]

    /// Launches `profileID` in the given terminal without moving focus.
    /// `beforeDispatch` runs after the launcher's last suspension, directly
    /// before the command is sent; a throw there cancels the launch.
    func launchForRemoteStart(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String,
        beforeDispatch: @escaping @MainActor () throws -> Void
    ) async throws -> AgentLaunchResult
}

extension AgentLaunchService: RemoteSessionLaunching {
    func launchForRemoteStart(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String,
        beforeDispatch: @escaping @MainActor () throws -> Void
    ) async throws -> AgentLaunchResult {
        try await launchAsync(
            profileID: profileID,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            focusPolicy: .preserveFirstResponder,
            beforeDispatch: beforeDispatch
        )
    }
}

/// Starts an agent session for a paired remote device.
///
/// The device names a workspace and a profile. This type chooses the
/// directory, opens a new terminal tab that is not selected, and launches the
/// agent there through the managed launcher, so the Mac's focus and visible
/// tab do not change.
@MainActor
final class RemoteSessionStarter {
    /// How long a new terminal may take to show its first shell prompt.
    static let defaultTerminalReadinessTimeout: Duration = .seconds(10)
    private static let terminalReadinessRetryInterval: Duration = .milliseconds(250)
    private static let maximumRememberedStarts = 64

    private struct RequestKey: Hashable {
        var deviceID: UUID
        var clientRequestID: String
    }

    private struct RememberedStart {
        var conversationID: RemoteConversationID
        var finishedAt: Date
    }

    private enum DispatchRefused: Error {
        /// The device lost its permission while the terminal was starting.
        case permission
        /// The terminal could not be given its conversation ID.
        case conversation
    }

    private let store: AppStore
    private weak var launcher: (any RemoteSessionLaunching)?
    private let fileManager: FileManager
    private let now: () -> Date
    private let terminalReadinessTimeout: Duration
    /// Whether the device may still start a session at this instant: remote
    /// access is on, and the device is unrevoked and permitted.
    private let deviceMayStart: (UUID) -> Bool
    /// Models that sessions of one provider report now, most recent first.
    private let recentModels: (AgentKind) -> [String]
    /// Publishes the session list after a launch, so the device sees the
    /// new conversation without waiting for the next change.
    private let publishSessionList: () -> Void

    private var inFlight: [RequestKey: Task<RemoteSessionStartResult, Never>] = [:]
    /// Starts that succeeded, kept so a repeat of the same request returns
    /// the first conversation instead of launching again. Held in memory:
    /// after a Toastty restart, or after
    /// `RemoteSessionStartPolicy.duplicateRequestWindow`, a repeat starts a
    /// new session. Refusals are not kept, because nothing was launched. An
    /// unexpired entry is never dropped to make room: at the limit, new
    /// starts are refused as busy until an entry expires.
    private var rememberedStarts: [RequestKey: RememberedStart] = [:]

    init(
        store: AppStore,
        launcher: (any RemoteSessionLaunching)?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        terminalReadinessTimeout: Duration = RemoteSessionStarter.defaultTerminalReadinessTimeout,
        deviceMayStart: @escaping (UUID) -> Bool,
        recentModels: @escaping (AgentKind) -> [String],
        publishSessionList: @escaping () -> Void
    ) {
        self.store = store
        self.launcher = launcher
        self.fileManager = fileManager
        self.now = now
        self.terminalReadinessTimeout = terminalReadinessTimeout
        self.deviceMayStart = deviceMayStart
        self.recentModels = recentModels
        self.publishSessionList = publishSessionList
    }

    // MARK: - Options

    func options(
        for request: RemoteSessionStartOptionsRequest,
        device: RemoteDeviceRecord
    ) -> RemoteSessionStartOptionsResponse {
        let permission = RemoteGatewayRequestHandler.sessionStartPermission(for: device)
        guard let workspace = store.state.workspacesByID[request.workspaceID] else {
            return RemoteSessionStartOptionsResponse(permission: permission, workspace: .notFound)
        }
        let directory = launchDirectory(in: workspace)
        return RemoteSessionStartOptionsResponse(
            permission: permission,
            workspace: directory == nil ? .noDirectory : .available,
            launchDirectory: directory,
            agents: offeredProfiles().map { summary in
                RemoteSessionStartAgent(
                    profileID: summary.profileID,
                    displayName: summary.displayName,
                    availability: Self.availability(of: summary),
                    supportsModel: summary.supportsModel,
                    recentModels: summary.supportsModel
                        ? Array(recentModels(summary.agent).prefix(RemoteSessionStartPolicy.maximumRecentModelCount))
                        : [],
                    reasoningEfforts: Self.reasoningEfforts(for: summary)
                )
            }
        )
    }

    /// Only providers that the remote session list can show are offered. A
    /// session of any other provider would start and then never appear on
    /// the device.
    private func offeredProfiles() -> [AgentLaunchProfileSummary] {
        (launcher?.launchProfileSummaries() ?? []).filter {
            ProviderTranscriptSupport.isManagedProvider($0.agent)
        }
    }

    private static func availability(
        of summary: AgentLaunchProfileSummary
    ) -> RemoteSessionStartAgentAvailability {
        if summary.isInstalled == false { return .notInstalled }
        return summary.acceptsInitialPrompt ? .available : .firstMessageUnsupported
    }

    /// The effort values each provider's command accepts. Empty for a
    /// provider with no effort setting.
    static func reasoningEfforts(for summary: AgentLaunchProfileSummary) -> [String] {
        guard summary.supportsReasoningEffort else { return [] }
        switch summary.agent {
        case .claude: return ["low", "medium", "high", "xhigh", "max"]
        case .codex: return ["low", "medium", "high", "xhigh"]
        case .pi: return ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        default: return []
        }
    }

    /// The directory a new session starts in: the first terminal, in tab
    /// order, whose directory is known and still exists. This does not
    /// follow focus, so the answer is the same between the options request
    /// and the start.
    func launchDirectory(in workspace: WorkspaceState) -> String? {
        for tab in workspace.orderedTabs {
            for slot in tab.layoutTree.allSlotInfos {
                guard case .terminal(let terminal) = tab.panels[slot.panelID],
                      let directory = terminal.agentLaunchWorkingDirectory else { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                    return directory
                }
            }
        }
        return nil
    }

    // MARK: - Start

    func start(
        _ request: RemoteSessionStartRequest,
        device: RemoteDeviceRecord
    ) async -> RemoteSessionStartResult {
        let key = RequestKey(deviceID: device.id, clientRequestID: request.clientRequestID)
        forgetExpiredStarts()
        if let remembered = rememberedStarts[key] {
            return .started(conversationID: remembered.conversationID)
        }
        if let task = inFlight[key] {
            return await task.value
        }
        guard inFlight.keys.contains(where: { $0.deviceID == device.id }) == false,
              rememberedStarts.count + inFlight.count < Self.maximumRememberedStarts else {
            return .rejected(reason: .busy)
        }
        // Not a child of the request's task: if the device disconnects, the
        // launch still finishes and a repeat of the request finds its result.
        let task = Task { @MainActor [weak self] () -> RemoteSessionStartResult in
            guard let self else { return .rejected(reason: .launchFailed) }
            return await self.performStart(request, deviceID: device.id)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if case .started(let conversationID) = result {
            rememberedStarts[key] = RememberedStart(conversationID: conversationID, finishedAt: now())
        }
        return result
    }

    private func forgetExpiredStarts() {
        let cutoff = now().addingTimeInterval(-RemoteSessionStartPolicy.duplicateRequestWindow)
        rememberedStarts = rememberedStarts.filter { $0.value.finishedAt > cutoff }
    }

    private func performStart(
        _ request: RemoteSessionStartRequest,
        deviceID: UUID
    ) async -> RemoteSessionStartResult {
        guard let launcher else { return .rejected(reason: .launchFailed) }
        guard let workspace = store.state.workspacesByID[request.workspaceID] else {
            return .rejected(reason: .workspaceNotFound)
        }
        guard let directory = launchDirectory(in: workspace) else {
            return .rejected(reason: .workspaceUnavailable)
        }
        guard let summary = offeredProfiles().first(where: { $0.profileID == request.profileID }),
              Self.availability(of: summary) == .available else {
            return .rejected(reason: .agentUnavailable)
        }
        if request.model != nil, summary.supportsModel == false {
            return .rejected(reason: .invalidRequest)
        }
        if let effort = request.reasoningEffort,
           Self.reasoningEfforts(for: summary).contains(effort) == false {
            return .rejected(reason: .invalidRequest)
        }
        // A wrapper command gives no safe way to pass text that starts with
        // a dash, so that text is refused instead of risking an option.
        if request.text.hasPrefix("-"), summary.acceptsLeadingDashPrompt == false {
            return .rejected(reason: .invalidRequest)
        }

        let tabID = UUID()
        let panelID = UUID()
        guard store.send(.createBackgroundTerminalTab(
            workspaceID: request.workspaceID,
            tabID: tabID,
            panelID: panelID,
            terminalCWD: directory
        )) else {
            return .rejected(reason: .launchFailed)
        }

        // The terminal gets its conversation ID before the command is sent.
        // If that fails nothing is launched, so every refusal from here on
        // still means no session started.
        let conversationID = RemoteConversationID()
        var tabWasSelected = false
        do {
            _ = try await launchWhenTerminalIsReady(
                launcher: launcher,
                request: request,
                panelID: panelID,
                directory: directory,
                beforeEachAttempt: { [store] in
                    if store.state.workspacesByID[request.workspaceID]?.resolvedSelectedTabID == tabID {
                        tabWasSelected = true
                    }
                },
                beforeDispatch: { [store, deviceMayStart] in
                    guard deviceMayStart(deviceID) else { throw DispatchRefused.permission }
                    guard store.send(.updateTerminalPanelRemoteConversationID(
                        panelID: panelID,
                        remoteConversationID: conversationID
                    )) else { throw DispatchRefused.conversation }
                }
            )
        } catch {
            if case .terminalUnavailable? = error as? AgentLaunchError {
                // The terminal took some of the command but did not confirm
                // it. The tab stays, so the person can see what arrived.
            } else if tabWasSelected == false {
                closeCreatedTabIfUnused(workspaceID: request.workspaceID, tabID: tabID, panelID: panelID)
            }
            if case .permission? = error as? DispatchRefused {
                return .rejected(reason: .permissionDenied)
            }
            ToasttyLog.warning(
                "Remote session start failed",
                category: .automation,
                metadata: ["profileID": request.profileID, "reason": Self.logReason(for: error)]
            )
            return .rejected(reason: .launchFailed)
        }

        publishSessionList()
        return .started(conversationID: conversationID)
    }

    /// A fixed label for the log. Launch errors can carry directories and
    /// command text, which Remote Access logs never include.
    private static func logReason(for error: any Error) -> String {
        if case .conversation? = error as? DispatchRefused { return "conversation_id_not_stored" }
        guard let launchError = error as? AgentLaunchError else { return "unexpected_error" }
        switch launchError {
        case .panelBusy: return "terminal_not_ready"
        case .terminalUnavailable: return "command_delivery_unconfirmed"
        case .cliUnavailable: return "toastty_cli_unavailable"
        case .invalidWorkingDirectory: return "invalid_working_directory"
        case .launchOverrideUnsupported, .invalidLaunchOverride, .unsafeLaunchOverrideArgv:
            return "model_or_effort_not_applicable"
        case .initialPromptUnsupported, .invalidInitialPrompt: return "first_message_not_accepted"
        default: return "launch_refused"
        }
    }

    /// A new terminal reports itself busy until its shell prints the first
    /// prompt, and the launcher refuses a busy terminal before it sends
    /// anything. Retry that refusal until the prompt appears or the readiness
    /// timeout passes. No other failure is retried: once the launcher has
    /// tried to send the command, part of it may be in the terminal.
    private func launchWhenTerminalIsReady(
        launcher: any RemoteSessionLaunching,
        request: RemoteSessionStartRequest,
        panelID: UUID,
        directory: String,
        beforeEachAttempt: @MainActor () -> Void,
        beforeDispatch: @escaping @MainActor () throws -> Void
    ) async throws -> AgentLaunchResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: terminalReadinessTimeout)
        while true {
            beforeEachAttempt()
            do {
                return try await launcher.launchForRemoteStart(
                    profileID: request.profileID,
                    workspaceID: request.workspaceID,
                    panelID: panelID,
                    cwd: directory,
                    model: request.model,
                    reasoningEffort: request.reasoningEffort,
                    initialPrompt: request.text,
                    beforeDispatch: beforeDispatch
                )
            } catch AgentLaunchError.panelBusy {
                guard clock.now < deadline else { throw AgentLaunchError.panelBusy(runningCommand: nil) }
                try await Task.sleep(for: Self.terminalReadinessRetryInterval)
            }
        }
    }

    /// Removes the tab this request opened, but only while it is still what
    /// the request made: one terminal, in a tab that is not selected. The
    /// caller also skips this when it saw the tab selected during the launch.
    private func closeCreatedTabIfUnused(workspaceID: UUID, tabID: UUID, panelID: UUID) {
        guard let workspace = store.state.workspacesByID[workspaceID],
              let tab = workspace.tabsByID[tabID],
              workspace.resolvedSelectedTabID != tabID,
              tab.panels.count == 1,
              tab.panels[panelID] != nil,
              tab.rightAuxPanel.orderedTabs.isEmpty else { return }
        _ = store.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
    }
}
