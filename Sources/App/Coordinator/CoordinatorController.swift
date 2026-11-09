import Combine
import CoreState
import Foundation

/// The part of the agent launcher the coordinator uses. A protocol so tests
/// can start the coordinator without terminals.
@MainActor
protocol CoordinatorAgentLaunching: AnyObject {
    /// Throws when no agent profile has this ID.
    func checkCoordinatorProfile(_ profileID: String) throws
    /// Launches into the given terminal without moving focus and with no
    /// first message.
    func launchCoordinator(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> AgentLaunchResult
}

extension AgentLaunchService: CoordinatorAgentLaunching {
    func checkCoordinatorProfile(_ profileID: String) throws {
        _ = try profileExecutableState(profileID: profileID)
    }

    func launchCoordinator(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> AgentLaunchResult {
        try await launchAsync(
            profileID: profileID,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            model: model,
            reasoningEffort: reasoningEffort,
            focusPolicy: .preserveFirstResponder
        )
    }
}

struct CoordinatorError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Owns the coordinator: one long-lived agent session in its own pinned
/// workspace. This is the one place that knows which workspace and session
/// that is, and `send` is the one way to give it text.
///
/// The coordinator is not a task. It has no task record, so it is in no task
/// list, stage or webhook event. Its state is the task records and the files
/// in its folder, so a fresh session can always replace it.
@MainActor
final class CoordinatorController: ObservableObject {
    enum AgentState: String, Equatable {
        /// No agent session runs in the coordinator's terminal.
        case notRunning
        /// Toastty is starting the agent.
        case starting
        case running
    }

    /// What the coordinator is right now.
    struct Status: Equatable {
        var location: CoordinatorLocation
        var agentState: AgentState
        /// The agent session in the coordinator's terminal, while one runs.
        var session: SessionRecord?
        /// Why the last start did not work, until the next start.
        var startFailure: String?
        var queuedCount: Int
        /// Why the first queued entry waits.
        var hold: CoordinatorSendHold?
    }

    struct StartResult: Equatable {
        var location: CoordinatorLocation
        /// The workspace was created by this call.
        var createdWorkspace: Bool
        /// This call started the agent. False when one already ran.
        var startedAgent: Bool
        var sessionID: String?
    }

    enum SendResult: Equatable {
        /// Typed and submitted at the agent's open prompt.
        case sent
        /// Typed, but the terminal did not confirm the Return key. It is
        /// not typed again.
        case sentUnconfirmed
        /// Kept until the agent's prompt is open. `position` counts from 1.
        case queued(position: Int, hold: CoordinatorSendHold)
    }

    /// Entries waiting for an open prompt. They are kept in memory only: an
    /// agent restart keeps them and an app quit loses them. A caller whose
    /// text must survive a quit keeps its own copy until `send` returns.
    static let maximumQueuedEntries = 50

    @Published private(set) var isStarting = false
    @Published private(set) var startFailure: String?
    @Published private(set) var queuedCount = 0
    @Published private(set) var hold: CoordinatorSendHold?

    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private weak var launcher: (any CoordinatorAgentLaunching)?
    private let directoryURL: URL
    private let configLoader: () throws -> TasksConfig
    private let deliverText: (String, UUID) -> TerminalInputDeliveryResult
    private let promptState: (UUID) -> TerminalPromptState
    private let fileManager: FileManager
    private let terminalReadinessTimeout: Duration
    private let now: () -> Date

    private var queue: [String] = []
    /// The coordinator's workspace the queue was filled for. The queue goes
    /// with that workspace: entries never reach a coordinator opened later.
    private var queueWorkspaceID: UUID?
    private var lastDelivery: CoordinatorPromptFacts.Delivery?
    private var recheckTask: Task<Void, Never>?
    private var sessionObserver: AnyCancellable?

