import Combine
import CoreState
import Foundation
import RemoteProtocol

/// One main-actor authority for local chat and authenticated remote clients.
/// The listener owns network policy. This service owns provider state and input.
@MainActor
final class ConversationService {
    struct Authorization {
        var canSend: Bool
        var writesEnabled: Bool
        var canApprovePermissions: Bool
        var canSendAttachments: Bool
        static let denied = Authorization(canSend: false, writesEnabled: false, canApprovePermissions: false, canSendAttachments: false)
    }
    var remoteAuthorization: ((UUID, RemoteConversationID) -> Authorization)?
    var onRemoteEvent: ((RemoteGatewayStreamMessage) -> Void)?
    var onInventoryChanged: (() -> Void)?
    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private(set) var localPanelIDs: Set<UUID> = []
    /// Task transcripts are read for card threads without granting local input.
    private var taskPanelIDs: Set<UUID> = []
    private struct TaskTranscriptSource {
        var taskID: UUID
        var resumeRecord: ManagedAgentResumeRecord
    }
    /// Stopping an agent clears the terminal's resume record. Keep the
    /// explicitly bound source while its task thread still reads the panel.
    private var taskTranscriptSources: [UUID: TaskTranscriptSource] = [:]
    private var remoteTrackingEnabled = false
    private var isTracking = false
    private var demandReconciliationTask: Task<Void, Never>?
    private var retainedPanelIDs: Set<UUID> {
        let conversations = sendQueue.conversationIDs.union(pendingSendConfirmationWork.keys.map(\.conversationID))
        return Set(conversations.compactMap { panelIDByConversationID[$0] })
    }
    private var publicationDepth = 0
    private var revision: UInt64 = 0
    private var changeSubscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    let projectionStore = RemoteConversationProjectionStore()
    let attachmentStore: RemoteMessageAttachmentStore
    /// When a phone message or stop last reached each panel. Remote delivery
    /// bypasses local-input tracking, so an exit after the turn asks here.
    private var lastRemoteInputAtByPanelID: [UUID: Date] = [:]
    private var coordinator = RemoteInputCoordinator()
    /// Messages held for the next open prompt, per conversation.
    private var sendQueue = RemoteSendQueue()
    /// Staged attachment directories owned by queued entries, so a removed or
    /// expired entry can release its files.
    private var stagedAttachmentsByQueuedRequestID: [String: RemoteMessageAttachmentStore.Staged] = [:]
    /// Limit Steer to providers that can read text during the running turn.
    /// Claude Code labels it queued, but reads it after active tool calls
    /// finish. Toastty's queue instead waits for the next open prompt.
    static let steerCapableProviders: Set<AgentKind> = [.codex, .claude]
    private var conversationTrackingCancellables: Set<AnyCancellable> = []
    private var storeActionObserverToken: UUID?
    private var conversationTrackingGeneration: UInt64 = 0
    private var sessionListBroadcastTask: Task<Void, Never>?
    private var localDraftEpochBroadcastTask: Task<Void, Never>?
    private let claudePromptStabilizationDelay: Duration
    private let sendConfirmationTimeout: Duration
    /// A steer's confirming user message arrives when the provider next reads
    /// its input, which can be well after a long tool call.
    private let steerConfirmationTimeout: Duration
    /// Codex writes `task_started` before the user message, and pre-turn work
    /// such as automatic context compaction can separate them by more than a
    /// minute. While a Codex turn that started after the send is running, a
    /// send stays pending up to this long after acceptance.
    private let codexTurnConfirmationTimeout: Duration
    private let localDraftEpochBroadcastInterval: Duration
    private struct PromptStabilizationWork {
        var token: ConversationPromptStabilizationToken
        var task: Task<Void, Never>
    }
    private var promptStabilizationWorkByConversationID: [
        RemoteConversationID: PromptStabilizationWork
    ] = [:]

    private struct PendingSendConfirmationKey: Hashable {
        var conversationID: RemoteConversationID
        var clientRequestID: String
    }
    private struct PendingSendConfirmationWork {
        var acceptedAt: Date
        var task: Task<Void, Never>
        /// A Codex turn that started after this send was accepted and has not
        /// ended yet. The inner value is the provider turn ID, when known.
        var runningCodexTurnID: String??
        /// The normal deadline passed while `runningCodexTurnID` was set, so
        /// the end of that turn decides the outcome.
        var isWaitingForCodexTurn = false
    }
    private var pendingSendConfirmationWork: [
        PendingSendConfirmationKey: PendingSendConfirmationWork
    ] = [:]

    private var tailersByConversationID: [RemoteConversationID: RemoteTranscriptTailer] = [:]
    private(set) var activeSessionIDByConversationID: [RemoteConversationID: String] = [:]
    private(set) var panelIDByConversationID: [RemoteConversationID: UUID] = [:]
    private var conversationIDByPanelID: [UUID: RemoteConversationID] = [:]
    private var controlCPromptEpochByConversationID: [RemoteConversationID: RemoteInputEpoch] = [:]
    private struct ProviderFeedIdentity: Equatable {
        var provider: AgentKind
        var nativeSessionID: String
        var snapshotID: String
    }
    private var providerFeedIdentityByConversationID: [
        RemoteConversationID: ProviderFeedIdentity
    ] = [:]
    private var providerFeedLastFingerprintByConversationID: [
        RemoteConversationID: String
    ] = [:]
    private var bootstrappedPromptAuthorityByConversationID: [
        RemoteConversationID: BootstrappedPromptAuthority
    ] = [:]
    /// Pending remote sends awaiting their confirming user message in the
    /// projection, oldest first, keyed by conversation.
    private var pendingSendCorrelator = RemotePendingSendCorrelator()

