import AppKit
import Combine
import CoreState
import Foundation
import RemoteProtocol

/// The part of the agent launcher the coordinator uses. A protocol so tests
/// can start the coordinator without terminals.
@MainActor
protocol CoordinatorAgentLaunching: AnyObject {
    /// Launches into the given terminal without moving focus and with no
    /// first message. A Codex agent reads all of the coordinator's
    /// instructions (`CoordinatorFolder.codexProjectDocMaxBytes`).
    func launchCoordinator(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        environment: [String: String],
        model: String?,
        reasoningEffort: String?
    ) async throws -> AgentLaunchResult

    /// What the profile would run, resolved as a launch resolves it,
    /// without launching anything. Throws when no profile has the ID.
    func profileExecutableState(profileID: String) throws -> AgentProfileExecutableState

    /// The argv of a Codex profile whose arguments cannot take the raised
    /// `project_doc_max_bytes` that the coordinator's start and resume
    /// add. `nil` when they can, or when the profile is not Codex's.
    func codexArgvLackingProjectDocMaxBytes(profileID: String) -> [String]?
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
            focusPolicy: .preserveFirstResponder,
            codexProjectDocMaxBytes: CoordinatorFolder.codexProjectDocMaxBytes
        )
    }
}

struct CoordinatorError: LocalizedError, Equatable {
    let message: String
    /// An installed agent that can start the coordinator in place of a
    /// configured one that is not installed.
    let alternativeAgent: CoordinatorAgentChoice?

    init(_ message: String, alternativeAgent: CoordinatorAgentChoice? = nil) {
        self.message = message
        self.alternativeAgent = alternativeAgent
    }

    var errorDescription: String? { message }
}

/// An installed agent profile that a person can choose to start the
/// coordinator with, in place of the configured one.
struct CoordinatorAgentChoice: Equatable {
    var profileID: String
    var displayName: String
    /// The configured profile that is not installed.
    var configuredProfileID: String
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
    /// For one session of the coordinator, checked as it starts or
    /// resumes: the argv of its Codex profile when that argv could not take
    /// the raised `project_doc_max_bytes`.
    @Published private var instructionsLimitCheck: (sessionID: String, argvLackingLimit: [String]?)?
    /// The profile argv whose notice the user chose not to see again: the
    /// limit may be set in the helper it runs or in Codex's config.
    @Published private var instructionsNoticeHiddenArgv: [String]?
    private let defaults: UserDefaults?
    static let instructionsNoticeHiddenArgvKey = "toastty.coordinator.instructionsNoticeHiddenArgv"
    /// The agent session that Toastty last started for the coordinator in
    /// this run. Its conversation is new, unlike one that a relaunch
    /// resumes.
    @Published private(set) var startedSessionID: String?
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
    /// Where the coordinator's workspace and terminal are saved, or `nil`
    /// to save nothing; see `CoordinatorWorkspaceRecord`.
    private let workspaceFileURL: URL?
    /// What the file at `workspaceFileURL` holds.
    private var savedWorkspaceRecord: CoordinatorWorkspaceRecord?
    private let configLoader: () throws -> TasksConfig
    /// Tells the agent of the given profile that the coordinator's folder
    /// is trusted, before that agent starts there. See `ClaudeFolderTrust`.
    private let trustFolder: @MainActor (_ profileID: String, _ directory: String) async -> Void
    private let deliverText: (String, UUID) -> TerminalInputDeliveryResult
    private let promptState: (UUID) -> TerminalPromptState
    private let managedAgentRestoreState: (UUID) -> TerminalManagedAgentRestoreState
    /// Scrolls a local-document panel to a line, from 1. See
    /// `WebPanelRuntimeRegistry.requestLocalDocumentReveal`.
    private let revealDocumentLine: (UUID, Int) -> Bool
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
        /// The folders of attached files that the message owns, by name
        /// (`CoordinatorAttachments`): its own, and the folders of the
        /// copies that it carried over from an Edit. Remove deletes these
        /// and no other. Its text never adds a folder: a list of files in
        /// it can name the folder of another message.
        let attachmentFolders: [String]

        init(
            id: String,
            text: String,
            byUser: Bool,
            typingWasInterrupted: Bool = false,
            attachmentFolders: [String]? = nil
        ) {
            self.id = id
            self.text = text
            self.byUser = byUser
            self.typingWasInterrupted = typingWasInterrupted
            var folders = [id]
            for folder in attachmentFolders ?? [] where folders.contains(folder) == false {
                folders.append(folder)
            }
            self.attachmentFolders = folders
        }

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
    /// Names the newest Stop of the coordinator's turn, from any app, or
    /// the set-aside entries that a relaunch restored. Each changes it. A
    /// paired device's Resume presents the token it read, so a Resume that
    /// comes late cannot let go what a later Stop holds
    /// (`RemoteAccessService`). `nil` before the first.
    @Published private(set) var heldSetToken: String?
    /// Each message as it is typed, for a view that shows it until the
    /// agent's conversation does.
    let typedEntries = PassthroughSubject<TypedEntry, Never>()

