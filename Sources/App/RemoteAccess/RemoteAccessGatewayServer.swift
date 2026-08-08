import CoreState
import Foundation
import Network

/// Loopback-only TCP listener for the remote-access gateway.
///
/// The server owns bytes and connection lifecycle; every routing,
/// authentication, origin, and rate-limit decision lives in the pure
/// `RemoteGatewayRequestHandler`. Tailscale Serve terminates HTTPS in front of
/// this listener — it never binds a non-loopback address, and the trusted
/// local automation socket is a different server entirely.
@MainActor
final class RemoteAccessGatewayServer {
    enum ServerError: Error {
        case invalidPort
    }

    private final class GatewayConnection {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var isWebSocket = false
        var deviceID: UUID?
        /// Frames handed to Network.framework that have not completed sending.
        /// A slow client that lets this grow past the bound is dropped rather
        /// than buffered without limit.
        var pendingSendCount = 0

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    static let maximumPendingSendsPerClient = 32

    private let handler: RemoteGatewayRequestHandler
    private let queue = DispatchQueue(label: "toastty.remote-access.gateway")
    private var listener: NWListener?
    private var connections: [UUID: GatewayConnection] = [:]
    private(set) var listeningPort: UInt16?

    var onWebSocketCountChanged: ((Int) -> Void)?

    init(handler: RemoteGatewayRequestHandler) {
        self.handler = handler
    }

    var webSocketClientCount: Int {
        connections.values.filter(\.isWebSocket).count
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
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                ToasttyLog.error(
                    "Remote access listener failed",
                    category: .automation,
                    metadata: ["error": "\(error)"]
                )
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.listeningPort = port
        ToasttyLog.info(
            "Remote access gateway listening",
            category: .automation,
            metadata: ["port": "\(port)"]
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        for connection in connections.values {
            if connection.isWebSocket {
                connection.connection.send(
                    content: RemoteWebSocketFraming.encodeServerCloseFrame(code: 1001),
                    completion: .contentProcessed { _ in }
                )
            }
            connection.connection.cancel()
        }
        connections.removeAll()
        onWebSocketCountChanged?(0)
    }

    /// Sends one stream message to every connected WebSocket client.
    func broadcast(_ message: RemoteGatewayStreamMessage) {
        guard connections.values.contains(where: \.isWebSocket) else { return }
        guard let payload = try? ConversationEventCoding.makeEncoder().encode(message),
              let text = String(data: payload, encoding: .utf8) else {
            return
        }
        let frame = RemoteWebSocketFraming.encodeServerTextFrame(text)
        for connection in connections.values where connection.isWebSocket {
            sendFrame(frame, to: connection)
        }
    }

    // MARK: - Connection lifecycle

    private func accept(_ nwConnection: NWConnection) {
        let connection = GatewayConnection(connection: nwConnection)
        let connectionID = connection.id
        connections[connectionID] = connection
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

            case .upgradeToWebSocket(let deviceID, let upgradeResponseData):
                connection.deviceID = deviceID
                connection.isWebSocket = true
                connection.connection.send(content: upgradeResponseData, completion: .contentProcessed { _ in })
                onWebSocketCountChanged?(webSocketClientCount)
            }
        }
    }

    private func drainWebSocketFrames(_ connection: GatewayConnection) {
        while true {
            switch RemoteWebSocketFraming.decodeClientFrame(connection.buffer) {
            case .needMoreData:
                return

            case .invalid:
                sendFrame(RemoteWebSocketFraming.encodeServerCloseFrame(code: 1002), to: connection)
                drop(connection.id)
                return

            case .frame(let frame, let consumedBytes):
                connection.buffer.removeFirst(consumedBytes)
                switch frame.opcode {
                case .ping:
                    sendFrame(RemoteWebSocketFraming.encodeServerFrame(opcode: .pong, payload: frame.payload), to: connection)
                case .close:
                    sendFrame(RemoteWebSocketFraming.encodeServerCloseFrame(), to: connection)
                    drop(connection.id)
                    return
                case .text, .binary, .pong, .continuation:
                    // v0 clients have nothing to say; ignore.
                    break
                }
            }
        }
    }

    private func sendFrame(_ frame: Data, to connection: GatewayConnection) {
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

    private func drop(_ connectionID: UUID) {
        guard let connection = connections.removeValue(forKey: connectionID) else { return }
        let wasWebSocket = connection.isWebSocket
        connection.connection.cancel()
        if wasWebSocket {
            onWebSocketCountChanged?(webSocketClientCount)
        }
    }
}
