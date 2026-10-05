import CoreState
import Foundation
import RemoteProtocol
@testable import ToasttyApp
import ToasttyMobileDomain

enum RemoteHostsFixtures {
    static let mini = RemoteHostConfiguration(
        id: "mini",
        displayName: "Mini",
        gatewayURL: URL(string: "https://mini.example-tailnet.ts.net")!,
        sshDestination: "mini"
    )
    static let attachCommand = "env TOASTTY_PANEL_ID=X \"$SHELL\" -lc 'zmx attach toastty.X'"
    static let attachableID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let plainID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let subspaceSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    static let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let subspaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let panelOnlyWorkspaceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!

    static func summary(
        id: UUID,
        title: String,
        workspaceID: UUID,
        workspaceTitle: String,
        status: RemoteSessionPresentationStatus,
        attachCommand: String?
    ) -> CompatibleConversationSummary {
        CompatibleConversationSummary(
            conversationID: RemoteConversationID(rawValue: id),
            provider: .claude,
            title: title,
            placement: RemoteConversationPlacement(workspaceID: workspaceID, workspaceTitle: workspaceTitle),
            cwd: "/repo",
            statusDetail: "Running tests",
            state: .working,
            presentationStatus: .known(status),
            inputAvailability: .unavailable(reason: .known(.working)),
            terminalAttachCommand: attachCommand,
            projectionGeneration: 0,
            latestSequence: 1,
            updatedAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
    }

    static func snapshot() -> CompatibleSessionListSnapshot {
        CompatibleSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(),
            conversations: [
                summary(
                    id: attachableID, title: "Fix sidebar hover", workspaceID: workspaceID,
                    workspaceTitle: "toastty", status: .needsApproval, attachCommand: attachCommand
                ),
                summary(
                    id: plainID, title: "Started from phone", workspaceID: workspaceID,
                    workspaceTitle: "toastty", status: .working, attachCommand: nil
                ),
                summary(
                    id: subspaceSessionID, title: "ios-new-session", workspaceID: subspaceID,
                    workspaceTitle: "ios-new-session", status: .ready, attachCommand: attachCommand
                ),
            ],
            workspaces: [
                RemoteWorkspaceSummary(id: workspaceID, title: "toastty", panels: []),
                RemoteWorkspaceSummary(
                    id: subspaceID, title: "ios-new-session", panels: [], parentWorkspaceID: workspaceID
                ),
                RemoteWorkspaceSummary(id: panelOnlyWorkspaceID, title: "notes", panels: []),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_786_000_010)
        )
    }

    static func host(
        status: RemoteHostConnectionStatus = .live,
        supportsTerminalAttach: Bool = true
    ) -> RemoteHostState {
        RemoteHostState(
            configuration: mini,
            status: status,
            snapshot: snapshot(),
            supportsTerminalAttach: supportsTerminalAttach
        )
    }
}

// MARK: - Fake gateway

final class RemoteHostsInMemoryCredentialStore: MobileCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: StoredMobileCredential?

    init(credential: StoredMobileCredential? = nil) { self.credential = credential }

    var current: StoredMobileCredential? { lock.withLock { credential } }
    func load() -> MobileCredentialLoadResult { lock.withLock { credential.map { .available($0) } ?? .missing } }
    func save(_ credential: StoredMobileCredential) throws { lock.withLock { self.credential = credential } }
    func delete() throws {
        try lock.withLock {
            if _failsDeletion { throw MobileCredentialStoreFailure.keychainStatus(errSecInteractionNotAllowed) }
            credential = nil
        }
    }

    private var _failsDeletion = false
    var failsDeletion: Bool {
        get { lock.withLock { _failsDeletion } }
        set { lock.withLock { _failsDeletion = newValue } }
    }
}

