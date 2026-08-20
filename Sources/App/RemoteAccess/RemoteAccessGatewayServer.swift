import RemoteProtocol
import CoreState
import Foundation
import Network

struct RemoteAccessWebSocketCounts: Equatable, Sendable {
    var total: Int
    var native: Int
}

@MainActor
protocol RemoteAccessGatewayServing: AnyObject {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)? { get set }
    var onDeviceRevoked: ((UUID) -> Void)? { get set }
    var onListenerReady: ((UInt16) -> Void)? { get set }
    var onListenerFailed: (() -> Void)? { get set }

    func start(port: UInt16) throws
    func stop()
    func disconnectWebSockets(for deviceID: UUID)
    func disconnectAllWebSockets()
    func broadcast(_ message: RemoteGatewayStreamMessage)
}

/// Loopback-only TCP listener for the remote-access gateway.
///
/// The server owns bytes and connection lifecycle; every routing,
/// authentication, origin, and rate-limit decision lives in the pure
/// `RemoteGatewayRequestHandler`. Tailscale Serve terminates HTTPS in front of
/// this listener — it never binds a non-loopback address, and the trusted
/// local automation socket is a different server entirely.
@MainActor
final class RemoteAccessGatewayServer: RemoteAccessGatewayServing {
    enum ServerError: Error {
        case invalidPort
    }

    private final class GatewayConnection {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var isWebSocket = false
        var deviceID: UUID?
        var authKind: RemoteDeviceAuthKind?
        var requestTimeoutTask: Task<Void, Never>?
        var closeFallbackTask: Task<Void, Never>?
        var isClosing = false
        /// Frames handed to Network.framework that have not completed sending.
        /// A slow client that lets this grow past the bound is dropped rather
        /// than buffered without limit.
        var pendingSendCount = 0

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    static let maximumPendingSendsPerClient = 32
    static let defaultMaximumConnections = 64
    static let defaultRequestHeaderTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let closeFlushTimeoutNanoseconds: UInt64 = 1_000_000_000

    private let handler: RemoteGatewayRequestHandler
    private let maximumConnections: Int
    private let requestHeaderTimeoutNanoseconds: UInt64
    private let queue = DispatchQueue(label: "toastty.remote-access.gateway")
    private var listener: NWListener?
    private var connections: [UUID: GatewayConnection] = [:]
    private(set) var listeningPort: UInt16?

    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: (() -> Void)?

    init(
        handler: RemoteGatewayRequestHandler,
        maximumConnections: Int = defaultMaximumConnections,
        requestHeaderTimeoutNanoseconds: UInt64 = defaultRequestHeaderTimeoutNanoseconds
    ) {
        self.handler = handler
        self.maximumConnections = max(1, maximumConnections)
        self.requestHeaderTimeoutNanoseconds = requestHeaderTimeoutNanoseconds
        handler.onDeviceRevoked = { [weak self] deviceID in
            // Self-revocation mutates durable store state synchronously inside
            // the handler. Queue transport teardown so `handle` can return and
            // the successful HTTP response can be handed to Network.framework
            // before every stream for that device receives policy close 1008.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.disconnectWebSockets(for: deviceID)
                self?.onDeviceRevoked?(deviceID)
            }
        }
    }

    var webSocketClientCount: Int {
        connections.values.filter { $0.isWebSocket && $0.isClosing == false }.count
    }

    var nativeWebSocketClientCount: Int {
        connections.values.filter {
            $0.isWebSocket && $0.isClosing == false && $0.authKind == .native
        }.count
    }

    private var webSocketCounts: RemoteAccessWebSocketCounts {
        RemoteAccessWebSocketCounts(
            total: webSocketClientCount,
            native: nativeWebSocketClientCount
        )
    }

    var connectionCountForTesting: Int {
        connections.count
    }

    func start(port: UInt16) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: nwPort
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        self.listener = listener
        self.listeningPort = nil
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                guard let self,
                      let listener,
                      self.listener === listener else {
                    return
                }
                switch state {
                case .ready:
                    self.listeningPort = port
                    self.onListenerReady?(port)
                    ToasttyLog.info(
                        "Remote access gateway listening",
                        category: .automation
                    )
                case .failed:
                    self.listener = nil
                    self.listeningPort = nil
                    listener.cancel()
                    self.onListenerFailed?()
                    ToasttyLog.error(
                        "Remote access listener failed",
                        category: .automation
                    )
                case .cancelled:
                    self.listener = nil
                    self.listeningPort = nil
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        stop(onListenerCancelled: nil)
    }