    init(store: AppStore, sessionRuntimeStore: SessionRuntimeStore,
         terminalRuntimeRegistry: TerminalRuntimeRegistry, runtimePaths: ToasttyRuntimePaths,
         claudePromptStabilizationDelay: Duration = .milliseconds(500),
         sendConfirmationTimeout: Duration = .seconds(10),
         steerConfirmationTimeout: Duration = .seconds(180),
         codexTurnConfirmationTimeout: Duration = .seconds(300),
         localDraftEpochBroadcastInterval: Duration = .milliseconds(500)) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.attachmentStore = RemoteMessageAttachmentStore(root: runtimePaths.remoteAccessDirectoryURL.appendingPathComponent("attachments", isDirectory: true))
        self.claudePromptStabilizationDelay = claudePromptStabilizationDelay
        self.sendConfirmationTimeout = sendConfirmationTimeout
        self.steerConfirmationTimeout = steerConfirmationTimeout
        self.codexTurnConfirmationTimeout = codexTurnConfirmationTimeout
        self.localDraftEpochBroadcastInterval = localDraftEpochBroadcastInterval
    }

    /// The app supplies the coordinator and currently open Peek panel IDs.
    func setLocalPanelIDs(_ panelIDs: Set<UUID>) {
        guard localPanelIDs != panelIDs else { return }
        localPanelIDs = panelIDs
        updateTracking()
    }

    func setTaskPanelIDs(_ panelIDs: Set<UUID>) {
        guard taskPanelIDs != panelIDs else { return }
        taskPanelIDs = panelIDs
        taskTranscriptSources = taskTranscriptSources.filter { panelIDs.contains($0.key) }
        updateTracking()
    }

    func setRemoteTrackingEnabled(_ enabled: Bool) {
        guard remoteTrackingEnabled != enabled else { return }
        remoteTrackingEnabled = enabled
        updateTracking()
    }

    private func updateTracking() {
        // Transport callbacks can synchronously change demand. Permissions
        // change immediately; teardown waits until the current ingest ends.
        guard publicationDepth == 0 else {
            scheduleDemandReconciliation()
            return
        }
        discardRemoteQueuedEntriesIfDisabled()
        let needsTracking = remoteTrackingEnabled || !localPanelIDs.isEmpty || !taskPanelIDs.isEmpty || !retainedPanelIDs.isEmpty
        if needsTracking {
            if !isTracking {
                isTracking = true
                beginConversationTracking()
            }
            syncConversations()
        } else if isTracking {
            isTracking = false
            endConversationTracking()
            publishChange()
        }
    }

    /// Reconcile after the current ingest/delivery finishes; tearing down from
    /// inside correlation would mutate the projector while it is in use.
    private func scheduleDemandReconciliation() {
        guard isTracking, demandReconciliationTask == nil else { return }
        demandReconciliationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.demandReconciliationTask = nil
            self.updateTracking()
        }
    }

    private func authorization(for source: ConversationInputSource, conversationID: RemoteConversationID, acceptedRequestID: String? = nil) -> Authorization {
        switch source {
        case .local:
            let hasAcceptedEntry = acceptedRequestID.map { requestID in
                sendQueue.entries(for: conversationID).contains { $0.clientRequestID == requestID && $0.source == .local }
            } ?? false
            guard hasAcceptedEntry || panelIDByConversationID[conversationID].map(localPanelIDs.contains) == true else { return .denied }
            return Authorization(canSend: true, writesEnabled: true, canApprovePermissions: true, canSendAttachments: true)
        case .remoteDevice(let deviceID):
            guard remoteTrackingEnabled else { return .denied }
            return remoteAuthorization?(deviceID, conversationID) ?? .denied
        }
    }

    var localConversations: [RemoteConversationSummary] {
        buildConversationSummaries().filter { $0.placement.panelID.map(localPanelIDs.contains) == true }
    }
    func conversationID(for panelID: UUID) -> RemoteConversationID? { conversationIDByPanelID[panelID] }
    /// Invalidation only. Read snapshots/cursor pages again after each revision.
    /// Each caller gets a separate stream, which survives tracking restarts.
    func changes() -> AsyncStream<UInt64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changeSubscribers[id] = continuation
        continuation.yield(revision)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.changeSubscribers.removeValue(forKey: id) }
        }
        return stream
    }
    private func publishChange() {
        revision &+= 1
        for subscriber in changeSubscribers.values { subscriber.yield(revision) }
    }
    private func emit(_ event: RemoteGatewayStreamMessage) {
        publishChange()
        if remoteTrackingEnabled {
            publicationDepth += 1
            defer { publicationDepth -= 1 }
            onRemoteEvent?(event)
        }
    }
    private func broadcastSessionList() {
        guard isTracking else { return }
        sessionListBroadcastTask?.cancel()
        sessionListBroadcastTask = nil
        publishChange()
        publicationDepth += 1
        defer { publicationDepth -= 1 }
        onInventoryChanged?()
    }
    func sendLocal(_ request: RemoteMessageSendRequest) async -> RemoteMessageSendResult { await send(request, source: .local) }
    func send(_ request: RemoteMessageSendRequest, source: ConversationInputSource) async -> RemoteMessageSendResult {
        guard request.text.utf8.count <= RemoteGatewayProtocol.maximumRequestBodyBytes,
              RemoteAttachmentPolicy.validationError(for: request.attachments) == nil else { return .rejected(reason: .invalidAttachments) }
        if request.attachments.isEmpty { return performRemoteSend(request, source: source) }
        return await performAttachmentSend(request, source: source)
    }
    func answerLocal(_ request: RemoteQuestionAnswerRequest) -> RemoteQuestionAnswerResult { performQuestionAnswer(request, source: .local) }
    func updateLocalQueue(_ request: RemoteConversationQueueUpdateRequest) -> RemoteConversationQueueUpdateResult { performQueueUpdate(request, source: .local) }
    func interruptLocal(_ request: RemoteConversationInterruptRequest) -> RemoteConversationInterruptResult { performRemoteInterrupt(request, source: .local) }
    func releaseLocalDraft(_ request: RemoteConversationLocalDraftReleaseRequest) -> RemoteConversationLocalDraftReleaseResult { performLocalDraftRelease(request, source: .local) }

    private func discardRemoteQueuedEntriesIfDisabled() {
        guard !remoteTrackingEnabled else { return }
        for conversationID in sendQueue.conversationIDs {
            for entry in sendQueue.entries(for: conversationID) where entry.source != .local {
                if let removed = sendQueue.remove(clientRequestID: entry.clientRequestID, for: conversationID) {
                    discardQueuedEntries([removed])
                    noteQueuedSendDropped(removed, for: conversationID)
                }
            }
        }
    }

    private func beginConversationTracking() {
        guard conversationTrackingCancellables.isEmpty, storeActionObserverToken == nil else { return }
        precondition(terminalRuntimeRegistry.localInputObserver == nil, "Inject the same ConversationService into all conversation surfaces")
        conversationTrackingGeneration &+= 1
        let generation = conversationTrackingGeneration
        terminalRuntimeRegistry.localInputObserver = { [weak self] panelID, kind in
            guard let self, self.conversationTrackingGeneration == generation else { return true }
            return self.noteLocalInput(panelID: panelID, kind: kind)
        }
        sessionRuntimeStore.$sessionRegistry.debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isTracking, self.conversationTrackingGeneration == generation else { return }
                self.syncConversations()
            }.store(in: &conversationTrackingCancellables)
        sessionRuntimeStore.$providerConversationRevision.dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isTracking, self.conversationTrackingGeneration == generation else { return }
                self.syncConversations()
            }.store(in: &conversationTrackingCancellables)
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            guard let self, self.isTracking, self.conversationTrackingGeneration == generation else { return }
            let activePanels = Set(self.sessionRuntimeStore.sessionRegistry.activeSessionIDByPanelID.keys)
            if Self.conversationPlacements(in: previousState, activePanels: activePanels) != Self.conversationPlacements(in: nextState, activePanels: activePanels) {
                self.scheduleSessionListBroadcast()
            }
            switch action {
            case .updateTerminalPanelResumeRecord, .updateTerminalPanelRemoteConversationID:
                self.syncConversations()
            case .focusPanel, .markPanelNotificationsRead, .recordDesktopNotification:
                self.scheduleSessionListBroadcast()
            default: break
            }
        }
    }
    private func endConversationTracking() {
        demandReconciliationTask?.cancel()
        demandReconciliationTask = nil
        sessionListBroadcastTask?.cancel()
        sessionListBroadcastTask = nil
        conversationTrackingCancellables.removeAll()
        if let storeActionObserverToken {
            store.removeActionAppliedObserver(storeActionObserverToken)
            self.storeActionObserverToken = nil
        }
        terminalRuntimeRegistry.localInputObserver = nil
        localDraftEpochBroadcastTask?.cancel()
        localDraftEpochBroadcastTask = nil

        let trackedConversationIDs = Set(tailersByConversationID.keys)
            .union(activeSessionIDByConversationID.keys)
            .union(panelIDByConversationID.keys)
            .union(pendingSendCorrelator.conversationIDs)
            .union(sendQueue.conversationIDs)
            .union(projectionStore.registeredConversationIDs)
        for conversationID in trackedConversationIDs {
            removeConversationState(conversationID)
        }
        tailersByConversationID.removeAll()
        activeSessionIDByConversationID.removeAll()
        panelIDByConversationID.removeAll()
        conversationIDByPanelID.removeAll()
        providerFeedIdentityByConversationID.removeAll()
        providerFeedLastFingerprintByConversationID.removeAll()
        bootstrappedPromptAuthorityByConversationID.removeAll()
        for work in promptStabilizationWorkByConversationID.values {
            work.task.cancel()
        }
        promptStabilizationWorkByConversationID.removeAll()
        for work in pendingSendConfirmationWork.values {
            work.task.cancel()
        }
        pendingSendConfirmationWork.removeAll()
        pendingSendCorrelator = RemotePendingSendCorrelator()
        coordinator = RemoteInputCoordinator()
    }

    func localSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        if let snapshot = projectionStore.conversationSnapshot(for: conversationID, at: date) {
            var snapshot = snapshot
            // The projection store has no descriptor context for placement
            // titles; overlay the registry-derived summary when available.
            if let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) {
                snapshot.summary = summary
            } else {
                snapshot.summary.placement.workspaceTabID = nil
                snapshot.summary.placement.workspaceTabTitle = nil
            }
            return snapshot
        }
        guard let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) else {
            return nil
        }
        return RemoteConversationSnapshot(summary: summary, pendingInteractions: [])
    }

    func events(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        projectionStore.conversationEvents(for: conversationID, after: cursor, limit: limit)
    }

    func events(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        projectionStore.conversationEvents(for: conversationID, before: cursor, limit: limit)
    }

    /// Clears the same authoritative unread state as desktop focus, but only

    /// One row of the panel scan: a panel that currently represents (or last
    /// represented) a managed agent conversation.
    struct ConversationCandidate {
        var conversationID: RemoteConversationID
        var provider: AgentKind
        var title: String
        var workspaceID: UUID
        var workspaceTitle: String
        var workspaceTabID: UUID
        var workspaceTabTitle: String
        var panelID: UUID

        var cwd: String?
        var activeSessionID: String?
        var runtimeBindingStartedAt: Date?
        var registryState: RemoteSessionState
        var presentationStatus: RemoteSessionPresentationStatus?
        var isUnread: Bool
        var statusDetail: String?
        var isFlaggedForLater: Bool
        var turnStartedAt: Date?
        var lastTurnDuration: TimeInterval?
        var waiting: SessionWaitingSummary?
        var updatedAt: Date
        var transcriptPath: String?
        var providerFeed: ManagedProviderConversationFeedSnapshot?
        var nativeBindingConfirmation: ManagedNativeSessionBindingConfirmation?

        var placement: RemoteConversationPlacement {
            RemoteConversationPlacement(
                workspaceID: workspaceID, workspaceTitle: workspaceTitle, panelID: panelID,
                workspaceTabID: workspaceTabID, workspaceTabTitle: workspaceTabTitle
            )
        }
    }

    private struct BootstrappedPromptAuthority {
        var managedSessionID: String
        var confirmation: ManagedNativeSessionBindingConfirmation
        var inputEpoch: RemoteInputEpoch
    }

    func syncConversations(broadcast: Bool = true) {
        guard isTracking else { return }
        let candidates = scanConversationCandidates(mintingIDs: true)
        var seenConversationIDs: Set<RemoteConversationID> = []
        var listChanged = false

        for candidate in candidates {
            guard ProviderTranscriptSupport.isManagedProvider(candidate.provider) else {
                continue
            }
            seenConversationIDs.insert(candidate.conversationID)

            if let projector = projectionStore.projectorState(for: candidate.conversationID),
               projector.provider != candidate.provider {
                removeConversationState(candidate.conversationID)
                listChanged = true
            }

            let isNewRegistration = projectionStore.isConversationRegistered(candidate.conversationID) == false
            if isNewRegistration {
                projectionStore.registerConversation(
                    candidate.conversationID,
                    descriptor: RemoteConversationProjectionStore.ConversationDescriptor(
                        provider: candidate.provider,
                        title: candidate.title,
                        placement: candidate.placement,
                        cwd: candidate.cwd
                    ),
                    bindingID: UUID(),
                    runtimeBound: candidate.activeSessionID != nil,
                    at: candidate.runtimeBindingStartedAt ?? Date()
                )
                listChanged = true
            } else {
                projectionStore.updateDescriptor(
                    candidate.conversationID,
                    descriptor: RemoteConversationProjectionStore.ConversationDescriptor(
                        provider: candidate.provider,
                        title: candidate.title,
                        placement: candidate.placement,
                        cwd: candidate.cwd
                    )
                )
            }

            let previousActiveSessionID = activeSessionIDByConversationID[candidate.conversationID]
            if previousActiveSessionID != candidate.activeSessionID {
                bootstrappedPromptAuthorityByConversationID.removeValue(
                    forKey: candidate.conversationID
                )
            }
            if let activeSessionID = candidate.activeSessionID {
                if previousActiveSessionID != activeSessionID {
                    let reason: ConversationBindingChangeReason =
                        previousActiveSessionID == nil && isNewRegistration
                            ? .runtimeBound
                            : .runtimeResumed
                    let emitted = projectionStore.noteBinding(
                        for: candidate.conversationID,
                        reason: reason,
                        providerSessionFilePath: candidate.transcriptPath,
                        clearsProviderSessionFilePath: candidate.transcriptPath == nil,
                        bindingID: UUID(),
                        at: candidate.runtimeBindingStartedAt ?? Date()
                    )
                    broadcastEvents(emitted, for: candidate.conversationID)
                    activeSessionIDByConversationID[candidate.conversationID] = activeSessionID
                    listChanged = true
                } else if let rolloutPath = candidate.transcriptPath,
                          let projector = projectionStore.projectorState(for: candidate.conversationID),
                          projector.providerSessionFilePath != rolloutPath {
                    // The runtime was already known before its provider file.
                    // Attach the now-authoritative file binding without
                    // replacing the projector or its run/generation.
                    let reason: ConversationBindingChangeReason =
                        projector.providerSessionFilePath == nil ? .runtimeBound : .runtimeResumed
                    let emitted = projectionStore.noteBinding(
                        for: candidate.conversationID,
                        reason: reason,
                        providerSessionFilePath: rolloutPath,
                        bindingID: UUID(),
                        at: candidate.runtimeBindingStartedAt ?? Date()
                    )
                    broadcastEvents(emitted, for: candidate.conversationID)
                    listChanged = true
                }
            } else if previousActiveSessionID != nil {
                let emitted = projectionStore.noteBinding(
                    for: candidate.conversationID,
                    reason: .runtimeEnded,
                    clearsProviderSessionFilePath: candidate.transcriptPath == nil,
                    bindingID: UUID(),
                    at: Date()
                )
                broadcastEvents(emitted, for: candidate.conversationID)
                activeSessionIDByConversationID[candidate.conversationID] = nil
                listChanged = true
            }

            if let rolloutPath = candidate.transcriptPath {
                ensureTailer(for: candidate.conversationID, provider: candidate.provider, path: rolloutPath)
            } else if invalidateTranscriptBinding(
                for: candidate.conversationID,
                runtimeBound: candidate.activeSessionID != nil
            ) {
                listChanged = true
            }

            if syncProviderFeed(candidate) {
                listChanged = true
            }

            // SessionEnd retires Cursor's root identity while its terminal
            // process can remain alive (for example after /clear).
            if candidate.provider == .cursor,
               candidate.nativeBindingConfirmation == nil,
               let projector = projectionStore.projectorState(for: candidate.conversationID),
               case .openPrompt = projector.inputAvailability {
                let emitted = projectionStore.noteBinding(
                    for: candidate.conversationID,
                    reason: .runtimeResumed,
                    clearsProviderSessionFilePath: true,
                    bindingID: UUID(),
                    at: candidate.updatedAt
                )
                broadcastEvents(emitted, for: candidate.conversationID)
                listChanged = listChanged || !emitted.isEmpty
            }

            // Maintain the panel↔conversation maps used by send delivery and
            // the local-input hook.
            if panelIDByConversationID[candidate.conversationID] != candidate.panelID {
                if let previousPanelID = panelIDByConversationID[candidate.conversationID] {
                    if conversationIDByPanelID[previousPanelID] == candidate.conversationID {
                        conversationIDByPanelID[previousPanelID] = nil
                    }
                }
                if let previousConversationID = conversationIDByPanelID[candidate.panelID],
                   previousConversationID != candidate.conversationID,
                   panelIDByConversationID[previousConversationID] == candidate.panelID {
                    panelIDByConversationID[previousConversationID] = nil
                }
                panelIDByConversationID[candidate.conversationID] = candidate.panelID
                conversationIDByPanelID[candidate.panelID] = candidate.conversationID
            }

            if let authority = bootstrappedPromptAuthorityByConversationID[
                candidate.conversationID
            ],
               let unavailableReason = Self.bootstrapInvalidationReason(
                for: candidate.registryState
               ) {
                let emitted = projectionStore.invalidateConfirmedOpenPrompt(
                    for: candidate.conversationID,
                    expectedEpoch: authority.inputEpoch,
                    state: candidate.registryState,
                    reason: unavailableReason,
                    at: candidate.updatedAt
                )
                if emitted.isEmpty == false {
                    // Close the provisional prompt as soon as the native
                    // runtime reports a non-ready state; send-time checks
                    // remain a final race guard rather than the primary UI.
                    syncCoordinatorAvailability(for: candidate.conversationID)
                    broadcastEvents(emitted, for: candidate.conversationID)
                    listChanged = true
                }
            }

            if candidate.provider != .cursor,
               let activeSessionID = candidate.activeSessionID,
               let confirmation = candidate.nativeBindingConfirmation,
               candidate.registryState == .ready,
               confirmation.managedSessionID == activeSessionID,
               sessionRuntimeStore.isNativeSessionBindingInputClean(confirmation) {
                let emitted = projectionStore.bootstrapConfirmedOpenPrompt(
                    for: candidate.conversationID,
                    at: confirmation.confirmedAt
                )
                if emitted.isEmpty == false,
                   let projector = projectionStore.projectorState(for: candidate.conversationID),
                   case .openPrompt(let epoch) = projector.inputAvailability {
                    bootstrappedPromptAuthorityByConversationID[candidate.conversationID] =
                        BootstrappedPromptAuthority(
                            managedSessionID: activeSessionID,
                            confirmation: confirmation,
                            inputEpoch: epoch
                        )
                    // Publish coordinator authority before clients receive the
                    // status event that exposes this prompt epoch.
                    syncCoordinatorAvailability(for: candidate.conversationID)
                    broadcastEvents(emitted, for: candidate.conversationID)
                    listChanged = true
                }
            }

            // Keep the coordinator's authoritative availability in step with
            // the projection so the session list and send gate agree.
            syncCoordinatorAvailability(for: candidate.conversationID)

            if let projector = projectionStore.projectorState(for: candidate.conversationID) {
                expireStaleQueueEntries(for: candidate.conversationID, bindingID: projector.bindingID)
            }
        }

        // Conversations whose panels disappeared or whose current runtime can
        // no longer provide a supported transcript must lose every live
        // binding. In particular, no old open-prompt epoch may survive behind
        // a registry-derived read-only row.
        let trackedConversationIDs = Set(tailersByConversationID.keys)
            .union(activeSessionIDByConversationID.keys)
            .union(panelIDByConversationID.keys)
            .union(pendingSendCorrelator.conversationIDs)
            .union(sendQueue.conversationIDs)
            .union(projectionStore.registeredConversationIDs)
        for conversationID in trackedConversationIDs where seenConversationIDs.contains(conversationID) == false {
            removeConversationState(conversationID)
            listChanged = true
        }

        // Deliver queued messages only now, after bindings, panel maps, and
        // availability are settled for every conversation.
        drainSendQueues()

        if broadcast, listChanged || candidates.isEmpty == false {
            broadcastSessionList()
        }
    }

    /// Pushes the projector's authoritative availability into the coordinator.
    /// The coordinator preserves a local draft against a stale republish, so
    /// this is safe to call on every sync.
    private func syncCoordinatorAvailability(for conversationID: RemoteConversationID) {
        guard let projector = projectionStore.projectorState(for: conversationID) else { return }
        defer {
            // The coordinator only tracks a turn once it knows the
            // conversation, which `setProviderAvailability` below guarantees.
            coordinator.setTurnEpoch(projector.turnEpoch, for: conversationID)
        }
        if let authority = bootstrappedPromptAuthorityByConversationID[conversationID] {
            guard case .openPrompt(let epoch) = projector.inputAvailability,
                  epoch == authority.inputEpoch else {
                bootstrappedPromptAuthorityByConversationID.removeValue(forKey: conversationID)
                let previous = coordinator.availability(for: conversationID)
                coordinator.setProviderAvailability(projector.inputAvailability, for: conversationID)
                logCoordinatorAvailabilityTransition(
                    for: conversationID,
                    source: "provider_projection",
                    previous: previous
                )
                return
            }
        }
        let previous = coordinator.availability(for: conversationID)
        coordinator.setProviderAvailability(projector.inputAvailability, for: conversationID)
        logCoordinatorAvailabilityTransition(
            for: conversationID,
            source: "provider_projection",
            previous: previous
        )
    }

    /// Claude's completion hook precedes the terminal composer's final reset.
    /// Delay only the prompt-open authority; transcript content and ready state
    /// remain current while the compose bar stays fail-closed.
    private func refreshPromptStabilization(for conversationID: RemoteConversationID) {
        let token = projectionStore.projectorState(for: conversationID)?
            .pendingPromptStabilizationToken
        if let existing = promptStabilizationWorkByConversationID[conversationID],
           existing.token == token {
            return
        }

        promptStabilizationWorkByConversationID
            .removeValue(forKey: conversationID)?
            .task.cancel()
        guard let token else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.claudePromptStabilizationDelay)
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  self.isTracking,
                  self.promptStabilizationWorkByConversationID[conversationID]?.token == token else {
                return
            }
            self.promptStabilizationWorkByConversationID.removeValue(forKey: conversationID)
            let emitted = self.projectionStore.completePromptStabilization(
                for: conversationID,
                token: token,
                at: Date()
            )
            guard emitted.isEmpty == false else { return }
            self.syncCoordinatorAvailability(for: conversationID)
            self.broadcastEvents(emitted, for: conversationID)
            self.drainSendQueue(for: conversationID)
            ToasttyLog.debug(
                "Remote prompt stabilization completed",
                category: .automation,
                metadata: [
                    "conversation_id": conversationID.rawValue.uuidString,
                ]
            )
        }
        promptStabilizationWorkByConversationID[conversationID] = PromptStabilizationWork(
            token: token,
            task: task
        )
    }

    private func logCoordinatorAvailabilityTransition(
        for conversationID: RemoteConversationID,
        source: String,
        previous: RemoteInputAvailability
    ) {
        let current = coordinator.availability(for: conversationID)
        guard current != previous else { return }
        ToasttyLog.info(
            "Remote input availability changed",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "source": source,
                "previous": Self.availabilityLogLabel(previous),
                "current": Self.availabilityLogLabel(current),
            ]
        )
    }

    private static func availabilityLogLabel(_ availability: RemoteInputAvailability) -> String {
        switch availability {
        case .unavailable(let reason):
            "unavailable:\(reason.rawValue)"
        case .openPrompt(let epoch):
            "open_prompt:\(epoch.bindingID.uuidString):\(epoch.counter)"
        case .pendingInteraction(let interactionIDs):
            "pending_interaction:\(interactionIDs.count)"
        case .localDraft(let epoch):
            "local_draft:\(epoch.bindingID.uuidString):\(epoch.counter)"
        }
    }

    static func conversationPlacements(
        in state: AppState, activePanels: Set<UUID>
    ) -> [UUID: RemoteConversationPlacement] {
        var placements: [UUID: RemoteConversationPlacement] = [:]
        for workspace in state.workspacesByID.values {
            for (panelID, panel) in workspace.allPanelsByID {
                guard case .terminal(let terminal) = panel,
                      activePanels.contains(panelID) || terminal.remoteConversationID != nil
                        || terminal.resumeRecord != nil,
                      let tabID = workspace.tabID(containingPanelID: panelID)
                        ?? workspace.rightAuxPanelTabLocation(containingPanelID: panelID)?.mainTabID,
                      let tab = workspace.tab(id: tabID) else { continue }
                placements[panelID] = RemoteConversationPlacement(
                    workspaceID: workspace.id, workspaceTitle: workspace.title, panelID: panelID,
                    workspaceTabID: tab.id, workspaceTabTitle: tab.displayTitle
                )
            }
        }
        return placements
    }

    func scanConversationCandidates(mintingIDs: Bool) -> [ConversationCandidate] {
        let registry = sessionRuntimeStore.sessionRegistry
        var candidates: [ConversationCandidate] = []
        let requestedPanels = localPanelIDs.union(taskPanelIDs).union(retainedPanelIDs)
        var seenPanelIDs: Set<UUID> = []

        for workspace in store.state.workspacesByID.values {
            for (panelID, panelState) in workspace.allPanelsByID {
                guard case .terminal(let terminalState) = panelState else { continue }
                guard remoteTrackingEnabled || requestedPanels.contains(panelID) else { continue }

                if taskPanelIDs.contains(panelID), let taskID = workspace.taskID, let record = terminalState.resumeRecord {
                    taskTranscriptSources[panelID] = TaskTranscriptSource(taskID: taskID, resumeRecord: record)
                }
                let retainedSource = taskPanelIDs.contains(panelID) ? taskTranscriptSources[panelID] : nil
                let savedTaskRecord = retainedSource.flatMap { $0.taskID == workspace.taskID ? $0.resumeRecord : nil }
                let resumeRecord = terminalState.resumeRecord ?? savedTaskRecord
                let activeSessionID = registry.activeSessionIDByPanelID[panelID]
                let activeRecord = activeSessionID.flatMap { registry.sessionsByID[$0] }
                // Use the same projected panel status as Toastty's desktop UI.
                // Looking at the raw active record here would miss projection
                // such as child activity, stopped ready/error sessions, and
                // focus-driven idle transitions.
                let panelStatus = sessionRuntimeStore.panelStatus(for: panelID)
                guard let tabID = workspace.tabID(containingPanelID: panelID)
                    ?? workspace.rightAuxPanelTabLocation(containingPanelID: panelID)?.mainTabID,
                      let workspaceTab = workspace.tab(id: tabID) else {
                    continue
                }
                let isUnread = workspaceTab.unreadPanelIDs.contains(panelID)
                let hasLiveAgent = activeRecord.map { $0.isActive && $0.agent != .processWatch } ?? false
                let restorableProvider = resumeRecord?.agent
                let restorableFeed = resumeRecord.flatMap { resumeRecord in
                    sessionRuntimeStore.providerConversationFeed(
                        provider: resumeRecord.agent,
                        nativeSessionID: resumeRecord.nativeSessionID
                    )
                }
                let hasRestorableTranscript = terminalState.remoteConversationID != nil
                    && (
                        restorableProvider.map(ProviderTranscriptSupport.hasFileTranscript) == true
                            || restorableFeed != nil
                    )
                guard hasLiveAgent || hasRestorableTranscript else { continue }
                guard seenPanelIDs.insert(panelID).inserted else { continue }

                let conversationID: RemoteConversationID
                if let existing = terminalState.remoteConversationID {
                    conversationID = existing
                } else if mintingIDs {
                    let minted = RemoteConversationID()
                    guard store.send(.updateTerminalPanelRemoteConversationID(
                        panelID: panelID,
                        remoteConversationID: minted
                    )) else {
                        continue
                    }
                    conversationID = minted
                } else {
                    continue
                }

                let provider: AgentKind
                if hasLiveAgent, let activeRecord {
                    provider = activeRecord.agent
                } else if let restorableProvider {
                    provider = restorableProvider
                } else {
                    continue
                }
                // Both Codex rollout files and Claude transcript files are
                // recorded as the resume record's sessionFilePath.
                let transcriptPath = ProviderTranscriptSupport.hasFileTranscript(provider)
                    && resumeRecord?.agent == provider
                    ? resumeRecord?.sessionFilePath
                    : nil
                let providerFeed = activeSessionID.flatMap {
                    sessionRuntimeStore.providerConversationFeed(managedSessionID: $0)
                } ?? restorableFeed
                let nativeBindingConfirmation: ManagedNativeSessionBindingConfirmation? =
                    activeRecord.flatMap { record in
                        guard ProviderTranscriptSupport.isManagedProvider(record.agent),
                              let confirmation = sessionRuntimeStore.nativeSessionBindingConfirmation(
                                  for: record.sessionID
                              ),
                              confirmation.agent == record.agent,
                              confirmation.panelID == panelID else { return nil }
                        // Cursor's hooks confirm a launch-scoped identity. It
                        // has no file transcript or persisted resume contract.
                        if record.agent == .cursor {
                            return providerFeed?.nativeSessionID == confirmation.nativeSessionID
                                ? confirmation : nil
                        }
                        guard let resumeRecord,
                              confirmation.nativeSessionID == resumeRecord.nativeSessionID,
                              confirmation.sessionFilePath == resumeRecord.sessionFilePath else {
                            return nil
                        }
                        return confirmation
                    }

                candidates.append(ConversationCandidate(
                    conversationID: conversationID,
                    provider: provider,
                    // Same precedence as the sidebar row, so a provider's
                    // generated name reaches remote clients too.
                    title: activeRecord?.displayTitleOverride
                        ?? activeRecord?.providerSessionName
                        ?? terminalState.displayPanelLabel,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    workspaceTabID: workspaceTab.id,
                    workspaceTabTitle: workspaceTab.displayTitle,
                    panelID: panelID,
                    cwd: activeRecord?.cwd ?? resumeRecord?.cwd,
                    activeSessionID: hasLiveAgent ? activeSessionID : nil,
                    runtimeBindingStartedAt: hasLiveAgent ? activeRecord?.startedAt : nil,
                    registryState: activeRecord.flatMap { record in
                        record.status.map { Self.remoteState(for: $0.kind) }
                    } ?? (hasLiveAgent ? .starting : .offline),
                    presentationStatus: panelStatus.map {
                        Self.remotePresentationStatus(
                            for: $0.status.kind,
                            isUnread: isUnread
                        )
                    },
                    isUnread: isUnread,
                    statusDetail: Self.remoteStatusDetail(from: panelStatus?.status.detail),
                    isFlaggedForLater: hasLiveAgent
                        && activeSessionID.map(sessionRuntimeStore.isLaterFlagged(sessionID:)) == true,
                    turnStartedAt: panelStatus?.turnStartedAt,
                    lastTurnDuration: panelStatus?.lastTurnDuration,
                    waiting: panelStatus?.projection.isWaitingOnChildren == true
                        ? panelStatus?.waitingSummary
                        : nil,
                    updatedAt: max(
                        activeRecord?.updatedAt ?? resumeRecord?.capturedAt ?? .distantPast,
                        providerFeed?.updatedAt ?? .distantPast
                    ),
                    transcriptPath: transcriptPath,
                    providerFeed: providerFeed,
                    nativeBindingConfirmation: nativeBindingConfirmation
                ))
            }
        }

        return candidates.sorted { lhs, rhs in
            (lhs.workspaceTitle, lhs.title, lhs.conversationID.rawValue.uuidString)
                < (rhs.workspaceTitle, rhs.title, rhs.conversationID.rawValue.uuidString)
        }
    }

    private func removeConversationState(_ conversationID: RemoteConversationID) {
        defer { scheduleDemandReconciliation() }
        promptStabilizationWorkByConversationID.removeValue(forKey: conversationID)?.task.cancel()
        cancelPendingSendConfirmations(for: conversationID)
        if isTracking, projectionStore.isConversationRegistered(conversationID) {
            emit(.resnapshotRequired(conversationID: conversationID))
        }
        tailersByConversationID.removeValue(forKey: conversationID)?.stop()
        projectionStore.removeConversation(conversationID)
        coordinator.removeConversation(conversationID)
        controlCPromptEpochByConversationID.removeValue(forKey: conversationID)
        activeSessionIDByConversationID.removeValue(forKey: conversationID)
        bootstrappedPromptAuthorityByConversationID.removeValue(forKey: conversationID)
        providerFeedIdentityByConversationID.removeValue(forKey: conversationID)
        providerFeedLastFingerprintByConversationID.removeValue(forKey: conversationID)
        pendingSendCorrelator.discard(for: conversationID)
        discardQueuedEntries(sendQueue.removeAll(for: conversationID))
        sendQueue.removeConversation(conversationID)
        if let panelID = panelIDByConversationID.removeValue(forKey: conversationID),
           conversationIDByPanelID[panelID] == conversationID {
            conversationIDByPanelID.removeValue(forKey: panelID)
        }

    }

    func buildConversationSummaries() -> [RemoteConversationSummary] {
        scanConversationCandidates(mintingIDs: false).map { candidate in
            // Codex conversations with a live projection report
            // transcript-derived state; everything else stays
            // presentation-derived and read-only.
            if let projector = projectionStore.projectorState(for: candidate.conversationID) {
                // Availability comes from the coordinator, which merges the
                // projector's provider transitions with local-draft
                // invalidation. The remote facade applies its write policy;
                // local input remains independent of that setting.
                let availability = coordinator.availability(for: candidate.conversationID)
                return RemoteConversationSummary(
                    conversationID: candidate.conversationID,
                    provider: candidate.provider,
                    title: candidate.title,
                    placement: candidate.placement,
                    cwd: candidate.cwd,
                    executionProfile: projector.executionProfile,
                    state: projector.state,
                    presentationStatus: candidate.presentationStatus,
                    statusDetail: candidate.statusDetail,
                    inputAvailability: availability,
                    pendingInteractionPreview: RemotePendingInteractionPreviewFormatter.make(
                        from: projectionStore.pendingInteractions(for: candidate.conversationID)
                    ),
                    isFlaggedForLater: candidate.isFlaggedForLater,
                    turnStartedAt: candidate.turnStartedAt,
                    lastTurnDuration: candidate.lastTurnDuration,
                    waiting: candidate.waiting,
                    inputControl: inputControl(for: candidate),
                    projectionGeneration: projector.generation,
                    latestSequence: projector.latestSequence,
                    updatedAt: max(projector.updatedAt, candidate.updatedAt)
                )
            }
            return RemoteConversationSummary(
                conversationID: candidate.conversationID,
                provider: candidate.provider,
                title: candidate.title,
                placement: candidate.placement,
                cwd: candidate.cwd,
                state: candidate.registryState,
                presentationStatus: candidate.presentationStatus,
                statusDetail: candidate.statusDetail,
                inputAvailability: .unavailable(reason: .unknownProviderState),
                isFlaggedForLater: candidate.isFlaggedForLater,
                turnStartedAt: candidate.turnStartedAt,
                lastTurnDuration: candidate.lastTurnDuration,
                waiting: candidate.waiting,
                latestSequence: 0,
                updatedAt: candidate.updatedAt
            )
        }
    }

    private static func remoteState(for kind: SessionStatusKind) -> RemoteSessionState {
        switch kind {
        case .idle, .ready:
            return .ready
        case .working:
            return .working
        case .needsApproval:
            return .awaitingInput
        case .error:
            return .error
        }
    }

    private static func bootstrapInvalidationReason(
        for state: RemoteSessionState
    ) -> RemoteInputUnavailableReason? {
        switch state {
        case .ready:
            nil
        case .starting:
            .starting
        case .working:
            .working
        case .awaitingInput:
            .unknownProviderState
        case .interrupted:
            .interrupted
        case .ended:
            .ended
        case .error:
            .error
        case .offline:
            .offline
        }
    }

    nonisolated static func remotePresentationStatus(
        for kind: SessionStatusKind,
        isUnread: Bool
    ) -> RemoteSessionPresentationStatus {
        switch kind {
        case .idle:
            return .idle
        case .working:
            return .working
        case .needsApproval:
            return .needsApproval
        case .ready:
            return isUnread ? .ready : .idle
        case .error:
            return .error
        }
    }

    /// Reads the exact desktop detail source and passes it through the shared
    /// wire normalization used by every summary producer.
    nonisolated static func remoteStatusDetail(from detail: String?) -> String? {
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RemoteConversationSummary.normalizedStatusDetail(trimmed)
    }

    // MARK: - Transcript tailers

    /// Replays a bounded launch-scoped provider snapshot into the same
    /// projector used by native transcript files. A new snapshot ID denotes
    /// an unreconcilable branch/rewrite and therefore starts a new generation.
    @discardableResult
    private func syncProviderFeed(_ candidate: ConversationCandidate) -> Bool {
        guard let feed = candidate.providerFeed,
              feed.provider == candidate.provider else {
            providerFeedIdentityByConversationID.removeValue(forKey: candidate.conversationID)
            providerFeedLastFingerprintByConversationID.removeValue(forKey: candidate.conversationID)
            return false
        }
        let identity = ProviderFeedIdentity(
            provider: feed.provider,
            nativeSessionID: feed.nativeSessionID,
            snapshotID: feed.snapshotID
        )
        let previousIdentity = providerFeedIdentityByConversationID[candidate.conversationID]
        let previousFingerprint = providerFeedLastFingerprintByConversationID[candidate.conversationID]
        let previousObservationIndex = previousFingerprint.flatMap { fingerprint in
            feed.observations.lastIndex { $0.fingerprint == fingerprint }
        }
        let feedWasRewritten = previousIdentity == identity
            && previousFingerprint != nil
            && previousObservationIndex == nil
        var changed = false
        if let previousIdentity, previousIdentity != identity || feedWasRewritten {
            discardPendingSendCorrelation(for: candidate.conversationID)
            projectionStore.forceResnapshot(
                for: candidate.conversationID,
                bindingID: UUID(),
                at: feed.updatedAt
            )
            emit(.resnapshotRequired(conversationID: candidate.conversationID))
            if let tailer = tailersByConversationID.removeValue(forKey: candidate.conversationID) {
                let path = tailer.fileURL.path
                let provider = tailer.provider
                tailer.stop()
                startTailer(for: candidate.conversationID, provider: provider, path: path)
            }
            changed = true
        }
        providerFeedIdentityByConversationID[candidate.conversationID] = identity

        let bindingIsAuthoritative = candidate.activeSessionID != nil
            && candidate.nativeBindingConfirmation?.nativeSessionID == feed.nativeSessionID
            && candidate.nativeBindingConfirmation?.agent == feed.provider
        let observationsToIngest: ArraySlice<ProviderTranscriptObservation>
        if previousIdentity == identity,
           feedWasRewritten == false,
           let previousObservationIndex {
            observationsToIngest = feed.observations.suffix(from: previousObservationIndex + 1)
        } else {
            observationsToIngest = feed.observations[...]
        }
        let observations = observationsToIngest.map { observation in
            guard observation.mayAuthorizeCurrentRuntime && bindingIsAuthoritative == false else {
                return observation
            }
            var historical = observation
            historical.mayAuthorizeCurrentRuntime = false
            return historical
        }
        let stamped = stampPendingSends(observations, for: candidate.conversationID)
        let emitted = projectionStore.ingest(stamped, for: candidate.conversationID)
        // Provider feeds are bounded snapshots and only their new suffix is
        // parsed here, so extracting links on the main actor stays cheap.
        projectionStore.noteLinkedFileReferences(
            RemoteConversationProjectionStore.linkedFileReferences(in: observations),
            for: candidate.conversationID)
        refreshPromptStabilization(for: candidate.conversationID)
        syncCoordinatorAvailability(for: candidate.conversationID)
        broadcastEvents(emitted, for: candidate.conversationID)
        if let lastFingerprint = feed.observations.last?.fingerprint {
            providerFeedLastFingerprintByConversationID[candidate.conversationID] = lastFingerprint
        } else {
            providerFeedLastFingerprintByConversationID.removeValue(forKey: candidate.conversationID)
        }
        return changed || emitted.isEmpty == false
    }

    private func ensureTailer(for conversationID: RemoteConversationID, provider: AgentKind, path: String) {
        if let existing = tailersByConversationID[conversationID] {
            if existing.fileURL.path == path {
                return
            }
            existing.stop()
            tailersByConversationID[conversationID] = nil
        }
        startTailer(for: conversationID, provider: provider, path: path)
    }

    /// A nil path is authoritative: stop watching the previous file and, for
    /// a live runtime, mint a fresh binding epoch so stale transcript state
    /// cannot continue authorizing remote input while metadata is absent.
    @discardableResult
    private func invalidateTranscriptBinding(
        for conversationID: RemoteConversationID,
        runtimeBound: Bool
    ) -> Bool {
        tailersByConversationID.removeValue(forKey: conversationID)?.stop()

        guard let projector = projectionStore.projectorState(for: conversationID),
              projector.providerSessionFilePath != nil else {
            return false
        }
        // A hook feed normally has no file. Only losing an actual file
        // binding invalidates pending sends; a routine feed sync does not.
        discardPendingSendCorrelation(for: conversationID)
        if runtimeBound {
            let emitted = projectionStore.noteBinding(
                for: conversationID,
                reason: .runtimeResumed,
                clearsProviderSessionFilePath: true,
                bindingID: UUID(),
                at: Date()
            )
            broadcastEvents(emitted, for: conversationID)
        } else {
            projectionStore.clearProviderSessionFilePath(for: conversationID)
        }
        return true
    }

    private func startTailer(for conversationID: RemoteConversationID, provider: AgentKind, path: String) {
        guard ProviderTranscriptSupport.hasFileTranscript(provider) else { return }
        // Every fresh tailer replays from byte zero. Discard correlation before
        // constructing it so historical same-text input cannot confirm a send
        // accepted against the previous file/tailer lifetime.
        discardPendingSendCorrelation(for: conversationID)
        let generation = conversationTrackingGeneration
        let tailer = RemoteTranscriptTailer(
            conversationID: conversationID,
            fileURL: URL(filePath: path),
            provider: provider,
            makeParser: {
                guard let parser = ProviderTranscriptSupport.makeParser(for: provider) else {
                    preconditionFailure("file transcript provider is missing a parser")
                }
                return parser
            }
        ) { [weak self] conversationID, event in
            self?.handleTailerEvent(conversationID, event, generation: generation)
        }
        tailersByConversationID[conversationID] = tailer
        tailer.start()
    }

    private func handleTailerEvent(
        _ conversationID: RemoteConversationID,
        _ event: RemoteTranscriptTailer.Event,
        generation: UInt64
    ) {
        // A detached tailer can deliver one final callback after cancellation.
        // Once the kill switch is off — or a later activation has begun — it
        // must not rebuild projection state from the previous transcript.
        guard isTracking, generation == conversationTrackingGeneration else { return }
        switch event {
        case .observations(let observations, let linkedFileReferences):
            // Stamp the confirming user message for any pending remote send
            // before it enters the projection, so the sending device can tell
            // its own send apart from another device's identical text.
            let stamped = stampPendingSends(observations, for: conversationID)
            let previousProfile = projectionStore.projectorState(for: conversationID)?.executionProfile
            let emitted = projectionStore.ingest(stamped, for: conversationID)
            projectionStore.noteLinkedFileReferences(linkedFileReferences, for: conversationID)
            refreshPromptStabilization(for: conversationID)
            // A newly ingested transcript can open the prompt; keep the
            // coordinator in step before broadcasting.
            syncCoordinatorAvailability(for: conversationID)
            // Profile reports have no transcript sequence or lifecycle event.
            // Publish them through the session list even when nothing else
            // changed, so an in-session model switch reaches subscribers.
            broadcastEvents(
                emitted,
                for: conversationID,
                sessionListChanged: previousProfile != projectionStore.projectorState(for: conversationID)?.executionProfile
            )
            drainSendQueue(for: conversationID)

        case .fileReplaced:
            // Unreconcilable rewrite: discard this conversation's sequence
            // space and re-read the file from the start under a fresh
            // generation. Discard delivery correlation before any early exit;
            // `startTailer` defensively repeats this for every replay path.
            discardPendingSendCorrelation(for: conversationID)
            guard let tailer = tailersByConversationID[conversationID] else { return }
            let path = tailer.fileURL.path
            let provider = tailer.provider
            tailer.stop()
            tailersByConversationID[conversationID] = nil
            projectionStore.forceResnapshot(for: conversationID, bindingID: UUID(), at: Date())
            if isTracking {
                emit(.resnapshotRequired(conversationID: conversationID))
            }
            startTailer(for: conversationID, provider: provider, path: path)
            broadcastSessionList()
        }
    }

    // MARK: - Broadcasting

    private func broadcastEvents(
        _ events: [ConversationEvent],
        for conversationID: RemoteConversationID,
        sessionListChanged: Bool = false
    ) {
        guard isTracking, let projector = projectionStore.projectorState(for: conversationID) else {
            return
        }
        if !events.isEmpty {
            emit(.conversationEvents(ConversationEventPage(
                conversationID: conversationID,
                projectionRunID: projectionStore.runID,
                projectionGeneration: projector.generation,
                events: events,
                latestSequence: projector.latestSequence,
                firstAvailableSequence: projector.firstAvailableSequence,
                historyTruncated: projector.firstAvailableSequence > 1
            )))
        }
        // Status-bearing events change the list rows too.
        if sessionListChanged || events.contains(where: { $0.kind == .statusChanged || $0.kind == .sessionBindingChanged }) {
            broadcastSessionList()
        }
    }

    func performQuestionAnswer(_ request: RemoteQuestionAnswerRequest, source: ConversationInputSource) -> RemoteQuestionAnswerResult {
        guard authorization(for: source, conversationID: request.conversationID).canSend else { return .rejected(reason: .sendScopeDenied) }
        guard authorization(for: source, conversationID: request.conversationID).writesEnabled else { return .rejected(reason: .sessionWritesDisabled) }
        guard isTracking,
              let panelID = panelIDByConversationID[request.conversationID],
              let sessionID = activeSessionIDByConversationID[request.conversationID] else {
            return .rejected(reason: .notBound)
        }
        guard let interaction = projectionStore.pendingInteractions(for: request.conversationID)
            .first(where: { $0.id == request.interactionID }) else { return .rejected(reason: .notPending) }
        guard interaction.inputEpoch == request.expectedInputEpoch else { return .rejected(reason: .epochMismatch) }
        guard interaction.responseID == request.responseID else { return .rejected(reason: .notPending) }
        if interaction.kind == .permission, authorization(for: source, conversationID: request.conversationID).canApprovePermissions == false {
            return .rejected(reason: .approvalsDisabled)
        }
        return sessionRuntimeStore.submitClaudeQuestion(request, sessionID: sessionID, panelID: panelID)
    }

    // MARK: - Gated free-form send

    private func performAttachmentSend(_ request: RemoteMessageSendRequest, source: ConversationInputSource) async -> RemoteMessageSendResult {
        if coordinator.hasProcessed(request.clientRequestID, for: request.conversationID) { return .duplicate }
        let initialAuthorization = authorization(for: source, conversationID: request.conversationID)
        guard initialAuthorization.canSend, initialAuthorization.canSendAttachments else { return .rejected(reason: .sendScopeDenied) }
        let staged: RemoteMessageAttachmentStore.Staged
        do { staged = try await attachmentStore.stage(request.attachments) }
        catch RemoteMessageAttachmentStore.StorageError.invalidAttachments { return .rejected(reason: .invalidAttachments) }
        catch { return .rejected(reason: .attachmentStorageUnavailable) }
        let result: RemoteMessageSendResult
        // Staging suspends. Re-read authorization and every input gate only
        // after it completes. performRemoteSend checks write policy, binding,
        // surface and epoch synchronously before evaluate/deliver/mark.
        let currentAuthorization = authorization(for: source, conversationID: request.conversationID)
        if !Task.isCancelled, currentAuthorization.canSend, currentAuthorization.canSendAttachments {
            result = performRemoteSend(request, source: source, deliveredText: staged.deliveryText(for: request), staged: staged)
        } else { result = .rejected(reason: .sendScopeDenied) }
        switch result {
        case .accepted, .uncertain, .queued: break
        case .rejected, .duplicate: await attachmentStore.discard(staged)
        }
        return result
    }

    private func deliveryContext(
        for conversationID: RemoteConversationID,
        panelID: UUID,
        source: ConversationInputSource,
        acceptedRequestID: String? = nil
    ) -> RemoteInputCoordinator.DeliveryContext {
        let promptState = terminalRuntimeRegistry.promptState(panelID: panelID)
        // A managed agent TUI commonly reports `.busy` even when its own
        // provider lifecycle says the composer is open. Provider availability
        // remains authoritative; this check only rejects a missing or exited
        // surface.
        return RemoteInputCoordinator.DeliveryContext(
            deviceHasSendScope: authorization(for: source, conversationID: conversationID, acceptedRequestID: acceptedRequestID).canSend,
            sessionWritesEnabled: authorization(for: source, conversationID: conversationID, acceptedRequestID: acceptedRequestID).writesEnabled,
            isBoundToLiveSurface: activeSessionIDByConversationID[conversationID] != nil,
            isSurfaceReadyForInput: promptState != .unavailable && promptState != .exited
        )
    }

    // MARK: - Queue, steer, and stop

    /// Holds a message on the Mac for the next open prompt. Accepted whenever
    /// the conversation could accept a live send later; the open-prompt gate
    /// runs at delivery time, not here.
    private func enqueueRemoteSend(
        _ request: RemoteMessageSendRequest,
        source: ConversationInputSource,
        staged: RemoteMessageAttachmentStore.Staged?
    ) -> RemoteMessageSendResult {
        let conversationID = request.conversationID
        guard isTracking,
              let panelID = panelIDByConversationID[conversationID],
              let projector = projectionStore.projectorState(for: conversationID) else {
            return .rejected(reason: .notBound)
        }
        if coordinator.hasProcessed(request.clientRequestID, for: conversationID) {
            return .duplicate
        }
        let context = deliveryContext(for: conversationID, panelID: panelID, source: source)
        if let rejection = RemoteInputCoordinator.commonRejection(for: request, context: context) {
            return .rejected(reason: rejection)
        }
        // The phone queued against the runtime it saw. A different binding
        // means a resumed or relaunched agent; the client must re-read state.
        guard request.expectedInputEpoch.bindingID == projector.bindingID else {
            return .rejected(reason: .turnMismatch)
        }
        let entry = RemoteSendQueue.Entry(
            request: request,
            source: source,
            bindingID: projector.bindingID,
            deliveredText: staged?.deliveryText(for: request),
            enqueuedAt: Date()
        )
        let result: RemoteMessageSendResult
        switch sendQueue.enqueue(entry) {
        case .queued(let position):
            if let staged { stagedAttachmentsByQueuedRequestID[request.clientRequestID] = staged }
            result = .queued(position: position)
        case .duplicate:
            result = .duplicate
        case .full:
            result = .rejected(reason: .queueFull)
        }
        ToasttyLog.info(
            "Remote send queued",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "client_request_id": request.clientRequestID,
                "result": String(describing: result),
                "queue_depth": String(sendQueue.entries(for: conversationID).count),
            ]
        )
        if case .queued = result {
            broadcastSessionList()
            // The prompt may already be open (the turn ended while the phone
            // still showed it working); deliver without waiting for a sync.
            drainSendQueue(for: conversationID)
        }
        return result
    }

    /// Types a message into the running turn. Same terminal path as a prompt
    /// send; the turn gate replaces the open-prompt gate.
    private func performRemoteSteer(
        _ request: RemoteMessageSendRequest,
        source: ConversationInputSource,
        deliveredText: String?
    ) -> RemoteMessageSendResult {
        let conversationID = request.conversationID
        guard isTracking,
              let panelID = panelIDByConversationID[conversationID],
              let projector = projectionStore.projectorState(for: conversationID) else {
            return .rejected(reason: .notBound)
        }
        guard Self.steerCapableProviders.contains(projector.provider) else {
            return .rejected(reason: .steerUnavailable)
        }
        let context = deliveryContext(for: conversationID, panelID: panelID, source: source)
        switch coordinator.evaluateSteer(request, context: context) {
        case .duplicate:
            return .duplicate
        case .reject(let reason):
            return .rejected(reason: reason)
        case .accept(let turnEpoch):
            recordRemoteInput(panelID: panelID)
            let delivery = terminalRuntimeRegistry.sendRemoteText(
                deliveredText ?? request.text,
                submit: true,
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            )
            switch delivery {
            case .unavailable:
                return .rejected(reason: .surfaceUnavailable)
            case .uncertain:
                coordinator.markSteerUncertain(request)
                recordPendingSend(request, for: conversationID, source: source, deliveredText: deliveredText, confirmationTimeout: steerConfirmationTimeout, deliveryMode: .steer)
                broadcastSessionList()
                return .uncertain
            case .delivered:
                coordinator.markSteerDelivered(request)
                recordPendingSend(request, for: conversationID, source: source, deliveredText: deliveredText, confirmationTimeout: steerConfirmationTimeout, deliveryMode: .steer)
                ToasttyLog.info(
                    "Remote steer delivered",
                    category: .automation,
                    metadata: [
                        "conversation_id": conversationID.rawValue.uuidString,
                        "client_request_id": request.clientRequestID,
                    ]
                )
                broadcastSessionList()
                return .accepted(epoch: turnEpoch)
            }
        }
    }

    func performQueueUpdate(
        _ request: RemoteConversationQueueUpdateRequest,
        source: ConversationInputSource
    ) -> RemoteConversationQueueUpdateResult {
        let conversationID = request.conversationID
        guard isTracking, authorization(for: source, conversationID: conversationID).canSend,
              authorization(for: source, conversationID: conversationID).writesEnabled,
              panelIDByConversationID[conversationID] != nil else {
            return .conversationNotFound
        }
        let result: RemoteConversationQueueUpdateResult
        switch request.action {
        case .remove:
            if let clientRequestID = request.clientRequestID,
               let removed = sendQueue.remove(clientRequestID: clientRequestID, for: conversationID) {
                discardQueuedEntries([removed])
                // Every device that queued or saw it learns it will not be
                // typed; the removing device also drops its own record.
                noteQueuedSendDropped(removed, for: conversationID)
                result = .updated
            } else {
                result = .unchanged
            }
        case .resume:
            result = sendQueue.resume(conversationID) ? .updated : .unchanged
        }
        ToasttyLog.info(
            "Remote queue update evaluated",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "action": request.action.rawValue,
                "result": result.rawValue,
            ]
        )
        if result == .updated {
            broadcastSessionList()
            if request.action == .resume { drainSendQueue(for: conversationID) }
        }
        return result
    }

    /// Sends the provider's interrupt key for the turn the client names and
    /// holds the queue, so nothing starts a new turn right after the stop.
    func performRemoteInterrupt(
        _ request: RemoteConversationInterruptRequest,
        source: ConversationInputSource
    ) -> RemoteConversationInterruptResult {
        let conversationID = request.conversationID
        guard isTracking, let panelID = panelIDByConversationID[conversationID] else {
            return .rejected(reason: .notBound)
        }
        let context = deliveryContext(for: conversationID, panelID: panelID, source: source)
        let result: RemoteConversationInterruptResult
        switch coordinator.evaluateInterrupt(
            for: conversationID,
            expectedTurnEpoch: request.expectedTurnEpoch,
            context: context
        ) {
        case .reject(let reason):
            result = .rejected(reason: reason)
        case .accept:
            recordRemoteInput(panelID: panelID)
            let delivery = terminalRuntimeRegistry.sendRemoteInterrupt(
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            )
            if delivery == .delivered {
                sendQueue.pause(conversationID)
                // Direct surface input bypasses the local key callback. Pause
                // queued sends before the shared status can become idle.
                _ = sessionRuntimeStore.handleLocalInterruptForPanelIfActive(
                    panelID: panelID,
                    kind: .escape,
                    at: Date()
                )
                result = .accepted
            } else {
                result = .rejected(reason: .surfaceUnavailable)
            }
        }
        ToasttyLog.info(
            "Remote interrupt evaluated",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "result": String(describing: result),
            ]
        )
        if result == .accepted {
            broadcastSessionList()
        }
        return result
    }

    /// Reopens a prompt that a Mac draft holds closed, after the remote user
    /// says the Mac composer is empty. Sends nothing to the terminal.
    func performLocalDraftRelease(
        _ request: RemoteConversationLocalDraftReleaseRequest,
        source: ConversationInputSource
    ) -> RemoteConversationLocalDraftReleaseResult {
        let conversationID = request.conversationID
        guard isTracking, let panelID = panelIDByConversationID[conversationID] else {
            return .rejected(reason: .notBound)
        }
        // Apply any provider transition the debounced sync has not pushed yet,
        // so a draft the agent already received is not reopened.
        syncCoordinatorAvailability(for: conversationID)
        let previous = coordinator.availability(for: conversationID)
        let result: RemoteConversationLocalDraftReleaseResult
        switch coordinator.releaseLocalDraft(
            for: conversationID,
            expectedDraftEpoch: request.expectedDraftEpoch,
            context: deliveryContext(for: conversationID, panelID: panelID, source: source)
        ) {
        case .reject(let reason):
            result = .rejected(reason: reason)
        case .released:
            // A prompt bootstrapped from native ownership checks the session
            // store's own local-input mark at send time.
            sessionRuntimeStore.clearLocalInputForActiveSession(panelID: panelID)
            result = .released
        }
        logCoordinatorAvailabilityTransition(
            for: conversationID,
            source: "remote_draft_release",
            previous: previous
        )
        ToasttyLog.info(
            "Remote local draft release evaluated",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "result": String(describing: result),
            ]
        )
        switch result {
        case .released:
            broadcastSessionList()
            drainSendQueue(for: conversationID)
        case .rejected(.draftChanged), .rejected(.noLocalDraft):
            // The client acted on a stale view; send it the current one now
            // rather than after the next keystroke throttle.
            broadcastSessionList()
        case .rejected:
            break
        }
        return result
    }

    private func drainSendQueues() {
        for conversationID in sendQueue.conversationIDs {
            drainSendQueue(for: conversationID)
        }
    }

    /// Delivers the next queued entry when, and only when, the coordinator
    /// reports an open prompt. One entry per open prompt: delivery consumes
    /// the prompt, and the rest wait for the turn it starts to end.
    private func drainSendQueue(for conversationID: RemoteConversationID) {
        guard isTracking, let entry = sendQueue.next(for: conversationID) else { return }
        guard case .openPrompt(let epoch) = coordinator.availability(for: conversationID) else { return }
        guard entry.bindingID == epoch.bindingID else {
            expireStaleQueueEntries(for: conversationID, bindingID: epoch.bindingID)
            return
        }
        guard authorization(for: entry.source, conversationID: conversationID, acceptedRequestID: entry.clientRequestID).canSend else {
            // The device lost send access since it queued the message.
            if let removed = sendQueue.remove(clientRequestID: entry.clientRequestID, for: conversationID) {
                discardQueuedEntries([removed])
            }
            logQueueDelivery(entry, for: conversationID, outcome: "device_send_denied")
            noteQueuedSendDropped(entry, for: conversationID)
            broadcastSessionList()
            drainSendQueue(for: conversationID)
            return
        }
        var request = entry.request
        request.deliveryMode = .prompt
        request.expectedInputEpoch = epoch
        let result = performRemoteSend(
            request,
            source: entry.source,
            deliveredText: entry.deliveredText,
            recordedDeliveryMode: .queue
        )
        let dropsEntry: Bool
        switch result {
        case .accepted, .uncertain, .duplicate:
            dropsEntry = true
        case .queued:
            // Unreachable: the drained request is a prompt send.
            dropsEntry = false
        case .rejected(let reason):
            switch reason {
            case .sendScopeDenied, .sessionWritesDisabled, .emptyText, .invalidAttachments,
                 .attachmentStorageUnavailable, .queueFull, .notWorking, .turnMismatch, .steerUnavailable:
                // Nothing a later prompt would change.
                dropsEntry = true
            case .notBound, .surfaceUnavailable, .promptNotOpen, .epochMismatch,
                 .localDraftPresent, .pendingInteraction:
                dropsEntry = false
            }
        }
        logQueueDelivery(entry, for: conversationID, outcome: String(describing: result))
        if dropsEntry {
            defer { scheduleDemandReconciliation() }
            if let removed = sendQueue.remove(clientRequestID: entry.clientRequestID, for: conversationID) {
                // A delivered entry's staged files are now the agent's to read;
                // only the bookkeeping entry is released here.
                stagedAttachmentsByQueuedRequestID.removeValue(forKey: removed.clientRequestID)
            }
            if case .rejected = result {
                noteQueuedSendDropped(entry, for: conversationID)
            }
            broadcastSessionList()
        }
    }

    /// Tells the queuing client that its message left the queue without being
    /// typed, through the same journal receipt a lost echo produces, so the
    /// phone never waits forever on a message the Mac will not deliver.
    private func noteQueuedSendDropped(
        _ entry: RemoteSendQueue.Entry,
        for conversationID: RemoteConversationID
    ) {
        let emitted = projectionStore.noteSendDeliveryUnconfirmed(
            for: conversationID,
            clientRequestID: entry.clientRequestID,
            at: Date()
        )
        broadcastEvents(emitted, for: conversationID)
    }

    /// Drops entries queued against a binding other than the current one.
    private func expireStaleQueueEntries(for conversationID: RemoteConversationID, bindingID: UUID) {
        let stale = sendQueue.removeAll(for: conversationID, notMatchingBindingID: bindingID)
        guard stale.isEmpty == false else { return }
        discardQueuedEntries(stale)
        for entry in stale {
            logQueueDelivery(entry, for: conversationID, outcome: "expired_binding_changed")
            noteQueuedSendDropped(entry, for: conversationID)
        }
        broadcastSessionList()
    }

    private func discardQueuedEntries(_ entries: [RemoteSendQueue.Entry]) {
        if !entries.isEmpty { scheduleDemandReconciliation() }
        for entry in entries {
            guard let staged = stagedAttachmentsByQueuedRequestID.removeValue(forKey: entry.clientRequestID) else { continue }
            Task { [attachmentStore] in await attachmentStore.discard(staged) }
        }
    }

    private func logQueueDelivery(
        _ entry: RemoteSendQueue.Entry,
        for conversationID: RemoteConversationID,
        outcome: String
    ) {
        ToasttyLog.info(
            "Remote queued send evaluated",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "client_request_id": entry.clientRequestID,
                "outcome": outcome,
                "queue_depth": String(sendQueue.entries(for: conversationID).count),
            ]
        )
    }

    private func inputControl(for candidate: ConversationCandidate) -> RemoteConversationInputControl {
        let conversationID = candidate.conversationID
        let turnEpoch = coordinator.turnEpoch(for: conversationID)
        let acceptsWrites = activeSessionIDByConversationID[conversationID] != nil
        let queue = sendQueue.inputControlQueue(for: conversationID)
        return RemoteConversationInputControl(
            turnEpoch: turnEpoch,
            canQueue: acceptsWrites,
            canSteer: acceptsWrites
                && turnEpoch != nil
                && Self.steerCapableProviders.contains(candidate.provider)
                && coordinator.canSteer(for: conversationID),
            canInterrupt: acceptsWrites && turnEpoch != nil,
            queuedMessages: queue.queuedMessages,
            isQueuePaused: queue.isPaused
        )
    }

    /// Performs a remote send synchronously on the main actor. The gate check
    /// and terminal delivery share this one call, so no epoch can change
    /// between `evaluate` and `markDelivered`.
    func performRemoteSend(
        _ request: RemoteMessageSendRequest,
        source: ConversationInputSource,
        deliveredText: String? = nil,
        staged: RemoteMessageAttachmentStore.Staged? = nil,
        recordedDeliveryMode: RemoteMessageDeliveryMode = .prompt
    ) -> RemoteMessageSendResult {
        guard request.attachments.isEmpty || deliveredText != nil else {
            return .rejected(reason: .invalidAttachments)
        }
        switch request.deliveryMode {
        case .prompt:
            break
        case .queue:
            return enqueueRemoteSend(request, source: source, staged: staged)
        case .steer:
            return performRemoteSteer(request, source: source, deliveredText: deliveredText)
        }
        guard isTracking else {
            return .rejected(reason: .notBound)
        }
        let conversationID = request.conversationID
        guard let panelID = panelIDByConversationID[conversationID] else {
            return .rejected(reason: .notBound)
        }
        if let rejection = bootstrappedAuthorityRejection(
            for: request,
            panelID: panelID
        ) {
            return .rejected(reason: rejection)
        }
        let context = deliveryContext(
            for: conversationID, panelID: panelID, source: source,
            acceptedRequestID: recordedDeliveryMode == .queue ? request.clientRequestID : nil
        )

        switch coordinator.evaluate(request, context: context) {
        case .duplicate:
            return .duplicate

        case .reject(let reason):
            return .rejected(reason: reason)

        case .accept(let epoch):
            // Deliver through the same automation path as terminal.send-text:
            // paste-oriented text plus a real Return key, which preserves
            // Ghostty bracketed-paste semantics for multi-line input and does
            // not steal the local first responder.
            recordRemoteInput(panelID: panelID)
            let delivery = terminalRuntimeRegistry.sendRemoteText(
                deliveredText ?? request.text,
                submit: true,
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            )
            switch delivery {
            case .unavailable:
                return .rejected(reason: .surfaceUnavailable)
            case .uncertain:
                let previous = coordinator.availability(for: conversationID)
                coordinator.markUncertain(request)
                logCoordinatorAvailabilityTransition(
                    for: conversationID,
                    source: "remote_delivery_uncertain",
                    previous: previous
                )
                recordPendingSend(request, for: conversationID, source: source, deliveredText: deliveredText, deliveryMode: recordedDeliveryMode)
                broadcastSessionList()
                return .uncertain
            case .delivered:
                let previous = coordinator.availability(for: conversationID)
                coordinator.markDelivered(request)
                logCoordinatorAvailabilityTransition(
                    for: conversationID,
                    source: "remote_delivery",
                    previous: previous
                )
                recordPendingSend(request, for: conversationID, source: source, deliveredText: deliveredText, deliveryMode: recordedDeliveryMode)
                broadcastSessionList()
                return .accepted(epoch: epoch)
            }
        }
    }

    /// Transcript observations normally provide send authority. A prompt
    /// opened from current-launch native ownership needs its own last-moment
    /// checks because the desktop may have changed after the phone rendered
    /// the epoch but before this request reached the host.
    private func bootstrappedAuthorityRejection(
        for request: RemoteMessageSendRequest,
        panelID: UUID
    ) -> RemoteMessageRejectionReason? {
        let conversationID = request.conversationID
        guard let authority = bootstrappedPromptAuthorityByConversationID[conversationID],
              authority.inputEpoch == request.expectedInputEpoch else {
            return nil
        }
        guard activeSessionIDByConversationID[conversationID] == authority.managedSessionID,
              let activeSession = sessionRuntimeStore.sessionRegistry.activeSession(
                  sessionID: authority.managedSessionID
              ),
              activeSession.panelID == panelID,
              activeSession.agent == authority.confirmation.agent,
              sessionRuntimeStore.nativeSessionBindingConfirmation(
                  for: authority.managedSessionID
              ) == authority.confirmation else {
            return .notBound
        }
        guard let statusKind = activeSession.status?.kind,
              statusKind == .idle || statusKind == .ready else {
            return .promptNotOpen
        }
        guard sessionRuntimeStore.isNativeSessionBindingInputClean(
            authority.confirmation
        ) else {
            return .localDraftPresent
        }
        guard let projector = projectionStore.projectorState(for: conversationID),
              projector.inputAvailability == .openPrompt(epoch: authority.inputEpoch) else {
            return .promptNotOpen
        }
        return nil
    }

    /// Records a local keyboard/paste/menu event on a panel so the coordinator
    /// invalidates any open remote epoch synchronously. The resulting network
    /// update is coalesced onto a later main-actor turn so summary construction
    /// and JSON encoding never run inside the terminal input call stack.
    @discardableResult
    func noteLocalInput(panelID: UUID, kind: TerminalLocalInputKind = .key) -> Bool {
        let conversationID = conversationIDByPanelID[panelID]
        // Only the first unbound Ctrl+C at a provider prompt can be ignored.
        // Another press may exit the agent. Remember presses in a draft too,
        // and do not reset this on Release (it does not send an agent key).
        if kind == .controlC, let conversationID,
           let projector = projectionStore.projectorState(for: conversationID),
           projector.provider == .claude,
           case .openPrompt(let epoch) = projector.inputAvailability {
            let alreadyPressed = controlCPromptEpochByConversationID[conversationID] == epoch
            controlCPromptEpochByConversationID[conversationID] = epoch
            if !alreadyPressed, case .openPrompt = coordinator.availability(for: conversationID) {
                sessionRuntimeStore.acknowledgePresentedProgramStatusResults(panelID: panelID)
                ToasttyLog.info("First Ctrl+C left the open prompt unchanged", category: .automation, metadata: [
                    "conversation_id": conversationID.rawValue.uuidString,
                ])
                return false
            }
        }
        // Record this here as well as through the registry's lifecycle tracker
        // so direct adapter callbacks share the same fail-closed contract.
        // The store uses an idempotent set.
        sessionRuntimeStore.noteLocalInputForActiveSession(panelID: panelID)
        guard let conversationID else { return true }
        promptStabilizationWorkByConversationID
            .removeValue(forKey: conversationID)?
            .task.cancel()
        _ = projectionStore.cancelPromptStabilization(for: conversationID)
        let previous = coordinator.availability(for: conversationID)
        let couldSteer = coordinator.canSteer(for: conversationID)
        coordinator.noteLocalInput(for: conversationID)
        if case .localDraft = previous {
            // Each keystroke in a draft advances its epoch; publish it
            // throttled and skip the per-keystroke transition log.
            scheduleLocalDraftEpochBroadcast()
        } else {
            logCoordinatorAvailabilityTransition(
                for: conversationID,
                source: "local_terminal_input:\(kind.rawValue)",
                previous: previous
            )
        }
        if couldSteer && !coordinator.canSteer(for: conversationID) {
            ToasttyLog.info("Local input marked the running turn", category: .automation, metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "source": kind.rawValue,
            ])
        }
        if previous.allowsRemoteSend || couldSteer != coordinator.canSteer(for: conversationID) {
            scheduleSessionListBroadcast()
        }
        return true
    }

    /// Each keystroke in a Mac draft advances its epoch, and a remote release
    /// must name the current one. Publish the epoch at most once per interval
    /// rather than once per keystroke; the trailing publish always carries the
    /// epoch after the last keystroke.
    private func scheduleLocalDraftEpochBroadcast() {
        guard isTracking, localDraftEpochBroadcastTask == nil else { return }
        localDraftEpochBroadcastTask = Task { @MainActor [weak self] in
            guard let interval = self?.localDraftEpochBroadcastInterval else { return }
            try? await Task.sleep(for: interval)
            guard let self, Task.isCancelled == false else { return }
            self.localDraftEpochBroadcastTask = nil
            guard self.isTracking else { return }
            self.broadcastSessionList()
        }
    }

    private func scheduleSessionListBroadcast() {
        guard isTracking, sessionListBroadcastTask == nil else { return }
        sessionListBroadcastTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, Task.isCancelled == false else { return }
            self.sessionListBroadcastTask = nil
            guard self.isTracking else { return }
            self.broadcastSessionList()
        }
    }

    private func recordPendingSend(
        _ request: RemoteMessageSendRequest,
        for conversationID: RemoteConversationID,
        source: ConversationInputSource,
        deliveredText: String? = nil,
        confirmationTimeout: Duration? = nil,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) {
        precondition(request.conversationID == conversationID)
        let confirmationTimeout = confirmationTimeout ?? sendConfirmationTimeout
        pendingSendCorrelator.record(
            request, deliveredText: deliveredText,
            origin: source == .local ? .local : .remote, deliveryMode: deliveryMode
        )
        let clientRequestID = request.clientRequestID
        let key = PendingSendConfirmationKey(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        )
        pendingSendConfirmationWork.removeValue(forKey: key)?.task.cancel()
        let acceptedAt = Date()
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: confirmationTimeout)
                guard Task.isCancelled == false else { return }
                if let extraWait = self?.codexTurnConfirmationExtension(for: key) {
                    try await Task.sleep(for: extraWait)
                    guard Task.isCancelled == false else { return }
                }
            } catch {
                return
            }
            self?.expireUnconfirmedSend(key, allowingLateEcho: true)
        }
        pendingSendConfirmationWork[key] = PendingSendConfirmationWork(
            acceptedAt: acceptedAt,
            task: task
        )
    }

    /// Returns how much longer to wait when the normal deadline passes while
    /// a Codex turn that started after the send is still running and the
    /// send can still match its user message.
    private func codexTurnConfirmationExtension(for key: PendingSendConfirmationKey) -> Duration? {
        guard isTracking,
              var work = pendingSendConfirmationWork[key],
              let turnID = work.runningCodexTurnID,
              pendingSendCorrelator.contains(clientRequestID: key.clientRequestID, for: key.conversationID) else {
            return nil
        }
        let remaining = codexTurnConfirmationTimeout - .seconds(Date().timeIntervalSince(work.acceptedAt))
        guard remaining > .zero else { return nil }
        work.isWaitingForCodexTurn = true
        pendingSendConfirmationWork[key] = work
        ToasttyLog.info(
            "Remote send confirmation is waiting for the started Codex turn",
            category: .automation,
            metadata: [
                "conversation_id": key.conversationID.rawValue.uuidString,
                "turn_id": turnID ?? "unknown",
            ]
        )
        return remaining
    }

    /// Reports the send unconfirmed. When only the deadline passed, a late
    /// echo may still confirm it.
    private func expireUnconfirmedSend(_ key: PendingSendConfirmationKey, allowingLateEcho: Bool) {
        defer { scheduleDemandReconciliation() }
        guard isTracking,
              let work = pendingSendConfirmationWork.removeValue(forKey: key) else {
            return
        }
        work.task.cancel()
        let conversationID = key.conversationID
        // Codex records a send's message within a turn, and a turn that ends
        // without it settles the send (see `trackCodexTurn`), so only other
        // providers keep an expired send matchable.
        if allowingLateEcho, projectionStore.projectorState(for: conversationID)?.provider != .codex {
            pendingSendCorrelator.expire(clientRequestID: key.clientRequestID, for: conversationID)
        } else {
            pendingSendCorrelator.discard(clientRequestID: key.clientRequestID, for: conversationID)
        }
        let emitted = projectionStore.noteSendDeliveryUnconfirmed(
            for: conversationID,
            clientRequestID: key.clientRequestID,
            at: Date()
        )
        guard emitted.isEmpty == false else { return }
        let latencyMs = max(0, Int(Date().timeIntervalSince(work.acceptedAt) * 1_000))
        ToasttyLog.warning(
            "Remote send was not confirmed by the provider transcript",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "latency_ms": String(latencyMs),
                "waited_for_codex_turn": String(work.isWaitingForCodexTurn),
            ]
        )
        broadcastEvents(emitted, for: conversationID)
    }

    /// Codex starts a turn before it records the turn's user message. Track a
    /// turn that starts after a pending send so the send's deadline can wait
    /// for it, and settle a send that was waiting once that turn ends without
    /// its message. Other providers report the turn start with or after the
    /// user message, so a missing message there is already a mismatch.
    private func trackCodexTurn(
        _ observation: ProviderTranscriptObservation,
        for conversationID: RemoteConversationID
    ) {
        guard observation.mayAuthorizeCurrentRuntime else { return }
        switch observation.payload {
        case .turnStarted(let turnID):
            // A start recorded before the send was delivered belongs to an
            // earlier turn. The margin covers the transcript's millisecond
            // timestamps and the delivery call itself.
            for (key, work) in pendingSendConfirmationWork
            where key.conversationID == conversationID
                && observation.timestamp >= work.acceptedAt.addingTimeInterval(-1) {
                pendingSendConfirmationWork[key]?.runningCodexTurnID = .some(turnID)
            }
        case .turnEnded(let endedTurnID, _):
            for (key, work) in pendingSendConfirmationWork where key.conversationID == conversationID {
                guard let runningTurnID = work.runningCodexTurnID else { continue }
                if let runningTurnID, let endedTurnID, runningTurnID != endedTurnID {
                    continue
                }
                if work.isWaitingForCodexTurn {
                    expireUnconfirmedSend(key, allowingLateEcho: false)
                } else {
                    pendingSendConfirmationWork[key]?.runningCodexTurnID = nil
                }
            }
        default:
            break
        }
    }

    /// A send waiting for a Codex turn can confirm only through its
    /// correlation entry. Once a different user message consumed it, or the
    /// transcript binding discarded it, settle the send now instead of at the
    /// turn's end or the time limit.
    private func expireCodexTurnWaitsWithoutCorrelation(for conversationID: RemoteConversationID) {
        for (key, work) in pendingSendConfirmationWork
        where key.conversationID == conversationID
            && work.isWaitingForCodexTurn
            && pendingSendCorrelator.contains(clientRequestID: key.clientRequestID, for: conversationID) == false {
            expireUnconfirmedSend(key, allowingLateEcho: false)
        }
    }

    private func discardPendingSendCorrelation(for conversationID: RemoteConversationID) {
        pendingSendCorrelator.discard(for: conversationID)
        expireCodexTurnWaitsWithoutCorrelation(for: conversationID)
    }

    /// Stamps the caller origin and clientRequestID onto the confirming user
    /// message for any pending send whose text matches, oldest first. Best
    /// effort: after a restart the pending map is gone and a rebuilt message
    /// reverts to origin=.unknown, which is acceptable runtime enrichment.
    private func stampPendingSends(
        _ observations: [ProviderTranscriptObservation],
        for conversationID: RemoteConversationID
    ) -> [ProviderTranscriptObservation] {
        if let sessionID = activeSessionIDByConversationID[conversationID],
           let panelID = panelIDByConversationID[conversationID] {
            sessionRuntimeStore.reconcileClaudeQuestionTranscript(observations, sessionID: sessionID, panelID: panelID)
        }
        let tracksCodexTurns = projectionStore.projectorState(for: conversationID)?.provider == .codex
        var stamped: [ProviderTranscriptObservation] = []
        stamped.reserveCapacity(observations.count)
        // One observation at a time, in transcript order: a Codex turn that
        // ends without the send must settle it before a later user message in
        // the same batch can match it.
        for observation in observations {
            let observation = pendingSendCorrelator.stamp([observation], for: conversationID)[0]
            stamped.append(observation)
            if case .transcript(.userMessage(let payload)) = observation.payload {
                var submittedOnMac = true
                if let clientRequestID = payload.clientRequestID {
                    let confirmedInTime = confirmPendingSend(
                        conversationID: conversationID,
                        clientRequestID: clientRequestID
                    )
                    // A late steer came from the provider's own input queue,
                    // so it says nothing about the Mac composer.
                    submittedOnMac = confirmedInTime == false && payload.deliveryMode != .steer
                }
                // The Mac user submitted what they typed, or a prompt send
                // confirmed after its deadline waited in the provider's prompt
                // until something, usually the Mac user's Return, submitted
                // it. The running turn no longer holds a local draft that a
                // steer or the next prompt must avoid.
                if submittedOnMac, observation.mayAuthorizeCurrentRuntime {
                    coordinator.noteLocalDraftSubmitted(for: conversationID)
                }
            }
            if tracksCodexTurns {
                trackCodexTurn(observation, for: conversationID)
            }
        }
        if tracksCodexTurns {
            expireCodexTurnWaitsWithoutCorrelation(for: conversationID)
        }
        return stamped
    }

    /// Returns whether the send was still within its deadline. A later
    /// confirmation corrects the earlier unconfirmed report on the phone.
    private func confirmPendingSend(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) -> Bool {
        defer { scheduleDemandReconciliation() }
        let key = PendingSendConfirmationKey(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        )
        guard let work = pendingSendConfirmationWork.removeValue(forKey: key) else {
            ToasttyLog.info(
                "Remote send confirmed by provider transcript after it was reported unconfirmed",
                category: .automation,
                metadata: ["conversation_id": conversationID.rawValue.uuidString]
            )
            return false
        }
        work.task.cancel()
        let latencyMs = max(0, Int(Date().timeIntervalSince(work.acceptedAt) * 1_000))
        ToasttyLog.info(
            "Remote send confirmed by provider transcript",
            category: .automation,
            metadata: [
                "conversation_id": conversationID.rawValue.uuidString,
                "latency_ms": String(latencyMs),
            ]
        )
        return true
    }

    private func cancelPendingSendConfirmations(for conversationID: RemoteConversationID) {
        let keys = pendingSendConfirmationWork.keys.filter {
            $0.conversationID == conversationID
        }
        for key in keys {
            pendingSendConfirmationWork.removeValue(forKey: key)?.task.cancel()
        }
    }

    // MARK: - Per-session write controls


}
extension ConversationService: SessionRemoteInputProbe {
    /// Phone input is rare, so each write also drops panels that are gone.
    private func recordRemoteInput(panelID: UUID) {
        lastRemoteInputAtByPanelID = lastRemoteInputAtByPanelID.filter {
            store.state.workspaceSelection(containingPanelID: $0.key) != nil
        }
        lastRemoteInputAtByPanelID[panelID] = Date()
    }

    func hasRemoteInput(panelID: UUID, since date: Date) -> Bool {
        if let deliveredAt = lastRemoteInputAtByPanelID[panelID], deliveredAt > date {
            return true
        }
        // A queued message waits for the next open prompt, and a delivered
        // one may still sit in the prompt until it is confirmed.
        return panelIDByConversationID.contains { conversationID, mappedPanelID in
            mappedPanelID == panelID
                && (sendQueue.entries(for: conversationID).isEmpty == false
                    || pendingSendCorrelator.conversationIDs.contains(conversationID))
        }
    }
}
