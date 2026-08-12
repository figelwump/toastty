import AppKit
import Combine
import CoreState
import Foundation
import RemoteProtocol

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

    func conversationEvents(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        MainActor.assumeIsolated {
            service?.facadeConversationEvents(for: conversationID, before: cursor, limit: limit)
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

    // Earlier builds persisted a per-conversation allowlist. Remote replies
    // now default on, so retaining or inverting those values would give stale
    // conversation IDs unintended meaning.
    private static let legacyWriteEnabledConversationsKey = "toastty.remoteAccess.writeEnabledConversations"

    static func discardLegacyWriteEnabledConversations(userDefaults: UserDefaults = ToasttyAppDefaults.current) {
        userDefaults.removeObject(forKey: legacyWriteEnabledConversationsKey)
    }
}

/// Default-on, process-local overrides for active conversations. Device scope
/// remains the durable remote-send kill switch.
struct RemoteSessionWritePolicy: Equatable, Sendable {
    private(set) var disabledConversationIDs: Set<RemoteConversationID> = []

    func isEnabled(for conversationID: RemoteConversationID) -> Bool {
        disabledConversationIDs.contains(conversationID) == false
    }

    /// Overlays the host's write policy without weakening provider-derived
    /// availability. Disabled sessions remain explicitly read-only even if
    /// their provider has an open prompt.
    func inputAvailability(
        providerAvailability: RemoteInputAvailability,
        for conversationID: RemoteConversationID
    ) -> RemoteInputAvailability {
        isEnabled(for: conversationID)
            ? providerAvailability
            : .unavailable(reason: .sessionWritesDisabled)
    }

    @discardableResult
    mutating func setEnabled(_ enabled: Bool, for conversationID: RemoteConversationID) -> Bool {
        if enabled {
            return disabledConversationIDs.remove(conversationID) != nil
        }
        return disabledConversationIDs.insert(conversationID).inserted
    }
}

/// Process-local enrichment that correlates an accepted remote send with the
/// next matching provider transcript user message. This must be expired when
/// a transcript file is replaced: the replacement tailer replays history from
/// byte zero, and historical same-text input cannot confirm a new send.
struct RemotePendingSendCorrelator: Sendable {
    private struct PendingSend: Sendable {
        var clientRequestID: String
        var trimmedText: String
    }

    private var pendingSendsByConversationID: [RemoteConversationID: [PendingSend]] = [:]

    var conversationIDs: Set<RemoteConversationID> {
        Set(pendingSendsByConversationID.keys)
    }

    mutating func record(_ request: RemoteMessageSendRequest) {
        let pendingSend = PendingSend(
            clientRequestID: request.clientRequestID,
            trimmedText: request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var pendingSends = pendingSendsByConversationID[request.conversationID, default: []]
        pendingSends.append(pendingSend)
        // Bound the pending list; a confirmation that never arrives must not
        // leak memory.
        if pendingSends.count > 32 {
            pendingSends.removeFirst()
        }
        pendingSendsByConversationID[request.conversationID] = pendingSends
    }

    mutating func discard(for conversationID: RemoteConversationID) {
        pendingSendsByConversationID.removeValue(forKey: conversationID)
    }

    mutating func stamp(
        _ observations: [ProviderTranscriptObservation],
        for conversationID: RemoteConversationID
    ) -> [ProviderTranscriptObservation] {
        guard pendingSendsByConversationID[conversationID]?.isEmpty == false else {
            // Keep dictionary membership equivalent to live correlation work.
            // This also repairs any empty queue left by an older code path.
            pendingSendsByConversationID.removeValue(forKey: conversationID)
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
            guard let pending = consumeOldest(for: conversationID) else {
                return observation
            }
            guard pending.trimmedText == trimmed else { return observation }
            var stampedPayload = payload
            stampedPayload.origin = .remote
            stampedPayload.clientRequestID = pending.clientRequestID
            var stamped = observation
            stamped.payload = .transcript(.userMessage(stampedPayload))
            return stamped
        }
    }

    private mutating func consumeOldest(for conversationID: RemoteConversationID) -> PendingSend? {
        guard var pendingSends = pendingSendsByConversationID[conversationID],
              pendingSends.isEmpty == false else {
            pendingSendsByConversationID.removeValue(forKey: conversationID)
            return nil
        }
        let oldest = pendingSends.removeFirst()
        if pendingSends.isEmpty {
            pendingSendsByConversationID.removeValue(forKey: conversationID)
        } else {
            pendingSendsByConversationID[conversationID] = pendingSends
        }
        return oldest
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
    @Published private(set) var currentNativePairingOffer: RemoteNativePairingOffer?
    @Published private(set) var currentNativePairingQRCode: NSImage?
    @Published private(set) var nativePairingError: String?
    @Published private(set) var devices: [RemoteDeviceRecord] = []
    @Published private(set) var connectedClientCount: Int = 0
    /// Active-conversation exceptions to the default-on remote-write policy.
    @Published private var sessionWritePolicy = RemoteSessionWritePolicy()
    /// Supported conversations shown by the per-session write controls.
    @Published private(set) var writeControllableSessions: [RemoteConversationSummary] = []
    @Published var tailnetOrigin: String {
        didSet {
            RemoteAccessPreferences.persistTailnetOrigin(tailnetOrigin)
            refreshHandlerConfiguration()
            if tailnetOrigin != oldValue, currentNativePairingOffer != nil {
                cancelNativePairingOffer()
            }
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
    private var pendingSendCorrelator = RemotePendingSendCorrelator()

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
        RemoteAccessPreferences.discardLegacyWriteEnabledConversations()
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
        handler.onDevicePaired = { [weak self] device in
            guard let self else { return }
            switch device.authKind {
            case .browser:
                self.currentPairingCode = nil
            case .native:
                self.currentNativePairingOffer = nil
                self.currentNativePairingQRCode = nil
                self.nativePairingError = nil
            }
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
        server.onListenerReady = { [weak self] port in
            guard let self, self.isEnabled else { return }
            self.listeningPort = port
            self.startupError = nil
        }
        server.onListenerFailed = { [weak self] in
            guard let self else { return }
            self.server.stop()
            self.sessionListBroadcastTask?.cancel()
            self.sessionListBroadcastTask = nil
            self.isEnabled = false
            self.listeningPort = nil
            self.invalidatePairingCode()
            self.cancelNativePairingOffer()
            self.startupError = "Could not start the local Remote Access listener. Try again."
        }
        server.onDeviceRevoked = { [weak self] _ in
            self?.deviceManagementError = nil
            self?.refreshDevices()
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
            listeningPort = nil
            do {
                try server.start(port: port)
                isEnabled = true
                auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessEnabled))
            } catch {
                isEnabled = false
                listeningPort = nil
                startupError = "Could not start the local Remote Access listener. Try again."
                ToasttyLog.error(
                    "Remote access gateway failed to start",
                    category: .automation
                )
            }
        } else {
            sessionListBroadcastTask?.cancel()
            sessionListBroadcastTask = nil
            server.stop()
            isEnabled = false
            listeningPort = nil
            invalidatePairingCode()
            cancelNativePairingOffer()
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

    func issueNativePairingOffer(at date: Date = Date()) {
        guard let gatewayURL = publicGatewayURL else {
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            nativePairingError = "Enter the HTTPS Tailscale Serve origin before pairing the native app."
            return
        }
        let offer: RemoteNativePairingOffer
        let encodedPayload: String
        do {
            offer = try deviceStore.issueNativePairingOffer(gatewayURL: gatewayURL, at: date)
            encodedPayload = try offer.qrPayload.encodedString()
        } catch {
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            nativePairingError = "The pairing offer could not be created. Check the Tailscale Serve origin."
            return
        }
        guard Data(encodedPayload.utf8).count <= RemoteNativePairingQRPayload.maximumEncodedByteCount else {
            deviceStore.cancelNativePairingOffer()
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            nativePairingError = "The pairing QR could not be created. Check the Tailscale Serve origin."
            return
        }
        guard let qrCode = RemoteAccessPairingQRCode.image(payload: encodedPayload) else {
            deviceStore.cancelNativePairingOffer()
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            nativePairingError = "The pairing QR could not be created. Try issuing a new offer."
            return
        }
        currentNativePairingOffer = offer
        currentNativePairingQRCode = qrCode
        nativePairingError = nil
    }

    func cancelNativePairingOffer() {
        deviceStore.cancelNativePairingOffer()
        currentNativePairingOffer = nil
        currentNativePairingQRCode = nil
        nativePairingError = nil
    }

    func refreshNativePairingOffer(at date: Date = Date()) {
        guard let offer = deviceStore.activeNativePairingOffer(at: date),
              let payload = try? offer.qrPayload.encodedString(),
              let qrCode = RemoteAccessPairingQRCode.image(payload: payload) else {
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            return
        }
        currentNativePairingOffer = offer
        currentNativePairingQRCode = qrCode
        nativePairingError = nil
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
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            nativePairingError = nil
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

    func facadeConversationEvents(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        projectionStore.conversationEvents(for: conversationID, before: cursor, limit: limit)
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
            .union(pendingSendCorrelator.conversationIDs)
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
        pendingSendCorrelator.discard(for: conversationID)
        if let panelID = panelIDByConversationID.removeValue(forKey: conversationID),
           conversationIDByPanelID[panelID] == conversationID {
            conversationIDByPanelID.removeValue(forKey: panelID)
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
                let availability = sessionWritePolicy.inputAvailability(
                    providerAvailability: coordinator.availability(for: candidate.conversationID),
                    for: candidate.conversationID
                )
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
                    pendingInteractionPreview: RemotePendingInteractionPreviewFormatter.make(
                        from: projectionStore.pendingInteractions(for: candidate.conversationID)
                    ),
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
        // Every fresh tailer replays from byte zero. Discard correlation before
        // constructing it so historical same-text input cannot confirm a send
        // accepted against the previous file/tailer lifetime.
        pendingSendCorrelator.discard(for: conversationID)
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
            // generation. Discard delivery correlation before any early exit;
            // `startTailer` defensively repeats this for every replay path.
            pendingSendCorrelator.discard(for: conversationID)
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
        let sessionWritesEnabled = sessionWritePolicy.isEnabled(for: conversationID)
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
        precondition(request.conversationID == conversationID)
        pendingSendCorrelator.record(request)
    }

    /// Stamps origin=.remote and the clientRequestID onto the confirming user
    /// message for any pending send whose text matches, oldest first. Best
    /// effort: after a restart the pending map is gone and a rebuilt message
    /// reverts to origin=.unknown, which is acceptable runtime enrichment.
    private func stampPendingSends(
        _ observations: [ProviderTranscriptObservation],
        for conversationID: RemoteConversationID
    ) -> [ProviderTranscriptObservation] {
        pendingSendCorrelator.stamp(observations, for: conversationID)
    }

    // MARK: - Per-session write controls

    func isSessionWriteEnabled(_ conversationID: RemoteConversationID) -> Bool {
        sessionWritePolicy.isEnabled(for: conversationID)
    }

    func setSessionWriteEnabled(_ enabled: Bool, for conversationID: RemoteConversationID) {
        guard sessionWritePolicy.setEnabled(enabled, for: conversationID) else { return }
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

    private func reportDeviceManagementFailure(_ message: String, error _: Error) {
        deviceManagementError = "\(message). Try again."
        ToasttyLog.error(
            message,
            category: .automation
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

    /// The configured Tailscale Serve origin is the only authority for native
    /// QR payloads. Never derive it from the loopback listener or an inbound
    /// Host header, either of which a local process can control.
    var publicGatewayURL: URL? {
        Self.publicGatewayURL(from: tailnetOrigin)
    }

    static func publicGatewayURL(from configuredOrigin: String) -> URL? {
        let trimmed = configuredOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              rawHost.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        let host = rawHost.lowercased()
        guard host != "ts.net", host.hasSuffix(".ts.net") else { return nil }
        components.scheme = "https"
        components.host = host
        components.port = nil
        components.path = ""
        return components.url
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