final class RemoteHostsFakeGateway: GatewayClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var helloFailure: GatewayFailure?
    private let capabilities: [RemoteGatewayCapability]
    private let snapshot: CompatibleSessionListSnapshot

    init(
        capabilities: [RemoteGatewayCapability] = RemoteGatewayHelloResponse().capabilities,
        snapshot: CompatibleSessionListSnapshot = RemoteHostsFixtures.snapshot(),
        helloFailure: GatewayFailure? = nil
    ) {
        self.capabilities = capabilities
        self.snapshot = snapshot
        self.helloFailure = helloFailure
    }

    func hello() async throws -> RemoteGatewayHelloResponse {
        if let failure = lock.withLock({ helloFailure }) { throw failure }
        return RemoteGatewayHelloResponse(capabilities: capabilities)
    }
    func sessions() async throws -> CompatibleSessionListSnapshot {
        if let failure = lock.withLock({ helloFailure }) { throw failure }
        return snapshot
    }
    func pair(_ request: RemoteGatewayPairRequest) async throws -> RemoteGatewayPairResponse {
        throw GatewayFailure.invalidResponse
    }
    func events(
        conversationID: RemoteConversationID, cursor: ConversationEventCursor?, limit: Int?
    ) async throws -> CompatibleGatewayEventsResponse { throw GatewayFailure.invalidResponse }
    func send(_ request: RemoteMessageSendRequest) async throws -> RemoteMessageSendResult {
        throw GatewayFailure.invalidResponse
    }
    func answerQuestion(_ request: RemoteQuestionAnswerRequest) async throws -> RemoteQuestionAnswerResult {
        throw GatewayFailure.invalidResponse
    }
    func acknowledgeConversationRead(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) async throws -> RemoteConversationReadAcknowledgementResponse { throw GatewayFailure.invalidResponse }
    func setWorkspaceDone(_ request: RemoteWorkspaceDoneRequest) async throws -> RemoteWorkspaceDoneResponse {
        throw GatewayFailure.invalidResponse
    }
    func setConversationFlag(
        _ request: RemoteConversationFlagRequest
    ) async throws -> RemoteConversationFlagResponse { throw GatewayFailure.invalidResponse }
    func sessionStartOptions(
        _ request: RemoteSessionStartOptionsRequest
    ) async throws -> RemoteSessionStartOptionsResponse { throw GatewayFailure.invalidResponse }
    func startSession(_ request: RemoteSessionStartRequest) async throws -> RemoteSessionStartResponse {
        throw GatewayFailure.invalidResponse
    }
}

/// Delivers one full session list, then stays open until it is closed.
actor RemoteHostsFakeSubscription: EventStreamSubscriptionProtocol {
    private var pending: CompatibleSessionListSnapshot?
    private var waiter: CheckedContinuation<Void, Never>?
    private var isClosed = false

    init(snapshot: CompatibleSessionListSnapshot) { pending = snapshot }

    func nextMessage() async throws -> CompatibleGatewayStreamMessage {
        if let snapshot = pending {
            pending = nil
            return .sessionList(snapshot)
        }
        if isClosed == false {
            await withCheckedContinuation { waiter = $0 }
        }
        throw GatewayFailure.network(reason: .connectionLost)
    }

    func close() async {
        isClosed = true
        waiter?.resume()
        waiter = nil
    }
}

struct RemoteHostsFakeEventStream: EventStreamClientProtocol {
    let snapshot: CompatibleSessionListSnapshot
    func connect() async throws -> any EventStreamSubscriptionProtocol {
        RemoteHostsFakeSubscription(snapshot: snapshot)
    }
}

struct RemoteHostsFakePairingClient: NativePairingClientProtocol {
    let result: Result<RemoteGatewayNativePairingExchangeResponse, NativeGatewayFailure>
    func exchangeConfirmed(
        candidate: PairingCandidate, deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        try result.get()
    }
}


extension RemoteHostsFixtures {
    static let credentialToken = Data(repeating: 7, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    static func exchangeResponse() -> RemoteGatewayNativePairingExchangeResponse {
        RemoteGatewayNativePairingExchangeResponse(
            device: RemoteGatewayDeviceSummary(id: UUID(), name: "Laptop", scopes: [.read, .send]),
            credentialCreatedAt: Date(timeIntervalSince1970: 1_786_000_000),
            credential: credentialToken
        )
    }

    static func storedCredential(gateway: URL = mini.gatewayURL) throws -> StoredMobileCredential {
        try StoredMobileCredential(gatewayURL: gateway, exchangeResponse: exchangeResponse())
    }

    /// A store whose remotes connect to fake gateways. A remote listed in
    /// `pairedRemoteIDs` has a credential; the others wait for pairing.
    @MainActor
    static func makeStore(
        configurations: [RemoteHostConfiguration] = [mini],
        pairedRemoteIDs: Set<String> = ["mini"],
        gateway: @escaping @MainActor (URL) -> RemoteHostsFakeGateway = { _ in RemoteHostsFakeGateway() }
    ) -> RemoteHostsStore {
        RemoteHostsStore(dependencies: .init(
            loadConfigurations: { configurations },
            credentialStore: { configuration in
                RemoteHostsInMemoryCredentialStore(
                    credential: pairedRemoteIDs.contains(configuration.id)
                        ? try? storedCredential(gateway: configuration.gatewayURL)
                        : nil
                )
            },
            makeCoordinator: { gatewayURL, _, scopes in
                ConnectionCoordinator(
                    gateway: gateway(gatewayURL),
                    eventStream: RemoteHostsFakeEventStream(snapshot: snapshot()),
                    deviceScopes: scopes
                )
            },
            pairingClient: RemoteHostsFakePairingClient(result: .failure(.capabilityUnavailable)),
            revokeDevice: { _, _ in },
            deviceName: { "Laptop" }
        ))
    }
}
