import Combine
import CoreState
import Foundation
import RemoteProtocol

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
        environment: [String: String],
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
        environment: [String: String],
        model: String?,
        reasoningEffort: String?
    ) async throws -> AgentLaunchResult {
        try await launchAsync(
            profileID: profileID,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            environment: environment,
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
        /// Typed into the agent's running turn: the user's message steered
        /// it. Only `sendUserText` and `steerQueuedEntry` steer.
        case steered
        /// Typed into the running turn, but the terminal did not confirm
        /// the Return key. It is not typed again.
        case steeredUnconfirmed

        /// The text went into the terminal.
        var wasTyped: Bool {
            switch self {
            case .sent, .sentUnconfirmed, .steered, .steeredUnconfirmed: true
            case .queued, .held: false
            }
        }
    }

    /// The most entries that wait for an open prompt. An agent restart
    /// keeps them all. An app quit keeps the user's own messages, which
    /// are saved in `queueFileURL`, and loses the others: a sender such as
    /// the wake digests keeps its own copy until `send` returns.
    static let maximumQueuedEntries = 50

    /// The coordinator's workspace whose agent Toastty is starting. A start
    /// belongs to its workspace: a coordinator opened after that one closed
    /// gets its own start.
    @Published private var startingWorkspaceID: UUID?
    @Published private var failedStart: FailedStart?
    @Published private(set) var queuedCount = 0
    @Published private(set) var hold: CoordinatorSendHold?
    /// The turn whose host refused a steer, for example because the
    /// terminal did not take the text. Messages wait for the rest of it.
    @Published private var turnThatRefusedASteer: RemoteInputEpoch?

    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private weak var launcher: (any CoordinatorAgentLaunching)?
    private let folder: CoordinatorFolder
    /// The files the user attached to messages for the coordinator.
    let attachments: CoordinatorAttachments
    /// Where the user's waiting messages are saved, or `nil` to save none.
    private let queueFileURL: URL?
    private let configLoader: () throws -> TasksConfig
    /// Tells the agent of the given profile that the coordinator's folder
    /// is trusted, before that agent starts there. See `ClaudeFolderTrust`.
    private let trustFolder: @MainActor (_ profileID: String, _ directory: String) async -> Void
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

    /// One message that waits for the coordinator's prompt.
    struct QueuedEntry: Equatable, Identifiable {
        /// Names the message for its sender. A message typed through the
        /// agent's conversation is echoed there under this ID.
        let id: String
        let text: String
        /// A person sent it, from the chat's composer or from quick entry.
        /// Such an entry is saved until it is typed, so an app quit does
        /// not lose it.
        let byUser: Bool
        /// Toastty quit while it typed this entry, so the coordinator may
        /// have it already. It waits with the paused entries until the
        /// user sends it again or removes it.
        var typingWasInterrupted = false

        /// "Steer now" may type it into a running turn: a message that the
        /// user wrote in the chat, also a reply. A quick entry message
        /// always waits for an open prompt, as messages from `coordinator
        /// send` and Toastty's digests do. The first line that Toastty
        /// writes on a message says which it is, also after a relaunch.
        var canBeSteered: Bool {
            guard byUser else { return false }
            switch CoordinatorMessageHeader.kind(of: text) {
            case .plain, .reply: return true
            case .digest, .fromSender, .quickEntry: return false
            }
        }
    }

    /// A message that reached the coordinator's terminal.
    struct TypedEntry: Equatable {
        let id: String
        let text: String
        /// The agent's conversation will show the message under `id`.
        let echoesInConversation: Bool
        /// It went into a running turn.
        var steered = false
    }

    /// Entries that wait for an open prompt, in the order they are typed.
    @Published private(set) var queuedEntries: [QueuedEntry] = []
    /// Entries that the user's Stop set aside. They are not typed, and do
    /// not hold later entries back, until `resumeQueue`.
    @Published private(set) var pausedEntries: [QueuedEntry] = []
    /// Each message as it is typed, for a view that shows it until the
    /// agent's conversation does.
    let typedEntries = PassthroughSubject<TypedEntry, Never>()

    /// What the coordinator's chat shows. Set once the app has the
    /// conversation access the chat reads through.
    var chat: CoordinatorChatModel?

    /// The question whether to start the coordinator, in a run that asks it.
    var startOffer: CoordinatorStartOffer?

    /// The coordinator's panel shows its terminal in place of the chat.
    var showsTerminal: Bool {
        get { store.coordinatorShowsTerminal }
        set {
            guard store.coordinatorShowsTerminal != newValue else { return }
            store.coordinatorShowsTerminal = newValue
            ToasttyLog.info("Changed what the coordinator's panel shows", category: .tasks, metadata: [
                "shows": newValue ? "terminal" : "chat",
            ])
        }
    }

    /// The chat needs the shared transcript view, which needs macOS 15.
    /// On macOS 14 the coordinator's panel shows its terminal, and no
    /// switch is offered.
    static var systemSupportsChat: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Whether the chat can show at all. A test sets it to see the panel
    /// as macOS 14 shows it.
    var supportsChat = CoordinatorController.systemSupportsChat

    /// Whether the chat covers this terminal. Keyboard focus and clicks
    /// meant for a covered terminal go to the chat.
    func coversTerminal(panelID: UUID) -> Bool {
        supportsChat && chat != nil && showsTerminal == false && location?.panelID == panelID
    }

    /// Reads and sends to agent conversations inside the app. Set once the
    /// app has it. Without it every agent gets its text through
    /// `CoordinatorSendGate`.
    var conversationAccess: (any LocalConversationAccess)? {
        didSet {
            syncConversationSubscription()
            drain()
        }
    }

    private static let rememberedTypedMessages = 500

    /// The controller's own subscription to the agent's conversation, and
    /// the task that follows its changes. See `syncConversationSubscription`.
    private var conversationSubscription: (any LocalConversationSubscription)?
    private var conversationObserver: Task<Void, Never>?
    private var typedMessageIDs: [String] = []
    /// The coordinator's workspace the queue was filled for. The queue goes
    /// with that workspace: entries never reach a coordinator opened later.
    private var queueWorkspaceID: UUID?
    /// The saved entry that Toastty types at this moment. It is saved
    /// before the text goes to the terminal: after a crash in that moment,
    /// the entry is not typed a second time without the user.
    private var typingEntryID: String?
    /// The queue as the file holds it, so that only a change is written.
    private var savedQueue: CoordinatorQueueSnapshot?
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
        queueFileURL: URL? = nil,
        configLoader: @escaping () throws -> TasksConfig,
        trustFolder: @escaping @MainActor (_ profileID: String, _ directory: String) async -> Void = { _, _ in },
        deliverText: @escaping (String, UUID) -> TerminalInputDeliveryResult,
        promptState: @escaping (UUID) -> TerminalPromptState,
        terminalReadinessTimeout: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.launcher = launcher
        self.folder = folder ?? CoordinatorFolder(directoryURL: directoryURL)
        self.attachments = CoordinatorAttachments(coordinatorDirectoryURL: directoryURL)
        self.queueFileURL = queueFileURL
        self.configLoader = configLoader
        self.trustFolder = trustFolder
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
            // Back in the coordinator, by any way: a task space no longer
            // needs to offer the way back.
            if let coordinator = nextState.coordinator,
               nextState.selectedWorkspaceID(in: coordinator.windowID) == coordinator.workspaceID,
               previousState.selectedWorkspaceID(in: coordinator.windowID) != coordinator.workspaceID {
                if self?.store.coordinatorReturnWorkspaceID != nil {
                    self?.store.coordinatorReturnWorkspaceID = nil
                }
            }
            if previousState.coordinator != nextState.coordinator {
                self?.syncConversationSubscription()
            }
            let workspaceID = nextState.coordinatorWorkspaceID
            guard previousState.coordinatorWorkspaceID != workspaceID else { return }
            // A coordinator opened later starts with the chat.
            self?.showsTerminal = false
            self?.onWorkspaceChange?(workspaceID)
            // The queue goes with its workspace: what waited for a closed
            // coordinator is dropped now, with its saved copy and files.
            Task { @MainActor [weak self] in self?.drain() }
        }
        restoreQueue()
        // A waiting message keeps the folders it names: after an edit in
        // the chat, its files are under the ID of the message it was.
        self.attachments.removeExpired(
            waitingMessageIDs: (queuedEntries + pausedEntries).reduce(into: Set<String>()) { ids, entry in
                ids.insert(entry.id)
                ids.formUnion(self.attachments.messageIDs(namedIn: entry.text))
            },
            now: now()
        )
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
        conversationObserver?.cancel()
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
            queuedCount: queuedEntries.count + pausedEntries.count,
            hold: queuedEntries.isEmpty ? nil : hold
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

    /// What a person asks of the coordinator from a menu, the command
    /// palette, the chat or the question at launch.
    enum UserCommand: Equatable {
        case open
        case restart

        var failureTitle: String {
            switch self {
            case .open: "Unable to Start the Coordinator"
            case .restart: "Unable to Restart the Coordinator"
            }
        }
    }

    /// Runs a person's command, and shows why when it did not work.
    func perform(
        _ command: UserCommand,
        windowID: UUID? = nil,
        presentFailure: @escaping @MainActor (String, String) -> Void = TaskActions.presentFailure
    ) {
        Task { @MainActor in
            do {
                switch command {
                case .open: try await open(windowID: windowID)
                case .restart: try await restart(windowID: windowID)
                }
            } catch {
                presentFailure(command.failureTitle, error.localizedDescription)
            }
        }
    }

    // MARK: - Policy

    /// Shows `policy.md` in the coordinator's workspace, in its right
    /// panel, so the chat stays in view; the user can read and edit it
    /// there. The workspace becomes the selected one, and a panel that
    /// already shows the file is used again. A missing policy is created
    /// first, as at a start.
    func openPolicy() throws {
        guard let location else {
            throw CoordinatorError("There is no coordinator. Open Coordinator first.")
        }
        let directory = try preparedDirectory()
        let path = URL(filePath: directory, directoryHint: .isDirectory)
            .appending(path: CoordinatorFolder.policyFileName, directoryHint: .notDirectory)
            .path
        _ = store.selectWorkspace(
            windowID: location.windowID,
            workspaceID: location.workspaceID,
            preferringUnreadSessionPanelIn: nil
        )
        guard store.createLocalDocumentPanel(
            workspaceID: location.workspaceID,
            request: LocalDocumentPanelCreateRequest(
                filePath: path,
                placementOverride: .rightPanel,
                formatOverride: .markdown
            )
        ) else {
            throw CoordinatorError("Toastty could not open \(path).")
        }
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
        // Toastty made this folder and wrote every file in it, so the agent
        // need not ask the user whether to trust it.
        await trustFolder(config.agent, directory)
        let terminal = try terminalForStart(location, directory: directory, replacingBusyTerminal: replacingBusyTerminal)
        let result: AgentLaunchResult
        do {
            result = try await TaskCoordinator.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                try await launcher.launchCoordinator(
                    profileID: config.agent,
                    workspaceID: location.workspaceID,
                    panelID: terminal.panelID,
                    cwd: directory,
                    // Also for a new terminal that is not the coordinator's
                    // yet, whose shell lacks it.
                    environment: CoordinatorFolder.gitEnvironment(for: folder.directoryURL),
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
    /// while no agent runs. One entry is typed for each open prompt.
    ///
    /// This is the one way into the coordinator for the chat's composer,
    /// quick entry, `coordinator send` and Toastty's own digests, so their
    /// text cannot interleave. It never types into a running turn: only the
    /// chat's composer steers, through `sendUserText`, and "Steer now"
    /// on a waiting message, through `steerQueuedEntry`.
    ///
    /// Pass `byUser: true` only when a person sent the message: it is then
    /// saved until it is typed, and waits across an app quit. `id` names
    /// the message for its sender; the conversation's echo of a typed
    /// message carries it.
    ///
    /// With `queueWhenHeld` off, text that cannot be typed now is not kept:
    /// the answer is `held`, and the caller sends its text again later. A
    /// caller that keeps its own durable copy uses this, so its text can
    /// change while it waits and is typed at most once. Such text never
    /// goes in front of entries that wait in the queue.
    @discardableResult
    func send(
        _ text: String,
        queueWhenHeld: Bool = true,
        byUser: Bool = false,
        id: String = UUID().uuidString
    ) throws -> SendResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw CoordinatorError("The message is empty.")
        }
        dropQueueOfAClosedCoordinator()
        guard let location else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        let entry = QueuedEntry(id: id, text: text, byUser: byUser)
        guard queueWhenHeld else {
            guard queuedEntries.isEmpty else { return .held(hold ?? .awaitingTurn) }
            switch typeAtOpenPrompt(entry, location: location, moment: now(), isSendersOwnCall: true) {
            case .typed(.delivered): return .sent
            case .typed: return .sentUnconfirmed
            case .held(let reason, _): return .held(reason)
            }
        }
        guard queuedEntries.count + pausedEntries.count < Self.maximumQueuedEntries else {
            throw CoordinatorError("The coordinator already has \(Self.maximumQueuedEntries) messages waiting.")
        }
        queuedEntries.append(entry)
        let waitingBefore = queuedEntries.count - 1
        switch drain(isSendersOwnCall: true) {
        case .delivered? where waitingBefore == 0:
            return .sent
        case .uncertain? where waitingBefore == 0:
            return .sentUnconfirmed
        default:
            return .queued(position: queuedEntries.count, hold: hold ?? .awaitingTurn)
        }
    }

    // MARK: - Steer

    /// Whether a message of the user's would go into the coordinator's
    /// running turn now: a turn runs in an agent that takes a steer (Claude
    /// Code or Codex), no question or permission waits for an answer, no
    /// text typed in the terminal touched the turn, the terminal takes
    /// input, no steer was refused in this turn, and no restart is under
    /// way.
    var canSteer: Bool {
        steerTarget(at: now()) != nil
    }

    /// The running turn a steer goes into.
    private struct SteerTarget {
        let subscription: any LocalConversationSubscription
        let session: SessionRecord
        let conversationID: RemoteConversationID
        let turnEpoch: RemoteInputEpoch
    }

    private func steerTarget(at moment: Date) -> SteerTarget? {
        // During a restart the running agent is about to end.
        guard isStarting == false,
              let session,
              session.status?.kind != .needsApproval,
              ProviderTranscriptSupport.isManagedProvider(session.agent),
              // The host checks the same before it types.
              promptState(session.panelID) != .unavailable,
              promptState(session.panelID) != .exited,
              let subscription = syncConversationSubscription(),
              let summary = subscription.snapshot(at: moment)?.summary,
              let control = summary.inputControl,
              // The host's own answer: a turn runs, the agent takes a
              // steer, and no local input touched the turn.
              control.canSteer,
              let turnEpoch = control.turnEpoch,
              turnEpoch != turnThatRefusedASteer else { return nil }
        if case .pendingInteraction = summary.inputAvailability { return nil }
        return SteerTarget(
            subscription: subscription,
            session: session,
            conversationID: summary.conversationID,
            turnEpoch: turnEpoch
        )
    }

    /// Sends the user's text from the chat's composer. With `steering`,
    /// the message goes into the coordinator's running turn when that turn
    /// can take it (`canSteer`), in front of anything that waits. Otherwise,
    /// and when the turn refuses the steer, it goes as `send(byUser: true)`
    /// sends it: typed at an open prompt, or queued and saved.
    @discardableResult
    func sendUserText(
        _ text: String,
        steering: Bool,
        id: String = UUID().uuidString
    ) throws -> SendResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if steering, text.isEmpty == false {
            switch steer(QueuedEntry(id: id, text: text, byUser: true)) {
            case .delivered?: return .steered
            case .uncertain?: return .steeredUnconfirmed
            case .unavailable?, nil: break
            }
        }
        return try send(text, byUser: true, id: id)
    }

    /// Types a waiting message of the user's into the running turn, for
    /// "Steer now" on its row. The message then leaves the queue and the
    /// saved file. When the turn cannot take it, it waits as before and
    /// this throws.
    func steerQueuedEntry(id: String) throws {
        guard let entry = (queuedEntries + pausedEntries).first(where: { $0.id == id }) else {
            throw CoordinatorError("The message was typed or removed already.")
        }
        guard entry.canBeSteered else {
            throw CoordinatorError("Only a message you wrote in the chat can go into the coordinator's turn. This one waits for the turn's end.")
        }
        guard steer(entry) != nil else {
            throw CoordinatorError("The coordinator's turn did not take the message. It still waits.")
        }
        queuedEntries.removeAll { $0.id == id }
        pausedEntries.removeAll { $0.id == id }
        typingEntryID = nil
        // Saves the queue without the message.
        drain()
    }

    /// Types the entry into the running turn through the conversation's
    /// steer path, under the turn the conversation shows now. A person
    /// asked for it now, so it is the user's input. Returns the delivery,
    /// or `nil` when nothing was typed.
    private func steer(_ entry: QueuedEntry) -> TerminalInputDeliveryResult? {
        // Also a quick entry message that Edit put back into the chat's
        // field keeps Toastty's first line, and waits.
        guard entry.canBeSteered else { return nil }
        let moment = now()
        guard let target = steerTarget(at: moment) else { return nil }
        // A saved entry: the file says that it is being typed, so a crash
        // in this moment cannot type it twice.
        guard noteTypingStarts(entry) else { return nil }
        let result = target.subscription.send(RemoteMessageSendRequest(
            conversationID: target.conversationID,
            clientRequestID: entry.id,
            expectedInputEpoch: target.turnEpoch,
            text: entry.text,
            deliveryMode: .steer
        ), byUser: true)
        switch result {
        case .accepted, .duplicate:
            noteTyped(entry, session: target.session, result: .delivered, throughConversation: true, steered: true)
            return .delivered
        case .uncertain:
            noteTyped(entry, session: target.session, result: .uncertain, throughConversation: true, steered: true)
            return .uncertain
        case .queued, .rejected:
            // The turn ended or changed between the snapshot and the send,
            // or the terminal did not take the text. The controls say Queue
            // for the rest of this turn, as the send does.
            noteTypingDidNotHappen()
            turnThatRefusedASteer = target.turnEpoch
            ToasttyLog.info("The coordinator's turn did not take a steer", category: .tasks, metadata: [
                "session_id": target.session.sessionID,
                "result": String(describing: result),
            ])
            return nil
        }
    }

    /// Stops the coordinator's running turn, as Escape in its terminal
    /// does. Entries that wait are set aside, so none starts a new turn
    /// right after the stop: they wait until `resumeQueue`.
    func stopTurn() throws {
        guard let subscription = syncConversationSubscription() else {
            throw CoordinatorError("The coordinator has no turn to stop.")
        }
        guard let summary = subscription.snapshot(at: now())?.summary,
              let turnEpoch = summary.inputControl?.turnEpoch else {
            throw CoordinatorError("The coordinator is not working on a turn.")
        }
        switch subscription.interrupt(RemoteConversationInterruptRequest(
            conversationID: summary.conversationID,
            expectedTurnEpoch: turnEpoch
        )) {
        case .accepted:
            ToasttyLog.info("Stopped the coordinator's turn", category: .tasks, metadata: [
                "set_aside": String(queuedEntries.count),
            ])
            pausedEntries.append(contentsOf: queuedEntries)
            queuedEntries.removeAll()
            drain()
        case .rejected(let reason):
            throw CoordinatorError("Toastty could not stop the coordinator's turn (\(reason.rawValue)).")
        }
    }

    /// Lets the entries that a stop set aside go again, before any entry
    /// that came later.
    func resumeQueue() {
        guard pausedEntries.isEmpty == false else { return }
        // The user sends an interrupted entry again: it is typed as any
        // other.
        queuedEntries.insert(contentsOf: pausedEntries.map { entry in
            var entry = entry
            entry.typingWasInterrupted = false
            return entry
        }, at: 0)
        pausedEntries.removeAll()
        drain()
    }

    /// Takes a waiting entry out of the queue. Returns it, or `nil` when it
    /// was typed or removed already. With `discardingAttachments`, the
    /// files attached to it go too: the message will not be sent. Without
    /// it they stay, for a caller that sends the entry's text again.
    @discardableResult
    func removeQueuedEntry(id: String, discardingAttachments: Bool = false) -> QueuedEntry? {
        let removed: QueuedEntry
        if let index = queuedEntries.firstIndex(where: { $0.id == id }) {
            removed = queuedEntries.remove(at: index)
        } else if let index = pausedEntries.firstIndex(where: { $0.id == id }) {
            removed = pausedEntries.remove(at: index)
        } else {
            return nil
        }
        if discardingAttachments {
            attachments.discard(messageID: removed.id, text: removed.text)
        }
        drain()
        return removed
    }

    /// Reopens a prompt that text typed in the coordinator's terminal holds
    /// closed. Call it only after the user said that the agent's prompt
    /// holds none of their text: the next entry is then typed there.
    /// Returns whether the prompt reopened.
    @discardableResult
    func releaseUserDraft() -> Bool {
        guard let subscription = syncConversationSubscription() else { return false }
        guard let summary = subscription.snapshot(at: now())?.summary,
              case .localDraft(let draftEpoch) = summary.inputAvailability else { return false }
        let result = subscription.releaseLocalDraft(RemoteConversationLocalDraftReleaseRequest(
            conversationID: summary.conversationID,
            expectedDraftEpoch: draftEpoch
        ))
        guard result == .released else { return false }
        drain()
        return true
    }

    /// The agent's conversation shows an open prompt now.
    var promptIsOpenForTesting: Bool {
        syncConversationSubscription()?.snapshot(at: now())?.summary.inputAvailability.allowsRemoteSend == true
    }

    /// The message was typed by this controller in this run of the app.
    func didType(messageID: String) -> Bool {
        typedMessageIDs.contains(messageID)
    }

    /// Types the first queued entry when the prompt is open. Returns that
    /// delivery's result, or `nil` when nothing was typed.
    @discardableResult
    private func drain(isSendersOwnCall: Bool = false) -> TerminalInputDeliveryResult? {
        recheckTask?.cancel()
        recheckTask = nil
        dropQueueOfAClosedCoordinator()
        defer {
            let waiting = queuedEntries.count + pausedEntries.count
            if queuedCount != waiting { queuedCount = waiting }
            saveQueue()
        }
        guard let location, let entry = queuedEntries.first else {
            setHold(nil)
            return nil
        }
        let moment = now()
        // Only the entry its sender just gave is typed in the sender's own
        // call. Any other entry was queued earlier.
        let isSendersOwnCall = isSendersOwnCall && queuedEntries.count == 1
        switch typeAtOpenPrompt(entry, location: location, moment: moment, isSendersOwnCall: isSendersOwnCall) {
        case .held(let reason, let recheckAt):
            setHold(reason)
            if let recheckAt { scheduleRecheck(at: recheckAt, from: moment) }
            return nil
        case .typed(let result):
            queuedEntries.removeFirst()
            typingEntryID = nil
            if queuedEntries.isEmpty {
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

    /// The one place that types into the coordinator: it types the entry
    /// when the agent's prompt is open, and says why not otherwise.
    ///
    /// An agent whose conversation Toastty reads gets the text through
    /// that conversation's send path. That path also serves a paired
    /// phone, so one check of the prompt covers every sender, and each
    /// open prompt is used once. Any other agent gets the text through
    /// `CoordinatorSendGate`, which rests on the session's reported status.
    private func typeAtOpenPrompt(
        _ entry: QueuedEntry,
        location: CoordinatorLocation,
        moment: Date,
        isSendersOwnCall: Bool
    ) -> TypingOutcome {
        // During a restart the agent that still runs is about to end with
        // its terminal: text typed there would be lost. The start drains
        // the queue when it ends.
        guard isStarting == false else {
            return .held(.agentStarting, recheckAt: nil)
        }
        if let session, ProviderTranscriptSupport.isManagedProvider(session.agent),
           let subscription = syncConversationSubscription() {
            return typeThroughConversation(
                entry,
                subscription: subscription,
                session: session,
                moment: moment,
                // A queued entry was the user's action when it was queued,
                // not now that Toastty types it.
                byUser: entry.byUser && isSendersOwnCall
            )
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
        guard noteTypingStarts(entry) else {
            return .held(.notSaved, recheckAt: moment.addingTimeInterval(Self.saveRetryInterval))
        }
        let result = deliverText(entry.text, panelID)
        switch result {
        case .unavailable:
            noteTypingDidNotHappen()
            return .held(.terminalUnavailable, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
        case .delivered, .uncertain:
            lastDelivery = CoordinatorPromptFacts.Delivery(
                sessionID: session.sessionID,
                at: moment,
                submitConfirmed: result == .delivered
            )
            noteTyped(entry, session: session, result: result, throughConversation: false)
            return .typed(result)
        }
    }

    /// Types the entry through the conversation's send path, under the
    /// prompt epoch the conversation shows now.
    private func typeThroughConversation(
        _ entry: QueuedEntry,
        subscription: any LocalConversationSubscription,
        session: SessionRecord,
        moment: Date,
        byUser: Bool
    ) -> TypingOutcome {
        guard let summary = subscription.snapshot(at: moment)?.summary else {
            // Toastty does not know the agent's conversation yet. Its first
            // report does not always change the session.
            return .held(.agentStarting, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
        }
        let epoch: RemoteInputEpoch
        switch summary.inputAvailability {
        case .openPrompt(let openEpoch):
            epoch = openEpoch
        case .localDraft:
            return .held(.userDraft, recheckAt: nil)
        case .pendingInteraction:
            return .held(.busy, recheckAt: nil)
        case .unavailable(let reason):
            // Toastty made this conversation when it launched the agent.
            // Until the agent reports its session, the prompt is closed
            // because the agent is not up, not because of its state.
            return .held(summary.state == .starting ? .agentStarting : Self.hold(for: reason), recheckAt: nil)
        }
        guard noteTypingStarts(entry) else {
            return .held(.notSaved, recheckAt: moment.addingTimeInterval(Self.saveRetryInterval))
        }
        let result = subscription.send(RemoteMessageSendRequest(
            conversationID: summary.conversationID,
            clientRequestID: entry.id,
            expectedInputEpoch: epoch,
            text: entry.text
        ), byUser: byUser)
        switch result {
        case .accepted, .duplicate:
            noteTyped(entry, session: session, result: .delivered, throughConversation: true)
            return .typed(.delivered)
        case .uncertain:
            noteTyped(entry, session: session, result: .uncertain, throughConversation: true)
            return .typed(.uncertain)
        case .queued:
            // Not reached: the request asks for the open prompt.
            noteTypingDidNotHappen()
            return .held(.busy, recheckAt: nil)
        case .rejected(let reason):
            noteTypingDidNotHappen()
            switch reason {
            case .localDraftPresent:
                return .held(.userDraft, recheckAt: nil)
            case .pendingInteraction:
                return .held(.busy, recheckAt: nil)
            case .surfaceUnavailable:
                return .held(.terminalUnavailable, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
            case .notBound:
                return .held(.agentStarting, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
            default:
                // The prompt changed between the snapshot and the send. The
                // conversation reports its next state.
                return .held(.promptNotOpen, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
            }
        }
    }

    private static func hold(for reason: RemoteInputUnavailableReason) -> CoordinatorSendHold {
        switch reason {
        case .starting:
            .agentStarting
        case .working:
            .busy
        case .surfaceUnavailable:
            .terminalUnavailable
        case .ended, .offline:
            .noSession
        case .interrupted, .error, .sessionWritesDisabled, .unknownProviderState:
            .promptNotOpen
        }
    }

    private func noteTyped(
        _ entry: QueuedEntry,
        session: SessionRecord,
        result: TerminalInputDeliveryResult,
        throughConversation: Bool,
        steered: Bool = false
    ) {
        typedMessageIDs.append(entry.id)
        if typedMessageIDs.count > Self.rememberedTypedMessages {
            typedMessageIDs.removeFirst(typedMessageIDs.count - Self.rememberedTypedMessages)
        }
        ToasttyLog.info("Typed a message into the coordinator", category: .tasks, metadata: [
            "session_id": session.sessionID,
            "submit_confirmed": result == .delivered ? "true" : "false",
            "path": throughConversation ? "conversation" : "status_gate",
            "mode": steered ? "steer" : "prompt",
            "by_user": entry.byUser ? "true" : "false",
            "queue_depth": String(max(0, queuedEntries.count - 1)),
        ])
        typedEntries.send(TypedEntry(
            id: entry.id, text: entry.text, echoesInConversation: throughConversation, steered: steered
        ))
    }

    private func dropQueueOfAClosedCoordinator() {
        let workspaceID = location?.workspaceID
        guard workspaceID != queueWorkspaceID else { return }
        // Their coordinator is gone, and with it the reason to keep the
        // files of the messages that waited for it.
        for entry in queuedEntries + pausedEntries {
            attachments.discard(messageID: entry.id, text: entry.text)
        }
        queuedEntries.removeAll()
        pausedEntries.removeAll()
        typingEntryID = nil
        lastDelivery = nil
        queueWorkspaceID = workspaceID
        saveQueue()
    }

    // MARK: - The saved queue

    /// Puts back the user's messages that waited when Toastty quit. They
    /// belong to the coordinator's workspace that they were sent to: a
    /// queue saved for another one is dropped with its files.
    private func restoreQueue() {
        guard let queueFileURL, let snapshot = CoordinatorQueueSnapshot.load(from: queueFileURL) else { return }
        guard let workspaceID = location?.workspaceID, snapshot.workspaceID == workspaceID else {
            for entry in snapshot.queued + snapshot.paused {
                attachments.discard(messageID: entry.id, text: entry.text)
            }
            try? CoordinatorQueueSnapshot.remove(at: queueFileURL)
            ToasttyLog.info("Dropped saved messages of a coordinator that is gone", category: .tasks, metadata: [
                "count": String(snapshot.queued.count + snapshot.paused.count),
            ])
            return
        }
        var queued = snapshot.queued.map { QueuedEntry(id: $0.id, text: $0.text, byUser: true) }
        var paused = snapshot.paused.map {
            QueuedEntry(id: $0.id, text: $0.text, byUser: true, typingWasInterrupted: $0.typingWasInterrupted ?? false)
        }
        // Toastty quit after it started to type this entry and before it
        // saved that the entry was typed. Whether the coordinator has it is
        // not known, so it is not typed again without the user.
        if let typingEntryID = snapshot.typingEntryID {
            if let index = queued.firstIndex(where: { $0.id == typingEntryID }) {
                var interrupted = queued.remove(at: index)
                interrupted.typingWasInterrupted = true
                paused.insert(interrupted, at: 0)
            } else if let index = paused.firstIndex(where: { $0.id == typingEntryID }) {
                // A paused entry that "Steer now" was typing.
                paused[index].typingWasInterrupted = true
            }
        }
        queueWorkspaceID = workspaceID
        queuedEntries = queued
        pausedEntries = paused
        queuedCount = queued.count + paused.count
        savedQueue = snapshot
        saveQueue()
        ToasttyLog.info("Restored the messages that waited for the coordinator", category: .tasks, metadata: [
            "queued": String(queued.count),
            "paused": String(paused.count),
        ])
    }

    /// How long a message whose typing could not be saved waits before
    /// Toastty tries again.
    static let saveRetryInterval: TimeInterval = 5

    /// Writes the user's waiting messages when they changed. Every change
    /// of the queue ends here, so the file is the queue at each moment
    /// that Toastty can quit. Returns whether the file now holds the queue.
    @discardableResult
    private func saveQueue() -> Bool {
        guard let queueFileURL else { return true }
        let snapshot = queueSnapshot()
        guard snapshot != savedQueue else { return true }
        do {
            if let snapshot {
                try snapshot.save(to: queueFileURL)
            } else {
                try CoordinatorQueueSnapshot.remove(at: queueFileURL)
            }
            savedQueue = snapshot
            return true
        } catch {
            // `savedQueue` stays as it was, so the next change writes again.
            ToasttyLog.warning("Could not save the messages that wait for the coordinator", category: .tasks, metadata: [
                "path": queueFileURL.path, "error": error.localizedDescription,
            ])
            return false
        }
    }

    private func queueSnapshot() -> CoordinatorQueueSnapshot? {
        guard let workspaceID = queueWorkspaceID else { return nil }
        let queued = queuedEntries.filter(\.byUser)
        let paused = pausedEntries.filter(\.byUser)
        guard queued.isEmpty == false || paused.isEmpty == false else { return nil }
        return CoordinatorQueueSnapshot(
            workspaceID: workspaceID,
            queued: queued.map { .init(id: $0.id, text: $0.text) },
            paused: paused.map {
                .init(id: $0.id, text: $0.text, typingWasInterrupted: $0.typingWasInterrupted ? true : nil)
            },
            typingEntryID: typingEntryID
        )
    }

    /// Saves that a saved entry is being typed, before its text goes to
    /// the terminal. Returns `false` when the entry must not be typed now:
    /// the file lists it as waiting and could not be changed, so a
    /// relaunch would type it again. An entry that the file never held can
    /// be typed, since no relaunch knows of it. The entry is the first
    /// queued one, or for a steer any waiting one.
    private func noteTypingStarts(_ entry: QueuedEntry) -> Bool {
        guard entry.byUser, queueFileURL != nil,
              (queuedEntries + pausedEntries).contains(where: { $0.id == entry.id }) else { return true }
        typingEntryID = entry.id
        if saveQueue() { return true }
        typingEntryID = nil
        let savedIDs = (savedQueue?.queued ?? []) + (savedQueue?.paused ?? [])
        return savedIDs.contains { $0.id == entry.id } == false
    }

    /// The terminal did not take the text: the entry waits as before.
    private func noteTypingDidNotHappen() {
        guard typingEntryID != nil else { return }
        typingEntryID = nil
        saveQueue()
    }

    /// Whether an entry waits whose typing a quit interrupted.
    var hasInterruptedEntry: Bool {
        pausedEntries.contains(where: \.typingWasInterrupted)
    }

    // MARK: - The conversation the controller sends through

    /// Holds one subscription to the conversation in the coordinator's
    /// terminal for as long as that terminal exists, and returns it.
    ///
    /// Toastty must read the conversation the whole time, not only when a
    /// message waits. What decides whether the prompt is open is seen only
    /// while it happens: text the user types in the terminal, and the use
    /// of a prompt by a message. A reader that starts later would take a
    /// prompt with the user's draft in it, or a prompt just used, for an
    /// open one.
    @discardableResult
    private func syncConversationSubscription() -> (any LocalConversationSubscription)? {
        let panelID = conversationAccess == nil ? nil : location?.panelID
        if conversationSubscription?.panelID == panelID {
            return conversationSubscription
        }
        conversationObserver?.cancel()
        conversationObserver = nil
        conversationSubscription?.cancel()
        conversationSubscription = nil
        guard let panelID, let conversationAccess else { return nil }
        let subscription = conversationAccess.subscribeToConversation(inPanel: panelID)
        let changes = subscription.changes
        conversationSubscription = subscription
        // A change can open the prompt for the next queued entry.
        conversationObserver = Task { @MainActor [weak self] in
            for await _ in changes {
                self?.drain()
            }
        }
        return subscription
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
