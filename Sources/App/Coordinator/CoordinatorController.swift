import Combine
import CoreState
import Foundation

/// The part of the agent launcher the coordinator uses. A protocol so tests
/// can start the coordinator without terminals.
@MainActor
protocol CoordinatorAgentLaunching: AnyObject {
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
        /// Not typed and not kept: the caller asked for no queue, and still
        /// has the text.
        case held(CoordinatorSendHold)

        /// The text went into the terminal.
        var wasTyped: Bool {
            self == .sent || self == .sentUnconfirmed
        }
    }

    /// Entries waiting for an open prompt. They are kept in memory only: an
    /// agent restart keeps them and an app quit loses them. A caller whose
    /// text must survive a quit keeps its own copy until `send` returns.
    static let maximumQueuedEntries = 50

    /// The coordinator's workspace whose agent Toastty is starting. A start
    /// belongs to its workspace: a coordinator opened after that one closed
    /// gets its own start.
    @Published private var startingWorkspaceID: UUID?
    @Published private var failedStart: FailedStart?
    @Published private(set) var queuedCount = 0
    @Published private(set) var hold: CoordinatorSendHold?

    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private weak var launcher: (any CoordinatorAgentLaunching)?
    private let folder: CoordinatorFolder
    private let configLoader: () throws -> TasksConfig
    private let deliverText: (String, UUID) -> TerminalInputDeliveryResult
    private let promptState: (UUID) -> TerminalPromptState
    private let terminalReadinessTimeout: Duration
    private let now: () -> Date

    private struct FailedStart {
        var workspaceID: UUID
        var reason: String
    }

    /// A terminal chosen for a start. `replacedPanelID` is the coordinator's
    /// terminal that closes once the agent runs in the new one.
    private struct StartTerminal {
        var panelID: UUID
        var tabID: UUID?
        var replacedPanelID: UUID?
    }

    private var queue: [String] = []
    /// The coordinator's workspace the queue was filled for. The queue goes
    /// with that workspace: entries never reach a coordinator opened later.
    private var queueWorkspaceID: UUID?
    private var lastDelivery: CoordinatorPromptFacts.Delivery?
    private var recheckTask: Task<Void, Never>?
    /// The one run of `CoordinatorFolder.prepareRepository` under way.
    private var repositoryPreparation: Task<Void, Never>?
    private var sessionObserver: AnyCancellable?
    private var storeObserverToken: UUID?

    /// Called after the coordinator's workspace was created, closed or
    /// replaced, with the workspace it is now.
    var onWorkspaceChange: ((UUID?) -> Void)?

    /// `deliverText` types text plus Return into a terminal panel as
    /// programmatic input, which is not the user's own. `folder` defaults to
    /// `directoryURL` with the instructions Toastty ships.
    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        launcher: (any CoordinatorAgentLaunching)?,
        directoryURL: URL,
        folder: CoordinatorFolder? = nil,
        configLoader: @escaping () throws -> TasksConfig,
        deliverText: @escaping (String, UUID) -> TerminalInputDeliveryResult,
        promptState: @escaping (UUID) -> TerminalPromptState,
        terminalReadinessTimeout: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.launcher = launcher
        self.folder = folder ?? CoordinatorFolder(directoryURL: directoryURL)
        self.configLoader = configLoader
        self.deliverText = deliverText
        self.promptState = promptState
        self.terminalReadinessTimeout = terminalReadinessTimeout
        self.now = now
        // A session that starts, ends a turn or stops can open the prompt
        // for the next queued entry. `sink` runs before the new value is
        // stored, so the queue is looked at on the next main-actor turn.
        sessionObserver = sessionRuntimeStore.$sessionRegistry
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.drain() }
            }
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, previousState, nextState in
            let workspaceID = nextState.coordinatorWorkspaceID
            guard previousState.coordinatorWorkspaceID != workspaceID else { return }
            self?.onWorkspaceChange?(workspaceID)
        }
        refreshFolderOfARestoredCoordinator()
    }

    /// After a relaunch, Toastty resumes the agent of a restored coordinator
    /// when its terminal comes up, and no start of this controller runs
    /// before that. The instruction files are written here, at launch, so
    /// the resumed agent reads the instructions of this Toastty. When they
    /// cannot be written, nothing is resumed: the terminal comes up without
    /// an agent, and the row says why until a start works.
    private func refreshFolderOfARestoredCoordinator() {
        guard let location else { return }
        do {
            try folder.prepareFiles()
        } catch {
            let reason = Self.startFailureReason(for: error)
            ToasttyLog.warning("Could not refresh the coordinator's folder at launch", category: .tasks, metadata: [
                "reason": reason,
            ])
            if let panelID = location.panelID {
                _ = store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: nil))
            }
            failedStart = FailedStart(workspaceID: location.workspaceID, reason: reason)
            return
        }
        Task { [weak self] in await self?.prepareRepository() }
    }

    deinit {
        recheckTask?.cancel()
        if let storeObserverToken {
            Task { @MainActor [store] in store.removeActionAppliedObserver(storeObserverToken) }
        }
    }

    // MARK: - State

    var location: CoordinatorLocation? {
        store.state.coordinator
    }

    /// Toastty is starting the agent of the current coordinator.
    var isStarting: Bool {
        startingWorkspaceID != nil && startingWorkspaceID == location?.workspaceID
    }

    /// Why the last start of the current coordinator's agent did not work.
    var startFailure: String? {
        guard let failedStart, failedStart.workspaceID == location?.workspaceID else { return nil }
        return failedStart.reason
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
        let sessionID = try await startAgent(location, replacingBusyTerminal: false)
        return StartResult(
            location: self.location ?? location,
            createdWorkspace: createdWorkspace,
            startedAgent: true,
            sessionID: sessionID
        )
    }

    /// Starts a fresh agent session in the coordinator's workspace. An agent
    /// that still runs is ended: the new session gets a new terminal, and
    /// once it runs there the old terminal closes. A start that fails leaves
    /// the old agent alone. A terminal at its shell prompt is used again.
    @discardableResult
    func restart(windowID requestedWindowID: UUID? = nil) async throws -> StartResult {
        guard isStarting == false else {
            throw CoordinatorError("The coordinator is already starting.")
        }
        let createdWorkspace = try createWorkspaceIfNeeded(windowID: requestedWindowID)
        guard let location else {
            throw CoordinatorError("Toastty could not create the coordinator's workspace.")
        }
        let sessionID = try await startAgent(location, replacingBusyTerminal: true)
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

    /// The coordinator's folder with its files in place. An agent never
    /// starts without the instructions of this Toastty.
    private func preparedDirectory() throws -> String {
        try folder.prepareFiles()
    }

    /// Makes the folder a git repository when it is none. Calls that
    /// overlap wait for the same run.
    private func prepareRepository() async {
        if let repositoryPreparation {
            await repositoryPreparation.value
            return
        }
        let folder = folder
        let preparation = Task { await folder.prepareRepository() }
        repositoryPreparation = preparation
        await preparation.value
        repositoryPreparation = nil
    }

    private func startAgent(_ location: CoordinatorLocation, replacingBusyTerminal: Bool) async throws -> String {
        let workspaceID = location.workspaceID
        startingWorkspaceID = workspaceID
        failedStart = nil
        defer {
            if startingWorkspaceID == workspaceID { startingWorkspaceID = nil }
            drain()
        }
        do {
            return try await launchAgent(location, replacingBusyTerminal: replacingBusyTerminal)
        } catch {
            let reason = Self.startFailureReason(for: error)
            if self.location?.workspaceID == workspaceID {
                failedStart = FailedStart(workspaceID: workspaceID, reason: reason)
            }
            ToasttyLog.warning("The coordinator's agent did not start", category: .tasks, metadata: ["reason": reason])
            throw CoordinatorError(reason)
        }
    }

    private func launchAgent(_ location: CoordinatorLocation, replacingBusyTerminal: Bool) async throws -> String {
        guard let launcher else {
            throw CoordinatorError("The agent launcher is not available.")
        }
        let config: TasksConfig.Coordinator
        do {
            config = try configLoader().coordinator
        } catch {
            throw CoordinatorError(error.localizedDescription)
        }
        let directory = try preparedDirectory()
        await prepareRepository()
        let terminal = try terminalForStart(location, directory: directory, replacingBusyTerminal: replacingBusyTerminal)
        let result: AgentLaunchResult
        do {
            result = try await TaskCoordinator.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                try await launcher.launchCoordinator(
                    profileID: config.agent,
                    workspaceID: location.workspaceID,
                    panelID: terminal.panelID,
                    cwd: directory,
                    model: config.model,
                    reasoningEffort: config.effort
                )
            }
        } catch {
            abandonReplacement(terminal)
            throw error
        }
        adoptReplacement(terminal, workspaceID: location.workspaceID)
        ToasttyLog.info("Started the coordinator's agent", category: .tasks, metadata: [
            "session_id": result.sessionID,
            "panel_id": terminal.panelID.uuidString,
            "agent": config.agent,
        ])
        return result.sessionID
    }

    /// The terminal the agent starts in: the coordinator's own when it can
    /// take a command, else a new one in the same workspace. A new terminal
    /// that replaces one becomes the coordinator's only after the agent
    /// started in it, so a start that fails ends no running agent.
    private func terminalForStart(
        _ location: CoordinatorLocation,
        directory: String,
        replacingBusyTerminal: Bool
    ) throws -> StartTerminal {
        if let panelID = location.panelID {
            let isBusy = sessionRuntimeStore.sessionRegistry.activeSession(for: panelID) != nil
                || promptState(panelID) == .busy
                || promptState(panelID) == .exited
                // Closing the terminal also drops its pending resume.
                || awaitsRestore(location)
            if replacingBusyTerminal == false || isBusy == false {
                return StartTerminal(panelID: panelID, tabID: nil, replacedPanelID: nil)
            }
        }
        let terminal = StartTerminal(panelID: UUID(), tabID: UUID(), replacedPanelID: location.panelID)
        guard let tabID = terminal.tabID, store.send(.createBackgroundTerminalTab(
            workspaceID: location.workspaceID,
            tabID: tabID,
            panelID: terminal.panelID,
            terminalCWD: directory
        )) else {
            throw CoordinatorError("Toastty could not open a terminal in the coordinator's workspace.")
        }
        if terminal.replacedPanelID == nil {
            // Nothing to replace: the new terminal is the coordinator's now.
            adoptReplacement(terminal, workspaceID: location.workspaceID)
        }
        return terminal
    }

    /// Makes a new terminal the coordinator's and closes the one it
    /// replaces, which ends the agent that ran there.
    private func adoptReplacement(_ terminal: StartTerminal, workspaceID: UUID) {
        guard let tabID = terminal.tabID else { return }
        guard store.send(.setCoordinatorPanel(panelID: terminal.panelID)) || location?.panelID == terminal.panelID else { return }
        _ = store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
        if let replacedPanelID = terminal.replacedPanelID {
            _ = store.send(.closePanel(panelID: replacedPanelID, preservesTabSelection: true))
        }
    }

    /// After a start that failed: the terminal that was to replace the
    /// coordinator's goes, and the old terminal with its agent stays. When
    /// the old terminal closed meanwhile, the new one is all there is.
    private func abandonReplacement(_ terminal: StartTerminal) {
        guard let replacedPanelID = terminal.replacedPanelID else { return }
        if location?.panelID == replacedPanelID {
            _ = store.send(.closePanel(panelID: terminal.panelID, preservesTabSelection: true))
        } else {
            _ = store.send(.setCoordinatorPanel(panelID: terminal.panelID))
        }
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
    ///
    /// With `queueWhenHeld` off, text that cannot be typed now is not kept:
    /// the answer is `held`, and the caller sends its text again later. A
    /// caller that keeps its own durable copy uses this, so its text can
    /// change while it waits and is typed at most once. Such text never
    /// goes in front of entries that wait in the queue.
    @discardableResult
    func send(_ text: String, queueWhenHeld: Bool = true) throws -> SendResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw CoordinatorError("The message is empty.")
        }
        dropQueueOfAClosedCoordinator()
        guard let location else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        guard queueWhenHeld else {
            guard queue.isEmpty else { return .held(hold ?? .awaitingTurn) }
            switch typeAtOpenPrompt(text, location: location, moment: now()) {
            case .typed(.delivered): return .sent
            case .typed: return .sentUnconfirmed
            case .held(let reason, _): return .held(reason)
            }
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
        switch typeAtOpenPrompt(text, location: location, moment: moment) {
        case .held(let reason, let recheckAt):
            setHold(reason)
            if let recheckAt { scheduleRecheck(at: recheckAt, from: moment) }
            return nil
        case .typed(let result):
            queue.removeFirst()
            if queue.isEmpty {
                setHold(nil)
            } else {
                // Sets the hold of the next entry, which waits for this
                // one's turn.
                drain()
            }
            return result
        }
    }

    private enum TypingOutcome {
        /// `delivered` or `uncertain`: the text is in the terminal.
        case typed(TerminalInputDeliveryResult)
        /// `recheckAt` is set when the hold can lift without a change to
        /// the session.
        case held(CoordinatorSendHold, recheckAt: Date?)
    }

    /// The one place that types into the coordinator: it types `text` when
    /// the agent's prompt is open, and says why not otherwise.
    private func typeAtOpenPrompt(_ text: String, location: CoordinatorLocation, moment: Date) -> TypingOutcome {
        // During a restart the agent that still runs is about to end with
        // its terminal: text typed there would be lost. The start drains
        // the queue when it ends.
        guard isStarting == false else {
            return .held(.agentStarting, recheckAt: nil)
        }
        switch CoordinatorSendGate.decide(promptFacts(location: location), now: moment) {
        case .hold(let reason, let recheckAt):
            return .held(reason, recheckAt: recheckAt)
        case .open:
            break
        }
        // `open` implies a session and its panel.
        guard let panelID = location.panelID, let session else {
            return .held(.noSession, recheckAt: nil)
        }
        let result = deliverText(text, panelID)
        switch result {
        case .unavailable:
            return .held(.terminalUnavailable, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
        case .delivered, .uncertain:
            lastDelivery = CoordinatorPromptFacts.Delivery(
                sessionID: session.sessionID,
                at: moment,
                submitConfirmed: result == .delivered
            )
            ToasttyLog.info("Typed a message into the coordinator", category: .tasks, metadata: [
                "session_id": session.sessionID,
                "submit_confirmed": result == .delivered ? "true" : "false",
                "queue_depth": String(max(0, queue.count - 1)),
            ])
            return .typed(result)
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
