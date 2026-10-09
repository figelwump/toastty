import Foundation
import Network
import XCTest
@testable import ToasttyMobileDomain

final class WebSocketPingTests: XCTestCase {
    func testTwoSequentialRealPingsWithReceivePending() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let connection = try await connect(to: server)
        do {
            let first = startOperation("first ordinary ping completes") { try await connection.ping() }
            await fulfillment(of: [server.firstPingReceived], timeout: 3)
            try await server.replyToNextPing()
            try await finishOperation(first)
            try await assertMessageCanBeReceived(connection, server: server)
            let receiving = startOperation("message arrives while second ping is pending") { try await connection.receive() }
            let nextReceived = XCTestExpectation(description: "second ordinary ping arrives")
            server.observeNextPing { nextReceived.fulfill() }
            let second = startOperation("second ordinary ping completes") { try await connection.ping() }
            await fulfillment(of: [nextReceived], timeout: 3)
            try await server.replyToNextPing()
            try await finishOperation(second)
            try await server.sendText("after second ping")
            let message = try await finishOperation(receiving)
            XCTAssertEqual(message, Data("after second ping".utf8))
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    func testRealTransportWaitsForPongAndKeepsSocketUsable() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let connection = try await connect(to: server)

        do {
            let ping = startOperation("ping completes") { try await connection.ping() }
            await fulfillment(of: [server.firstPingReceived], timeout: 3)
            XCTAssertNil(ping.outcome.result)

            try await server.replyToNextPing()
            try await finishOperation(ping)
            try await assertMessageCanBeReceived(connection, server: server)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    func testCancellingRealPingWithNoPongFinishesPromptlyAndLatePongDoesNotCloseSocket() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let connection = try await connect(to: server)

        do {
            let ping = startOperation("cancelled ping completes") { try await connection.ping() }
            await fulfillment(of: [server.firstPingReceived], timeout: 3)
            XCTAssertNil(ping.outcome.result)
            // This is the same cancellation a caller's ping deadline performs.
            // The server deliberately sends no pong until the waiter finishes.
            ping.task.cancel()
            do {
                try await finishOperation(ping)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            }

            try await server.replyToNextPing()
            try await assertMessageCanBeReceived(connection, server: server)

            // The coordinator keeps its event receive loop active during a probe.
            let receiving = startOperation("message arrives after next ping") { try await connection.receive() }
            let nextPingReceived = XCTestExpectation(description: "next ping reaches same socket")
            server.observeNextPing { nextPingReceived.fulfill() }
            let nextPing = startOperation("next ping completes") { try await connection.ping() }
            await fulfillment(of: [nextPingReceived], timeout: 3)
            try await server.replyToNextPing()
            try await finishOperation(nextPing)
            try await server.sendText("after cancelled ping")
            let message = try await finishOperation(receiving)
            XCTAssertEqual(message, Data("after cancelled ping".utf8))
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private func connect(to server: LoopbackWebSocketServer) async throws -> any WebSocketConnection {
        server.start()
        await fulfillment(of: [server.listenerReady], timeout: 3)
        let url = try XCTUnwrap(server.startupResult).get()
        let connecting = startOperation("WebSocket opens") {
            try await URLSessionWebSocketTransport().connect(request: URLRequest(url: url))
        }
        return try await finishOperation(connecting)
    }

    private func assertMessageCanBeReceived(
        _ connection: any WebSocketConnection,
        server: LoopbackWebSocketServer
    ) async throws {
        let receiving = startOperation("message arrives on same socket") { try await connection.receive() }
        try await server.sendText("socket remains usable")
        let message = try await finishOperation(receiving)
        XCTAssertEqual(message, Data("socket remains usable".utf8))
    }

    private func startOperation<Value: Sendable>(
        _ description: String,
        operation: @escaping @Sendable () async throws -> Value
    ) -> PendingOperation<Value> {
        let completion = XCTestExpectation(description: description)
        let outcome = OperationOutcome<Value>()
        let task = Task {
            do {
                outcome.record(.success(try await operation()))
            } catch {
                outcome.record(.failure(error))
            }
            completion.fulfill()
        }
        return PendingOperation(task: task, completion: completion, outcome: outcome)
    }

    private func finishOperation<Value: Sendable>(_ pending: PendingOperation<Value>) async throws -> Value {
        await fulfillment(of: [pending.completion], timeout: 3)
        guard let result = pending.outcome.result else {
            pending.task.cancel()
            throw LoopbackFailure.operationTimedOut
        }
        return try result.get()
    }
}

private struct PendingOperation<Value: Sendable> {
    let task: Task<Void, Never>
    let completion: XCTestExpectation
    let outcome: OperationOutcome<Value>
}

private final class OperationOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<Value, any Error>?

    var result: Result<Value, any Error>? { lock.withLock { storedResult } }

    func record(_ result: Result<Value, any Error>) {
        lock.withLock { storedResult = result }
    }
}

private enum LoopbackFailure: Error {
    case listenerHasNoPort
    case noConnectionOrPing
    case operationTimedOut
}

private final class LoopbackWebSocketServer: @unchecked Sendable {
    let listenerReady = XCTestExpectation(description: "loopback listener is ready")
    let firstPingReceived = XCTestExpectation(description: "server receives ping without replying")

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ToasttyMobileDomainTests.WebSocketPing")
    private let lock = NSLock()
    private var storedStartupResult: Result<URL, any Error>?
    private var connection: NWConnection?
    private var pendingPings: [Data] = []
    private var pingObserver: (@Sendable () -> Void)?

    var startupResult: Result<URL, any Error>? { lock.withLock { storedStartupResult } }

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = false
        options.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        pingObserver = { [firstPingReceived] in firstPingReceived.fulfill() }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port,
                      let url = URL(string: "ws://localhost:\(port.rawValue)/api/subscribe") else {
                    self.completeStartup(.failure(LoopbackFailure.listenerHasNoPort))
                    return
                }
                self.completeStartup(.success(url))
            case .failed(let error):
                self.completeStartup(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connection = connection }
            connection.start(queue: self.queue)
            self.receive(from: connection)
        }
    }

    func start() { listener.start(queue: queue) }

    func stop() {
        listener.cancel()
        lock.withLock { connection }?.cancel()
    }

    func observeNextPing(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { pingObserver = observer }
    }

    func replyToNextPing() async throws {
        let payload: Data? = lock.withLock {
            guard pendingPings.isEmpty == false else { return nil }
            return pendingPings.removeFirst()
        }
        guard let payload else { throw LoopbackFailure.noConnectionOrPing }
        try await send(payload, opcode: .pong)
    }

    func sendText(_ text: String) async throws {
        try await send(Data(text.utf8), opcode: .text)
    }

    private func completeStartup(_ result: Result<URL, any Error>) {
        let shouldFulfill = lock.withLock {
            guard storedStartupResult == nil else { return false }
            storedStartupResult = result
            return true
        }
        if shouldFulfill { listenerReady.fulfill() }
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .ping {
                let observer = self.lock.withLock {
                    self.pendingPings.append(data ?? Data())
                    let observer = self.pingObserver
                    self.pingObserver = nil
                    return observer
                }
                observer?()
            }
            if metadata?.opcode != .close { self.receive(from: connection) }
        }
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async throws {
        guard let connection = lock.withLock({ connection }) else { throw LoopbackFailure.noConnectionOrPing }
        let context = NWConnection.ContentContext(
            identifier: "test WebSocket frame",
            metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