    /// What the coordinator's chat shows. Set once the app has the
    /// conversation access the chat reads through.
    var chat: CoordinatorChatModel?
    /// The newest row of the coordinator's chat that the user read, on this
    /// Mac or on a paired device. The chat and Remote Access share it.
    let chatReadThrough: CoordinatorChatReadThrough

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
            if newValue {
                terminalKeyLog.start()
            } else {
                terminalKeyLog.stop()
            }
            logKeyboardOwnerAfterPanelChange()
        }
    }

    /// The record of the key presses that follow Show Terminal.
    private let terminalKeyLog = CoordinatorTerminalKeyLog()
    private var keyboardOwnerLog: Task<Void, Never>?

    /// Says in the log which view has the keyboard once the panel's change
    /// has settled. Show Terminal tries for about 0.2 seconds to give the
    /// terminal the keyboard, and says nothing when that does not work.
    private func logKeyboardOwnerAfterPanelChange() {
        keyboardOwnerLog?.cancel()
        keyboardOwnerLog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, Task.isCancelled == false else { return }
            var metadata = self.terminalLogFacts()
            metadata["keyboard_owner"] = self.terminalKeyLog.keyboardOwner()
            metadata["app_active"] = NSApp.isActive ? "true" : "false"
            ToasttyLog.info("The keyboard's owner after the coordinator's panel changed", category: .tasks, metadata: metadata)
        }
    }

    /// The coordinator's state that explains a key press or a hold in the log.
    private func terminalLogFacts() -> [String: String] {
        var facts = [
            "shows": showsTerminal ? "terminal" : "chat",
            "hold": hold?.rawValue ?? "none",
            "queued": String(queuedCount),
        ]
        if let summary = conversationSubscription?.snapshot(at: now())?.summary {
            facts["input"] = switch summary.inputAvailability {
            case .openPrompt: "open_prompt"
            case .localDraft: "local_draft"
            case .pendingInteraction(let ids): "pending_interaction:\(ids.count)"
            case .unavailable(let reason): "unavailable:\(reason.rawValue)"
            }
        }
        if let session, session.agent == .claude, let terminals {
            facts["claude_dialog"] = terminals.claudeDialogPlaceForLog(panelID: session.panelID)
        }
        return facts
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

    /// The app's terminals, which give the coordinator's terminal the
    /// keyboard. Set by `connectKeyboard(to:)`.
    private weak var terminals: TerminalRuntimeRegistry?
    // Workspace and window changes can schedule an automatic focus restore
    // during the switch. Keep the user's explicit request independent of it.
    private let showTerminalFocus = TerminalFocusCoordinator()

    /// Connects the keyboard of the chat and the terminal under it:
    /// keyboard focus meant for the covered terminal goes to the chat's
    /// field, and Show Terminal gives the terminal the keyboard.
    func connectKeyboard(to terminals: TerminalRuntimeRegistry) {
        self.terminals = terminals
        terminals.coveringInputFocus = { [weak self] panelID in
            guard let self, self.coversTerminal(panelID: panelID) else { return nil }
            return { [weak self] in self?.chat?.focusComposer() ?? false }
        }
        terminals.keyPressObserver = { [weak self] panelID, press in
            guard let self, self.location?.panelID == panelID else { return }
            self.terminalKeyLog.record(press)
        }
        terminalKeyLog.isCoordinatorTerminal = { [weak self, weak terminals] responder in
            guard let panelID = self?.location?.panelID else { return false }
            return terminals?.isKeyboardFocusTarget(responder, panelID: panelID) ?? false
        }
        terminalKeyLog.terminalWindow = { [weak self, weak terminals] in
            guard let panelID = self?.location?.panelID else { return nil }
            return terminals?.terminalWindow(panelID: panelID)
        }
        terminalKeyLog.context = { [weak self] in self?.terminalLogFacts() ?? [:] }
    }

    /// Show Terminal, in the chat's notice or in the panel's header: give
    /// the keyboard to the terminal as soon as its AppKit view is ready.
    func showTerminal() {
        showsTerminal = true
        guard let location, let panelID = location.panelID else { return }
        // policy.md beside it can have the focus.
        _ = store.send(.focusPanel(workspaceID: location.workspaceID, panelID: panelID))
        showTerminalFocus.scheduleFocusRestore(avoidStealingKeyboardFocus: false) { [weak self] in
            guard let self, self.showsTerminal, self.location == location,
                  self.store.state.selectedWindowID == location.windowID,
                  let workspace = self.store.selectedWorkspace(in: location.windowID),
                  workspace.id == location.workspaceID, workspace.focusedPanelID == panelID,
                  let terminals = self.terminals else { return true }
            return terminals.focusVisibleTerminalIfPossible(panelID: panelID)
        }
    }

    /// A composer focus request can run after the chat starts leaving.
    func presentsComposer(at host: CoordinatorChatModel.Host, panelID: UUID) -> Bool {
        guard let location, location.panelID == panelID,
              let window = store.window(id: location.windowID) else { return false }
        switch host {
        case .dock:
            return dockShows(in: location.windowID)
        case .panel:
            return coversTerminal(panelID: panelID) && !window.showsTasksView &&
                store.selectedWorkspace(in: window.id)?.focusedPanelID == panelID &&
                window.selectedWorkspaceID == location.workspaceID
        }
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

    /// The workspace the coordinator's window showed before the full view
    /// opened, so that the dock can go back to it.
    private var workspaceBeforeFullView: UUID?

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
        workspaceFileURL: URL? = nil,
        configLoader: @escaping () throws -> TasksConfig,
        trustFolder: @escaping @MainActor (_ profileID: String, _ directory: String) async -> Void = { _, _ in },
        deliverText: @escaping (String, UUID) -> TerminalInputDeliveryResult,
        promptState: @escaping (UUID) -> TerminalPromptState,
        managedAgentRestoreState: @escaping (UUID) -> TerminalManagedAgentRestoreState = { _ in .inactive },
        revealDocumentLine: @escaping (UUID, Int) -> Bool = { _, _ in false },
        terminalReadinessTimeout: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults? = nil
    ) {
        chatReadThrough = CoordinatorChatReadThrough(defaults: defaults)
        self.defaults = defaults
        instructionsNoticeHiddenArgv = defaults?.stringArray(forKey: Self.instructionsNoticeHiddenArgvKey)
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.launcher = launcher
        self.folder = folder ?? CoordinatorFolder(directoryURL: directoryURL)
        self.attachments = CoordinatorAttachments(coordinatorDirectoryURL: directoryURL)
        self.queueFileURL = queueFileURL
        self.workspaceFileURL = workspaceFileURL
        self.configLoader = configLoader
        self.trustFolder = trustFolder
        self.deliverText = deliverText
        self.promptState = promptState
        self.managedAgentRestoreState = managedAgentRestoreState
        self.revealDocumentLine = revealDocumentLine
        self.terminalReadinessTimeout = terminalReadinessTimeout
        self.now = now
        // First, so that a coordinator whose mark the layout lost comes
        // back as one the layout restored.
        restoreWorkspaceMark()
        // A session that starts, ends a turn or stops can open the prompt
        // for the next queued entry. `sink` runs before the new value is
        // stored, so the queue is looked at on the next main-actor turn.
        // The end of a turn is found in the new value at once: each change
        // of the session store comes here on its own, also a failed turn
        // that a new turn follows at once.
        sessionObserver = sessionRuntimeStore.$sessionRegistry
            .sink { [weak self] registry in
                MainActor.assumeIsolated {
                    self?.noteTurnEnd(in: registry)
                    self?.checkInstructionsLimit(in: registry)
                }
                Task { @MainActor [weak self] in self?.drain() }
            }
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, previousState, nextState in
            // The full view opened: the dock's way out of it goes back to
            // the workspace the user came from.
            if let coordinator = nextState.coordinator,
               nextState.selectedWorkspaceID(in: coordinator.windowID) == coordinator.workspaceID,
               let previousWorkspaceID = previousState.selectedWorkspaceID(in: coordinator.windowID),
               previousWorkspaceID != coordinator.workspaceID {
                self?.workspaceBeforeFullView = previousWorkspaceID
            }
            if previousState.coordinator != nextState.coordinator {
                self?.syncConversationSubscription()
                self?.saveWorkspaceRecord()
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
        // A waiting message keeps the folders it owns: after an edit in
        // the chat, its files are under the ID of the message it was. It
        // also keeps each folder its text names, so the files are there
        // when it is typed; a name in a text only keeps a folder, and never
        // removes one.
        self.attachments.removeExpired(
            waitingMessageIDs: (queuedEntries + pausedEntries).reduce(into: Set<String>()) { ids, entry in
                ids.formUnion(entry.attachmentFolders)
                ids.formUnion(self.attachments.messageIDs(namedIn: entry.text))
            },
            now: now()
        )
        refreshFolderOfARestoredCoordinator()
        saveWorkspaceRecord()
    }

    /// Puts the coordinator's mark back on its workspace when the layout has
    /// none: a Toastty that does not know the coordinator, such as v0.9.2,
    /// saved the layout last. The reducer checks that the saved workspace
    /// can still hold the mark.
    private func restoreWorkspaceMark() {
        guard let workspaceFileURL else { return }
        savedWorkspaceRecord = CoordinatorWorkspaceRecord.load(from: workspaceFileURL)
        guard store.state.coordinator == nil, let saved = savedWorkspaceRecord,
              store.send(.restoreCoordinatorWorkspace(workspaceID: saved.workspaceID, panelID: saved.panelID)) else { return }
        ToasttyLog.warning("Restored the coordinator's mark, which the saved layout had lost", category: .tasks, metadata: [
            "workspace_id": saved.workspaceID.uuidString,
            "panel_id": store.state.coordinator?.panelID?.uuidString ?? "",
        ])
    }

    /// Saves where the coordinator lives now, or removes the file when
    /// there is no coordinator.
    private func saveWorkspaceRecord() {
        guard let workspaceFileURL else { return }
        let record = location.map { CoordinatorWorkspaceRecord(workspaceID: $0.workspaceID, panelID: $0.panelID) }
        guard record != savedWorkspaceRecord else { return }
        do {
            if let record {
                try record.save(to: workspaceFileURL)
            } else {
                try CoordinatorWorkspaceRecord.remove(at: workspaceFileURL)
            }
            savedWorkspaceRecord = record
        } catch {
            ToasttyLog.warning("Could not save where the coordinator lives", category: .tasks, metadata: [
                "path": workspaceFileURL.path, "error": error.localizedDescription,
            ])
        }
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

    /// The running Codex coordinator may read only Codex's default share
    /// of its instructions: its profile's arguments could not take the
    /// raised `project_doc_max_bytes` (`CoordinatorFolder.codexProjectDocMaxBytes`).
    /// False for that argv once the user chose not to see this again.
    var mayReadPartOfItsInstructions: Bool {
        guard let session, let check = instructionsLimitCheck, check.sessionID == session.sessionID,
              let argv = check.argvLackingLimit else { return false }
        return argv != instructionsNoticeHiddenArgv
    }

    /// Hides the notice for the current profile argv, also after a
    /// relaunch. A profile with another argv is checked again.
    func hideInstructionsNotice() {
        guard let argv = instructionsLimitCheck?.argvLackingLimit else { return }
        instructionsNoticeHiddenArgv = argv
        defaults?.set(argv, forKey: Self.instructionsNoticeHiddenArgvKey)
    }

    /// Checks a session of the coordinator once, as it starts or resumes,
    /// so the result is the profile that the launch used, not one that the
    /// user edits later.
    private func checkInstructionsLimit(in registry: SessionRegistry) {
        guard let panelID = location?.panelID, let record = registry.activeSession(for: panelID),
              instructionsLimitCheck?.sessionID != record.sessionID else { return }
        let argv = record.agent == .codex
            ? launcher?.codexArgvLackingProjectDocMaxBytes(profileID: record.agent.rawValue)
            : nil
        instructionsLimitCheck = (record.sessionID, argv)
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

    /// The terminal registry owns the restore from before surface creation
    /// through command handoff. Its shell can show a prompt during that time.
    private func awaitsRestore(_ location: CoordinatorLocation) -> Bool {
        guard let panelID = location.panelID else { return false }
        return managedAgentRestoreState(panelID) == .pending
    }

    /// The coordinator's agent conversation is new, so it has no history:
    /// Toastty starts its agent or started it in this run, or no agent runs
    /// and the terminal has no conversation saved to resume. A conversation
    /// that a relaunch resumes is not new.
    var hasNewConversation: Bool {
        guard let location else { return false }
        guard let session else {
            return isStarting || hasSavedConversation(location) == false
        }
        // While Toastty starts it, the session may show before the start
        // returns its ID.
        return session.sessionID == startedSessionID || isStarting
    }

    /// The terminal has an agent conversation that Toastty saved to resume.
    private func hasSavedConversation(_ location: CoordinatorLocation) -> Bool {
        guard let panelID = location.panelID,
              case .terminal(let terminal)? = store.state.workspacesByID[location.workspaceID]?.panelState(for: panelID)
        else { return false }
        return terminal.resumeRecord != nil
    }

    /// Notes the agent session that Toastty started, whose conversation is
    /// new.
    func noteStartedSession(_ sessionID: String) {
        startedSessionID = sessionID
    }

    // MARK: - The dock

    /// The chat can show, in the full view or in the dock.
    var chatIsAvailable: Bool {
        supportsChat && chat != nil
    }

    /// Whether the dock shows in `windowID` now.
    func dockShows(in windowID: UUID) -> Bool {
        guard let window = store.window(id: windowID) else { return false }
        return CoordinatorDockPresentation.showsDock(window: window, coordinator: location, chatAvailable: chatIsAvailable)
    }

    /// Opens the dock in the coordinator's window. From the full view, the
    /// window goes back to the workspace it showed before, or else to the
    /// first workspace in the sidebar. `focusComposer` gives the dock's
    /// field the keyboard. Returns whether the dock shows.
    @discardableResult
    func showDock(focusComposer: Bool) -> Bool {
        guard chatIsAvailable, let location, let window = store.window(id: location.windowID) else { return false }
        if window.selectedWorkspaceID == location.workspaceID {
            guard let workspaceID = CoordinatorDockPresentation.workspaceLeavingFullView(
                state: store.state,
                coordinator: location,
                previousWorkspaceID: workspaceBeforeFullView
            ) else { return false }
            _ = store.send(.setCoordinatorDockVisible(windowID: location.windowID, visible: true))
            _ = store.selectWorkspace(
                windowID: location.windowID,
                workspaceID: workspaceID,
                preferringUnreadSessionPanelIn: sessionRuntimeStore
            )
        } else {
            _ = store.send(.setCoordinatorDockVisible(windowID: location.windowID, visible: true))
        }
        if focusComposer {
            chat?.requestComposerFocus(host: .dock)
        }
        ToasttyLog.info("Showed the coordinator's dock", category: .tasks)
        return dockShows(in: location.windowID)
    }

    /// The dock's field has the keyboard in `windowID`.
    func dockHasKeyboard(in windowID: UUID) -> Bool {
        dockShows(in: windowID) && chat?.composerHasKeyboard(host: .dock) == true
    }

    /// Gives the dock's field the keyboard, when the dock shows in
    /// `windowID`. Returns whether the dock shows.
    func focusDockComposer(in windowID: UUID) -> Bool {
        guard dockShows(in: windowID), let chat else { return false }
        chat.requestComposerFocus(host: .dock)
        return true
    }

    func hideDock() {
        guard let location else { return }
        _ = store.send(.setCoordinatorDockVisible(windowID: location.windowID, visible: false))
    }

    /// The dock's toolbar button and sidebar row: hides a dock that shows,
    /// and otherwise shows it with the keyboard in its field.
    func toggleDock() {
        guard let location else { return }
        if dockShows(in: location.windowID) {
            hideDock()
        } else {
            showDock(focusComposer: true)
        }
    }

    /// What Cmd+Shift+K does now, in the coordinator's window. `nil`
    /// without a coordinator.
    var dockShortcutAction: CoordinatorDockPresentation.ShortcutAction? {
        guard let location, let window = store.window(id: location.windowID) else { return nil }
        // The full view's chat shows only in the coordinator's tab, and
        // not while focus mode shows another panel.
        let panelIsDisplayed = location.panelID.map { panelID in
            store.state.workspacesByID[location.workspaceID]?.panelIsDisplayedInSelectedTab(panelID) == true
        } ?? false
        let fullViewChatOnScreen = chatIsAvailable
            && panelIsDisplayed
            && showsTerminal == false
            && window.selectedWorkspaceID == location.workspaceID
            && window.showsTasksView == false
        return CoordinatorDockPresentation.shortcutAction(
            dockShows: dockShows(in: location.windowID),
            dockHasKeyboard: chat?.composerHasKeyboard(host: .dock) == true,
            fullViewChatOnScreen: fullViewChatOnScreen,
            fullViewHasKeyboard: chat?.composerHasKeyboard(host: .panel) == true
        )
    }

    /// Cmd+Shift+K: the keyboard goes to the chat's field, in the dock or
    /// in the full view. Only when the dock's field has it already does
    /// the dock hide.
    func performDockShortcut() {
        guard let location, let action = dockShortcutAction else { return }
        ToasttyLog.info("Ran the coordinator's dock shortcut", category: .tasks, metadata: ["action": "\(action)"])
        switch action {
        case .showDock:
            showDock(focusComposer: true)
        case .hideDock:
            hideDock()
        case .focusDock:
            chat?.requestComposerFocus(host: .dock)
        case .focusFullView:
            // Another panel in the coordinator's workspace, such as
            // policy.md, can have the focus.
            if let panelID = location.panelID {
                _ = store.send(.focusPanel(workspaceID: location.workspaceID, panelID: panelID))
            }
            chat?.requestComposerFocus(host: .panel)
        }
    }

    /// Files were dropped on the full view's chat: its window and workspace
    /// are selected, and the coordinator's panel takes the focus, as a
    /// terminal does for a file dropped on it.
    func focusPanelForDrop() {
        guard let location, let panelID = location.panelID else { return }
        _ = store.focusDroppedFilePanel(windowID: location.windowID, workspaceID: location.workspaceID, panelID: panelID)
    }

    /// Opens the coordinator's workspace, where the chat shows in full.
    /// `showingTerminal` shows its terminal in place of the chat, with the
    /// keyboard, for an answer that only the terminal takes.
    func openFullView(showingTerminal: Bool = false) {
        guard let location else { return }
        if showingTerminal {
            showsTerminal = true
        }
        _ = store.selectWorkspace(
            windowID: location.windowID,
            workspaceID: location.workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
        if showingTerminal {
            showTerminal()
        }
    }

    /// A click on a task's chip in the chat: the task's space opens, and
    /// the chat stays beside it in the dock.
    func openTaskSpaceFromChat(workspaceID: UUID, fallbackWindowID: UUID) {
        if let location {
            _ = store.send(.setCoordinatorDockVisible(windowID: location.windowID, visible: true))
        }
        TaskActions.openTaskSpace(
            workspaceID: workspaceID,
            fallbackWindowID: fallbackWindowID,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
        )
    }

    // MARK: - Open and restart

    /// Creates the coordinator's workspace on first use, selects it when
    /// `select` is set, and starts the agent when none runs. A terminal that
    /// is busy with something else is left alone: the call then fails, and
    /// Restart replaces that terminal.
    ///
    /// `agent` starts this coordinator's agent with that profile, with its
    /// own model and effort, in place of `[coordinator]` in tasks.toml.
    @discardableResult
    func open(windowID requestedWindowID: UUID? = nil, select: Bool = true, agent: String? = nil) async throws -> StartResult {
        try checkAgentBeforeCreatingWorkspace(agent)
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
        let sessionID = try await startAgent(location, replacingBusyTerminal: false, agent: agent)
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
    func restart(windowID requestedWindowID: UUID? = nil, agent: String? = nil) async throws -> StartResult {
        guard isStarting == false else {
            throw CoordinatorError("The coordinator is already starting.")
        }
        try checkAgentBeforeCreatingWorkspace(agent)
        let createdWorkspace = try createWorkspaceIfNeeded(windowID: requestedWindowID)
        guard let location else {
            throw CoordinatorError("Toastty could not create the coordinator's workspace.")
        }
        let sessionID = try await startAgent(location, replacingBusyTerminal: true, agent: agent)
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

    /// Shows why the coordinator's agent did not start, and offers an
    /// installed agent in its place, on the window of the command when it
    /// has one. Returns true when the person chose to start with that agent.
    typealias AgentChoicePresenter = @MainActor (
        _ title: String,
        _ message: String,
        _ choice: CoordinatorAgentChoice,
        _ windowID: UUID?
    ) async -> Bool

    /// Runs a person's command, and shows why when it did not work. When
    /// the configured agent is not installed and another one is, the
    /// failure offers to start with that one. The task's value is whether
    /// the coordinator's agent runs, or was already running, at the end.
    @discardableResult
    func perform(
        _ command: UserCommand,
        windowID: UUID? = nil,
        presentFailure: @escaping @MainActor (String, String) -> Void = TaskActions.presentFailure,
        offerAgent: @escaping AgentChoicePresenter = CoordinatorController.presentAgentChoice
    ) -> Task<Bool, Never> {
        Task { @MainActor in
            do {
                try await run(command, windowID: windowID, agent: nil)
                return true
            } catch let error as CoordinatorError {
                guard let choice = error.alternativeAgent else {
                    presentFailure(command.failureTitle, error.message)
                    return false
                }
                guard await offerAgent(
                    command.failureTitle,
                    error.message + "\n\n" + Self.agentChoiceText(choice),
                    choice,
                    windowID
                ) else { return false }
                do {
                    try await run(command, windowID: windowID, agent: choice.profileID)
                    return true
                } catch {
                    presentFailure(command.failureTitle, error.localizedDescription)
                    return false
                }
            } catch {
                presentFailure(command.failureTitle, error.localizedDescription)
                return false
            }
        }
    }

    private func run(_ command: UserCommand, windowID: UUID?, agent: String?) async throws {
        switch command {
        case .open: try await open(windowID: windowID, agent: agent)
        case .restart: try await restart(windowID: windowID, agent: agent)
        }
    }

    /// What the alert adds below the failure when it offers `choice`.
    static func agentChoiceText(_ choice: CoordinatorAgentChoice) -> String {
        "\(startButtonTitle(choice)) starts the coordinator with \(choice.displayName) now, with its own model and effort. "
            + "Toastty does not change tasks.toml, so a later start tries \(choice.configuredProfileID) again."
    }

    static func startButtonTitle(_ choice: CoordinatorAgentChoice) -> String {
        "Start with \(choice.displayName)"
    }

    /// The failure as an alert with a button that starts with `choice`. It
    /// is a sheet on the window, so that the main actor, and with it
    /// Toastty's socket, keeps working while the alert waits for an answer;
    /// an app-modal alert would hold the main actor in this task.
    static func presentAgentChoice(
        title: String,
        message: String,
        choice: CoordinatorAgentChoice,
        windowID: UUID?
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addConfiguredButton(withTitle: startButtonTitle(choice), behavior: .defaultAction)
        alert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        alert.window.setAccessibilityIdentifier("coordinator.agent-not-installed")
        guard let window = windowID.flatMap(AgentLaunchUI.window(for:)) ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn
    }

    // MARK: - Documents

    /// Shows one of the coordinator's files, such as `policy.md`, in the
    /// coordinator's workspace, in the right panel of the tab that holds the
    /// coordinator's terminal, so the chat stays in view; the user can read
    /// and edit it there. The workspace and that tab become the selected
    /// ones, and a panel that already shows the file is used again. A
    /// missing file is created first, as at a start. The ledger shows its
    /// last line, also in a panel that was open already: the file grew
    /// since.
    func openDocument(_ document: CoordinatorDocument) throws {
        guard let location else {
            throw CoordinatorError("There is no coordinator. Open Coordinator first.")
        }
        let directory = try preparedDirectory()
        let path = URL(filePath: directory, directoryHint: .isDirectory)
            .appending(path: document.fileName, directoryHint: .notDirectory)
            .path
        _ = store.selectWorkspace(
            windowID: location.windowID,
            workspaceID: location.workspaceID,
            preferringUnreadSessionPanelIn: nil
        )
        // Each tab has its own right panel.
        if let panelID = location.panelID,
           let tabID = store.state.workspacesByID[location.workspaceID]?.tabID(containingPanelID: panelID) {
            _ = store.send(.selectWorkspaceTab(workspaceID: location.workspaceID, tabID: tabID))
        }
        guard let outcome = store.createLocalDocumentPanelOutcome(
            workspaceID: location.workspaceID,
            request: LocalDocumentPanelCreateRequest(
                filePath: path,
                placementOverride: .rightPanel,
                formatOverride: .markdown
            )
        ) else {
            throw CoordinatorError("Toastty could not open \(path).")
        }
        if document.opensAtLastLine,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            _ = revealDocumentLine(outcome.panelID, Self.lastLineNumber(of: text))
        }
    }

    /// The number of the text's last line, from 1, as the document panel
    /// counts lines (`contentLines` in `LocalDocumentPanelApp.tsx`): `\r\n`
    /// and `\r` end a line as `\n` does, and a line end at the end of the
    /// text starts no line.
    static func lastLineNumber(of text: String) -> Int {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let newline = UInt8(ascii: "\n")
        var count = normalized.utf8.reduce(0) { $1 == newline ? $0 + 1 : $0 }
        if normalized.utf8.last != newline { count += 1 }
        return max(count, 1)
    }

    /// A start that would make the coordinator's workspace checks its agent
    /// first, so that an agent that is not installed leaves no workspace
    /// and no folder behind. A start in a workspace that exists checks it
    /// in `launchAgent`, and the workspace shows why it failed.
    private func checkAgentBeforeCreatingWorkspace(_ agent: String?) throws {
        guard store.state.coordinator == nil else { return }
        _ = try startConfiguration(agent: agent)
    }

    /// The agent, model and effort that a start uses, once Toastty found
    /// the agent's command. `agent` replaces `[coordinator]`, with the
    /// profile's own model and effort: a model set for one agent does not
    /// fit another.
    private func startConfiguration(agent: String?) throws -> TasksConfig.Coordinator {
        guard let launcher else {
            throw CoordinatorError("The agent launcher is not available.")
        }
        var config: TasksConfig.Coordinator
        do {
            config = try configLoader().coordinator
        } catch {
            throw CoordinatorError(error.localizedDescription)
        }
        if let agent, agent != config.agent {
            config = TasksConfig.Coordinator(agent: agent)
        }
        try Self.checkInstalled(config.agent, launcher: launcher, choosingFrom: Self.agentChoices)
        return config
    }

    /// The agents that a start offers in place of one that is not
    /// installed, in this order: the two that Toastty sets up for the
    /// coordinator, Claude's folder trust and Codex's instruction size.
    static let agentChoices = [AgentKind.claude.rawValue, AgentKind.codex.rawValue]

    /// Throws, with the first installed agent of `choices` as the
    /// alternative, when the profile's command is not installed or no
    /// profile has the ID. A command that Toastty cannot check, such as a
    /// relative path, is left to the launch.
    static func checkInstalled(
        _ profileID: String,
        launcher: any CoordinatorAgentLaunching,
        choosingFrom choices: [String]
    ) throws {
        var message: String
        do {
            let state = try launcher.profileExecutableState(profileID: profileID)
            switch state.failure {
            case nil, .explicitPathNotAbsolute?:
                return
            case .commandNotFound?:
                message = "The coordinator's agent \(profileID) is not installed: Toastty did not find the \(state.command.isEmpty ? profileID : state.command) command. Install it, or set"
            case .explicitPathNotExecutable?:
                message = "The coordinator's agent \(profileID) is not installed: \(state.command) is not a program that can run. Install it, or set"
            }
        } catch {
            message = "The coordinator's agent \(profileID) is not an agent profile. Set"
        }
        let alternative = choices.lazy
            .filter { $0 != profileID }
            .compactMap { choice -> CoordinatorAgentChoice? in
                guard let state = try? launcher.profileExecutableState(profileID: choice),
                      state.executablePath != nil else { return nil }
                return CoordinatorAgentChoice(profileID: choice, displayName: state.displayName, configuredProfileID: profileID)
            }
            .first
        message += " agent under [coordinator] in ~/.toastty/tasks.toml to an agent profile that is installed"
        if let alternative {
            message += ", such as \(alternative.profileID)"
        }
        message += "."
        throw CoordinatorError(message, alternativeAgent: alternative)
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

    private func startAgent(_ location: CoordinatorLocation, replacingBusyTerminal: Bool, agent: String?) async throws -> String {
        let workspaceID = location.workspaceID
        startingWorkspaceID = workspaceID
        failedStart = nil
        defer {
            if startingWorkspaceID == workspaceID { startingWorkspaceID = nil }
            drain()
        }
        do {
            return try await launchAgent(location, replacingBusyTerminal: replacingBusyTerminal, agent: agent)
        } catch {
            let reason = Self.startFailureReason(for: error)
            if self.location?.workspaceID == workspaceID {
                failedStart = FailedStart(workspaceID: workspaceID, reason: reason)
            }
            ToasttyLog.warning("The coordinator's agent did not start", category: .tasks, metadata: [
                "reason": reason,
                "requested_action": replacingBusyTerminal ? "restart" : "open",
            ])
            // Keeps the installed agent that a person can choose instead.
            throw error as? CoordinatorError ?? CoordinatorError(reason)
        }
    }

    private func launchAgent(_ location: CoordinatorLocation, replacingBusyTerminal: Bool, agent: String?) async throws -> String {
        let config = try startConfiguration(agent: agent)
        guard let launcher else {
            throw CoordinatorError("The agent launcher is not available.")
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
        noteStartedSession(result.sessionID)
        checkInstructionsLimit(in: sessionRuntimeStore.sessionRegistry)
        ToasttyLog.info("Started the coordinator's agent", category: .tasks, metadata: [
            "session_id": result.sessionID,
            "panel_id": terminal.panelID.uuidString,
            "agent": config.agent,
            "requested_action": replacingBusyTerminal ? "restart" : "open",
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
                // Closing the terminal also drops its pending resume or any
                // text that may have been left there by an unconfirmed paste.
                || managedAgentRestoreState(panelID) != .inactive
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
    ///
    /// `attachmentFolders` names folders of attached files that the message
    /// owns besides its own (`QueuedEntry.attachmentFolders`).
    @discardableResult
    func send(
        _ text: String,
        queueWhenHeld: Bool = true,
        byUser: Bool = false,
        id: String = UUID().uuidString,
        attachmentFolders: [String] = []
    ) throws -> SendResult {
        // The entry keeps the text as it is typed, which is also how the
        // agent's conversation echoes it.
        let text = AgentPasteText.keepingImagePathsAsText(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.isEmpty == false else {
            throw CoordinatorError("The message is empty.")
        }
        dropQueueOfAClosedCoordinator()
        guard let location else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        let entry = QueuedEntry(id: id, text: text, byUser: byUser, attachmentFolders: attachmentFolders)
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
        id: String = UUID().uuidString,
        attachmentFolders: [String] = []
    ) throws -> SendResult {
        let text = AgentPasteText.keepingImagePathsAsText(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if steering, text.isEmpty == false {
            switch steer(QueuedEntry(id: id, text: text, byUser: true, attachmentFolders: attachmentFolders)) {
            case .delivered?: return .steered
            case .uncertain?: return .steeredUnconfirmed
            case .unavailable?, nil: break
            }
        }
        return try send(text, byUser: true, id: id, attachmentFolders: attachmentFolders)
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
            // The stop set the waiting entries aside already: see
            // `setWaitingEntriesAside`.
            ToasttyLog.info("Stopped the coordinator's turn", category: .tasks, metadata: [
                "set_aside": String(pausedEntries.count),
            ])
        case .rejected(let reason):
            throw CoordinatorError("Toastty could not stop the coordinator's turn (\(reason.rawValue)).")
        }
    }

    /// A Stop from any app, this chat's or a paired phone's, ended the
    /// coordinator's turn. Entries that wait are set aside, so none starts
    /// a new turn right after the stop: they wait until `resumeQueue`. The
    /// conversation calls this before the stopped turn's end can open the
    /// prompt.
    private func setWaitingEntriesAside() {
        // Also a Stop that sets none of these aside holds the messages of
        // the conversation's own queue: it names them.
        heldSetToken = UUID().uuidString
        guard queuedEntries.isEmpty == false else { return }
        ToasttyLog.info("Set the coordinator's waiting messages aside after a stop", category: .tasks, metadata: [
            "set_aside": String(queuedEntries.count),
        ])
        pausedEntries.append(contentsOf: queuedEntries)
        queuedEntries.removeAll()
        drain()
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
    /// folders that it owns go too: the message will not be sent. Without
    /// it they stay, for a caller that sends the entry's text again.
    ///
    /// The saved file changes first. When it cannot be saved without the
    /// entry, nothing changes and this throws: a relaunch would bring the
    /// entry back, and type it without its files. An entry that the file
    /// never held goes also then, since no relaunch knows of it.
    @discardableResult
    func removeQueuedEntry(id: String, discardingAttachments: Bool = false) throws -> QueuedEntry? {
        var queued = queuedEntries
        var paused = pausedEntries
        let removed: QueuedEntry
        if let index = queued.firstIndex(where: { $0.id == id }) {
            removed = queued.remove(at: index)
        } else if let index = paused.firstIndex(where: { $0.id == id }) {
            removed = paused.remove(at: index)
        } else {
            return nil
        }
        guard saveQueue(queueSnapshot(queued: queued, paused: paused)) || savedQueueLists(id) == false else {
            ToasttyLog.warning("Kept a waiting message for the coordinator: the queue could not be saved without it", category: .tasks)
            throw CoordinatorError(
                "Toastty could not save the waiting messages, so the message still waits. Try Remove again."
            )
        }
        queuedEntries = queued
        pausedEntries = paused
        if discardingAttachments {
            attachments.discard(folders: removed.attachmentFolders)
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

    // MARK: - Quiet turns

    /// The keys of the digests whose turn the coordinator marked quiet,
    /// oldest first (`CoordinatorWakeState.quietDigestKeys`). The service
    /// that keeps the wake state sets it, and sends `quietDigestChanges`
    /// when the keys change.
    var quietDigestKeys: () -> [String] = { [] }
    /// Sends when `quietDigestKeys` changes: a turn is marked quiet, a mark
    /// is removed or forgotten, or another coordinator starts. Paired
    /// devices fold the turns with the Mac's chat (`RemoteAccessService`).
    let quietDigestChanges = PassthroughSubject<Void, Never>()

    /// Whether the message is a digest whose turn the coordinator marked
    /// quiet.
    func isQuietDigest(_ text: String) -> Bool {
        let keys = quietDigestKeys()
        return keys.isEmpty == false && keys.contains(CoordinatorWakeState.digestKey(text))
    }

    /// The newest text this controller typed into the agent, from any
    /// sender, as `CoordinatorWakeState.digestKey`, and when.
    private var lastTyped: (key: String, at: Date)?
    /// The wake turn that the coordinator marked quiet: its session, the
    /// key of the digest that started it, and what names the turn. The
    /// session's last turn end moves when its status ends the turn, and the
    /// conversation's turn epoch when its transcript does. Either can come
    /// first.
    private var quietTurn: QuietTurn?

    private struct QuietTurn {
        let sessionID: String
        let digestKey: String
        let previousTurnEndedAt: Date?
        let turnEpoch: RemoteInputEpoch?
    }

    /// The conversation's epoch of the turn that runs now.
    private func runningTurnEpoch(_ subscription: any LocalConversationSubscription) -> RemoteInputEpoch? {
        subscription.snapshot(at: now())?.summary.inputControl?.turnEpoch
    }

    /// The events read to find the newest message to the agent.
    private static let quietTurnEventLimit = 200

    /// The text of the newest message to the agent among its newest events,
    /// also one typed in its terminal, which does not pass through this
    /// controller. `nil` when no message is among them.
    private func newestMessageToTheAgent(_ subscription: any LocalConversationSubscription) -> String? {
        guard case .page(let page) = subscription.events(before: nil, limit: Self.quietTurnEventLimit) else { return nil }
        for event in page.events.reversed() {
            if case .userMessage(let payload) = event.payload { return payload.text }
        }
        return nil
    }

    /// Whether the turn that the digest with this key started still has no
    /// other message in it: this controller typed nothing after the digest,
    /// nobody typed in the terminal since, and the conversation shows no
    /// newer message. Each check covers what the others can miss: the
    /// conversation reads the transcript with a delay, and keys typed in
    /// the terminal do not pass through this controller.
    private func onlyTheDigestReached(_ digestKey: String, subscription: any LocalConversationSubscription) -> Bool {
        guard let lastTyped, lastTyped.key == digestKey else { return false }
        if let panelID = location?.panelID, let typedAt = sessionRuntimeStore.lastUserInputAt(panelID: panelID),
           typedAt > lastTyped.at {
            return false
        }
        // A turn with more events than the page holds started with the
        // digest that this controller typed last.
        guard let newest = newestMessageToTheAgent(subscription) else { return true }
        return CoordinatorWakeState.digestKey(newest) == digestKey
    }

    /// Marks the turn that runs now as quiet, when the digest with this key
    /// started it and no other message came into it. `false` changes
    /// nothing.
    func markQuietTurn(digestKey: String) -> Bool {
        guard let session,
              let subscription = syncConversationSubscription(),
              subscription.snapshot(at: now())?.summary.state == .working,
              onlyTheDigestReached(digestKey, subscription: subscription) else { return false }
        quietTurn = QuietTurn(
            sessionID: session.sessionID,
            digestKey: digestKey,
            previousTurnEndedAt: session.lastTurnEndedAt,
            turnEpoch: runningTurnEpoch(subscription)
        )
        return true
    }

    /// Removes the quiet mark, when the coordinator runs `coordinator wake`
    /// without `--quiet` after it marked the turn quiet: the last call of
    /// the turn decides. Returns whether the mark belonged to the turn that
    /// runs now, so that the caller also removes the saved mark. The mark
    /// of a turn that has ended stays.
    func unmarkQuietTurn(digestKey: String) -> Bool {
        guard let quietTurn, quietTurn.digestKey == digestKey else { return false }
        self.quietTurn = nil
        guard let session, session.sessionID == quietTurn.sessionID,
              session.lastTurnEndedAt == quietTurn.previousTurnEndedAt,
              let subscription = syncConversationSubscription(),
              runningTurnEpoch(subscription) == quietTurn.turnEpoch else { return false }
        return true
    }

    /// Whether the turn of this session that ends now is the quiet one, and
    /// no message came into it after the mark.
    func turnEndsQuietly(sessionID: String) -> Bool {
        guard let quietTurn, quietTurn.sessionID == sessionID,
              let subscription = syncConversationSubscription() else { return false }
        return onlyTheDigestReached(quietTurn.digestKey, subscription: subscription)
    }

    // MARK: - Turn ends

    /// A turn of the coordinator's agent ended, as its session reports it.
    struct TurnEnd: Equatable {
        let sessionID: String
        /// The turn ended with an error, such as an API error, and not
        /// normally.
        let failed: Bool
        /// `CoordinatorWakeState.digestKey` of the message that this
        /// controller typed at the open prompt and that started the turn.
        /// `nil` when something else started it, such as text typed in the
        /// terminal.
        let startedByKey: String?
    }

    /// Called at the end of each turn of the coordinator's agent. The
    /// service that keeps the wake state sets it.
    var onTurnEnd: ((TurnEnd) -> Void)?

    /// The coordinator's session and the end of its last turn, as the last
    /// change of the session store showed them.
    private var observedTurnEnd: (sessionID: String, endedAt: Date?)?
    /// The messages typed at an open prompt whose turns have not ended,
    /// oldest first.
    private var promptsAwaitingTurnEnd: [(sessionID: String, key: String, at: Date)] = []
    private static let rememberedPromptsAwaitingTurnEnd = 20

    /// Finds the end of a turn of the coordinator's agent in a change of
    /// the session store: its session's `lastTurnEndedAt` moves. The
    /// session's status then says how the turn ended. A turn belongs to
    /// the last message typed at an open prompt before the turn started.
    /// The agent's transcript can open the prompt before its status ends
    /// the turn, so the next message can be typed before the end is seen;
    /// that message waits for a later turn.
    private func noteTurnEnd(in registry: SessionRegistry) {
        guard let panelID = location?.panelID, let record = registry.activeSession(for: panelID) else {
            observedTurnEnd = nil
            return
        }
        let previous = observedTurnEnd
        observedTurnEnd = (record.sessionID, record.lastTurnEndedAt)
        guard let previous, previous.sessionID == record.sessionID,
              let endedAt = record.lastTurnEndedAt, endedAt != previous.endedAt else { return }
        // The session store sets both from the same two times, so this is
        // the turn's start exactly.
        let startedAt = endedAt.addingTimeInterval(-(record.lastTurnDuration ?? 0))
        var startedByKey: String?
        if let index = promptsAwaitingTurnEnd.lastIndex(where: { $0.sessionID == record.sessionID && $0.at <= startedAt }) {
            startedByKey = promptsAwaitingTurnEnd[index].key
            // Older messages had their turns, or none that was seen.
            promptsAwaitingTurnEnd.removeFirst(index + 1)
        }
        onTurnEnd?(TurnEnd(sessionID: record.sessionID, failed: record.status?.kind == .error, startedByKey: startedByKey))
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
        if session.agent == .claude, terminals?.claudeHasNativeDialog(panelID: session.panelID) == true {
            return .held(.terminalDialog, recheckAt: moment.addingTimeInterval(CoordinatorSendGate.pollInterval))
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
        let typed = (key: CoordinatorWakeState.digestKey(entry.text), at: now())
        lastTyped = typed
        // A steer goes into a turn that runs already.
        if steered == false {
            promptsAwaitingTurnEnd.append((session.sessionID, typed.key, typed.at))
            if promptsAwaitingTurnEnd.count > Self.rememberedPromptsAwaitingTurnEnd {
                promptsAwaitingTurnEnd.removeFirst()
            }
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
            attachments.discard(folders: entry.attachmentFolders)
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
                attachments.discard(folders: entry.ownedAttachmentFolders)
            }
            try? CoordinatorQueueSnapshot.remove(at: queueFileURL)
            ToasttyLog.info("Dropped saved messages of a coordinator that is gone", category: .tasks, metadata: [
                "count": String(snapshot.queued.count + snapshot.paused.count),
            ])
            return
        }
        var queued = snapshot.queued.map {
            QueuedEntry(id: $0.id, text: $0.text, byUser: true, attachmentFolders: $0.ownedAttachmentFolders)
        }
        var paused = snapshot.paused.map {
            QueuedEntry(
                id: $0.id,
                text: $0.text,
                byUser: true,
                typingWasInterrupted: $0.typingWasInterrupted ?? false,
                attachmentFolders: $0.ownedAttachmentFolders
            )
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
        if paused.isEmpty == false { heldSetToken = UUID().uuidString }
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
        saveQueue(queueSnapshot())
    }

    /// Writes `snapshot` when the file holds another queue. Returns whether
    /// the file now holds `snapshot`.
    private func saveQueue(_ snapshot: CoordinatorQueueSnapshot?) -> Bool {
        guard let queueFileURL else { return true }
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

    /// The file's content for the queue, or for `queued` and `paused` in
    /// its place: a change that is saved before it is made.
    private func queueSnapshot(
        queued: [QueuedEntry]? = nil,
        paused: [QueuedEntry]? = nil
    ) -> CoordinatorQueueSnapshot? {
        guard let workspaceID = queueWorkspaceID else { return nil }
        let queued = (queued ?? queuedEntries).filter(\.byUser)
        let paused = (paused ?? pausedEntries).filter(\.byUser)
        guard queued.isEmpty == false || paused.isEmpty == false else { return nil }
        return CoordinatorQueueSnapshot(
            workspaceID: workspaceID,
            queued: queued.map { .init(id: $0.id, text: $0.text, attachmentFolders: $0.attachmentFolders) },
            paused: paused.map {
                .init(
                    id: $0.id,
                    text: $0.text,
                    typingWasInterrupted: $0.typingWasInterrupted ? true : nil,
                    attachmentFolders: $0.attachmentFolders
                )
            },
            typingEntryID: typingEntryID
        )
    }

    /// Whether the saved file lists the entry `id`, so a relaunch would
    /// bring it back.
    private func savedQueueLists(_ id: String) -> Bool {
        ((savedQueue?.queued ?? []) + (savedQueue?.paused ?? [])).contains { $0.id == id }
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
        return savedQueueLists(entry.id) == false
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

    // MARK: - Answering the agent's question

    /// The question card that the coordinator's agent shows now. `card` is
    /// its ID, which an answer names.
    struct OpenQuestion: Equatable {
        var card: String
        var header: String
        var question: String
        var options: [String]
    }

    /// The answer that `answerOpenQuestion` gave: the card it answered, the
    /// choice it took, and the text that the agent received.
    struct QuestionAnswer: Equatable {
        var card: OpenQuestion
        var chosenOption: String?
        var answer: String
    }

    /// The open question card that `answerOpenQuestion` can answer: the
    /// only one, with one question. `nil` without such a card.
    func openQuestion() -> OpenQuestion? {
        try? openQuestionCard().open
    }

    /// Answers the question card that the coordinator's agent shows now,
    /// for someone outside the chat. `card` names the card that the caller
    /// read, so an answer never lands on a later card. Pass exactly one of
    /// `option`, a choice's label, and `text`. The card must ask one
    /// question; permission prompts are not answered here.
    ///
    /// The agent receives the answer as text after Toastty's first line
    /// for `sender`, in the form of a message that `coordinator send`
    /// brings, so it never reads as the user's. The user answers in the
    /// chat or on a phone, without such a line. A `nil` sender answers as
    /// the user, as the chat's card does: only a test instance of a Debug
    /// build passes it (see `AppControlExecutor.terminalAnswersCountAsUser`).
    func answerOpenQuestion(
        card cardID: String,
        option: String?,
        text: String?,
        from sender: CoordinatorMessageHeader.Sender?
    ) throws -> QuestionAnswer {
        let trimmed = { (value: String?) -> String? in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        let option = trimmed(option), text = trimmed(text)
        guard (option == nil) != (text == nil) else {
            throw CoordinatorError("Pass exactly one of option and text.")
        }
        let (subscription, conversationID, card, question, open) = try openQuestionCard()
        guard open.card == cardID else {
            throw CoordinatorError("The open card is another one: \(open.card). Read it with coordinator get.")
        }
        var answerText = text ?? ""
        var chosen: RemotePendingInteraction.Option?
        if let option {
            // The exact label first; else a label that differs only in case, when only one does.
            let caseless = question.options.filter { $0.label.compare(option, options: .caseInsensitive) == .orderedSame }
            guard let match = question.options.first(where: { $0.label == option })
                ?? (caseless.count == 1 ? caseless.first : nil) else {
                let labels = question.options.map { "\"\($0.label)\"" }.joined(separator: ", ")
                throw CoordinatorError("The card has no choice \"\(option)\". Its choices: \(labels).")
            }
            answerText = match.label
            chosen = match
        }
        let answer: String
        let reply: RemoteInteractionAnswer
        if let sender {
            // The sender's line goes first, and the choice goes as text after
            // it: a chosen option alone would reach the agent as the user's.
            answer = CoordinatorMessageHeader.message(from: sender, text: answerText)
            reply = RemoteInteractionAnswer(questionID: question.id, text: answer)
        } else {
            answer = answerText
            reply = chosen.map { RemoteInteractionAnswer(questionID: question.id, selectedOptionIDs: [$0.id]) }
                ?? RemoteInteractionAnswer(questionID: question.id, text: answer)
        }
        let request = RemoteQuestionAnswerRequest(
            conversationID: conversationID,
            interactionID: card.id,
            responseID: card.responseID ?? "",
            expectedInputEpoch: card.inputEpoch,
            clientRequestID: UUID().uuidString.lowercased(),
            answers: [reply]
        )
        switch subscription.answerQuestion(request) {
        case .submitted, .duplicate:
            return QuestionAnswer(card: open, chosenOption: chosen?.label, answer: answer)
        case .rejected(let reason):
            throw CoordinatorError("The answer was refused: \(reason.rawValue).")
        }
    }

    private func openQuestionCard() throws -> (
        subscription: any LocalConversationSubscription,
        conversationID: RemoteConversationID,
        card: RemotePendingInteraction,
        question: RemoteInteractionQuestion,
        open: OpenQuestion
    ) {
        guard let subscription = syncConversationSubscription(), let conversationID = subscription.conversationID else {
            throw CoordinatorError("The coordinator has no agent conversation.")
        }
        let cards = (subscription.snapshot(at: Date())?.pendingInteractions ?? []).filter {
            $0.kind == .question && $0.state == .pending && $0.responseID?.isEmpty == false
        }
        guard let card = cards.first, let questions = card.questions else {
            throw CoordinatorError("The coordinator shows no question card.")
        }
        guard cards.count == 1, questions.count == 1, let question = questions.first else {
            throw CoordinatorError("The card asks more than one question; answer it in the coordinator's chat.")
        }
        let open = OpenQuestion(
            card: card.id.rawValue,
            header: question.header,
            question: question.question,
            options: question.options.map(\.label)
        )
        return (subscription, conversationID, card, question, open)
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
        subscription.onStop = { [weak self] in self?.setWaitingEntriesAside() }
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
        guard hold != next else { return }
        let previous = hold
        hold = next
        var metadata = terminalLogFacts()
        metadata["previous_hold"] = previous?.rawValue ?? "none"
        ToasttyLog.info("Changed why the coordinator's waiting message waits", category: .tasks, metadata: metadata)
        // A new reason while the terminal shows is the moment that a later
        // report asks about: record the next key presses again.
        if showsTerminal { terminalKeyLog.start() }
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
