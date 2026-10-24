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

/// Bridges the gateway's authenticated close request into the main-actor-owned
/// workspace layout.
final class RemoteAccessConversationCloseBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func close(
        _ request: RemoteConversationCloseRequest,
        device: RemoteDeviceRecord
    ) -> RemoteConversationCloseResult {
        MainActor.assumeIsolated {
            service?.closeConversation(request, device: device) ?? .conversationNotFound
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

/// Bridges the gateway's authenticated draft release into the main-actor-owned
/// input coordinator.
final class RemoteAccessLocalDraftReleaseBridge: @unchecked Sendable {
    weak var service: RemoteAccessService?

    func release(
        _ request: RemoteConversationLocalDraftReleaseRequest,
        device: RemoteDeviceRecord
    ) -> RemoteConversationLocalDraftReleaseResult {
        MainActor.assumeIsolated {
            service?.performLocalDraftRelease(request, device: device) ?? .rejected(reason: .notBound)
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

/// Process-local enrichment that correlates an accepted conversation send with the
/// next matching provider transcript user message. This must be expired when
/// a transcript file is replaced: the replacement tailer replays history from
/// byte zero, and historical same-text input cannot confirm a new send.
struct RemotePendingSendCorrelator: Sendable {
    private struct PendingSend: Sendable {
        var clientRequestID: String
        var trimmedText: String
        var displayText: String?
        var origin: ConversationMessageOrigin
        var deliveryMode: RemoteMessageDeliveryMode
        /// Reported unconfirmed after its deadline. It may still be the next
        /// user message: a provider can hold a delivery in its prompt until
        /// someone submits it on the Mac.
        var isExpired = false
    }

    private var pendingSendsByConversationID: [RemoteConversationID: [PendingSend]] = [:]

    var conversationIDs: Set<RemoteConversationID> {
        Set(pendingSendsByConversationID.keys)
    }

    mutating func record(
        _ request: RemoteMessageSendRequest,
        deliveredText: String? = nil,
        origin: ConversationMessageOrigin = .remote,
        deliveryMode: RemoteMessageDeliveryMode = .prompt
    ) {
        let pendingSend = PendingSend(
            clientRequestID: request.clientRequestID,
            trimmedText: (deliveredText ?? request.text).trimmingCharacters(in: .whitespacesAndNewlines),
            displayText: request.attachments.isEmpty ? nil : request.displayText,
            origin: origin,
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

    func contains(clientRequestID: String, for conversationID: RemoteConversationID) -> Bool {
        pendingSendsByConversationID[conversationID]?.contains { $0.clientRequestID == clientRequestID } == true
    }

    mutating func discard(for conversationID: RemoteConversationID) {
        pendingSendsByConversationID.removeValue(forKey: conversationID)
    }

    mutating func discard(clientRequestID: String, for conversationID: RemoteConversationID) {
        guard var pending = pendingSendsByConversationID[conversationID] else { return }
        pending.removeAll { $0.clientRequestID == clientRequestID }
        store(pending, for: conversationID)
    }

    /// Keeps a send whose deadline passed matchable by the next user message
    /// only. See `stamp`.
    mutating func expire(clientRequestID: String, for conversationID: RemoteConversationID) {
        guard var pending = pendingSendsByConversationID[conversationID],
              let index = pending.firstIndex(where: { $0.clientRequestID == clientRequestID }) else {
            return
        }
        pending[index].isExpired = true
        pendingSendsByConversationID[conversationID] = pending
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
            guard let pending = takeConfirmingSend(text: trimmed, for: conversationID) else {
                return observation
            }
            var stampedPayload = payload
            if let displayText = pending.displayText { stampedPayload.text = displayText }
            stampedPayload.origin = pending.origin
            stampedPayload.clientRequestID = pending.clientRequestID
            stampedPayload.deliveryMode = pending.deliveryMode == .prompt ? nil : pending.deliveryMode
            var stamped = observation
            stamped.payload = .transcript(.userMessage(stampedPayload))
            return stamped
        }
    }

    /// Delivery and provider logs are ordered, so normally only the oldest
    /// pending send can confirm against the next user message; a mismatch
    /// expires it rather than misattributing a later identical local message.
    /// An expired send breaks that order: its late echo can arrive at any
    /// point, or never. While one is pending, a user message confirms
    /// whichever pending send has its text and consumes no other send. A user
    /// message that matches nothing ends every expired send's chance to
    /// confirm, so a much later identical message cannot claim one.
    private mutating func takeConfirmingSend(
        text: String,
        for conversationID: RemoteConversationID
    ) -> PendingSend? {
        guard var pendingSends = pendingSendsByConversationID[conversationID],
              pendingSends.isEmpty == false else {
            pendingSendsByConversationID.removeValue(forKey: conversationID)
            return nil
        }
        let match: PendingSend?
        if pendingSends.contains(where: \.isExpired) {
            match = pendingSends.firstIndex { $0.trimmedText == text }.map { pendingSends.remove(at: $0) }
            if match == nil {
                pendingSends.removeAll(where: \.isExpired)
            }
        } else {
            let oldest = pendingSends.removeFirst()
            match = oldest.trimmedText == text ? oldest : nil
        }
        store(pendingSends, for: conversationID)
        return match
    }

    private mutating func store(_ pendingSends: [PendingSend], for conversationID: RemoteConversationID) {
        if pendingSends.isEmpty {
            pendingSendsByConversationID.removeValue(forKey: conversationID)
        } else {
            pendingSendsByConversationID[conversationID] = pendingSends
        }
    }
}

/// Listener state is independent of local conversation tracking.
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

/// Owns network access and device policy. Conversation state and delivery
/// belong to the injected service shared with native conversation surfaces.
@MainActor
final class RemoteAccessService: ObservableObject {
    let conversationService: ConversationService
    private var conversationTrackingCancellables: Set<AnyCancellable> = []
    private var sessionListBroadcastTask: Task<Void, Never>?
    private var storeActionObserverToken: UUID?
    private typealias ConversationCandidate = ConversationService.ConversationCandidate
    static let steerCapableProviders = ConversationService.steerCapableProviders

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
    private let pushMacPresence: @MainActor () -> RemotePushMacPresence
    private var pushTasksByEventID: [UUID: Task<Void, Never>] = [:]
    private var pushCleanupTask: Task<Void, Never>?
    private var nextPushCleanupIndex = 0
    private var pushCleanupRequestedWhileRunning = false
    private var pushForegroundObserver: AnyCancellable?
    private let auditLog: RemoteAccessAuditLog
    private let facadeBridge = RemoteAccessFacadeBridge()
    private let sendBridge = RemoteAccessSendBridge()
    private let questionAnswerBridge = RemoteAccessQuestionAnswerBridge()
    private let readAcknowledgementBridge = RemoteAccessReadAcknowledgementBridge()
    private let workspaceDoneBridge = RemoteAccessWorkspaceDoneBridge()
    private let conversationFlagBridge = RemoteAccessConversationFlagBridge()
    private let conversationCloseBridge = RemoteAccessConversationCloseBridge()
    private let sessionCloseController: SessionCloseController?
    private let queueUpdateBridge = RemoteAccessQueueUpdateBridge()
    private let interruptBridge = RemoteAccessInterruptBridge()
    private let localDraftReleaseBridge = RemoteAccessLocalDraftReleaseBridge()
    private let sessionStartBridge = RemoteAccessSessionStartBridge()
    private var sessionStarter: RemoteSessionStarter?
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
        conversationService: ConversationService? = nil,
        sessionLauncher: (any RemoteSessionLaunching)? = nil,
        sessionCloseController: SessionCloseController? = nil,
        sessionExitController: SessionExitController? = nil,
        port: UInt16 = RemoteAccessPreferences.loadPort(),
        initiallyEnabled: Bool = RemoteAccessPreferences.loadEnabled(),
        claudePromptStabilizationDelay: Duration = .milliseconds(500),
        sendConfirmationTimeout: Duration = .seconds(10),
        steerConfirmationTimeout: Duration = .seconds(180),
        codexTurnConfirmationTimeout: Duration = .seconds(300),
        localDraftEpochBroadcastInterval: Duration = .milliseconds(500),
        pushConfiguration: RemotePushConfiguration? = .configured(),
        pushRelay: any RemotePushRelaying = RemotePushRelayClient(),
        pushMacPresence: @escaping @MainActor () -> RemotePushMacPresence = { .current() },
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
        self.conversationService = conversationService ?? ConversationService(
            store: store, sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry, runtimePaths: runtimePaths,
            claudePromptStabilizationDelay: claudePromptStabilizationDelay,
            sendConfirmationTimeout: sendConfirmationTimeout,
            steerConfirmationTimeout: steerConfirmationTimeout,
            codexTurnConfirmationTimeout: codexTurnConfirmationTimeout,
            localDraftEpochBroadcastInterval: localDraftEpochBroadcastInterval
        )
        self.previewScratchpadDirectory = runtimePaths.scratchpadDocumentsDirectoryURL
        self.store = store
        self.annotationStyleStore = annotationStyleStore
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.sessionCloseController = sessionCloseController
        self.port = port
        self.tailnetServeSetup = tailnetServeSetup
        self.pushConfiguration = pushConfiguration
        self.pushRelay = pushRelay
        self.pushMacPresence = pushMacPresence
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
            conversationCloseHandler: { [conversationCloseBridge] request, device in
                conversationCloseBridge.close(request, device: device)
            },
            queueUpdateHandler: { [queueUpdateBridge] request, device in
                queueUpdateBridge.update(request, device: device)
            },
            interruptHandler: { [interruptBridge] request, device in
                interruptBridge.interrupt(request, device: device)
            },
            localDraftReleaseHandler: { [localDraftReleaseBridge] request, device in
                localDraftReleaseBridge.release(request, device: device)
            }
        )
        self.server = gatewayServerFactory(handler)
        self.conversationService.remoteAuthorization = { [weak self] deviceID, conversationID in
            guard let self, self.isReady,
                  let device = self.deviceStore.devices.first(where: { $0.id == deviceID && !$0.isRevoked }) else { return .denied }
            return ConversationService.Authorization(
                canSend: device.scopes.contains(.send),
                writesEnabled: self.sessionWritePolicy.isEnabled(for: conversationID),
                canApprovePermissions: device.canApprovePermissions,
                canSendAttachments: device.authKind == .native
            )
        }
        self.conversationService.onRemoteEvent = { [weak self] message in
            guard let self, self.isEnabled else { return }
            self.server.broadcast(message)
        }
        self.conversationService.onInventoryChanged = { [weak self] in
            guard let self, self.isEnabled else { return }
            let sessions = self.buildConversationSummaries().filter {
                ProviderTranscriptSupport.isManagedProvider($0.provider)
            }
            if self.writeControllableSessions != sessions {
                self.writeControllableSessions = sessions
            }
            self.broadcastSessionList()
        }
        handler.previewHandler = { [weak self] operation in
            guard let self else { return operation.errorResponse(.stale) }
            return await self.resolvePreview(operation)
        }
        handler.attachmentSendHandler = { [weak self] request, device in
            guard let self else { return .rejected(reason: .notBound) }
            return await self.performRemoteAttachmentSend(request, device: device)
        }
        Task { [attachmentStore = self.conversationService.attachmentStore] in try? await attachmentStore.cleanup() }
        panelMetadataCache.onChange = { [weak self] in self?.scheduleSessionListBroadcast() }
        self.devices = deviceStore.devices
        facadeBridge.service = self
        sendBridge.service = self
        questionAnswerBridge.service = self
        readAcknowledgementBridge.service = self
        workspaceDoneBridge.service = self
        conversationFlagBridge.service = self
        conversationCloseBridge.service = self
        queueUpdateBridge.service = self
        interruptBridge.service = self
        localDraftReleaseBridge.service = self
        sessionStartBridge.service = self
        sessionExitController?.remoteInputProbe = self.conversationService
        sessionStarter = RemoteSessionStarter(
            store: store,
            launcher: sessionLauncher,
            attachmentStore: self.conversationService.attachmentStore,
            deviceMayStart: { [weak self] deviceID in
                guard let self, self.isEnabled else { return false }
                return self.deviceStore.devices.first { $0.id == deviceID }?.canStartSessions ?? false
            },
            recentModels: { [weak self] provider in self?.recentModels(for: provider) ?? [] },
            publishSessionList: { [weak self] in self?.syncConversations() },
            sessionStartedInNewTab: { [weak sessionExitController] sessionID in
                sessionExitController?.markClosesPaneOnCleanExit(sessionID: sessionID)
            }
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
        // SessionRuntimeStore has already accepted and deduplicated the event.
        // Drop it now while the Mac is in use; becoming idle must not replay it.
        guard pushMacPresence().allowsPush else { return }
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
            projectionRunID: conversationService.projectionStore.runID,
            conversations: conversations,
            generatedAt: date,
            workspaces: Self.workspaceInventory(
                state: store.state, metadata: panelMetadataCache.metadata, associations: associations,
                annotationColorTokens: annotationStyleStore.colorTokensByKey,
                conversationIDsBySessionID: Self.conversationIDsBySessionID(
                    conversationService.activeSessionIDByConversationID, listed: conversations))
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
        if web.definition == .localDocument { return web.localDocument?.filePath }
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
            let isLinked = conversationService.projectionStore.isFileReferenceLinked(reference, in: conversationID)
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
        guard let projector = conversationService.projectionStore.projectorState(for: request.conversationID),
              let mappedPanelID = conversationService.panelIDByConversationID[request.conversationID],
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
            currentProjectionRunID: conversationService.projectionStore.runID,
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

    /// Closes a session's pane for a remote client, through the same controller
    /// as the sidebar's Close Session item. Like interrupt, it needs session
    /// writes, because it can stop a running agent.
    func closeConversation(
        _ request: RemoteConversationCloseRequest,
        device _: RemoteDeviceRecord
    ) -> RemoteConversationCloseResult {
        var result = RemoteConversationCloseResult.conversationNotFound
        // A fresh scan, as for flags, so a pane closed a moment ago is
        // reported missing rather than closed twice.
        if isReady, let candidate = scanConversationCandidates(mintingIDs: false)
            .first(where: { $0.conversationID == request.conversationID }) {
            if sessionWritePolicy.isEnabled(for: request.conversationID) == false {
                result = .sessionWritesDisabled
            } else if let sessionCloseController {
                result = switch sessionCloseController.closeSession(
                    panelID: candidate.panelID,
                    stopIfBusy: request.stopIfBusy,
                    confirmedWorkspaceCloseID: request.confirmedWorkspaceCloseID,
                    source: AppActionSource("remote_access", detail: "conversation_close")
                ) {
                case .closed: .closed
                case .confirmationRequired: .confirmationRequired
                case .workspaceCloseConfirmationRequired: .workspaceConfirmationRequired
                case .unsavedDocument: .unsavedDocument
                case .notFound: .conversationNotFound
                case .failed: .failed
                }
            } else {
                result = .failed
            }
        }
        ToasttyLog.info(
            "Remote conversation close request evaluated",
            category: .automation,
            metadata: [
                "conversation_id": request.conversationID.rawValue.uuidString,
                "stop_if_busy": String(request.stopIfBusy),
                "confirmed_workspace_close_id": request.confirmedWorkspaceCloseID?.uuidString ?? "none",
                "result": result.rawValue,
            ]
        )
        if result == .closed {
            syncConversations()
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
    /// active first, without repeats. Sessions report a model only while
    /// remote access is on.
    func recentModels(for provider: AgentKind) -> [String] {
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

    func setDevicePermissionApproval(_ enabled: Bool, for deviceID: UUID) {
        guard let device = deviceStore.devices.first(where: { $0.id == deviceID }),
              device.isRevoked == false else { return }
        do {
            guard try deviceStore.setPermissionApprovalEnabled(enabled, forDevice: deviceID) else { return }
        } catch {
            reportDeviceManagementFailure("Could not update device permissions", error: error)
            return
        }
        auditLog.record(RemoteAccessAuditEntry(
            at: Date(),
            action: .deviceScopesChanged,
            deviceID: deviceID,
            detail: enabled ? "approve_enabled" : "approve_disabled"
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
    private func syncConversations(broadcast: Bool = true) { conversationService.syncConversations(broadcast: broadcast) }
    private func scanConversationCandidates(mintingIDs: Bool) -> [ConversationCandidate] {
        conversationService.scanConversationCandidates(mintingIDs: mintingIDs)
    }
    private func buildConversationSummaries() -> [RemoteConversationSummary] {
        conversationService.buildConversationSummaries().map { summary in
            var summary = summary
            summary.inputAvailability = sessionWritePolicy.inputAvailability(providerAvailability: summary.inputAvailability, for: summary.conversationID)
            if !sessionWritePolicy.isEnabled(for: summary.conversationID) {
                summary.inputControl?.canQueue = false
                summary.inputControl?.canSteer = false
                summary.inputControl?.canInterrupt = false
            }
            return summary
        }
    }
    func facadeConversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot? {
        guard var snapshot = conversationService.localSnapshot(for: conversationID, at: date) else { return nil }
        if let summary = buildConversationSummaries().first(where: { $0.conversationID == conversationID }) { snapshot.summary = summary }
        return snapshot
    }
    func facadeConversationEvents(for conversationID: RemoteConversationID, after cursor: ConversationEventCursor?, limit: Int) -> ConversationEventPageOutcome {
        conversationService.events(for: conversationID, after: cursor, limit: limit)
    }
    func facadeConversationEvents(for conversationID: RemoteConversationID, before cursor: ConversationEventBackwardCursor?, limit: Int) -> ConversationEventPageOutcome {
        conversationService.events(for: conversationID, before: cursor, limit: limit)
    }
    func performRemoteSend(_ request: RemoteMessageSendRequest, device: RemoteDeviceRecord, deliveredText: String? = nil, staged: RemoteMessageAttachmentStore.Staged? = nil, recordedDeliveryMode: RemoteMessageDeliveryMode = .prompt) -> RemoteMessageSendResult {
        guard isReady else { return .rejected(reason: .notBound) }
        return conversationService.performRemoteSend(request, source: .remoteDevice(device.id), deliveredText: deliveredText, staged: staged, recordedDeliveryMode: recordedDeliveryMode)
    }
    private func performRemoteAttachmentSend(_ request: RemoteMessageSendRequest, device: RemoteDeviceRecord) async -> RemoteMessageSendResult {
        guard isReady else { return .rejected(reason: .notBound) }
        return await conversationService.send(request, source: .remoteDevice(device.id))
    }
    func performQuestionAnswer(_ request: RemoteQuestionAnswerRequest, device: RemoteDeviceRecord) -> RemoteQuestionAnswerResult {
        guard isReady else { return .rejected(reason: .notBound) }
        return conversationService.performQuestionAnswer(request, source: .remoteDevice(device.id))
    }
    func performQueueUpdate(_ request: RemoteConversationQueueUpdateRequest, device: RemoteDeviceRecord) -> RemoteConversationQueueUpdateResult {
        guard isReady else { return .conversationNotFound }
        return conversationService.performQueueUpdate(request, source: .remoteDevice(device.id))
    }
    func performRemoteInterrupt(_ request: RemoteConversationInterruptRequest, device: RemoteDeviceRecord) -> RemoteConversationInterruptResult {
        guard isReady else { return .rejected(reason: .notBound) }
        return conversationService.performRemoteInterrupt(request, source: .remoteDevice(device.id))
    }
    func performLocalDraftRelease(_ request: RemoteConversationLocalDraftReleaseRequest, device: RemoteDeviceRecord) -> RemoteConversationLocalDraftReleaseResult {
        guard isReady else { return .rejected(reason: .notBound) }
        return conversationService.performLocalDraftRelease(request, source: .remoteDevice(device.id))
    }
    @discardableResult
    func noteLocalInput(panelID: UUID, kind: TerminalLocalInputKind = .key) -> Bool {
        conversationService.noteLocalInput(panelID: panelID, kind: kind)
    }
    nonisolated static func remotePresentationStatus(for kind: SessionStatusKind, isUnread: Bool) -> RemoteSessionPresentationStatus {
        ConversationService.remotePresentationStatus(for: kind, isUnread: isUnread)
    }
    nonisolated static func remoteStatusDetail(from detail: String?) -> String? { ConversationService.remoteStatusDetail(from: detail) }
    private func beginConversationTracking() {
        conversationService.setRemoteTrackingEnabled(true)
        panelMetadataCache.start()
        store.$state.combineLatest(store.$recentRightPanelItems)
            .sink { [weak self] state, recentItems in
                guard let self else { return }
                self.panelMetadataCache.updateInputs(Self.panelMetadataInputs(state: state, recentItems: recentItems, scratchpadDirectory: self.previewScratchpadDirectory))
            }.store(in: &conversationTrackingCancellables)
        annotationStyleStore.$colorTokensByKey.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.scheduleSessionListBroadcast() }
            .store(in: &conversationTrackingCancellables)
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            guard let self, self.isEnabled else { return }
            let colors = self.annotationStyleStore.colorTokensByKey
            if Self.workspaceInventory(state: previousState, annotationColorTokens: colors) != Self.workspaceInventory(state: nextState, annotationColorTokens: colors) {
                self.scheduleSessionListBroadcast()
            }
            switch action {
            case .setWorkspaceParent, .updateScratchpadPanelState:
                self.scheduleSessionListBroadcast()
            default: break
            }
        }
    }
    private func endConversationTracking() {
        if let storeActionObserverToken {
            store.removeActionAppliedObserver(storeActionObserverToken)
            self.storeActionObserverToken = nil
        }
        conversationTrackingCancellables.removeAll()
        panelMetadataPollTask?.cancel()
        panelMetadataPollTask = nil
        panelMetadataCache.stop()
        conversationService.setRemoteTrackingEnabled(false)
        writeControllableSessions = []
        loggedPresentationStateByConversationID.removeAll()
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

}
