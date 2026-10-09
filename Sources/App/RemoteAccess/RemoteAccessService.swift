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
final class RemoteAccessQuestionAnswerBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?
    func answer(_ request: RemoteQuestionAnswerRequest, device: RemoteDeviceRecord) -> RemoteQuestionAnswerResult {
        MainActor.assumeIsolated {
            service?.performQuestionAnswer(request, device: device) ?? .rejected(reason: .notBound)
        }
    }
}

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

/// Bridges the gateway's authenticated done request into the main-actor-owned
/// workspace state.
final class RemoteAccessWorkspaceDoneBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func setDone(
        _ request: RemoteWorkspaceDoneRequest,
        device: RemoteDeviceRecord
    ) -> RemoteWorkspaceDoneResult {
        MainActor.assumeIsolated {
            service?.setWorkspaceDone(request, device: device) ?? .workspaceNotFound
        }
    }
}

/// Bridges the gateway's authenticated flag request into the main-actor-owned
/// session registry.
final class RemoteAccessConversationFlagBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func setFlag(
        _ request: RemoteConversationFlagRequest,
        device: RemoteDeviceRecord
    ) -> RemoteConversationFlagResult {
        MainActor.assumeIsolated {
            service?.setConversationFlag(request, device: device) ?? .conversationNotFound
        }
    }
}

/// Bridges the gateway's authenticated queue edit into the main-actor-owned
/// send queue.
final class RemoteAccessQueueUpdateBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func update(
        _ request: RemoteConversationQueueUpdateRequest,
        device: RemoteDeviceRecord
    ) -> RemoteConversationQueueUpdateResult {
        MainActor.assumeIsolated {
            service?.performQueueUpdate(request, device: device) ?? .conversationNotFound
        }
    }
}

/// Bridges the gateway's authenticated interrupt into the main-actor-owned
/// terminal delivery path.
final class RemoteAccessInterruptBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func interrupt(
        _ request: RemoteConversationInterruptRequest,
        device: RemoteDeviceRecord
    ) -> RemoteConversationInterruptResult {
        MainActor.assumeIsolated {
            service?.performRemoteInterrupt(request, device: device) ?? .rejected(reason: .notBound)
        }
    }
}