    /// `deliverText` types text plus Return into a terminal panel as
    /// programmatic input, which is not the user's own.
    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        launcher: (any CoordinatorAgentLaunching)?,
        directoryURL: URL,
        configLoader: @escaping () throws -> TasksConfig,
        deliverText: @escaping (String, UUID) -> TerminalInputDeliveryResult,
        promptState: @escaping (UUID) -> TerminalPromptState,
        fileManager: FileManager = .default,
        terminalReadinessTimeout: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.launcher = launcher
        self.directoryURL = directoryURL
        self.configLoader = configLoader
        self.deliverText = deliverText
        self.promptState = promptState
        self.fileManager = fileManager
        self.terminalReadinessTimeout = terminalReadinessTimeout
        self.now = now
        // A session that starts, ends a turn or stops can open the prompt
        // for the next queued entry. `sink` runs before the new value is
        // stored, so the queue is looked at on the next main-actor turn.
        sessionObserver = sessionRuntimeStore.$sessionRegistry
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.drain() }
            }
    }

    deinit {
        recheckTask?.cancel()
    }

    // MARK: - State

    var location: CoordinatorLocation? {
        store.state.coordinator
    }

    /// The agent session in the coordinator's terminal, while one runs.
    var session: SessionRecord? {
        location?.panelID.flatMap { sessionRuntimeStore.sessionRegistry.activeSession(for: $0) }
    }

    /// `nil` when there is no coordinator.
    var status: Status? {
        guard let location else { return nil }
        let session = session
        let isStarting = isStarting || (session == nil && awaitsRestore(location))
        return Status(
            location: location,
            agentState: session != nil ? .running : (isStarting ? .starting : .notRunning),
            session: session,
            startFailure: session == nil && isStarting == false ? startFailure : nil,
            queuedCount: queue.count,
            hold: queue.isEmpty ? nil : hold
        )
    }

    /// After a relaunch, Toastty resumes the agent of a restored terminal
    /// when that terminal comes up. Until then the terminal has a saved
    /// conversation to resume, no session and no surface. A second start in
    /// that time would type into the same shell as the resume.
    private func awaitsRestore(_ location: CoordinatorLocation) -> Bool {
        guard let panelID = location.panelID,
              case .terminal(let terminal)? = store.state.workspacesByID[location.workspaceID]?.panelState(for: panelID),
              terminal.resumeRecord != nil else { return false }
        return promptState(panelID) == .unavailable
    }

    // MARK: - Open and restart

    /// Creates the coordinator's workspace on first use, selects it when
    /// `select` is set, and starts the agent when none runs. A terminal that
    /// is busy with something else is left alone: the call then fails, and
    /// Restart replaces that terminal.
    @discardableResult
    func open(windowID requestedWindowID: UUID? = nil, select: Bool = true) async throws -> StartResult {
        let createdWorkspace = try createWorkspaceIfNeeded(windowID: requestedWindowID)
        guard let location else {
            throw CoordinatorError("Toastty could not create the coordinator's workspace.")
        }
        if select {
            _ = store.selectWorkspace(
                windowID: location.windowID,
                workspaceID: location.workspaceID,
                preferringUnreadSessionPanelIn: sessionRuntimeStore
            )
        }
        if let session {
            return StartResult(location: location, createdWorkspace: createdWorkspace, startedAgent: false, sessionID: session.sessionID)
        }
        // A start under way, or the resume after a relaunch, gets the agent.
        guard isStarting == false, awaitsRestore(location) == false else {
            return StartResult(location: location, createdWorkspace: createdWorkspace, startedAgent: false, sessionID: nil)
        }
        let sessionID = try await startAgent(replacingBusyTerminal: false)
        return StartResult(
            location: self.location ?? location,
            createdWorkspace: createdWorkspace,
            startedAgent: true,
            sessionID: sessionID
        )
    }

    /// Starts a fresh agent session in the coordinator's workspace. An agent
    /// that still runs is ended: its terminal is closed and the new session
    /// gets a new one. A terminal at its shell prompt is used again.
    @discardableResult
    func restart(windowID requestedWindowID: UUID? = nil) async throws -> StartResult {
        guard isStarting == false else {
            throw CoordinatorError("The coordinator is already starting.")
        }
        let createdWorkspace = try createWorkspaceIfNeeded(windowID: requestedWindowID)
        guard let location else {
            throw CoordinatorError("Toastty could not create the coordinator's workspace.")
        }
        let sessionID = try await startAgent(replacingBusyTerminal: true)
        return StartResult(
            location: self.location ?? location,
            createdWorkspace: createdWorkspace,
            startedAgent: true,
            sessionID: sessionID
        )
    }

    private func createWorkspaceIfNeeded(windowID requestedWindowID: UUID?) throws -> Bool {
        guard store.state.coordinator == nil else { return false }
        guard let windowID = requestedWindowID ?? store.state.selectedWindowID ?? store.state.windows.first?.id,
              store.window(id: windowID) != nil else {
            throw CoordinatorError("Toastty has no open window for the coordinator.")
        }
        let directory = try preparedDirectory()
        guard store.send(.createCoordinatorWorkspace(
            windowID: windowID,
            workspaceID: UUID(),
            panelID: UUID(),
            terminalCWD: directory
        )) else {
            throw CoordinatorError("Toastty could not create the coordinator's workspace.")
        }
        ToasttyLog.info("Created the coordinator's workspace", category: .tasks, metadata: [
            "workspace_id": store.state.coordinatorWorkspaceID?.uuidString ?? "none",
            "directory": directory,
        ])
        return true
    }

    private func preparedDirectory() throws -> String {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw CoordinatorError("Toastty could not create the coordinator's folder \(directoryURL.path): \(error.localizedDescription)")
        }
        return directoryURL.path
    }

    private func startAgent(replacingBusyTerminal: Bool) async throws -> String {
        isStarting = true
        startFailure = nil
        defer {
            isStarting = false
            drain()
        }
        do {
            return try await launchAgent(replacingBusyTerminal: replacingBusyTerminal)
        } catch {
            let reason = Self.startFailureReason(for: error)
            startFailure = reason
            ToasttyLog.warning("The coordinator's agent did not start", category: .tasks, metadata: ["reason": reason])
            throw CoordinatorError(reason)
        }
    }

    private func launchAgent(replacingBusyTerminal: Bool) async throws -> String {
        guard let launcher else {
            throw CoordinatorError("The agent launcher is not available.")
        }
        let config: TasksConfig.Coordinator
        do {
            config = try configLoader().coordinator
        } catch {
            throw CoordinatorError(error.localizedDescription)
        }
        // Checked before a restart closes the terminal of a running agent:
        // a wrong setting must not end the session it cannot replace.
        try launcher.checkCoordinatorProfile(config.agent)
        let directory = try preparedDirectory()
        guard let location else {
            throw CoordinatorError("The coordinator's workspace is closed.")
        }
        let panelID = try terminalForStart(location, directory: directory, replacingBusyTerminal: replacingBusyTerminal)
        let result = try await TaskCoordinator.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
            try await launcher.launchCoordinator(
                profileID: config.agent,
                workspaceID: location.workspaceID,
                panelID: panelID,
                cwd: directory,
                model: config.model,
                reasoningEffort: config.effort
            )
        }
        ToasttyLog.info("Started the coordinator's agent", category: .tasks, metadata: [
            "session_id": result.sessionID,
            "panel_id": panelID.uuidString,
            "agent": config.agent,
        ])
        return result.sessionID
    }

    /// The terminal the agent starts in: the coordinator's own when it can
    /// take a command, else a new one in the same workspace.
    private func terminalForStart(
        _ location: CoordinatorLocation,
        directory: String,
        replacingBusyTerminal: Bool
    ) throws -> UUID {
        if let panelID = location.panelID {
            let isBusy = sessionRuntimeStore.sessionRegistry.activeSession(for: panelID) != nil
                || promptState(panelID) == .busy
                || promptState(panelID) == .exited
                // Closing the terminal also drops its pending resume.
                || awaitsRestore(location)
            if replacingBusyTerminal == false || isBusy == false {
                return panelID
            }
        }
        let tabID = UUID()
        let panelID = UUID()
        guard store.send(.createBackgroundTerminalTab(
            workspaceID: location.workspaceID,
            tabID: tabID,
            panelID: panelID,
            terminalCWD: directory
        )), store.send(.setCoordinatorPanel(panelID: panelID)) else {
            throw CoordinatorError("Toastty could not open a terminal in the coordinator's workspace.")
        }
        _ = store.send(.selectWorkspaceTab(workspaceID: location.workspaceID, tabID: tabID))
        if let previousPanelID = location.panelID {
            // Closing the terminal ends the agent that ran in it.
            _ = store.send(.closePanel(panelID: previousPanelID, preservesTabSelection: true))
        }
        return panelID
    }

    static func startFailureReason(for error: any Error) -> String {
        if let error = error as? CoordinatorError {
            return error.message
        }
        guard let launchError = error as? AgentLaunchError else {
            return "The coordinator's agent did not start: \(error.localizedDescription)"
        }
        switch launchError {
        case .panelBusy, .terminalUnavailable:
            return "The coordinator's terminal is busy or not ready. Restart Coordinator starts the agent in a new terminal."
        case .commandDeliveryUncertain:
            return "The agent command may not have reached the terminal. Check the coordinator's terminal before you restart it."
        default:
            return "The coordinator's agent did not start: \(launchError.localizedDescription)"
        }
    }

    // MARK: - Send

    /// Gives the coordinator's agent a message. The text is typed now when
    /// the agent is at an open prompt, and waits in order otherwise: while
    /// the agent works, while the user has a draft in that terminal, and
    /// while no agent runs. One entry is typed for each open prompt. The
    /// text is typed as programmatic input, so it never counts as the
    /// user's own typing.
    @discardableResult
    func send(_ text: String) throws -> SendResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw CoordinatorError("The message is empty.")
        }
        dropQueueOfAClosedCoordinator()
        guard location != nil else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        guard queue.count < Self.maximumQueuedEntries else {
            throw CoordinatorError("The coordinator already has \(Self.maximumQueuedEntries) messages waiting.")
        }
        queue.append(text)
        let waitingBefore = queue.count - 1
        switch drain() {
        case .delivered? where waitingBefore == 0:
            return .sent
        case .uncertain? where waitingBefore == 0:
            return .sentUnconfirmed
        default:
            return .queued(position: queue.count, hold: hold ?? .awaitingTurn)
        }
    }

    /// Types the first queued entry when the prompt is open. Returns that
    /// delivery's result, or `nil` when nothing was typed.
    @discardableResult
    private func drain() -> TerminalInputDeliveryResult? {
        recheckTask?.cancel()
        recheckTask = nil
        dropQueueOfAClosedCoordinator()
        defer {
            if queuedCount != queue.count { queuedCount = queue.count }
        }
        guard let location, let text = queue.first else {
            setHold(nil)
            return nil
        }
        let moment = now()
        switch CoordinatorSendGate.decide(promptFacts(location: location), now: moment) {
        case .hold(let reason, let recheckAt):
            setHold(reason)
            if let recheckAt { scheduleRecheck(at: recheckAt, from: moment) }
            return nil
        case .open:
            break
        }
        // `open` implies a session and its panel.
        guard let panelID = location.panelID, let session else { return nil }
        let result = deliverText(text, panelID)
        switch result {
        case .unavailable:
            setHold(.terminalUnavailable)
            scheduleRecheck(at: moment.addingTimeInterval(CoordinatorSendGate.pollInterval), from: moment)
            return nil
        case .delivered, .uncertain:
            queue.removeFirst()
            lastDelivery = CoordinatorPromptFacts.Delivery(sessionID: session.sessionID, at: moment)
            ToasttyLog.info("Typed a message into the coordinator", category: .tasks, metadata: [
                "session_id": session.sessionID,
                "submit_confirmed": result == .delivered ? "true" : "false",
                "queue_depth": String(queue.count),
            ])
            if queue.isEmpty {
                setHold(nil)
            } else {
                setHold(.awaitingTurn)
                scheduleRecheck(
                    at: moment.addingTimeInterval(CoordinatorSendGate.turnStartTimeout),
                    from: moment
                )
            }
            return result
        }
    }

    private func dropQueueOfAClosedCoordinator() {
        let workspaceID = location?.workspaceID
        guard workspaceID != queueWorkspaceID else { return }
        queue.removeAll()
        lastDelivery = nil
        queueWorkspaceID = workspaceID
    }

    private func promptFacts(location: CoordinatorLocation) -> CoordinatorPromptFacts {
        guard let panelID = location.panelID,
              let record = sessionRuntimeStore.sessionRegistry.activeSession(for: panelID) else {
            return CoordinatorPromptFacts(session: nil, isTerminalReady: false, lastDelivery: lastDelivery)
        }
        let terminalState = promptState(panelID)
        return CoordinatorPromptFacts(
            session: CoordinatorPromptFacts.Session(
                sessionID: record.sessionID,
                statusKind: record.status?.kind,
                startedAt: record.startedAt,
                lastTurnEndedAt: record.lastTurnEndedAt,
                lastTurnDuration: record.lastTurnDuration,
                // A provider Toastty follows reports its own session once
                // its process is up. Any other agent reports nothing, so
                // its status alone decides.
                hasReportedStart: ProviderTranscriptSupport.isManagedProvider(record.agent) == false
                    || sessionRuntimeStore.nativeSessionBindingConfirmation(for: record.sessionID) != nil
            ),
            isTerminalReady: terminalState != .unavailable && terminalState != .exited,
            lastUserInputAt: sessionRuntimeStore.lastUserInputAt(panelID: panelID),
            lastDelivery: lastDelivery
        )
    }

    private func setHold(_ next: CoordinatorSendHold?) {
        if hold != next { hold = next }
    }

    private func scheduleRecheck(at date: Date, from moment: Date) {
        let delay = max(0.05, date.timeIntervalSince(moment))
        recheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.drain()
        }
    }
}
