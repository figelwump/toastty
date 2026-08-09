import Combine
import CoreState
import Foundation

/// Facade handed to the gateway request handler. The gateway server is
/// main-actor bound, so every call arrives on the main actor; this bridge
/// makes that contract explicit and forwards into the service's isolated
/// state. `assumeIsolated` traps loudly if a future transport ever calls the
/// facade off the main actor.
final class RemoteAccessFacadeBridge: RemoteSessionFacade, @unchecked Sendable {
    weak var service: RemoteAccessService?

    func sessionList(at date: Date) -> RemoteSessionListSnapshot {
        MainActor.assumeIsolated {
            service?.facadeSessionList(at: date)
                ?? RemoteSessionListSnapshot(
                    projectionRunID: RemoteProjectionRunID(),
                    conversations: [],
                    generatedAt: date
                )
        }
    }

    func conversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        MainActor.assumeIsolated {
            service?.facadeConversationSnapshot(for: conversationID, at: date)
        }
    }

    func conversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        MainActor.assumeIsolated {
            service?.facadeConversationEvents(for: conversationID, after: cursor, limit: limit)
                ?? .conversationNotFound
        }
    }
}

/// Bridges the gateway's synchronous main-actor send call into the service.
final class RemoteAccessSendBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func send(_ request: RemoteMessageSendRequest, device: RemoteDeviceRecord) -> RemoteMessageSendResult {
        MainActor.assumeIsolated {
            service?.performRemoteSend(request, device: device) ?? .rejected(reason: .notBound)
        }
    }
}

enum RemoteAccessPreferences {
    static let defaultPort: UInt16 = 42871
    private static let enabledKey = "toastty.remoteAccess.enabled"
    private static let portKey = "toastty.remoteAccess.port"
    private static let tailnetOriginKey = "toastty.remoteAccess.tailnetOrigin"