/// Bridges the gateway's synchronous options request into the main-actor
/// session starter.
final class RemoteAccessSessionStartBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func options(
        _ request: RemoteSessionStartOptionsRequest,
        device: RemoteDeviceRecord
    ) -> RemoteSessionStartOptionsResponse {
        MainActor.assumeIsolated {
            service?.sessionStartOptions(request, device: device)
                ?? RemoteSessionStartOptionsResponse(
                    permission: RemoteGatewayRequestHandler.sessionStartPermission(for: device),
                    workspace: .notFound
                )
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
        var displayText: String?
        var deliveryMode: RemoteMessageDeliveryMode
    }

    private var pendingSendsByConversationID: [RemoteConversationID: [PendingSend]] = [:]

    var conversationIDs: Set<RemoteConversationID> {
        Set(pendingSendsByConversationID.keys)
    }

    mutating func record(
        _ request: RemoteMessageSendRequest,
        deliveredText: String? = nil,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) {
        let pendingSend = PendingSend(
            clientRequestID: request.clientRequestID,
            trimmedText: (deliveredText ?? request.text).trimmingCharacters(in: .whitespacesAndNewlines),
            displayText: request.attachments.isEmpty ? nil : request.displayText,
            deliveryMode: deliveryMode
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
            if let displayText = pending.displayText { stampedPayload.text = displayText }
            stampedPayload.origin = .remote
            stampedPayload.clientRequestID = pending.clientRequestID
            stampedPayload.deliveryMode = pending.deliveryMode == .prompt ? nil : pending.deliveryMode
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
    typealias TailnetServeSetup = @Sendable (_ port: UInt16, _ configuredOrigin: String, _ configureIfNeeded: Bool) async throws -> String

    @Published private(set) var activationState: RemoteAccessActivationState = .off
    @Published private(set) var tailnetSetupState: RemoteAccessTailnetSetupState = .unchecked
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
            if tailnetOrigin != oldValue, isApplyingSetupOrigin == false {
                invalidateTailnetSetup(preservingBlockingFailure: true)
            }
            if tailnetOrigin != oldValue, currentNativePairingOffer != nil {
                cancelNativePairingOffer()
            }
        }
    }

    private let panelMetadataCache = RemotePanelMetadataCache()
    private var panelMetadataPollTask: Task<Void, Never>?
    private let previewScratchpadDirectory: URL
    private let store: AppStore
    private let annotationStyleStore: AnnotationStyleStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let deviceStore: RemoteDeviceStore
    private let pushConfiguration: RemotePushConfiguration?
    private let pushRelay: any RemotePushRelaying
    private var pushTasksByEventID: [UUID: Task<Void, Never>] = [:]
    private var pushCleanupTask: Task<Void, Never>?
    private var nextPushCleanupIndex = 0
    private var pushCleanupRequestedWhileRunning = false
    private var pushForegroundObserver: AnyCancellable?
    private let auditLog: RemoteAccessAuditLog
    private let projectionStore = RemoteConversationProjectionStore()
    private let facadeBridge = RemoteAccessFacadeBridge()
    private let attachmentStore: RemoteMessageAttachmentStore
    private let sendBridge = RemoteAccessSendBridge()
    private let questionAnswerBridge = RemoteAccessQuestionAnswerBridge()
    private let readAcknowledgementBridge = RemoteAccessReadAcknowledgementBridge()
    private let workspaceDoneBridge = RemoteAccessWorkspaceDoneBridge()
    private let conversationFlagBridge = RemoteAccessConversationFlagBridge()
    private let queueUpdateBridge = RemoteAccessQueueUpdateBridge()
    private let interruptBridge = RemoteAccessInterruptBridge()
    private let sessionStartBridge = RemoteAccessSessionStartBridge()
    private var sessionStarter: RemoteSessionStarter?
    private var coordinator = RemoteInputCoordinator()
    /// Messages held for the next open prompt, per conversation.
    private var sendQueue = RemoteSendQueue()
    /// Staged attachment directories owned by queued entries, so a removed or
    /// expired entry can release its files.
    private var stagedAttachmentsByQueuedRequestID: [String: RemoteMessageAttachmentStore.Staged] = [:]
    /// Steer types into a running TUI, so it is limited to providers whose
    /// behavior for input during a turn is verified. Claude Code holds such
    /// input in its own queue until the turn ends, which Toastty's queue
    /// already covers.
    static let steerCapableProviders: Set<AgentKind> = [.codex]
    /// A steer's confirming user message arrives when the provider next reads
    /// its input, which can be well after a long tool call.
    private static let steerConfirmationTimeout: Duration = .seconds(180)
    private let handler: RemoteGatewayRequestHandler
    private let server: any RemoteAccessGatewayServing
    private let port: UInt16
    private let tailnetServeSetup: TailnetServeSetup
    private var tailnetSetupTask: Task<Void, Never>?
    private var tailnetSetupTaskID: UUID?
    private var tailnetSetupGeneration: UInt64 = 0
    private var isApplyingSetupOrigin = false
    private enum TailnetSetupIntent: Equatable {
        case verify
        case configure
    }
    private var pendingTailnetSetupIntent: TailnetSetupIntent?
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

    var canIssueNativePairingOffer: Bool {
        isReady && tailnetSetupState.permitsPairing && publicGatewayURL != nil
    }

    init(
        store: AppStore,
        annotationStyleStore: AnnotationStyleStore,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        runtimePaths: ToasttyRuntimePaths,
        sessionLauncher: (any RemoteSessionLaunching)? = nil,
        port: UInt16 = RemoteAccessPreferences.loadPort(),
        initiallyEnabled: Bool = RemoteAccessPreferences.loadEnabled(),
        claudePromptStabilizationDelay: Duration = .milliseconds(500),
        sendConfirmationTimeout: Duration = .seconds(10),
        pushConfiguration: RemotePushConfiguration? = .configured(),
        pushRelay: any RemotePushRelaying = RemotePushRelayClient(),
        tailnetServeSetup: @escaping TailnetServeSetup = { port, configuredOrigin, configureIfNeeded in
            try await TailscaleServeSetup().run(
                port: port,
                configuredOrigin: configuredOrigin,
                configureIfNeeded: configureIfNeeded
            )
        },
        gatewayServerFactory: (RemoteGatewayRequestHandler) -> any RemoteAccessGatewayServing = {
            RemoteAccessGatewayServer(handler: $0)
        }
    ) {
        self.attachmentStore = RemoteMessageAttachmentStore(root: runtimePaths.remoteAccessDirectoryURL.appendingPathComponent("attachments", isDirectory: true))
        self.previewScratchpadDirectory = runtimePaths.scratchpadDocumentsDirectoryURL
        self.store = store
        self.annotationStyleStore = annotationStyleStore
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.port = port
        self.tailnetServeSetup = tailnetServeSetup
        self.claudePromptStabilizationDelay = claudePromptStabilizationDelay
        self.sendConfirmationTimeout = sendConfirmationTimeout
        self.pushConfiguration = pushConfiguration
        self.pushRelay = pushRelay
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
            questionAnswerHandler: { [questionAnswerBridge] request, device in
                questionAnswerBridge.answer(request, device: device)
            },
            readAcknowledgementHandler: { [readAcknowledgementBridge] request, device in
                readAcknowledgementBridge.acknowledge(request, device: device)
            },
            workspaceDoneHandler: { [workspaceDoneBridge] request, device in
                workspaceDoneBridge.setDone(request, device: device)
            },
            conversationFlagHandler: { [conversationFlagBridge] request, device in
                conversationFlagBridge.setFlag(request, device: device)
            },
            queueUpdateHandler: { [queueUpdateBridge] request, device in
                queueUpdateBridge.update(request, device: device)
            },
            interruptHandler: { [interruptBridge] request, device in
                interruptBridge.interrupt(request, device: device)
            }
        )
        self.server = gatewayServerFactory(handler)
        handler.previewHandler = { [weak self] operation in
            guard let self else { return operation.errorResponse(.stale) }
            return await self.resolvePreview(operation)
        }
        handler.attachmentSendHandler = { [weak self] request, device in
            guard let self else { return .rejected(reason: .notBound) }
            return await self.performRemoteAttachmentSend(request, device: device)
        }
        Task { [attachmentStore] in try? await attachmentStore.cleanup() }
        panelMetadataCache.onChange = { [weak self] in self?.scheduleSessionListBroadcast() }
        self.devices = deviceStore.devices
        facadeBridge.service = self
        sendBridge.service = self
        questionAnswerBridge.service = self
        readAcknowledgementBridge.service = self
        workspaceDoneBridge.service = self
        conversationFlagBridge.service = self
        queueUpdateBridge.service = self
        interruptBridge.service = self
        sessionStartBridge.service = self
        sessionStarter = RemoteSessionStarter(
            store: store,
            launcher: sessionLauncher,
            attachmentStore: attachmentStore,
            deviceMayStart: { [weak self] deviceID in
                guard let self, self.isEnabled else { return false }
                return self.deviceStore.devices.first { $0.id == deviceID }?.canStartSessions ?? false
            },
            recentModels: { [weak self] provider in self?.recentModels(for: provider) ?? [] },
            publishSessionList: { [weak self] in self?.syncConversations() }
        )
        handler.sessionStartOptionsHandler = { [sessionStartBridge] request, device in
            sessionStartBridge.options(request, device: device)
        }
        handler.sessionStartHandler = { [weak self] request, device in
            guard let starter = self?.sessionStarter else { return .rejected(reason: .launchFailed) }
            return await starter.start(request, device: device)
        }
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
            self.retryPushCleanup()
        }
        handler.onPushRegistrationChanged = { [weak self] in self?.retryPushCleanup() }
        sessionRuntimeStore.onActionableEvent = { [weak self] event in self?.sendPushNotification(for: event) }
        pushForegroundObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.retryPushCleanup() }

        server.onWebSocketCountsChanged = { [weak self] counts in
            guard let self else { return }
            let previousCount = self.connectedClientCount
            self.connectedClientCount = counts.total
            self.connectedNativeClientCount = counts.native
            self.updatePanelMetadataPolling()
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
            self.startPendingTailnetSetupIfReady()
        }
        server.onListenerFailed = { [weak self] failure in
            guard let self, self.isEnabled else { return }
            self.failActivation(failure)
        }
        server.onDeviceRevoked = { [weak self] _ in
            self?.deviceManagementError = nil
            self?.refreshDevices()
            self?.retryPushCleanup()
        }

        refreshHandlerConfiguration()
        retryPushCleanup()
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
                failActivation(RemoteAccessListenerFailure(error))
                ToasttyLog.error(
                    "Remote access gateway failed to start",
                    category: .automation
                )
            }
        } else {
            invalidateTailnetSetup()
            let shouldAudit = activationState != .off
            activationState = .off
            for task in pushTasksByEventID.values { task.cancel() }
            pushTasksByEventID.removeAll()
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

    private func failActivation(_ failure: RemoteAccessListenerFailure) {
        guard activationState != .off else { return }
        invalidateTailnetSetup()
        activationState = .failed(
            message: failure.recoveryMessage(port: port)
        )
        for task in pushTasksByEventID.values { task.cancel() }
        pushTasksByEventID.removeAll()
        sessionListBroadcastTask?.cancel()
        sessionListBroadcastTask = nil
        server.stop()
        invalidatePairingCode()
        cancelNativePairingOffer()
        endConversationTracking()
        connectedClientCount = 0
        connectedNativeClientCount = 0
    }

    // MARK: - Private tailnet setup

    /// Only a settings action requests a Serve change. Restoration and other
    /// setEnabled callers keep their existing listener-only behavior.
    func setEnabledFromSettings(_ enabled: Bool, persist: Bool = true) {
        if enabled {
            setUpTailnetAccess(persistEnabled: persist)
        } else {
            setEnabled(false, persist: persist)
        }
    }

    func setUpTailnetAccess(persistEnabled: Bool = true) {
        invalidateTailnetSetup()
        pendingTailnetSetupIntent = .configure
        tailnetSetupState = .waitingForListener
        cancelNativePairingOffer()
        // Prepare the intent before start, because a server can report ready
        // synchronously from start(port:).
        if isEnabled == false {
            setEnabled(true, persist: persistEnabled)
        }
        startPendingTailnetSetupIfReady()
    }

    /// Settings can inspect a restored or manual configuration without making
    /// changes. Failed attempts need an explicit retry, so appearance does not
    /// discard an approval link or disrupt pairing through a manual setup.
    func verifyTailnetSetupIfNeeded() {
        guard isReady, tailnetSetupTask == nil, tailnetSetupState == .unchecked else { return }
        pendingTailnetSetupIntent = .verify
        cancelNativePairingOffer()
        startPendingTailnetSetupIfReady()
    }

    private func invalidateTailnetSetup(preservingBlockingFailure: Bool = false) {
        tailnetSetupGeneration &+= 1
        pendingTailnetSetupIntent = nil
        tailnetSetupTask?.cancel()
        // Keep the task until it finishes. A retry must not overlap a process
        // that is still completing cancellation.
        if preservingBlockingFailure,
           case .failed = tailnetSetupState,
           tailnetSetupState.permitsPairing == false {
            // An origin edit cannot remove a known Funnel or mapping conflict.
            // Only an explicit setup attempt can verify that it was resolved.
            return
        }
        tailnetSetupState = .unchecked
    }

    private func startPendingTailnetSetupIfReady() {
        guard tailnetSetupTask == nil,
              let intent = pendingTailnetSetupIntent,
              let listeningPort else { return }
        pendingTailnetSetupIntent = nil
        let configureIfNeeded = intent == .configure
        let originAtStart = tailnetOrigin
        let generation = tailnetSetupGeneration
        let taskID = UUID()
        tailnetSetupTaskID = taskID
        tailnetSetupState = configureIfNeeded ? .configuring : .checking
        tailnetSetupTask = Task { [weak self, tailnetServeSetup] in
            let result: Result<String, TailscaleServeSetupError>?
            do {
                let origin = try await tailnetServeSetup(listeningPort, originAtStart, configureIfNeeded)
                result = .success(origin)
            } catch is CancellationError {
                result = nil
            } catch let error as TailscaleServeSetupError {
                result = .failure(error)
            } catch {
                result = .failure(.statusUnavailable)
            }
            guard let self else { return }
            if Task.isCancelled == false,
               generation == self.tailnetSetupGeneration,
               self.listeningPort == listeningPort,
               self.tailnetOrigin == originAtStart {
                switch result {
                case .success(let origin)?:
                    if originAtStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.isApplyingSetupOrigin = true
                        self.tailnetOrigin = origin
                        self.isApplyingSetupOrigin = false
                    }
                    self.tailnetSetupState = .configured
                case .failure(let error)?:
                    self.tailnetSetupState = .failed(error)
                case nil:
                    self.tailnetSetupState = .unchecked
                }
            }
            guard self.tailnetSetupTaskID == taskID else { return }
            self.tailnetSetupTask = nil
            self.tailnetSetupTaskID = nil
            self.startPendingTailnetSetupIfReady()
        }
    }

    private func beginConversationTracking() {
        guard storeActionObserverToken == nil, conversationTrackingCancellables.isEmpty else { return }
        conversationTrackingGeneration &+= 1
        let generation = conversationTrackingGeneration
        panelMetadataCache.start()
        store.$state.combineLatest(store.$recentRightPanelItems)
            .sink { [weak self] state, recentItems in
                guard let self, self.conversationTrackingGeneration == generation else { return }
                self.panelMetadataCache.updateInputs(Self.panelMetadataInputs(
                    state: state, recentItems: recentItems, scratchpadDirectory: self.previewScratchpadDirectory
                ))
            }
            .store(in: &conversationTrackingCancellables)

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

        // Chip colors live outside AppState, so the inventory diff below never
        // sees a color-only change. The broadcast is deferred, so it reads the
        // store after this willSet publication lands.
        annotationStyleStore.$colorTokensByKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self,
                      self.isEnabled,
                      self.conversationTrackingGeneration == generation else { return }
                self.scheduleSessionListBroadcast()
            }
            .store(in: &conversationTrackingCancellables)

        // Resume-record and conversation-identity changes mutate panel state
        // without touching the session registry; without this observer a
        // rollout-path change would never restart the transcript tailer.
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            guard let self,
                  self.isEnabled,
                  self.conversationTrackingGeneration == generation else { return }
            // Passing the claimed colors skips deriving a fallback for every
            // key on every action; color changes have their own trigger.
            let colors = self.annotationStyleStore.colorTokensByKey
            // The inventory names a spawner by conversation, which needs the
            // live session map, so this comparison cannot see a change of
            // spawner alone. Only a parent change makes one.
            var inventoryChanged = false
            if case .setWorkspaceParent = action {
                inventoryChanged = true
            }
            if inventoryChanged
                || Self.workspaceInventory(state: previousState, annotationColorTokens: colors)
                != Self.workspaceInventory(state: nextState, annotationColorTokens: colors) {
                self.scheduleSessionListBroadcast()
            }
            // Auxiliary-panel inventory cannot detect a rename on a terminal-only
            // tab. Compare placement values so moves, resets and focus-derived
            // title changes publish even when no provider activity occurs.
            let activePanels = Set(self.sessionRuntimeStore.sessionRegistry.activeSessionIDByPanelID.keys)
            if Self.conversationPlacements(in: previousState, activePanels: activePanels)
                != Self.conversationPlacements(in: nextState, activePanels: activePanels) {
                self.scheduleSessionListBroadcast()
            }
            switch action {
            case .updateScratchpadPanelState:
                // A link can change independently of title or document revision.
                self.scheduleSessionListBroadcast()
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
        panelMetadataPollTask?.cancel()
        panelMetadataPollTask = nil
        panelMetadataCache.stop()
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
        guard isReady, tailnetSetupState.permitsPairing else { return }
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
            retryPushCleanup()
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
            retryPushCleanup()
        } catch {
            reportDeviceManagementFailure("Could not revoke paired devices", error: error)
        }
    }

    func recentAuditEntries(limit: Int = 50) -> [RemoteAccessAuditEntry] {
        auditLog.recentEntries(limit: limit)
    }

    // MARK: - Native notification delivery

    private func sendPushNotification(for event: ManagedSessionActionableEvent) {
        guard isEnabled, let pushConfiguration,
              ProviderTranscriptSupport.isManagedProvider(event.agent),
              pushTasksByEventID[event.eventID] == nil else { return }
        guard pushTasksByEventID.count < 8 else {
            ToasttyLog.warning("Notification event dropped because delivery is busy", category: .automation)
            return
        }
        let registrations = deviceStore.eligiblePushRegistrations(configuration: pushConfiguration)
        guard !registrations.isEmpty,
              sessionRuntimeStore.sessionRegistry.activeSessionIDByPanelID[event.panelID] == event.sessionID,
              let record = sessionRuntimeStore.sessionRegistry.sessionsByID[event.sessionID], record.isActive, record.agent == event.agent,
              let panel = store.state.workspacesByID.values.compactMap({ $0.allPanelsByID[event.panelID] }).first,
              case .terminal(let terminal) = panel else { return }
        if terminal.remoteConversationID == nil {
            guard store.send(.updateTerminalPanelRemoteConversationID(panelID: event.panelID, remoteConversationID: RemoteConversationID())) else { return }
        }
        guard let candidate = scanConversationCandidates(mintingIDs: false).first(where: {
                  $0.panelID == event.panelID
                      && $0.activeSessionID == event.sessionID && $0.provider == event.agent
              }) else { return }
        // The event precedes the debounced projection. Capture durable routing
        // and the current sidebar title now, while its session still matches.
        let status: RemotePushSessionStatus
        switch event.kind {
        case .turnComplete: status = .ready
        case .needsApproval: status = .needsApproval
        }
        let notification = RemotePushSessionNotification(
            eventID: event.eventID,
            conversationID: candidate.conversationID,
            sessionTitle: candidate.title,
            status: status
        )
        pushTasksByEventID[event.eventID] = Task { [weak self] in
            guard let self else { return }
            defer { self.pushTasksByEventID.removeValue(forKey: event.eventID) }
            await withTaskGroup(of: Void.self) { group in
                for (index, registration) in registrations.enumerated() {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    if index >= 4 { await group.next() }
                    group.addTask {
                        await self.deliverPushNotification(notification, to: registration, configuration: pushConfiguration)
                    }
                }
            }
        }
    }

    private func deliverPushNotification(
        _ notification: RemotePushSessionNotification,
        to registration: RemoteDevicePushRegistration,
        configuration: RemotePushConfiguration
    ) async {
        guard !Task.isCancelled, isEnabled,
              deviceStore.eligiblePushRegistrations(configuration: configuration).contains(registration) else { return }
        if await pushRelay.send(notification, to: registration) == .registrationUnavailable {
            do {
                try deviceStore.clearPushRegistration(matching: registration)
                retryPushCleanup()
            } catch {
                ToasttyLog.error("Failed to save notification grant removal", category: .automation)
            }
        }
    }

    private func retryPushCleanup() {
        guard pushCleanupTask == nil else {
            pushCleanupRequestedWhileRunning = true
            return
        }
        let pending = deviceStore.pendingPushCleanup
        guard !pending.isEmpty else { return }
        let start = nextPushCleanupIndex % pending.count
        let count = min(16, pending.count)
        let registrations = (0..<count).map { pending[(start + $0) % pending.count] }
        // Keep the unwrapped boundary so records appended during this batch
        // are first in the next batch, rather than restarting a full prefix.
        nextPushCleanupIndex = start + count
        pushCleanupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pushCleanupTask = nil
                if self.pushCleanupRequestedWhileRunning {
                    self.pushCleanupRequestedWhileRunning = false
                    self.retryPushCleanup()
                }
            }
            for registration in registrations {
                guard !Task.isCancelled else { return }
                if await self.pushRelay.revoke(registration) {
                    do { try self.deviceStore.completePushCleanup(registration) }
                    catch { ToasttyLog.error("Failed to save notification cleanup", category: .automation) }
                }
            }
        }
    }

    // MARK: - Facade surface (main-actor entry points for the bridge)

    func facadeSessionList(at date: Date) -> RemoteSessionListSnapshot {
        refreshPanelMetadata()
        return makeSessionList(at: date)
    }

    private func makeSessionList(at date: Date) -> RemoteSessionListSnapshot {
        let conversations = buildConversationSummaries()
        let associations = Self.scratchpadConversationAssociations(
            state: store.state, registry: sessionRuntimeStore.sessionRegistry,
            conversations: conversations)
        return RemoteSessionListSnapshot(
            projectionRunID: projectionStore.runID,
            conversations: conversations,
            generatedAt: date,
            workspaces: Self.workspaceInventory(
                state: store.state, metadata: panelMetadataCache.metadata, associations: associations,
                annotationColorTokens: annotationStyleStore.colorTokensByKey,
                conversationIDsBySessionID: Self.conversationIDsBySessionID(
                    activeSessionIDByConversationID, listed: conversations))
        )
    }

    /// Maps each managed session to its conversation, limited to the
    /// conversations this snapshot lists, so a subspace never names a spawner
    /// the client cannot open.
    static func conversationIDsBySessionID(
        _ activeSessionIDByConversationID: [RemoteConversationID: String],
        listed conversations: [RemoteConversationSummary]
    ) -> [String: RemoteConversationID] {
        var result: [String: RemoteConversationID] = [:]
        for conversation in conversations {
            if let sessionID = activeSessionIDByConversationID[conversation.conversationID] {
                result[sessionID] = conversation.conversationID
            }
        }
        return result
    }

    /// Keys missing from `annotationColorTokens` resolve to the style store's
    /// deterministic fallback, as the sidebar does.
    static func workspaceInventory(
        state: AppState, metadata: [UUID: RemotePanelMetadataCache.Metadata] = [:],
        associations: [UUID: RemoteConversationID] = [:],
        annotationColorTokens: [String: AnnotationColorToken] = [:],
        conversationIDsBySessionID: [String: RemoteConversationID] = [:]
    ) -> [RemoteWorkspaceSummary] {
        let parentIDs = state.subspaceParentIDsByWorkspaceID()
        var ids: [UUID] = []
        var seen: Set<UUID> = []
        for window in state.windows {
            for id in window.workspaceIDs where state.workspacesByID[id] != nil {
                if seen.insert(id).inserted { ids.append(id) }
            }
        }
        for id in state.workspacesByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids.compactMap { id in
            guard let workspace = state.workspacesByID[id] else { return nil }
            let panels = workspace.orderedTabs.flatMap { tab in
                tab.rightAuxPanel.orderedTabs.compactMap { auxiliary -> RemoteWorkspacePanel? in
                    guard case .web(let web) = auxiliary.panelState,
                          metadata[auxiliary.panelID]?.isConfirmedMissing != true else { return nil }
                    return RemoteWorkspacePanel(
                        panelID: auxiliary.panelID,
                        auxiliaryTabID: auxiliary.id,
                        workspaceTabID: tab.id,
                        workspaceTabTitle: tab.displayTitle,
                        kind: web.definition.rawValue,
                        title: web.title,
                        revision: web.scratchpad?.revision,
                        filePath: Self.localPreviewPath(web),
                        url: (web.currentURL ?? web.initialURL).flatMap(URL.init(string:)),
                        updatedAt: metadata[auxiliary.panelID]?.updatedAt,
                        associatedConversationID: web.definition == .scratchpad
                            ? associations[auxiliary.panelID] : nil
                    )
                }
            }
            let annotations = workspace.annotations
                .sorted { $0.key < $1.key }
                .map { key, annotation in
                    let token = annotationColorTokens[key]
                        ?? AnnotationStyleStore.fallbackColorToken(forKey: key)
                    return RemoteWorkspaceAnnotation(
                        key: key,
                        text: annotation.text,
                        // Persisted layouts are user-editable; send only a link the
                        // sidebar itself would open.
                        url: annotation.url
                            .flatMap(WorkspaceAnnotation.validatedURLString)
                            .flatMap(URL.init(string:)),
                        color: WorkspaceAnnotationChipPalette.hexString(token.baseHexValue)
                    )
                }
            // A spawner and a done mark mean something only for a nested
            // workspace, so they travel with a valid parent link.
            let parentID = parentIDs[id]
            return RemoteWorkspaceSummary(
                id: id, title: workspace.title, panels: panels, annotations: annotations,
                parentWorkspaceID: parentID,
                spawningConversationID: parentID == nil
                    ? nil : workspace.spawningSessionID.flatMap { conversationIDsBySessionID[$0] },
                primaryAnnotationKey: workspace.primaryAnnotationKey
                    .flatMap { workspace.annotations[$0] == nil ? nil : $0 },
                doneAt: parentID == nil ? nil : workspace.doneAt)
        }
    }

    static func scratchpadConversationAssociations(
        state: AppState, registry: SessionRegistry,
        conversations: [RemoteConversationSummary]
    ) -> [UUID: RemoteConversationID] {
        var conversationBySessionID: [String: RemoteConversationSummary] = [:]
        for conversation in conversations {
            guard let panelID = conversation.placement.panelID,
                  let workspaceID = conversation.placement.workspaceID,
                  case .terminal(let terminal)? = state.workspacesByID[workspaceID]?.panelState(for: panelID),
                  terminal.remoteConversationID == conversation.conversationID,
                  let session = registry.activeSession(for: panelID),
                  session.agent == conversation.provider else { continue }
            conversationBySessionID[session.sessionID] = conversation
        }
        var associations: [UUID: RemoteConversationID] = [:]
        for workspace in state.workspacesByID.values {
            for tab in workspace.orderedTabs {
                for panel in tab.rightAuxPanel.orderedTabs {
                    guard case .web(let web) = panel.panelState,
                          web.definition == .scratchpad,
                          let link = web.scratchpad?.sessionLink,
                          let conversation = conversationBySessionID[link.sessionID],
                          conversation.provider == link.agent else { continue }
                    // Session IDs name exact live bindings. A reused source
                    // panel or a saved title never establishes an association.
                    associations[panel.panelID] = conversation.conversationID
                }
            }
        }
        return associations
    }

    static func panelMetadataInputs(
        state: AppState, recentItems: [RecentRightPanelItem], scratchpadDirectory: URL
    ) -> [UUID: RemotePanelMetadataCache.Input] {
        let recentDates = recentItems.reduce(into: [RecentRightPanelItemID: Date]()) { result, item in
            result[item.id] = max(result[item.id] ?? .distantPast, item.updatedAt)
        }
        var inputs: [UUID: RemotePanelMetadataCache.Input] = [:]
        for workspace in state.workspacesByID.values {
            for tab in workspace.orderedTabs {
                for panel in tab.rightAuxPanel.orderedTabs {
                    guard case .web(let web) = panel.panelState else { continue }
                    let source: RemotePanelMetadataSource?
                    let recentID: RecentRightPanelItemID?
                    if let path = Self.localPreviewPath(web) {
                        source = .init(path: path, kind: .localFile)
                        recentID = web.definition == .localDocument
                            ? .localDocument(path: path)
                            : AppStore.normalizedBrowserRecentURL(web.restorableURL).map { .browser(url: $0) }
                    } else if let scratchpad = web.scratchpad, web.definition == .scratchpad {
                        source = .init(path: scratchpadDirectory.appendingPathComponent(
                            scratchpad.documentID.uuidString + ".json").path,
                            kind: .scratchpad(revision: scratchpad.revision))
                        recentID = .scratchpad(documentID: scratchpad.documentID)
                    } else {
                        source = nil
                        recentID = AppStore.normalizedBrowserRecentURL(web.restorableURL).map { .browser(url: $0) }
                    }
                    inputs[panel.panelID] = .init(source: source, recentActivityAt: recentID.flatMap { recentDates[$0] })
                }
            }
        }
        return inputs
    }

    private func refreshPanelMetadata() {
        guard isEnabled else { return }
        panelMetadataCache.updateInputs(Self.panelMetadataInputs(
            state: store.state, recentItems: store.recentRightPanelItems,
            scratchpadDirectory: previewScratchpadDirectory
        ))
        panelMetadataCache.requestRefresh()
    }

    private func updatePanelMetadataPolling() {
        guard isEnabled, connectedNativeClientCount > 0 else {
            panelMetadataPollTask?.cancel()
            panelMetadataPollTask = nil
            return
        }
        refreshPanelMetadata()
        guard panelMetadataPollTask == nil else { return }
        panelMetadataPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.isEnabled, self.connectedNativeClientCount > 0 else { return }
                self.refreshPanelMetadata()
            }
        }
    }

    private static func localPreviewPath(_ web: WebPanelState) -> String? {
        if web.definition == .localDocument { return web.filePath }
        if web.definition == .browser,
           let rawURL = web.currentURL ?? web.initialURL,
           let url = URL(string: rawURL), url.isFileURL {
            return url.path
        }
        return nil
    }

    private func previewContext(target: RemotePreviewTarget) throws -> RemotePreviewContext {
        switch target {
        case .panel(let workspaceID, let panelID):
            guard let workspace = store.state.workspacesByID[workspaceID],
                  let panel = workspace.orderedTabs.lazy.flatMap({ $0.rightAuxPanel.orderedTabs })
                    .first(where: { $0.panelID == panelID }),
                  case .web(let web) = panel.panelState else { throw RemotePreviewError.stale }
            if let path = Self.localPreviewPath(web) {
                return .init(title: web.title, source: .file(reference: path, recordedCWD: nil,
                                                           openPaths: [path], format: web.localDocument?.format,
                                                           isTranscriptLinked: false))
            }
            if web.definition == .scratchpad, let scratchpad = web.scratchpad {
                return .init(title: web.title, source: .scratchpad(documentID: scratchpad.documentID,
                                                                  revision: scratchpad.revision,
                                                                  storeDirectory: previewScratchpadDirectory))
            }
            if web.definition == .browser,
               let rawURL = web.currentURL ?? web.initialURL, let url = URL(string: rawURL) {
                return .init(title: web.title, source: .web(url))
            }
            throw RemotePreviewError.unsupported
        case .conversationFile(let conversationID, let reference):
            guard let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }),
                  let workspaceID = summary.placement.workspaceID,
                  let workspace = store.state.workspacesByID[workspaceID] else { throw RemotePreviewError.stale }
            let paths = workspace.orderedTabs.flatMap { tab in
                tab.rightAuxPanel.orderedTabs.compactMap { panel -> String? in
                    guard case .web(let web) = panel.panelState else { return nil }
                    return Self.localPreviewPath(web)
                }
            }
            // The grant comes from the Mac's own transcript data for this
            // conversation; the phone only names which reference it wants.
            let isLinked = projectionStore.isFileReferenceLinked(reference, in: conversationID)
            return .init(title: reference, source: .file(reference: reference, recordedCWD: summary.cwd,
                                                        openPaths: paths, format: nil,
                                                        isTranscriptLinked: isLinked))
        }
    }

    private func resolvePreview(_ operation: RemoteGatewayPreviewOperation) async -> RemoteGatewayHTTPResponse {
        // The provider logs failures of the read itself, where the applied
        // grant is known. Failures around it are logged here.
        var context: RemotePreviewContext?
        var stage = RemotePreviewProvider.FailureStage.context
        do {
            let captured = try previewContext(target: operation.request.target)
            context = captured
            stage = .read
            let work = Task.detached(priority: .utility) {
                try RemotePreviewProvider.response(operation: operation, context: captured)
            }
            let response = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            stage = .recheck
            guard try previewContext(target: operation.request.target) == captured else {
                throw RemotePreviewError.stale
            }
            return response
        } catch {
            if stage != .read, (error is CancellationError) == false {
                RemotePreviewProvider.logFailure(
                    error, stage: stage, request: operation.request, context: context)
            }
            return operation.errorResponse((error as? RemotePreviewError) ?? .missing)
        }
    }

    func facadeConversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
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

    /// Marks a subspace done or open again for a remote client, through the
    /// same reducer action as the sidebar checkbox, so its rules (subspaces
    /// only, an existing mark keeps its time) hold for every caller.
    func setWorkspaceDone(
        _ request: RemoteWorkspaceDoneRequest,
        device _: RemoteDeviceRecord
    ) -> RemoteWorkspaceDoneResult {
        var result = RemoteWorkspaceDoneResult.workspaceNotFound
        if isReady, let workspace = store.state.workspacesByID[request.workspaceID] {
            result = Self.workspaceDoneResult(
                requestedDone: request.done,
                isSubspace: store.state.subspaceParentIDsByWorkspaceID()[request.workspaceID] != nil,
                isDone: workspace.doneAt != nil,
                hasWorkInProgress: scanConversationCandidates(mintingIDs: false).contains { candidate in
                    guard candidate.workspaceID == request.workspaceID else { return false }
                    switch candidate.presentationStatus {
                    case .working?, .needsApproval?, .error?: return true
                    case .ready?, .idle?, nil: return false
                    }
                }
            )
            if result == .updated {
                let didChange = store.send(.setWorkspaceDone(
                    workspaceID: request.workspaceID,
                    doneAt: request.done ? Date() : nil
                ))
                if didChange == false { result = .unchanged }
            }
        }
        ToasttyLog.info(
            "Remote workspace done request evaluated",
            category: .automation,
            metadata: [
                "workspace_id": request.workspaceID.uuidString,
                "done": String(request.done),
                "result": result.rawValue,
            ]
        )
        if result == .updated {
            // Publish now so the requesting client confirms its optimistic
            // check; this cancels the coalesced broadcast the store action
            // scheduled for the same change.
            broadcastSessionList()
        }
        return result
    }

    /// Sets or clears a session's "Flag for Later" mark for a remote client,
    /// through the same store call as the sidebar's context menu item. The
    /// Mac still clears the mark itself when the session starts new work.
    func setConversationFlag(
        _ request: RemoteConversationFlagRequest,
        device _: RemoteDeviceRecord
    ) -> RemoteConversationFlagResult {
        var result = RemoteConversationFlagResult.conversationNotFound
        // A fresh scan rather than the debounced conversation map, so a
        // session that ended a moment ago is refused instead of "updated".
        if isReady, let sessionID = scanConversationCandidates(mintingIDs: false)
            .first(where: { $0.conversationID == request.conversationID })?.activeSessionID {
            if sessionRuntimeStore.isLaterFlagged(sessionID: sessionID) == request.flagged {
                result = .unchanged
            } else {
                sessionRuntimeStore.setLaterFlag(sessionID: sessionID, isFlagged: request.flagged)
                result = .updated
            }
        }
        ToasttyLog.info(
            "Remote conversation flag request evaluated",
            category: .automation,
            metadata: [
                "conversation_id": request.conversationID.rawValue.uuidString,
                "flagged": String(request.flagged),
                "result": result.rawValue,
            ]
        )
        if result == .updated {
            broadcastSessionList()
        }
        return result
    }

    /// A client offers the checkbox only on a quiet subspace, so a request
    /// to mark one done while a session works, waits on approval, or failed
    /// is late: an agent started after the tap. Refusing it keeps a delayed
    /// request from restoring a mark that new work just cleared. Opening a
    /// task again is always allowed.
    nonisolated static func workspaceDoneResult(
        requestedDone: Bool,
        isSubspace: Bool,
        isDone: Bool,
        hasWorkInProgress: Bool
    ) -> RemoteWorkspaceDoneResult {
        guard isSubspace else { return .notSubspace }
        guard isDone != requestedDone else { return .unchanged }
        if requestedDone, hasWorkInProgress { return .workInProgress }
        return .updated
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

    private static func conversationPlacements(
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

    private func scanConversationCandidates(mintingIDs: Bool) -> [ConversationCandidate] {
        let registry = sessionRuntimeStore.sessionRegistry
        var candidates: [ConversationCandidate] = []
        var seenPanelIDs: Set<UUID> = []

        for workspace in store.state.workspacesByID.values {
            for (panelID, panelState) in workspace.allPanelsByID {
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
                        guard let resumeRecord = terminalState.resumeRecord,
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
                    isFlaggedForLater: hasLiveAgent
                        && activeSessionID.map(sessionRuntimeStore.isLaterFlagged(sessionID:)) == true,
                    turnStartedAt: panelStatus?.turnStartedAt,
                    lastTurnDuration: panelStatus?.lastTurnDuration,
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
        discardQueuedEntries(sendQueue.removeAll(for: conversationID))
        sendQueue.removeConversation(conversationID)
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
        pendingSendCorrelator.discard(for: conversationID)
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

    private func broadcastEvents(
        _ events: [ConversationEvent],
        for conversationID: RemoteConversationID,
        sessionListChanged: Bool = false
    ) {
        guard isEnabled, let projector = projectionStore.projectorState(for: conversationID) else {
            return
        }
        if !events.isEmpty {
            server.broadcast(.conversationEvents(ConversationEventPage(
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

    private func broadcastSessionList() {
        guard isEnabled else { return }
        sessionListBroadcastTask?.cancel()
        sessionListBroadcastTask = nil
        let snapshot = makeSessionList(at: Date())
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

    func performQuestionAnswer(_ request: RemoteQuestionAnswerRequest, device: RemoteDeviceRecord) -> RemoteQuestionAnswerResult {
        guard device.scopes.contains(.send) else { return .rejected(reason: .sendScopeDenied) }
        guard sessionWritePolicy.isEnabled(for: request.conversationID) else { return .rejected(reason: .sessionWritesDisabled) }
        guard isReady,
              let panelID = panelIDByConversationID[request.conversationID],
              let sessionID = activeSessionIDByConversationID[request.conversationID] else {
            return .rejected(reason: .notBound)
        }
        guard let interaction = projectionStore.pendingInteractions(for: request.conversationID)
            .first(where: { $0.id == request.interactionID }) else { return .rejected(reason: .notPending) }
        guard interaction.inputEpoch == request.expectedInputEpoch else { return .rejected(reason: .epochMismatch) }
        guard interaction.responseID == request.responseID else { return .rejected(reason: .notPending) }
        return sessionRuntimeStore.submitClaudeQuestion(request, sessionID: sessionID, panelID: panelID)
    }

    // MARK: - Gated free-form send

    private func performRemoteAttachmentSend(_ request: RemoteMessageSendRequest, device: RemoteDeviceRecord) async -> RemoteMessageSendResult {
        if coordinator.hasProcessed(request.clientRequestID, for: request.conversationID) { return .duplicate }
        let staged: RemoteMessageAttachmentStore.Staged
        do { staged = try await attachmentStore.stage(request.attachments) }
        catch RemoteMessageAttachmentStore.StorageError.invalidAttachments { return .rejected(reason: .invalidAttachments) }
        catch { return .rejected(reason: .attachmentStorageUnavailable) }
        let result: RemoteMessageSendResult
        // Staging suspends. Re-read authorization and every input gate only
        // after it completes; delivery itself remains synchronous.
        if !Task.isCancelled, let currentDevice = deviceStore.devices.first(where: {
            $0.id == device.id && !$0.isRevoked && $0.authKind == .native && $0.scopes.contains(.send)
        }) {
            result = performRemoteSend(request, device: currentDevice, deliveredText: staged.deliveryText(for: request), staged: staged)
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
        device: RemoteDeviceRecord
    ) -> RemoteInputCoordinator.DeliveryContext {
        let promptState = terminalRuntimeRegistry.promptState(panelID: panelID)
        // A managed agent TUI commonly reports `.busy` even when its own
        // provider lifecycle says the composer is open. Provider availability
        // remains authoritative; this check only rejects a missing or exited
        // surface.
        return RemoteInputCoordinator.DeliveryContext(
            deviceHasSendScope: device.scopes.contains(.send),
            sessionWritesEnabled: sessionWritePolicy.isEnabled(for: conversationID),
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
        device: RemoteDeviceRecord,
        staged: RemoteMessageAttachmentStore.Staged?
    ) -> RemoteMessageSendResult {
        let conversationID = request.conversationID
        guard isReady,
              let panelID = panelIDByConversationID[conversationID],
              let projector = projectionStore.projectorState(for: conversationID) else {
            return .rejected(reason: .notBound)
        }
        if coordinator.hasProcessed(request.clientRequestID, for: conversationID) {
            return .duplicate
        }
        let context = deliveryContext(for: conversationID, panelID: panelID, device: device)
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
            deviceID: device.id,
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
        device: RemoteDeviceRecord,
        deliveredText: String?
    ) -> RemoteMessageSendResult {
        let conversationID = request.conversationID
        guard isReady,
              let panelID = panelIDByConversationID[conversationID],
              let projector = projectionStore.projectorState(for: conversationID) else {
            return .rejected(reason: .notBound)
        }
        guard Self.steerCapableProviders.contains(projector.provider) else {
            return .rejected(reason: .steerUnavailable)
        }
        let context = deliveryContext(for: conversationID, panelID: panelID, device: device)
        switch coordinator.evaluateSteer(request, context: context) {
        case .duplicate:
            return .duplicate
        case .reject(let reason):
            return .rejected(reason: reason)
        case .accept(let turnEpoch):
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
                recordPendingSend(request, for: conversationID, deliveredText: deliveredText, confirmationTimeout: Self.steerConfirmationTimeout, deliveryMode: .steer)
                broadcastSessionList()
                return .uncertain
            case .delivered:
                coordinator.markSteerDelivered(request)
                recordPendingSend(request, for: conversationID, deliveredText: deliveredText, confirmationTimeout: Self.steerConfirmationTimeout, deliveryMode: .steer)
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
        device _: RemoteDeviceRecord
    ) -> RemoteConversationQueueUpdateResult {
        let conversationID = request.conversationID
        guard isReady, panelIDByConversationID[conversationID] != nil else {
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
        device: RemoteDeviceRecord
    ) -> RemoteConversationInterruptResult {
        let conversationID = request.conversationID
        guard isReady, let panelID = panelIDByConversationID[conversationID] else {
            return .rejected(reason: .notBound)
        }
        let context = deliveryContext(for: conversationID, panelID: panelID, device: device)
        let result: RemoteConversationInterruptResult
        switch coordinator.evaluateInterrupt(
            for: conversationID,
            expectedTurnEpoch: request.expectedTurnEpoch,
            context: context
        ) {
        case .reject(let reason):
            result = .rejected(reason: reason)
        case .accept:
            let delivery = terminalRuntimeRegistry.sendRemoteInterrupt(
                panelID: panelID,
                focusPolicy: .preserveFirstResponder
            )
            if delivery == .delivered {
                sendQueue.pause(conversationID)
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

    private func drainSendQueues() {
        for conversationID in sendQueue.conversationIDs {
            drainSendQueue(for: conversationID)
        }
    }

    /// Delivers the next queued entry when, and only when, the coordinator
    /// reports an open prompt. One entry per open prompt: delivery consumes
    /// the prompt, and the rest wait for the turn it starts to end.
    private func drainSendQueue(for conversationID: RemoteConversationID) {
        guard isReady, let entry = sendQueue.next(for: conversationID) else { return }
        guard case .openPrompt(let epoch) = coordinator.availability(for: conversationID) else { return }
        guard entry.bindingID == epoch.bindingID else {
            expireStaleQueueEntries(for: conversationID, bindingID: epoch.bindingID)
            return
        }
        guard let device = deviceStore.devices.first(where: {
            $0.id == entry.deviceID && !$0.isRevoked && $0.scopes.contains(.send)
        }) else {
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
            device: device,
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
        let acceptsWrites = sessionWritePolicy.isEnabled(for: conversationID)
            && activeSessionIDByConversationID[conversationID] != nil
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
        device: RemoteDeviceRecord,
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
            return enqueueRemoteSend(request, device: device, staged: staged)
        case .steer:
            return performRemoteSteer(request, device: device, deliveredText: deliveredText)
        }
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
        let context = deliveryContext(for: conversationID, panelID: panelID, device: device)

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
                recordPendingSend(request, for: conversationID, deliveredText: deliveredText, deliveryMode: recordedDeliveryMode)
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
                recordPendingSend(request, for: conversationID, deliveredText: deliveredText, deliveryMode: recordedDeliveryMode)
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
        let couldSteer = coordinator.canSteer(for: conversationID)
        coordinator.noteLocalInput(for: conversationID)
        logCoordinatorAvailabilityTransition(
            for: conversationID,
            source: "local_terminal_input",
            previous: previous
        )
        if previous.allowsRemoteSend || couldSteer != coordinator.canSteer(for: conversationID) {
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

    private func recordPendingSend(
        _ request: RemoteMessageSendRequest,
        for conversationID: RemoteConversationID,
        deliveredText: String? = nil,
        confirmationTimeout: Duration? = nil,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) {
        precondition(request.conversationID == conversationID)
        let confirmationTimeout = confirmationTimeout ?? sendConfirmationTimeout
        pendingSendCorrelator.record(request, deliveredText: deliveredText, deliveryMode: deliveryMode)
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
                try await Task.sleep(for: confirmationTimeout)
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
        if let sessionID = activeSessionIDByConversationID[conversationID],
           let panelID = panelIDByConversationID[conversationID] {
            sessionRuntimeStore.reconcileClaudeQuestionTranscript(observations, sessionID: sessionID, panelID: panelID)
        }
        let stamped = pendingSendCorrelator.stamp(observations, for: conversationID)
        for observation in stamped {
            guard case .transcript(.userMessage(let payload)) = observation.payload else { continue }
            if payload.clientRequestID == nil, observation.mayAuthorizeCurrentRuntime {
                // The Mac user submitted what they typed: the running turn no
                // longer holds a local draft that a steer or the next prompt
                // must avoid.
                coordinator.noteLocalDraftSubmitted(for: conversationID)
            }
            guard let clientRequestID = payload.clientRequestID else {
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

    // MARK: - Session start

    func sessionStartOptions(
        _ request: RemoteSessionStartOptionsRequest,
        device: RemoteDeviceRecord
    ) -> RemoteSessionStartOptionsResponse {
        sessionStarter?.options(for: request, device: device)
            ?? RemoteSessionStartOptionsResponse(
                permission: RemoteGatewayRequestHandler.sessionStartPermission(for: device),
                workspace: .notFound
            )
    }

    /// Models that this provider's listed sessions report, most recently
    /// active first, without repeats.
    private func recentModels(for provider: AgentKind) -> [String] {
        var seen: Set<String> = []
        return buildConversationSummaries()
            .filter { $0.provider == provider }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { $0.executionProfile?.modelIdentifier }
            // Only values a start request would accept back.
            .filter {
                RemoteSessionStartPolicy.isValidSelectionValue(
                    $0, maximumLength: RemoteSessionStartPolicy.maximumModelLength
                )
            }
            .filter { seen.insert($0).inserted }
    }

    func setDeviceSessionStart(_ enabled: Bool, for deviceID: UUID) {
        guard let device = deviceStore.devices.first(where: { $0.id == deviceID }),
              device.isRevoked == false else { return }
        do {
            guard try deviceStore.setSessionStartDisabled(enabled == false, forDevice: deviceID) else { return }
        } catch {
            reportDeviceManagementFailure("Could not update device permissions", error: error)
            return
        }
        auditLog.record(RemoteAccessAuditEntry(
            at: Date(),
            action: .deviceScopesChanged,
            deviceID: deviceID,
            detail: enabled ? "start_enabled" : "start_disabled"
        ))
        deviceManagementError = nil
        refreshDevices()
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
        if let canonicalOrigin = publicGatewayURL?.absoluteString {
            origins.insert(canonicalOrigin)
        }
        handler.updateConfiguration(RemoteGatewayConfiguration(
            allowedOrigins: origins,
            staticResources: Self.loadWebClientResources(),
            pushConfiguration: pushConfiguration
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
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        let host = rawHost.lowercased()
        guard host != "ts.net", host.hasSuffix(".ts.net") else { return nil }
        components.scheme = "https"
        components.host = host
        if components.port == 443 { components.port = nil }
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