    /// Test/lifecycle seam for a deterministic same-port restart. Listener
    /// cancellation is asynchronous even though `cancel()` itself is not.
    func stopAndWaitForListenerCancellation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stop(onListenerCancelled: {
                continuation.resume()
            })
        }
    }

    /// Immediately terminates subscriptions authenticated as one revoked
    /// device. Deleting the stored credential only protects future requests;
    /// active WebSockets must be closed separately.
    func disconnectWebSockets(for deviceID: UUID) {
        let matchingConnectionIDs = connections.values.compactMap { connection in
            connection.isWebSocket && connection.deviceID == deviceID ? connection.id : nil
        }
        for connectionID in matchingConnectionIDs {
            guard let connection = connections[connectionID] else { continue }
            beginClosing(connection, code: 1008)
        }
    }

    func disconnectAllWebSockets() {
        let connectionIDs = connections.values.filter(\.isWebSocket).map(\.id)
        for connectionID in connectionIDs {
            guard let connection = connections[connectionID] else { continue }
            beginClosing(connection, code: 1008)
        }
    }

    /// Sends one stream message to every connected WebSocket client.
    func broadcast(_ message: RemoteGatewayStreamMessage) {
        guard connections.values.contains(where: \.isWebSocket) else { return }
        guard let payload = try? ConversationEventCoding.makeEncoder().encode(message),
              let text = String(data: payload, encoding: .utf8) else {
            return
        }
        let frame = RemoteWebSocketFraming.encodeServerTextFrame(text)
        for connection in connections.values where connection.isWebSocket && connection.isClosing == false {
            sendFrame(frame, to: connection)
        }
    }

    // MARK: - Connection lifecycle

    private func stop(onListenerCancelled: (@MainActor @Sendable () -> Void)?) {
        let listener = listener
        self.listener = nil
        listeningPort = nil
        if let listener {
            if let onListenerCancelled {
                listener.stateUpdateHandler = { state in
                    guard case .cancelled = state else { return }
                    Task { @MainActor in
                        onListenerCancelled()
                    }
                }
            }
            listener.cancel()
        } else {
            onListenerCancelled?()
        }

        for connection in Array(connections.values) {
            if connection.isWebSocket {
                beginClosing(connection, code: 1001)
            } else {
                drop(connection.id)
            }
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < maximumConnections else {
            ToasttyLog.warning(
                "Rejected remote access connection at capacity",
                category: .automation,
                metadata: ["maximum_connections": "\(maximumConnections)"]
            )
            nwConnection.cancel()
            return
        }
        let connection = GatewayConnection(connection: nwConnection)
        let connectionID = connection.id
        connections[connectionID] = connection
        connection.requestTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.requestHeaderTimeoutNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self,
                  self.connections[connectionID]?.isWebSocket == false else {
                return
            }
            self.drop(connectionID)
        }
        nwConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.drop(connectionID)
                }
            default:
                break
            }
        }
        nwConnection.start(queue: queue)
        receive(on: connectionID)
    }

    private func receive(on connectionID: UUID) {
        guard let connection = connections[connectionID] else { return }
        connection.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, data.isEmpty == false {
                    self.handleReceivedData(data, connectionID: connectionID)
                }
                if isComplete || error != nil {
                    self.drop(connectionID)
                } else if self.connections[connectionID] != nil {
                    self.receive(on: connectionID)
                }
            }
        }
    }

    private func handleReceivedData(_ data: Data, connectionID: UUID) {
        guard let connection = connections[connectionID] else { return }
        connection.buffer.append(data)
        if connection.isWebSocket {
            drainWebSocketFrames(connection)
        } else {
            drainHTTPRequest(connection)
        }
    }

    private func drainHTTPRequest(_ connection: GatewayConnection) {
        switch RemoteGatewayHTTPRequest.parse(connection.buffer) {
        case .needMoreData:
            if connection.buffer.count > RemoteGatewayHTTPRequest.maximumHeaderBytes + RemoteGatewayHTTPRequest.maximumBodyBytes {
                drop(connection.id)
            }

        case .invalid:
            let connectionID = connection.id
            let response = RemoteGatewayHTTPResponse.text(status: 400, reason: "Bad Request", "Malformed request")
            connection.connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.drop(connectionID)
                }
            })

        case .request(let request, _):
            let connectionID = connection.id
            connection.buffer.removeAll()
            switch handler.handle(request, at: Date()) {
            case .respond(let response):
                connection.connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.drop(connectionID)
                    }
                })

            case .upgradeToWebSocket(let deviceID, let authKind, let upgradeResponseData):
                connection.requestTimeoutTask?.cancel()
                connection.requestTimeoutTask = nil
                connection.deviceID = deviceID
                connection.authKind = authKind
                connection.isWebSocket = true
                connection.connection.send(content: upgradeResponseData, completion: .contentProcessed { _ in })
                onWebSocketCountsChanged?(webSocketCounts)
            }
        }
    }

    private func drainWebSocketFrames(_ connection: GatewayConnection) {
        while true {
            switch RemoteWebSocketFraming.decodeClientFrame(connection.buffer) {
            case .needMoreData:
                return

            case .invalid:
                beginClosing(connection, code: 1002)
                return

            case .frame(let frame, let consumedBytes):
                connection.buffer.removeFirst(consumedBytes)
                switch frame.opcode {
                case .ping:
                    sendFrame(RemoteWebSocketFraming.encodeServerFrame(opcode: .pong, payload: frame.payload), to: connection)
                case .close:
                    if connection.isClosing {
                        // Server-initiated close is complete only after the
                        // peer acknowledges it with its own close frame.
                        drop(connection.id)
                    } else {
                        // Reply to a peer-initiated close, then leave the
                        // receive side alive until EOF or the bounded fallback.
                        beginClosing(connection, code: 1000)
                    }
                    return
                case .text, .binary, .pong, .continuation:
                    // v0 clients have nothing to say; ignore.
                    break
                }
            }
        }
    }

    private func sendFrame(_ frame: Data, to connection: GatewayConnection) {
        guard connection.isClosing == false else { return }
        guard connection.pendingSendCount < Self.maximumPendingSendsPerClient else {
            ToasttyLog.warning(
                "Dropping slow remote access client",
                category: .automation,
                metadata: ["device_id": connection.deviceID?.uuidString ?? "-"]
            )
            drop(connection.id)
            return
        }
        let connectionID = connection.id
        connection.pendingSendCount += 1
        connection.connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.connections[connectionID]?.pendingSendCount -= 1
            }
        })
    }

    private func beginClosing(_ connection: GatewayConnection, code: UInt16) {
        guard connections[connection.id] === connection,
              connection.isClosing == false else {
            return
        }
        connection.isClosing = true
        connection.requestTimeoutTask?.cancel()
        connection.requestTimeoutTask = nil
        onWebSocketCountsChanged?(webSocketCounts)

        let connectionID = connection.id
        connection.closeFallbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.closeFlushTimeoutNanoseconds)
            } catch {
                return
            }
            self?.drop(connectionID)
        }
        connection.connection.send(
            content: RemoteWebSocketFraming.encodeServerCloseFrame(code: code),
            completion: .contentProcessed { [weak self] error in
                // `contentProcessed(nil)` means Network.framework accepted the
                // bytes, not that the peer received or acknowledged the close.
                // Keep receiving so the WebSocket handshake can complete.
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    self?.drop(connectionID)
                }
            }
        )
    }

    private func drop(_ connectionID: UUID) {
        guard let connection = connections.removeValue(forKey: connectionID) else { return }
        connection.requestTimeoutTask?.cancel()
        connection.requestTimeoutTask = nil
        connection.closeFallbackTask?.cancel()
        connection.closeFallbackTask = nil
        let wasWebSocket = connection.isWebSocket
        let wasAlreadyRemovedFromCount = connection.isClosing
        connection.connection.cancel()
        if wasWebSocket && wasAlreadyRemovedFromCount == false {
            onWebSocketCountsChanged?(webSocketCounts)
        }
    }
}
