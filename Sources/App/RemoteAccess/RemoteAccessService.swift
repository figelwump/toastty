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
    private let claudePromptStabilizationDelay: Duration
    private let sendConfirmationTimeout: Duration

    private struct RemotePresentationDiagnosticState: Equatable {
        var provider: AgentKind
        var workspaceID: UUID?
        var panelID: UUID?
        var lifecycleState: RemoteSessionState
        var presentationStatus: RemoteSessionPresentationStatus?
        var isUnread: Bool
    }
    private var loggedPresentationStateByConversationID: [
        RemoteConversationID: RemotePresentationDiagnosticState
    ] = [:]

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
    }
    private var pendingSendConfirmationWork: [
        PendingSendConfirmationKey: PendingSendConfirmationWork
    ] = [:]

    private var tailersByConversationID: [RemoteConversationID: RemoteTranscriptTailer] = [:]
    private var activeSessionIDByConversationID: [RemoteConversationID: String] = [:]
    private var panelIDByConversationID: [RemoteConversationID: UUID] = [:]
    private var conversationIDByPanelID: [UUID: RemoteConversationID] = [:]
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
        claudePromptStabilizationDelay: Duration = .milliseconds(500),
        sendConfirmationTimeout: Duration = .seconds(10),
        gatewayServerFactory: (RemoteGatewayRequestHandler) -> any RemoteAccessGatewayServing = {
            RemoteAccessGatewayServer(handler: $0)
        }
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.port = port
        self.claudePromptStabilizationDelay = claudePromptStabilizationDelay
        self.sendConfirmationTimeout = sendConfirmationTimeout
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

        sessionRuntimeStore.$providerConversationRevision
            .dropFirst()
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
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            guard let self,
                  self.isEnabled,
                  self.conversationTrackingGeneration == generation else { return }
            switch action {
            case .updateTerminalPanelResumeRecord, .updateTerminalPanelRemoteConversationID:
                self.syncConversations()
            case .focusPanel(let workspaceID, let panelID),
                 .markPanelNotificationsRead(let workspaceID, let panelID),
                 .recordDesktopNotification(let workspaceID, let panelID?):
                guard Self.panelIsUnread(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    state: previousState
                ) != Self.panelIsUnread(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    state: nextState
                ) else {
                    return
                }
                self.scheduleSessionListBroadcast()
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
        writeControllableSessions = []
        loggedPresentationStateByConversationID.removeAll()
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
        guard isReady else {
            logReadAcknowledgement(
                request,
                result: .conversationNotFound,
                reason: "service_not_ready"
            )
            return .conversationNotFound
        }
        guard let projector = projectionStore.projectorState(for: request.conversationID),
              let mappedPanelID = panelIDByConversationID[request.conversationID],
              let candidate = scanConversationCandidates(mintingIDs: false).first(where: {
                  $0.conversationID == request.conversationID && $0.panelID == mappedPanelID
              }) else {
            logReadAcknowledgement(
                request,
                result: .conversationNotFound,
                reason: "conversation_not_bound"
            )
            return .conversationNotFound
        }
        guard let workspace = store.state.workspacesByID[candidate.workspaceID],
              let tabID = workspace.tabID(containingPanelID: mappedPanelID)
                ?? workspace.rightAuxPanelTabLocation(containingPanelID: mappedPanelID)?.mainTabID else {
            logReadAcknowledgement(
                request,
                result: .conversationNotFound,
                reason: "panel_not_placed",
                before: candidate
            )
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
            logReadAcknowledgement(
                request,
                result: result,
                reason: "boundary_evaluated",
                before: candidate,
                after: candidate
            )
            return result
        }

        _ = store.send(.markPanelNotificationsRead(
            workspaceID: candidate.workspaceID,
            panelID: mappedPanelID
        ))
        let updatedCandidate = scanConversationCandidates(mintingIDs: false).first(where: {
            $0.conversationID == request.conversationID && $0.panelID == mappedPanelID
        })
        logReadAcknowledgement(
            request,
            result: .acknowledged,
            reason: "unread_cleared",
            before: candidate,
            after: updatedCandidate
        )
        // The action may also drive SessionRuntimeStore's active ready -> idle
        // transition. Publish immediately; broadcastSessionList cancels the
        // coalesced store-action broadcast scheduled for the same mutation.
        broadcastSessionList()
        return .acknowledged
    }

    private func logReadAcknowledgement(
        _ request: RemoteConversationReadAcknowledgementRequest,
        result: RemoteConversationReadAcknowledgementResult,
        reason: String,
        before: ConversationCandidate? = nil,
        after: ConversationCandidate? = nil
    ) {
        ToasttyLog.info(
            "Remote conversation read acknowledgement evaluated",
            category: .automation,
            metadata: [
                "conversation_id": request.conversationID.rawValue.uuidString,
                "projection_run_id": request.projectionRunID.rawValue.uuidString,
                "projection_generation": String(request.projectionGeneration),
                "observed_through_sequence": String(request.observedThroughSequence),
                "result": result.rawValue,
                "reason": reason,
                "workspace_id": before?.workspaceID.uuidString ?? after?.workspaceID.uuidString ?? "unknown",
                "panel_id": before?.panelID.uuidString ?? after?.panelID.uuidString ?? "unknown",
                "provider": before?.provider.rawValue ?? after?.provider.rawValue ?? "unknown",
                "before_lifecycle": before?.registryState.rawValue ?? "unknown",
                "before_presentation": before?.presentationStatus?.rawValue ?? "none",
                "before_unread": before.map { String($0.isUnread) } ?? "unknown",
                "after_lifecycle": after?.registryState.rawValue ?? "unknown",
                "after_presentation": after?.presentationStatus?.rawValue ?? "none",
                "after_unread": after.map { String($0.isUnread) } ?? "unknown",
            ]
        )
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
        var isUnread: Bool
        var statusDetail: String?
        var updatedAt: Date
        var transcriptPath: String?
        var providerFeed: ManagedProviderConversationFeedSnapshot?
        var nativeBindingConfirmation: ManagedNativeSessionBindingConfirmation?
    }

    private struct BootstrappedPromptAuthority {
        var managedSessionID: String
        var confirmation: ManagedNativeSessionBindingConfirmation
        var inputEpoch: RemoteInputEpoch
    }

    private func syncConversations(broadcast: Bool = true) {
        guard isEnabled else { return }
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

            if let activeSessionID = candidate.activeSessionID,
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
            ProviderTranscriptSupport.isManagedProvider($0.provider)
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
                  self.isEnabled,
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
            ToasttyLog.debug(
                "Claude remote prompt stabilization completed",
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
                guard let tabID = workspace.tabID(containingPanelID: panelID)
                    ?? workspace.rightAuxPanelTabLocation(containingPanelID: panelID)?.mainTabID,
                      let workspaceTab = workspace.tab(id: tabID) else {
                    continue
                }
                let isUnread = workspaceTab.unreadPanelIDs.contains(panelID)
                let hasLiveAgent = activeRecord.map { $0.isActive && $0.agent != .processWatch } ?? false
                let restorableProvider = terminalState.resumeRecord?.agent
                let restorableFeed = terminalState.resumeRecord.flatMap { resumeRecord in
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
                    && terminalState.resumeRecord?.agent == provider
                    ? terminalState.resumeRecord?.sessionFilePath
                    : nil
                let providerFeed = activeSessionID.flatMap {
                    sessionRuntimeStore.providerConversationFeed(managedSessionID: $0)
                } ?? restorableFeed
                let nativeBindingConfirmation: ManagedNativeSessionBindingConfirmation? =
                    activeRecord.flatMap { record in
                        guard ProviderTranscriptSupport.isManagedProvider(record.agent),
                              let resumeRecord = terminalState.resumeRecord,
                              let confirmation = sessionRuntimeStore.nativeSessionBindingConfirmation(
                                  for: record.sessionID
                              ),
                              confirmation.agent == record.agent,
                              confirmation.panelID == panelID,
                              confirmation.nativeSessionID == resumeRecord.nativeSessionID,
                              confirmation.sessionFilePath == resumeRecord.sessionFilePath else {
                            return nil
                        }
                        return confirmation
                    }

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
                        Self.remotePresentationStatus(
                            for: $0.status.kind,
                            isUnread: isUnread
                        )
                    },
                    isUnread: isUnread,
                    statusDetail: Self.remoteStatusDetail(from: panelStatus?.status.detail),
                    updatedAt: max(
                        activeRecord?.updatedAt ?? terminalState.resumeRecord?.capturedAt ?? .distantPast,
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
        promptStabilizationWorkByConversationID.removeValue(forKey: conversationID)?.task.cancel()
        cancelPendingSendConfirmations(for: conversationID)
        if isEnabled, projectionStore.isConversationRegistered(conversationID) {
            server.broadcast(.resnapshotRequired(conversationID: conversationID))
        }
        tailersByConversationID.removeValue(forKey: conversationID)?.stop()
        projectionStore.removeConversation(conversationID)
        coordinator.removeConversation(conversationID)
        activeSessionIDByConversationID.removeValue(forKey: conversationID)
        bootstrappedPromptAuthorityByConversationID.removeValue(forKey: conversationID)
        providerFeedIdentityByConversationID.removeValue(forKey: conversationID)
        providerFeedLastFingerprintByConversationID.removeValue(forKey: conversationID)
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
            pendingSendCorrelator.discard(for: candidate.conversationID)
            projectionStore.forceResnapshot(
                for: candidate.conversationID,
                bindingID: UUID(),
                at: feed.updatedAt
            )
            server.broadcast(.resnapshotRequired(conversationID: candidate.conversationID))
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
        guard ProviderTranscriptSupport.hasFileTranscript(provider) else { return }
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
        guard isEnabled, generation == conversationTrackingGeneration else { return }
        switch event {
        case .observations(let observations):
            // Stamp the confirming user message for any pending remote send
            // before it enters the projection, so the sending device can tell
            // its own send apart from another device's identical text.
            let stamped = stampPendingSends(observations, for: conversationID)
            let emitted = projectionStore.ingest(stamped, for: conversationID)
            refreshPromptStabilization(for: conversationID)
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
        sessionListBroadcastTask?.cancel()
        sessionListBroadcastTask = nil
        let snapshot = facadeSessionList(at: Date())
        logRemotePresentationChanges(in: snapshot)
        server.broadcast(.sessionList(snapshot))
    }

    private func logRemotePresentationChanges(in snapshot: RemoteSessionListSnapshot) {
        let current = Dictionary(uniqueKeysWithValues: snapshot.conversations.map { summary in
            let state = RemotePresentationDiagnosticState(
                provider: summary.provider,
                workspaceID: summary.placement.workspaceID,
                panelID: summary.placement.panelID,
                lifecycleState: summary.state,
                presentationStatus: summary.presentationStatus,
                isUnread: Self.panelIsUnread(
                    workspaceID: summary.placement.workspaceID,
                    panelID: summary.placement.panelID,
                    state: store.state
                )
            )
            return (summary.conversationID, state)
        })

        let conversationIDs = Set(loggedPresentationStateByConversationID.keys).union(current.keys)
        for conversationID in conversationIDs.sorted(by: {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }) {
            let previous = loggedPresentationStateByConversationID[conversationID]
            let next = current[conversationID]
            guard previous != next else { continue }

            let reference = next ?? previous
            ToasttyLog.info(
                "Remote session presentation changed",
                category: .automation,
                metadata: [
                    "conversation_id": conversationID.rawValue.uuidString,
                    "change": previous == nil ? "added" : (next == nil ? "removed" : "updated"),
                    "workspace_id": reference?.workspaceID?.uuidString ?? "unknown",
                    "panel_id": reference?.panelID?.uuidString ?? "unknown",
                    "provider": reference?.provider.rawValue ?? "unknown",
                    "previous_lifecycle": previous?.lifecycleState.rawValue ?? "none",
                    "previous_presentation": previous?.presentationStatus?.rawValue ?? "none",
                    "previous_unread": previous.map { String($0.isUnread) } ?? "none",
                    "current_lifecycle": next?.lifecycleState.rawValue ?? "none",
                    "current_presentation": next?.presentationStatus?.rawValue ?? "none",
                    "current_unread": next.map { String($0.isUnread) } ?? "none",
                ]
            )
        }
        loggedPresentationStateByConversationID = current
    }

    nonisolated private static func panelIsUnread(
        workspaceID: UUID?,
        panelID: UUID?,
        state: AppState
    ) -> Bool {
        guard let workspaceID,
              let panelID,
              let workspace = state.workspacesByID[workspaceID],
              let tabID = workspace.tabID(containingPanelID: panelID)
                ?? workspace.rightAuxPanelTabLocation(containingPanelID: panelID)?.mainTabID else {
            return false
        }
        return workspace.tab(id: tabID)?.unreadPanelIDs.contains(panelID) == true
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
        if let rejection = bootstrappedAuthorityRejection(
            for: request,
            panelID: panelID
        ) {
            return .rejected(reason: rejection)
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
    func noteLocalInput(panelID: UUID) {
        // Production terminal input already records this through the session
        // lifecycle tracker. Repeat it here so direct test/adapter callbacks
        // share the same fail-closed contract; the store uses an idempotent set.
        sessionRuntimeStore.noteLocalInputForActiveSession(panelID: panelID)
        guard let conversationID = conversationIDByPanelID[panelID] else { return }
        promptStabilizationWorkByConversationID
            .removeValue(forKey: conversationID)?
            .task.cancel()
        _ = projectionStore.cancelPromptStabilization(for: conversationID)
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
        let clientRequestID = request.clientRequestID
        let key = PendingSendConfirmationKey(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        )
        pendingSendConfirmationWork.removeValue(forKey: key)?.task.cancel()
        let acceptedAt = Date()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.sendConfirmationTimeout)
            } catch {
                return
            }
            guard Task.isCancelled == false,
                  self.isEnabled,
                  let work = self.pendingSendConfirmationWork.removeValue(forKey: key) else {
                return
            }
            let emitted = self.projectionStore.noteSendDeliveryUnconfirmed(
                for: conversationID,
                clientRequestID: clientRequestID,
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
                ]
            )
            self.broadcastEvents(emitted, for: conversationID)
        }
        pendingSendConfirmationWork[key] = PendingSendConfirmationWork(
            acceptedAt: acceptedAt,
            task: task
        )
    }

    /// Stamps origin=.remote and the clientRequestID onto the confirming user
    /// message for any pending send whose text matches, oldest first. Best
    /// effort: after a restart the pending map is gone and a rebuilt message
    /// reverts to origin=.unknown, which is acceptable runtime enrichment.
    private func stampPendingSends(
        _ observations: [ProviderTranscriptObservation],
        for conversationID: RemoteConversationID
    ) -> [ProviderTranscriptObservation] {
        let stamped = pendingSendCorrelator.stamp(observations, for: conversationID)
        for observation in stamped {
            guard case .transcript(.userMessage(let payload)) = observation.payload,
                  let clientRequestID = payload.clientRequestID else {
                continue
            }
            confirmPendingSend(
                conversationID: conversationID,
                clientRequestID: clientRequestID
            )
        }
        return stamped
    }

    private func confirmPendingSend(
        conversationID: RemoteConversationID,
        clientRequestID: String
    ) {
        let key = PendingSendConfirmationKey(
            conversationID: conversationID,
            clientRequestID: clientRequestID
        )
        guard let work = pendingSendConfirmationWork.removeValue(forKey: key) else {
            return
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
