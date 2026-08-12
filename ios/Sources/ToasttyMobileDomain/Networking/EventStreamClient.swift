import Foundation

public protocol WebSocketConnection: Sendable {
    func receive() async throws -> Data
    func close() async
}

public protocol WebSocketTransport: Sendable {
    func connect(request: URLRequest) async throws -> any WebSocketConnection
}

public protocol EventStreamSubscriptionProtocol: Sendable {
    func nextMessage() async throws -> CompatibleGatewayStreamMessage
    func close() async
}

public protocol EventStreamClientProtocol: Sendable {
    func connect() async throws -> any EventStreamSubscriptionProtocol
}

public struct EventStreamClient: EventStreamClientProtocol, Sendable {
    public let baseURL: URL

    private let transport: any WebSocketTransport
    private let credentialProvider: any GatewayCredentialProvider
    private let compatibilityDecoder: GatewayCompatibilityDecoder

    public init(
        baseURL: URL,
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        credentialProvider: any GatewayCredentialProvider = StaticGatewayCredentialProvider(nil),
        compatibilityDecoder: GatewayCompatibilityDecoder = GatewayCompatibilityDecoder()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.credentialProvider = credentialProvider
        self.compatibilityDecoder = compatibilityDecoder
    }

    public func connect() async throws -> any EventStreamSubscriptionProtocol {
        var request = try makeRequest()
        do {
            if let credential = try await credentialProvider.credential() {
                GatewayClient.apply(credential, to: &request)
            }
            let connection = try await transport.connect(request: request)
            return EventStreamSubscription(connection: connection, decoder: compatibilityDecoder)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GatewayFailure {
            throw failure
        } catch {
            throw GatewayFailure.network
        }
    }

    private func makeRequest() throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw GatewayFailure.invalidResponse
        }
        let originScheme = scheme
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = "/api/subscribe"
        components.query = nil
        components.fragment = nil
        guard let streamURL = components.url else { throw GatewayFailure.invalidResponse }

        components.scheme = originScheme
        components.path = ""
        guard let origin = components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw GatewayFailure.invalidResponse
        }
        var request = URLRequest(url: streamURL)
        request.httpMethod = "GET"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        return request
    }
}

public actor EventStreamSubscription: EventStreamSubscriptionProtocol {
    private let connection: any WebSocketConnection
    private let decoder: GatewayCompatibilityDecoder
    private var isClosed = false

    public init(connection: any WebSocketConnection, decoder: GatewayCompatibilityDecoder) {
        self.connection = connection
        self.decoder = decoder
    }

    public func nextMessage() async throws -> CompatibleGatewayStreamMessage {
        guard isClosed == false else { throw CancellationError() }
        do {
            let data = try await connection.receive()
            return try decoder.decodeStreamMessage(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch GatewayCompatibilityError.unsupportedProtocolVersion(let version) {
            throw GatewayFailure.protocolMismatch(version: version)
        } catch let error as GatewayCompatibilityError {
            throw GatewayFailure.operationCompatibility(error)
        } catch let failure as GatewayFailure {
            throw failure
        } catch {
            throw GatewayFailure.network
        }
    }

    public func close() async {
        guard isClosed == false else { return }
        isClosed = true
        await connection.close()
    }
}

public struct URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func connect(request: URLRequest) async throws -> any WebSocketConnection {
        let openGate = WebSocketOpenGate()
        let delegate = URLSessionWebSocketOpenDelegate(openGate: openGate)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let resources = URLSessionWebSocketOpeningResources(session: session, task: task)
        openGate.setCancellationHandler { resources.cancel() }
        task.resume()

        do {
            try await withTaskCancellationHandler {
                try await openGate.waitUntilOpen()
                try Task.checkCancellation()
            } onCancel: {
                openGate.cancel()
            }
            openGate.clearCancellationHandler()
            return URLSessionWebSocketConnection(
                session: session,
                delegate: delegate,
                task: task
            )
        } catch {
            resources.cancel()
            throw error
        }
    }
}

public actor URLSessionWebSocketConnection: WebSocketConnection {
    private let session: URLSession
    private let delegate: URLSessionWebSocketOpenDelegate
    private let task: URLSessionWebSocketTask
    private var isClosed = false

    fileprivate init(
        session: URLSession,
        delegate: URLSessionWebSocketOpenDelegate,
        task: URLSessionWebSocketTask
    ) {
        self.session = session
        self.delegate = delegate
        self.task = task
    }

    public func receive() async throws -> Data {
        guard isClosed == false else { throw CancellationError() }
        do {
            let message = try await withTaskCancellationHandler {
                try await task.receive()
            } onCancel: {
                task.cancel(with: .goingAway, reason: nil)
            }
            switch message {
            case .data(let data):
                return data
            case .string(let string):
                return Data(string.utf8)
            @unknown default:
                throw GatewayFailure.invalidResponse
            }
        } catch {
            closeResources()
            throw error
        }
    }

    public func close() {
        closeResources()
    }

    private func closeResources() {
        guard isClosed == false else { return }
        isClosed = true
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        _ = delegate
    }
}

private final class URLSessionWebSocketOpeningResources: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

final class WebSocketOpenGate: @unchecked Sendable {
    private enum State {
        case waiting([CheckedContinuation<Void, any Error>])
        case opened
        case failed(any Error)
    }

    private let lock = NSLock()
    private var state: State = .waiting([])
    private var cancellationHandler: (@Sendable () -> Void)?

    func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            switch state {
            case .waiting(var continuations):
                continuations.append(continuation)
                state = .waiting(continuations)
                lock.unlock()
            case .opened:
                lock.unlock()
                continuation.resume()
            case .failed(let error):
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { cancellationHandler = handler }
    }

    func clearCancellationHandler() {
        lock.withLock { cancellationHandler = nil }
    }

    func didOpen() {
        let continuations: [CheckedContinuation<Void, any Error>] = lock.withLock {
            guard case .waiting(let continuations) = state else { return [] }
            state = .opened
            cancellationHandler = nil
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func didFail(_ error: any Error) {
        let continuations: [CheckedContinuation<Void, any Error>] = lock.withLock {
            guard case .waiting(let continuations) = state else { return [] }
            state = .failed(error)
            cancellationHandler = nil
            return continuations
        }
        continuations.forEach { $0.resume(throwing: error) }
    }

    func cancel() {
        let result: ([CheckedContinuation<Void, any Error>], (@Sendable () -> Void)?) = lock.withLock {
            guard case .waiting(let continuations) = state else { return ([], nil) }
            state = .failed(CancellationError())
            let handler = cancellationHandler
            cancellationHandler = nil
            return (continuations, handler)
        }
        result.1?()
        result.0.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private final class URLSessionWebSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let openGate: WebSocketOpenGate

    init(openGate: WebSocketOpenGate) {
        self.openGate = openGate
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        openGate.didOpen()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        openGate.didFail(error ?? URLError(.cannotConnectToHost))
    }
}
