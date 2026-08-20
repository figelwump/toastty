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

/// Bridges the gateway's authenticated read acknowledgement into the
/// main-actor-owned conversation and workspace state.
final class RemoteAccessReadAcknowledgementBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func acknowledge(
        _ request: RemoteConversationReadAcknowledgementRequest,
        device: RemoteDeviceRecord
    ) -> RemoteConversationReadAcknowledgementResult {
        MainActor.assumeIsolated {
            service?.acknowledgeConversationRead(request, device: device) ?? .conversationNotFound
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
enum RemoteAccessActivationState: Equatable, Sendable {
    case off
    case starting
    case ready(port: UInt16)
    case failed(message: String)

    var isEnabled: Bool {
        switch self {
        case .starting, .ready:
            true
        case .off, .failed:
            false
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

@MainActor
final class RemoteAccessService: ObservableObject {
    @Published private(set) var activationState: RemoteAccessActivationState = .off
    @Published private(set) var deviceManagementError: String?
    @Published private(set) var currentPairingCode: RemotePairingCode?
    @Published private(set) var currentNativePairingOffer: RemoteNativePairingOffer?
    @Published private(set) var currentNativePairingQRCode: NSImage?
    @Published private(set) var nativePairingError: String?
    @Published private(set) var devices: [RemoteDeviceRecord] = []
    @Published private(set) var connectedClientCount: Int = 0
    @Published private(set) var connectedNativeClientCount: Int = 0
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
    private let readAcknowledgementBridge = RemoteAccessReadAcknowledgementBridge()
    private var coordinator = RemoteInputCoordinator()
    private let handler: RemoteGatewayRequestHandler
    private let server: any RemoteAccessGatewayServing
    private let port: UInt16
    private var conversationTrackingCancellables: Set<AnyCancellable> = []
    private var storeActionObserverToken: UUID?
    private var conversationTrackingGeneration: UInt64 = 0
    private var sessionListBroadcastTask: Task<Void, Never>?

    private var tailersByConversationID: [RemoteConversationID: RemoteTranscriptTailer] = [:]
    private var activeSessionIDByConversationID: [RemoteConversationID: String] = [:]
    private var panelIDByConversationID: [RemoteConversationID: UUID] = [:]
    private var conversationIDByPanelID: [UUID: RemoteConversationID] = [:]
    /// Pending remote sends awaiting their confirming user message in the
    /// projection, oldest first, keyed by conversation.
    private var pendingSendCorrelator = RemotePendingSendCorrelator()

    var isEnabled: Bool {
        activationState.isEnabled
    }

    var isReady: Bool {
        activationState.isReady
    }

    var listeningPort: UInt16? {
        guard case .ready(let port) = activationState else { return nil }
        return port
    }

    var startupError: String? {
        guard case .failed(let message) = activationState else { return nil }
        return message
    }

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        runtimePaths: ToasttyRuntimePaths,
        port: UInt16 = RemoteAccessPreferences.loadPort(),
        initiallyEnabled: Bool = RemoteAccessPreferences.loadEnabled(),
        gatewayServerFactory: (RemoteGatewayRequestHandler) -> any RemoteAccessGatewayServing = {
            RemoteAccessGatewayServer(handler: $0)
        }
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.port = port
        self.tailnetOrigin = RemoteAccessPreferences.loadTailnetOrigin() ?? ""
        self.deviceStore = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        self.auditLog = RemoteAccessAuditLog(fileURL: runtimePaths.remoteAccessAuditFileURL)
        self.handler = RemoteGatewayRequestHandler(
            deviceStore: deviceStore,
            auditLog: auditLog,
            facade: facadeBridge,
            configuration: RemoteGatewayConfiguration(allowedOrigins: []),
            sendHandler: { [sendBridge] request, device in
                sendBridge.send(request, device: device)
            },
            readAcknowledgementHandler: { [readAcknowledgementBridge] request, device in
                readAcknowledgementBridge.acknowledge(request, device: device)
            }
        )
        self.server = gatewayServerFactory(handler)
        self.devices = deviceStore.devices
        facadeBridge.service = self
        sendBridge.service = self
        readAcknowledgementBridge.service = self
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

        server.onWebSocketCountsChanged = { [weak self] counts in
            guard let self else { return }
            let previousCount = self.connectedClientCount
            self.connectedClientCount = counts.total
            self.connectedNativeClientCount = counts.native
            if counts.total > previousCount {
                // A fresh subscriber gets the current snapshot immediately
                // instead of waiting for the next registry change.
                self.broadcastSessionList()
            }
        }
        server.onListenerReady = { [weak self] port in
            guard let self else { return }
            guard case .starting = self.activationState else {
                // A cancelled startup must never leave a late listener alive.
                // The concrete server also rejects stale listener identities;
                // this keeps the service contract fail-closed for any server.
                if self.isEnabled == false {
                    self.server.stop()
                }
                return
            }
            self.activationState = .ready(port: port)
            self.auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessEnabled))
        }
        server.onListenerFailed = { [weak self] in
            guard let self, self.isEnabled else { return }
            self.failActivation()
        }
        server.onDeviceRevoked = { [weak self] _ in
            self?.deviceManagementError = nil
            self?.refreshDevices()
        }

        refreshHandlerConfiguration()
        if initiallyEnabled {
            setEnabled(true, persist: false)
        }
    }

    // MARK: - Kill switch

    func setEnabled(_ enabled: Bool, persist: Bool = true) {
        if persist {
            RemoteAccessPreferences.persistEnabled(enabled)
        }
        if enabled {
            guard isEnabled == false else { return }
            activationState = .starting
            RemoteAccessPreferences.discardLegacyWriteEnabledConversations()
            beginConversationTracking()
            syncConversations(broadcast: false)
            do {
                try server.start(port: port)
            } catch {
                failActivation()
                ToasttyLog.error(
                    "Remote access gateway failed to start",
                    category: .automation
                )
            }
        } else {
            let shouldAudit = activationState != .off
            activationState = .off
            sessionListBroadcastTask?.cancel()
            sessionListBroadcastTask = nil
            server.stop()
            invalidatePairingCode()
            cancelNativePairingOffer()
            endConversationTracking()
            connectedClientCount = 0
            connectedNativeClientCount = 0
            if shouldAudit {
                auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .remoteAccessDisabled))
            }
        }
    }

    private func failActivation() {
        guard activationState != .off else { return }
        activationState = .failed(
            message: "Could not start the local Remote Access listener. Try again."
        )
        sessionListBroadcastTask?.cancel()
        sessionListBroadcastTask = nil
        server.stop()
        invalidatePairingCode()
        cancelNativePairingOffer()
        endConversationTracking()
        connectedClientCount = 0
        connectedNativeClientCount = 0
    }

    private func beginConversationTracking() {
        guard storeActionObserverToken == nil, conversationTrackingCancellables.isEmpty else { return }
        conversationTrackingGeneration &+= 1
        let generation = conversationTrackingGeneration

        // Observe local keyboard/paste input to invalidate open remote epochs.
        terminalRuntimeRegistry.localInputObserver = { [weak self] panelID in
            guard let self, self.conversationTrackingGeneration == generation else { return }
            self.noteLocalInput(panelID: panelID)
        }

        sessionRuntimeStore.$sessionRegistry
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      self.isEnabled,
                      self.conversationTrackingGeneration == generation else { return }
                self.syncConversations()
            }
            .store(in: &conversationTrackingCancellables)

        // Resume-record and conversation-identity changes mutate panel state
        // without touching the session registry; without this observer a
        // rollout-path change would never restart the transcript tailer.
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, _, _ in
            guard let self,
                  self.isEnabled,
                  self.conversationTrackingGeneration == generation else { return }
            switch action {
            case .updateTerminalPanelResumeRecord, .updateTerminalPanelRemoteConversationID:
                self.syncConversations()
            default:
                break
            }
        }
    }

    private func endConversationTracking() {
        conversationTrackingCancellables.removeAll()
        if let storeActionObserverToken {
            store.removeActionAppliedObserver(storeActionObserverToken)
            self.storeActionObserverToken = nil
        }
        terminalRuntimeRegistry.localInputObserver = nil

        let trackedConversationIDs = Set(tailersByConversationID.keys)
            .union(activeSessionIDByConversationID.keys)
            .union(panelIDByConversationID.keys)
            .union(pendingSendCorrelator.conversationIDs)
            .union(projectionStore.registeredConversationIDs)
        for conversationID in trackedConversationIDs {
            removeConversationState(conversationID)
        }
        tailersByConversationID.removeAll()
        activeSessionIDByConversationID.removeAll()
        panelIDByConversationID.removeAll()
        conversationIDByPanelID.removeAll()
        pendingSendCorrelator = RemotePendingSendCorrelator()
        coordinator = RemoteInputCoordinator()
        writeControllableSessions = []
    }

    // MARK: - Pairing and devices

    func issuePairingCode() {
        guard isReady else { return }
        let code = deviceStore.issuePairingCode(at: Date())
        currentPairingCode = code
        auditLog.record(RemoteAccessAuditEntry(at: Date(), action: .pairingCodeIssued))
    }

    func invalidatePairingCode() {
        deviceStore.invalidatePairingCode()
        currentPairingCode = nil
    }

    func issueNativePairingOffer(at date: Date = Date()) {
        guard isReady else { return }
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
        guard isReady else {
            currentNativePairingOffer = nil
            currentNativePairingQRCode = nil
            return
        }
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

    /// Clears the same authoritative unread state as desktop focus, but only
    /// when the phone proves it displayed the current live edge, including an
    /// authoritative empty transcript.
    /// All checks and the mutation are main-actor synchronous, preventing a
    /// new event from arriving between boundary validation and clearing.
    func acknowledgeConversationRead(
        _ request: RemoteConversationReadAcknowledgementRequest,
        device _: RemoteDeviceRecord
    ) -> RemoteConversationReadAcknowledgementResult {
        guard isReady else { return .conversationNotFound }
        guard let projector = projectionStore.projectorState(for: request.conversationID),
              let mappedPanelID = panelIDByConversationID[request.conversationID],
              let candidate = scanConversationCandidates(mintingIDs: false).first(where: {
                  $0.conversationID == request.conversationID && $0.panelID == mappedPanelID
              }) else {
            return .conversationNotFound
        }
        guard let workspace = store.state.workspacesByID[candidate.workspaceID],
              let tabID = workspace.tabID(containingPanelID: mappedPanelID)
                ?? workspace.rightAuxPanelTabLocation(containingPanelID: mappedPanelID)?.mainTabID else {
            return .conversationNotFound
        }
        let result = Self.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: projectionStore.runID,
            currentProjectionGeneration: projector.generation,
            currentLatestSequence: projector.latestSequence,
            isUnread: workspace.tab(id: tabID)?.unreadPanelIDs.contains(mappedPanelID) == true
        )
        guard result == .acknowledged else {
            return result
        }

        _ = store.send(.markPanelNotificationsRead(
            workspaceID: candidate.workspaceID,
            panelID: mappedPanelID
        ))
        // The action also drives SessionRuntimeStore's ready -> idle
        // transition. Publish the resulting list immediately rather than
        // waiting for the debounced registry observer.
        broadcastSessionList()
        return .acknowledged
    }

    nonisolated static func readAcknowledgementResult(
        request: RemoteConversationReadAcknowledgementRequest,
        currentProjectionRunID: RemoteProjectionRunID,
        currentProjectionGeneration: UInt64,
        currentLatestSequence: UInt64,
        isUnread: Bool
    ) -> RemoteConversationReadAcknowledgementResult {
        guard request.projectionRunID == currentProjectionRunID,
              request.projectionGeneration == currentProjectionGeneration else {
            return .staleBoundary
        }
        guard request.observedThroughSequence == currentLatestSequence else {
            return .staleBoundary
        }
        return isUnread ? .acknowledged : .alreadyRead
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
        var runtimeBindingStartedAt: Date?
        var registryState: RemoteSessionState
        var presentationStatus: RemoteSessionPresentationStatus?
        var statusDetail: String?
        var updatedAt: Date
        var transcriptPath: String?
    }

    private func syncConversations(broadcast: Bool = true) {
        guard isEnabled else { return }
        let candidates = scanConversationCandidates(mintingIDs: true)
        var seenConversationIDs: Set<RemoteConversationID> = []
        var listChanged = false

        for candidate in candidates {
            guard ProviderTranscriptSupport.isSupported(candidate.provider) else {
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
                        placement: RemoteConversationPlacement(
                            workspaceID: candidate.workspaceID,
                            workspaceTitle: candidate.workspaceTitle,
                            panelID: candidate.panelID
                        ),
                        cwd: candidate.cwd
                    )
                )
            }

            let previousActiveSessionID = activeSessionIDByConversationID[candidate.conversationID]
            if let activeSessionID = candidate.activeSessionID {
                if previousActiveSessionID != activeSessionID {
                    if isNewRegistration, candidate.transcriptPath == nil {
                        // Registration already initialized this empty
                        // projector as runtime-bound. Track the live surface
                        // immediately so send/lifecycle decisions do not wait
                        // for the provider to publish its transcript path.
                        activeSessionIDByConversationID[candidate.conversationID] = activeSessionID
                    } else {
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
                    }
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
        let previous = coordinator.availability(for: conversationID)
        coordinator.setProviderAvailability(projector.inputAvailability, for: conversationID)
        logCoordinatorAvailabilityTransition(
            for: conversationID,
            source: "provider_projection",
            previous: previous
        )
    }

    private func logCoordinatorAvailabilityTransition(
        for conversationID: RemoteConversationID,
        source: String,
        previous: RemoteInputAvailability
    ) {
        let current = coordinator.availability(for: conversationID)
        guard current != previous else { return }
        ToasttyLog.debug(
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

    private func scanConversationCandidates(mintingIDs: Bool) -> [ConversationCandidate] {
        let registry = sessionRuntimeStore.sessionRegistry
        var candidates: [ConversationCandidate] = []
        var seenPanelIDs: Set<UUID> = []

        for workspace in store.state.workspacesByID.values {
            for (panelID, panelState) in workspace.panels {
                guard case .terminal(let terminalState) = panelState else { continue }

                let activeSessionID = registry.activeSessionIDByPanelID[panelID]
                let activeRecord = activeSessionID.flatMap { registry.sessionsByID[$0] }
                // Use the same projected panel status as Toastty's desktop UI.
                // Looking at the raw active record here would miss projection
                // such as child activity, stopped ready/error sessions, and
                // focus-driven idle transitions.
                let panelStatus = sessionRuntimeStore.panelStatus(for: panelID)
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
                    runtimeBindingStartedAt: hasLiveAgent ? activeRecord?.startedAt : nil,
                    registryState: activeRecord.flatMap { record in
                        record.status.map { Self.remoteState(for: $0.kind) }
                    } ?? (hasLiveAgent ? .starting : .offline),
                    presentationStatus: panelStatus.map {
                        Self.remotePresentationStatus(for: $0.status.kind)
                    },
                    statusDetail: Self.remoteStatusDetail(from: panelStatus?.status.detail),
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
                    presentationStatus: candidate.presentationStatus,
                    statusDetail: candidate.statusDetail,
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
                presentationStatus: candidate.presentationStatus,
                statusDetail: candidate.statusDetail,
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

    nonisolated static func remotePresentationStatus(
        for kind: SessionStatusKind
    ) -> RemoteSessionPresentationStatus {
        switch kind {
        case .idle:
            return .idle
        case .working:
            return .working
        case .needsApproval:
            return .needsApproval
        case .ready:
            return .ready
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
        pendingSendCorrelator.discard(for: conversationID)

        guard let projector = projectionStore.projectorState(for: conversationID),
              projector.providerSessionFilePath != nil else {
            return false
        }
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
        // Every fresh tailer replays from byte zero. Discard correlation before
        // constructing it so historical same-text input cannot confirm a send
        // accepted against the previous file/tailer lifetime.
        pendingSendCorrelator.discard(for: conversationID)
        let generation = conversationTrackingGeneration
        let tailer = RemoteTranscriptTailer(
            conversationID: conversationID,
            fileURL: URL(filePath: path),
            provider: provider,
            makeParser: {
                ProviderTranscriptSupport.makeParser(for: provider) ?? CodexRolloutTranscriptParser()
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
        guard isEnabled, generation == conversationTrackingGeneration else { return }
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
        guard isReady else {
            return .rejected(reason: .notBound)
        }
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
                let previous = coordinator.availability(for: conversationID)
                coordinator.markUncertain(request)
                logCoordinatorAvailabilityTransition(
                    for: conversationID,
                    source: "remote_delivery_uncertain",
                    previous: previous
                )
                recordPendingSend(request, for: conversationID)
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
        let previous = coordinator.availability(for: conversationID)
        coordinator.noteLocalInput(for: conversationID)
        logCoordinatorAvailabilityTransition(
            for: conversationID,
            source: "local_terminal_input",
            previous: previous
        )
        if previous.allowsRemoteSend {
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

    nonisolated static func publicGatewayURL(from configuredOrigin: String) -> URL? {
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