    static func loadEnabled(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func persistEnabled(_ enabled: Bool, userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func loadPort(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> UInt16 {
        let stored = userDefaults.integer(forKey: portKey)
        guard stored > 0, stored <= UInt16.max, stored >= 1024 else { return defaultPort }
        return UInt16(stored)
    }

    static func loadTailnetOrigin(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> String? {
        let value = userDefaults.string(forKey: tailnetOriginKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, value.isEmpty == false else { return nil }
        return value
    }

    static func persistTailnetOrigin(_ origin: String?, userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        let trimmed = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            userDefaults.set(trimmed, forKey: tailnetOriginKey)
        } else {
            userDefaults.removeObject(forKey: tailnetOriginKey)
        }
    }

    // Per-session remote-write opt-in, keyed by durable conversation ID. Every
    // session starts read-only; a write must be enabled on the Mac.
    private static let writeEnabledConversationsKey = "toastty.remoteAccess.writeEnabledConversations"

    static func loadWriteEnabledConversations(userDefaults: UserDefaults = ToasttyAppDefaults.current) -> Set<String> {
        Set(userDefaults.stringArray(forKey: writeEnabledConversationsKey) ?? [])
    }

    static func persistWriteEnabledConversations(_ ids: Set<String>, userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        userDefaults.set(Array(ids).sorted(), forKey: writeEnabledConversationsKey)
    }
}

/// Long-lived host service composing the remote-access gateway: device store,
/// audit log, request handler, loopback listener, the session-registry
/// adapter, and — for Codex conversations — the live transcript projection
/// fed by rollout-file tailers.
@MainActor
final class RemoteAccessService: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var startupError: String?
    @Published private(set) var deviceManagementError: String?
    @Published private(set) var currentPairingCode: RemotePairingCode?
    @Published private(set) var devices: [RemoteDeviceRecord] = []
    @Published private(set) var connectedClientCount: Int = 0
    /// Durable conversation IDs (as strings) with remote writes enabled.
    @Published private(set) var writeEnabledConversationIDs: Set<String>
    /// Supported conversations shown by the per-session write controls.
    @Published private(set) var writeControllableSessions: [RemoteConversationSummary] = []
    @Published var tailnetOrigin: String {
        didSet {
            RemoteAccessPreferences.persistTailnetOrigin(tailnetOrigin)
            refreshHandlerConfiguration()
        }
    }

    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let deviceStore: RemoteDeviceStore
    private let auditLog: RemoteAccessAuditLog
    private let projectionStore = RemoteConversationProjectionStore()
    private let facadeBridge = RemoteAccessFacadeBridge()
    private let sendBridge = RemoteAccessSendBridge()
    private var coordinator = RemoteInputCoordinator()
    private let handler: RemoteGatewayRequestHandler
    private let server: RemoteAccessGatewayServer
    private let port: UInt16
    private var cancellables: Set<AnyCancellable> = []
    private var sessionListBroadcastTask: Task<Void, Never>?

    private var tailersByConversationID: [RemoteConversationID: RemoteTranscriptTailer] = [:]
    private var activeSessionIDByConversationID: [RemoteConversationID: String] = [:]
    private var panelIDByConversationID: [RemoteConversationID: UUID] = [:]
    private var conversationIDByPanelID: [UUID: RemoteConversationID] = [:]
    /// Pending remote sends awaiting their confirming user message in the
    /// projection, oldest first, keyed by conversation.
    private var pendingSendsByConversationID: [RemoteConversationID: [(clientRequestID: String, trimmedText: String)]] = [:]

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        runtimePaths: ToasttyRuntimePaths
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.port = RemoteAccessPreferences.loadPort()
        self.tailnetOrigin = RemoteAccessPreferences.loadTailnetOrigin() ?? ""
        self.writeEnabledConversationIDs = RemoteAccessPreferences.loadWriteEnabledConversations()
        self.deviceStore = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        self.auditLog = RemoteAccessAuditLog(fileURL: runtimePaths.remoteAccessAuditFileURL)
        self.handler = RemoteGatewayRequestHandler(
            deviceStore: deviceStore,
            auditLog: auditLog,
            facade: facadeBridge,
            configuration: RemoteGatewayConfiguration(allowedOrigins: []),
            sendHandler: { [sendBridge] request, device in
                sendBridge.send(request, device: device)
            }
        )
        self.server = RemoteAccessGatewayServer(handler: handler)
        self.devices = deviceStore.devices
        facadeBridge.service = self
        sendBridge.service = self
        handler.onDevicePaired = { [weak self] _ in
            guard let self else { return }
            self.currentPairingCode = nil
            self.deviceManagementError = nil
            self.refreshDevices()
        }

        // Observe local keyboard/paste input to invalidate open remote epochs.
        terminalRuntimeRegistry.localInputObserver = { [weak self] panelID in
            self?.noteLocalInput(panelID: panelID)
        }

        server.onWebSocketCountChanged = { [weak self] count in
            guard let self else { return }
            let previousCount = self.connectedClientCount
            self.connectedClientCount = count
            if count > previousCount {
                // A fresh subscriber gets the current snapshot immediately
                // instead of waiting for the next registry change.
                self.broadcastSessionList()
            }
        }

        sessionRuntimeStore.$sessionRegistry
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncConversations()
            }
            .store(in: &cancellables)

        // Resume-record and conversation-identity changes mutate panel state
        // without touching the session registry; without this observer a
        // rollout-path change would never restart the transcript tailer.
        store.addActionAppliedObserver { [weak self] action, _, _ in
            switch action {
            case .updateTerminalPanelResumeRecord, .updateTerminalPanelRemoteConversationID:
                self?.syncConversations()
            default:
                break
            }
        }

        refreshHandlerConfiguration()
        syncConversations(broadcast: false)
        if RemoteAccessPreferences.loadEnabled() {
            setEnabled(true, persist: false)
        }
    }

    // MARK: - Kill switch

    func setEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist {
            RemoteAccessPreferences.persistEnabled(enabled)
        }
        startupError = nil
        if enabled {
            syncConversations(broadcast: false)
            do {
                try server.start(port: port)
                isEnabled = true
                listeningPort = port
                auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessEnabled))
            } catch {
                isEnabled = false
                listeningPort = nil
                startupError = "Could not listen on 127.0.0.1:\(port): \(error.localizedDescription)"
                ToasttyLog.error(
                    "Remote access gateway failed to start",
                    category: .automation,
                    metadata: ["error": "\(error)", "port": "\(port)"]
                )
            }
        } else {
            sessionListBroadcastTask?.cancel()
            sessionListBroadcastTask = nil
            server.stop()
            isEnabled = false
            listeningPort = nil
            invalidatePairingCode()
            auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessDisabled))
        }
    }

    // MARK: - Pairing and devices

    func issuePairingCode() {
        let code = deviceStore.issuePairingCode(at: Date())
        currentPairingCode = code
        auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .pairingCodeIssued))
    }

    func invalidatePairingCode() {
        deviceStore.invalidatePairingCode()
        currentPairingCode = nil
    }

    func refreshDevices() {
        devices = deviceStore.devices
    }

    func revokeDevice(_ deviceID: UUID) {
        do {
            let didRevoke = try deviceStore.revokeDevice(deviceID, at: Date())
            // Sweep even when the durable record was already revoked. A retry
            // must still close any connection that survived an earlier app
            // interruption or best-effort transport teardown.
            server.disconnectWebSockets(for: deviceID)
            guard didRevoke else {
                deviceManagementError = nil
                return
            }
            auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .deviceRevoked, deviceID: deviceID))
            deviceManagementError = nil
            refreshDevices()
        } catch {
            reportDeviceManagementFailure("Could not revoke the device", error: error)
        }
    }

    func revokeAllDevices() {
        do {
            try deviceStore.revokeAllDevices(at: Date())
            server.disconnectAllWebSockets()
            auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .allDevicesRevoked))
            currentPairingCode = nil
            deviceManagementError = nil
            refreshDevices()
        } catch {
            reportDeviceManagementFailure("Could not revoke paired devices", error: error)
        }
    }

    func recentAuditEntries(limit: Int = 50) -> [RemoteAccessAuditEntry] {
        auditLog.recentEntries(limit: limit)
    }

    // MARK: - Facade surface (main-actor entry points for the bridge)

    func facadeSessionList(at date: Date) -> RemoteSessionListSnapshot {
        RemoteSessionListSnapshot(
            projectionRunID: projectionStore.runID,
            conversations: buildConversationSummaries(),
            generatedAt: date
        )
    }

    func facadeConversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        if let snapshot = projectionStore.conversationSnapshot(for: conversationID, at: date) {
            var snapshot = snapshot
            // The projection store has no descriptor context for placement
            // titles; overlay the registry-derived summary when available.
            if let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) {
                snapshot.summary = summary
            }
            return snapshot
        }
        guard let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) else {
            return nil
        }
        return RemoteConversationSnapshot(summary: summary, pendingInteractions: [])
    }

    func facadeConversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        projectionStore.conversationEvents(for: conversationID, after: cursor, limit: limit)
    }

    // MARK: - Conversation sync

    /// One row of the panel scan: a panel that currently represents (or last
    /// represented) a managed agent conversation.
    private struct ConversationCandidate {
        var conversationID: RemoteConversationID
        var provider: AgentKind
        var title: String
        var workspaceID: UUID
        var workspaceTitle: String
        var panelID: UUID
        var cwd: String?
        var activeSessionID: String?
        var registryState: RemoteSessionState
        var updatedAt: Date
        var transcriptPath: String?
    }

    private func syncConversations(broadcast: Bool = true) {
        let candidates = scanConversationCandidates(mintingIDs: true)
        var seenConversationIDs: Set<RemoteConversationID> = []
        var listChanged = false

        for candidate in candidates {
            guard ProviderTranscriptSupport.isSupported(candidate.provider),
                  let rolloutPath = candidate.transcriptPath else {
                // Providers without a transcript parser stay registry-derived.
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
                        placement: RemoteConversationPlacement(
                            workspaceID: candidate.workspaceID,
                            workspaceTitle: candidate.workspaceTitle,
                            panelID: candidate.panelID
                        ),
                        cwd: candidate.cwd
                    ),
                    bindingID: UUID(),
                    runtimeBound: false,
                    at: Date()
                )
                listChanged = true
            }

            let previousActiveSessionID = activeSessionIDByConversationID[candidate.conversationID]
            if let activeSessionID = candidate.activeSessionID {
                if previousActiveSessionID != activeSessionID {
                    // A runtime (newly or re-)bound to this conversation.
                    let reason: ConversationBindingChangeReason =
                        (previousActiveSessionID == nil && isNewRegistration == false) || previousActiveSessionID != nil
                            ? .runtimeResumed
                            : .runtimeBound
                    let emitted = projectionStore.noteBinding(
                        for: candidate.conversationID,
                        reason: reason,
                        providerSessionFilePath: rolloutPath,
                        bindingID: UUID(),
                        at: Date()
                    )
                    broadcastEvents(emitted, for: candidate.conversationID)
                    activeSessionIDByConversationID[candidate.conversationID] = activeSessionID
                    listChanged = true
                }
            } else if previousActiveSessionID != nil {
                let emitted = projectionStore.noteBinding(
                    for: candidate.conversationID,
                    reason: .runtimeEnded,
                    bindingID: UUID(),
                    at: Date()
                )
                broadcastEvents(emitted, for: candidate.conversationID)
                activeSessionIDByConversationID[candidate.conversationID] = nil
                listChanged = true
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
            // Keep the coordinator's authoritative availability in step with
            // the projection so the session list and send gate agree.
            syncCoordinatorAvailability(for: candidate.conversationID)

            ensureTailer(for: candidate.conversationID, provider: candidate.provider, path: rolloutPath)
        }

        // Conversations whose panels disappeared or whose current runtime can
        // no longer provide a supported transcript must lose every live
        // binding. In particular, no old open-prompt epoch may survive behind
        // a registry-derived read-only row.
        let trackedConversationIDs = Set(tailersByConversationID.keys)
            .union(activeSessionIDByConversationID.keys)
            .union(panelIDByConversationID.keys)
            .union(pendingSendsByConversationID.keys)
            .union(projectionStore.registeredConversationIDs)
        for conversationID in trackedConversationIDs where seenConversationIDs.contains(conversationID) == false {
            removeConversationState(conversationID)
            listChanged = true
        }

        let controllableSessions = buildConversationSummaries().filter {
            ProviderTranscriptSupport.isSupported($0.provider)
        }
        if writeControllableSessions != controllableSessions {
            writeControllableSessions = controllableSessions
        }

        if broadcast, listChanged || candidates.isEmpty == false {
            broadcastSessionList()
        }
    }

    /// Pushes the projector's authoritative availability into the coordinator.
    /// The coordinator preserves a local draft against a stale republish, so
    /// this is safe to call on every sync.
    private func syncCoordinatorAvailability(for conversationID: RemoteConversationID) {
        guard let projector = projectionStore.projectorState(for: conversationID) else { return }
        coordinator.setProviderAvailability(projector.inputAvailability, for: conversationID)
    }

    private func scanConversationCandidates(mintingIDs: Bool) -> [ConversationCandidate] {
        let registry = sessionRuntimeStore.sessionRegistry
        var candidates: [ConversationCandidate] = []
        var seenPanelIDs: Set<UUID> = []

        for workspace in store.state.workspacesByID.values {
            for (panelID, panelState) in workspace.panels {
                guard case .terminal(let terminalState) = panelState else { continue }

                let activeSessionID = registry.activeSessionIDByPanelID[panelID]
                let activeRecord = activeSessionID.flatMap { registry.sessionsByID[$0] }
                let hasLiveAgent = activeRecord.map { $0.isActive && $0.agent != .processWatch } ?? false
                let restorableProvider = terminalState.resumeRecord?.agent
                let hasRestorableTranscript = terminalState.remoteConversationID != nil
                    && restorableProvider.map(ProviderTranscriptSupport.isSupported) == true
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
                let transcriptPath = ProviderTranscriptSupport.isSupported(provider)
                    && terminalState.resumeRecord?.agent == provider
                    ? terminalState.resumeRecord?.sessionFilePath
                    : nil

                candidates.append(ConversationCandidate(
                    conversationID: conversationID,
                    provider: provider,
                    title: activeRecord?.displayTitleOverride ?? terminalState.displayPanelLabel,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    panelID: panelID,
                    cwd: activeRecord?.cwd ?? terminalState.resumeRecord?.cwd,
                    activeSessionID: hasLiveAgent ? activeSessionID : nil,
                    registryState: activeRecord.flatMap { record in
                        record.status.map { Self.remoteState(for: $0.kind) }
                    } ?? (hasLiveAgent ? .starting : .offline),
                    updatedAt: activeRecord?.updatedAt ?? terminalState.resumeRecord?.capturedAt ?? Date(),
                    transcriptPath: transcriptPath
                ))
            }
        }

        return candidates.sorted { lhs, rhs in
            (lhs.workspaceTitle, lhs.title, lhs.conversationID.rawValue.uuidString)
                < (rhs.workspaceTitle, rhs.title, rhs.conversationID.rawValue.uuidString)
        }
    }

    private func removeConversationState(_ conversationID: RemoteConversationID) {
        if isEnabled, projectionStore.isConversationRegistered(conversationID) {
            server.broadcast(.resnapshotRequired(conversationID: conversationID))
        }
        tailersByConversationID.removeValue(forKey: conversationID)?.stop()
        projectionStore.removeConversation(conversationID)
        coordinator.removeConversation(conversationID)
        activeSessionIDByConversationID.removeValue(forKey: conversationID)
        pendingSendsByConversationID.removeValue(forKey: conversationID)
        if let panelID = panelIDByConversationID.removeValue(forKey: conversationID),
           conversationIDByPanelID[panelID] == conversationID {
            conversationIDByPanelID.removeValue(forKey: panelID)
        }

        let rawID = conversationID.rawValue.uuidString
        if writeEnabledConversationIDs.remove(rawID) != nil {
            RemoteAccessPreferences.persistWriteEnabledConversations(writeEnabledConversationIDs)
        }
    }

    private func buildConversationSummaries() -> [RemoteConversationSummary] {
        scanConversationCandidates(mintingIDs: false).map { candidate in
            // Codex conversations with a live projection report
            // transcript-derived state; everything else stays
            // presentation-derived and read-only.
            if let projector = projectionStore.projectorState(for: candidate.conversationID) {
                // Availability comes from the coordinator, which merges the
                // projector's provider transitions with local-draft
                // invalidation and honors the per-session write opt-in — the
                // client's compose bar must never open when writes are off.
                let availability = writeEnabledConversationIDs.contains(candidate.conversationID.rawValue.uuidString)
                    ? coordinator.availability(for: candidate.conversationID)
                    : RemoteInputAvailability.unavailable(reason: .unknownProviderState)
                return RemoteConversationSummary(
                    conversationID: candidate.conversationID,
                    provider: candidate.provider,
                    title: candidate.title,
                    placement: RemoteConversationPlacement(
                        workspaceID: candidate.workspaceID,
                        workspaceTitle: candidate.workspaceTitle,
                        panelID: candidate.panelID
                    ),
                    cwd: candidate.cwd,
                    state: projector.state,
                    inputAvailability: availability,
                    projectionGeneration: projector.generation,
                    latestSequence: projector.latestSequence,
                    updatedAt: max(projector.updatedAt, candidate.updatedAt)
                )
            }
            return RemoteConversationSummary(
                conversationID: candidate.conversationID,
                provider: candidate.provider,
                title: candidate.title,
                placement: RemoteConversationPlacement(
                    workspaceID: candidate.workspaceID,
                    workspaceTitle: candidate.workspaceTitle,
                    panelID: candidate.panelID
                ),
                cwd: candidate.cwd,
                state: candidate.registryState,
                inputAvailability: .unavailable(reason: .unknownProviderState),
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

    // MARK: - Transcript tailers

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

    private func startTailer(for conversationID: RemoteConversationID, provider: AgentKind, path: String) {
        let tailer = RemoteTranscriptTailer(
            conversationID: conversationID,
            fileURL: URL(filePath: path),
            provider: provider,
            makeParser: {
                ProviderTranscriptSupport.makeParser(for: provider) ?? CodexRolloutTranscriptParser()
            }
        ) { [weak self] conversationID, event in
            self?.handleTailerEvent(conversationID, event)
        }
        tailersByConversationID[conversationID] = tailer
        tailer.start()
    }

    private func handleTailerEvent(_ conversationID: RemoteConversationID, _ event: RemoteTranscriptTailer.Event) {
        switch event {
        case .observations(let observations):
            // Stamp the confirming user message for any pending remote send
            // before it enters the projection, so the sending device can tell
            // its own send apart from another device's identical text.
            let stamped = stampPendingSends(observations, for: conversationID)
            let emitted = projectionStore.ingest(stamped, for: conversationID)
            // A newly ingested transcript can open the prompt; keep the
            // coordinator in step before broadcasting.
            syncCoordinatorAvailability(for: conversationID)
            broadcastEvents(emitted, for: conversationID)

        case .fileReplaced:
            // Unreconcilable rewrite: discard this conversation's sequence
            // space and re-read the file from the start under a fresh
            // generation.
            guard let tailer = tailersByConversationID[conversationID] else { return }
            let path = tailer.fileURL.path
            let provider = tailer.provider
            tailer.stop()
            tailersByConversationID[conversationID] = nil
            projectionStore.forceResnapshot(for: conversationID, bindingID: UUID(), at: Date())
            if isEnabled {
                server.broadcast(.resnapshotRequired(conversationID: conversationID))
            }
            startTailer(for: conversationID, provider: provider, path: path)
            broadcastSessionList()
        }
    }

    // MARK: - Broadcasting

    private func broadcastEvents(_ events: [ConversationEvent], for conversationID: RemoteConversationID) {
        guard events.isEmpty == false else { return }
        guard isEnabled, let projector = projectionStore.projectorState(for: conversationID) else {
            return
        }
        server.broadcast(.conversationEvents(ConversationEventPage(
            conversationID: conversationID,
            projectionRunID: projectionStore.runID,
            projectionGeneration: projector.generation,
            events: events,
            latestSequence: projector.latestSequence,
            firstAvailableSequence: projector.firstAvailableSequence,
            historyTruncated: projector.firstAvailableSequence > 1
        )))
        // Status-bearing events change the list rows too.
        if events.contains(where: { $0.kind == .statusChanged || $0.kind == .sessionBindingChanged }) {
            broadcastSessionList()
        }
    }

    private func broadcastSessionList() {
        guard isEnabled else { return }
        server.broadcast(.sessionList(facadeSessionList(at: Date())))
    }

    // MARK: - Gated free-form send

    /// Performs a remote send synchronously on the main actor. The gate check
    /// and terminal delivery share this one call, so no epoch can change
    /// between `evaluate` and `markDelivered`.
    func performRemoteSend(_ request: RemoteMessageSendRequest, device: RemoteDeviceRecord) -> RemoteMessageSendResult {
        let conversationID = request.conversationID
        guard let panelID = panelIDByConversationID[conversationID] else {
            return .rejected(reason: .notBound)
        }
        let sessionWritesEnabled = writeEnabledConversationIDs.contains(conversationID.rawValue.uuidString)
        let isBound = activeSessionIDByConversationID[conversationID] != nil
        let promptState = terminalRuntimeRegistry.promptState(panelID: panelID)
        // A managed agent TUI commonly reports `.busy` even when its own
        // provider lifecycle says the composer is open. Provider availability
        // remains authoritative; this check only rejects a missing or exited
        // surface.
        let surfaceReady = promptState != .unavailable && promptState != .exited

        let context = RemoteInputCoordinator.DeliveryContext(
            deviceHasSendScope: device.scopes.contains(.send),
            sessionWritesEnabled: sessionWritesEnabled,
            isBoundToLiveSurface: isBound,
            isSurfaceReadyForInput: surfaceReady
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
            let delivery = terminalRuntimeRegistry.sendRemoteText(
                request.text,
                submit: true,
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            )
            switch delivery {
            case .unavailable:
                return .rejected(reason: .surfaceUnavailable)
            case .uncertain:
                coordinator.markUncertain(request)
                recordPendingSend(request, for: conversationID)
                broadcastSessionList()
                return .uncertain
            case .delivered:
                coordinator.markDelivered(request)
                recordPendingSend(request, for: conversationID)
                broadcastSessionList()
                return .accepted(epoch: epoch)
            }
        }
    }

    /// Records a local keyboard/paste/menu event on a panel so the coordinator
    /// invalidates any open remote epoch synchronously. The resulting network
    /// update is coalesced onto a later main-actor turn so summary construction
    /// and JSON encoding never run inside the terminal input call stack.
    func noteLocalInput(panelID: UUID) {
        guard let conversationID = conversationIDByPanelID[panelID] else { return }
        let wasOpen = coordinator.availability(for: conversationID).allowsRemoteSend
        coordinator.noteLocalInput(for: conversationID)
        if wasOpen {
            scheduleSessionListBroadcast()
        }
    }

    private func scheduleSessionListBroadcast() {
        guard isEnabled, sessionListBroadcastTask == nil else { return }
        sessionListBroadcastTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, Task.isCancelled == false else { return }
            self.sessionListBroadcastTask = nil
            guard self.isEnabled else { return }
            self.broadcastSessionList()
        }
    }

    private func recordPendingSend(_ request: RemoteMessageSendRequest, for conversationID: RemoteConversationID) {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSendsByConversationID[conversationID, default: []].append((request.clientRequestID, trimmed))
        // Bound the pending list; a confirmation that never arrives must not
        // leak memory.
        if pendingSendsByConversationID[conversationID]!.count > 32 {
            pendingSendsByConversationID[conversationID]!.removeFirst()
        }
    }

    /// Stamps origin=.remote and the clientRequestID onto the confirming user
    /// message for any pending send whose text matches, oldest first. Best
    /// effort: after a restart the pending map is gone and a rebuilt message
    /// reverts to origin=.unknown, which is acceptable runtime enrichment.
    private func stampPendingSends(
        _ observations: [ProviderTranscriptObservation],
        for conversationID: RemoteConversationID
    ) -> [ProviderTranscriptObservation] {
        guard pendingSendsByConversationID[conversationID]?.isEmpty == false else {
            return observations
        }
        return observations.map { observation in
            guard case .transcript(.userMessage(let payload)) = observation.payload,
                  payload.origin == .unknown else {
                return observation
            }
            let trimmed = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Delivery and provider logs are ordered. Only the oldest pending
            // send can confirm against the next user message; if it does not
            // match, expire it rather than misattributing a later identical
            // local message.
            guard let pending = pendingSendsByConversationID[conversationID]?.first else {
                return observation
            }
            pendingSendsByConversationID[conversationID]?.removeFirst()
            guard pending.trimmedText == trimmed else { return observation }
            var stamped = observation
            stamped.payload = .transcript(.userMessage(ConversationUserMessagePayload(
                text: payload.text,
                origin: .remote,
                clientRequestID: pending.clientRequestID
            )))
            return stamped
        }
    }

    // MARK: - Per-session write controls

    func isSessionWriteEnabled(_ conversationID: RemoteConversationID) -> Bool {
        writeEnabledConversationIDs.contains(conversationID.rawValue.uuidString)
    }

    func setSessionWriteEnabled(_ enabled: Bool, for conversationID: RemoteConversationID) {
        let key = conversationID.rawValue.uuidString
        guard writeEnabledConversationIDs.contains(key) != enabled else { return }
        if enabled {
            writeEnabledConversationIDs.insert(key)
        } else {
            writeEnabledConversationIDs.remove(key)
        }
        RemoteAccessPreferences.persistWriteEnabledConversations(writeEnabledConversationIDs)
        auditLog.record(RemoteAccessAuditEntry(
            at: Date(),
            action: .sessionWritesChanged,
            detail: enabled ? "enabled" : "disabled"
        ))
        broadcastSessionList()
    }

    func setDeviceSendScope(_ enabled: Bool, for deviceID: UUID) {
        guard let device = deviceStore.devices.first(where: { $0.id == deviceID }),
              device.isRevoked == false else { return }
        var scopes = device.scopes
        if enabled {
            scopes.insert(.send)
        } else {
            scopes.remove(.send)
        }
        do {
            guard try deviceStore.setScopes(scopes, forDevice: deviceID) else { return }
        } catch {
            reportDeviceManagementFailure("Could not update device permissions", error: error)
            return
        }
        auditLog.record(RemoteAccessAuditEntry(
            at: Date(),
            action: .deviceScopesChanged,
            deviceID: deviceID,
            detail: enabled ? "send_enabled" : "send_disabled"
        ))
        deviceManagementError = nil
        refreshDevices()
    }

    private func reportDeviceManagementFailure(_ message: String, error: Error) {
        deviceManagementError = "\(message). Try again."
        ToasttyLog.error(
            message,
            category: .automation,
            metadata: ["error": "\(error)"]
        )
    }

    // MARK: - Configuration

    private func refreshHandlerConfiguration() {
        var origins: Set<String> = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)",
        ]
        if tailnetOrigin.isEmpty == false {
            var normalized = tailnetOrigin
            if normalized.hasSuffix("/") {
                normalized = String(normalized.dropLast())
            }
            if normalized.contains("://") == false {
                normalized = "https://" + normalized
            }
            origins.insert(normalized)
        }
        handler.updateConfiguration(RemoteGatewayConfiguration(
            allowedOrigins: origins,
            staticResources: Self.loadWebClientResources()
        ))
    }

    static func loadWebClientResources(bundle: Bundle = .main) -> [String: RemoteGatewayStaticResource] {
        guard let clientDirectory = bundle.resourceURL?
            .appending(path: "RemoteWebClient", directoryHint: .isDirectory) else {
            return [:]
        }
        let contentTypesByExtension = [
            "html": "text/html; charset=utf-8",
            "js": "text/javascript; charset=utf-8",
            "css": "text/css; charset=utf-8",
            "svg": "image/svg+xml",
        ]
        var resources: [String: RemoteGatewayStaticResource] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: clientDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            guard let contentType = contentTypesByExtension[file.pathExtension.lowercased()],
                  let data = try? Data(contentsOf: file) else {
                continue
            }
            resources["/\(file.lastPathComponent)"] = RemoteGatewayStaticResource(
                contentType: contentType,
                data: data
            )
        }
        return resources
    }
}
