import Foundation
import XCTest
@testable import ToasttyMobileDomain

final class EventStreamClientTests: XCTestCase {
    func testWSSRequestUsesSubscribeRouteHTTPSOriginAndCredentialHeader() async throws {
        let connection = MockWebSocketConnection(messages: [
            try CompatibilityFixture.data("stream-unknown-top-level"),
        ])
        let transport = RecordingWebSocketTransport(connection: connection)
        let client = EventStreamClient(
            baseURL: try XCTUnwrap(URL(string: "https://toastty.tail.example/ignored?query=1")),
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "stream-secret"))
        )

        let subscription = try await client.connect()
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "wss://toastty.tail.example/api/subscribe")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://toastty.tail.example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stream-secret")
        let message = try await subscription.nextMessage()
        XCTAssertEqual(message, .ignoredUnknown(type: "future_notification"))
        await subscription.close()
        let wasClosed = await connection.wasClosed()
        XCTAssertTrue(wasClosed)
    }

    func testHTTPGatewayConvertsToWSAndCookieCredential() async throws {
        let connection = MockWebSocketConnection(messages: [])
        let transport = RecordingWebSocketTransport(connection: connection)
        let client = EventStreamClient(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8080")),
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.cookie(name: "session", value: "secret"))
        )

        let subscription = try await client.connect()
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "ws://127.0.0.1:8080/api/subscribe")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:8080")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=secret")
        await subscription.close()
    }

    func testConnectKeepsSpecificNetworkClassification() async throws {
        let client = EventStreamClient(
            baseURL: try XCTUnwrap(URL(string: "https://toastty.example")),
            transport: FailingWebSocketTransport(error: URLError(.dnsLookupFailed))
        )

        do {
            _ = try await client.connect()
            XCTFail("Expected a classified transport failure")
        } catch let failure as GatewayFailure {
            XCTAssertEqual(failure, .network(reason: .dns))
        }
    }

    func testCloseCancelsAnInFlightReceiveWithoutPolling() async throws {
        let connection = MockWebSocketConnection(messages: [])
        let subscription = EventStreamSubscription(connection: connection, decoder: GatewayCompatibilityDecoder())
        let receiveStarted = await connection.receiveStartedSignal()
        let receiveTask = Task { try await subscription.nextMessage() }
        await receiveStarted.wait()
        await subscription.close()

        do {
            _ = try await receiveTask.value
            XCTFail("Expected receive cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let wasClosed = await connection.wasClosed()
        XCTAssertTrue(wasClosed)
    }

    func testOpenGateDoesNotCompleteBeforeDidOpen() async throws {
        let gate = WebSocketOpenGate()
        let completion = AsyncSignal()
        let waiterStarted = AsyncSignal()
        let task = Task {
            await waiterStarted.signal()
            try await gate.waitUntilOpen()
            await completion.signal()
        }
        await waiterStarted.wait()
        let completedBeforeOpen = await completion.isSignalled()
        XCTAssertFalse(completedBeforeOpen)

        gate.didOpen()
        try await task.value
        let completedAfterOpen = await completion.isSignalled()
        XCTAssertTrue(completedAfterOpen)
    }

    func testOpenGateCancellationResumesWaiterAndCancelsResources() async {
        let gate = WebSocketOpenGate()
        let cancellation = AsyncSignal()
        gate.setCancellationHandler {
            Task { await cancellation.signal() }
        }
        let waiterStarted = AsyncSignal()
        let task = Task {
            await waiterStarted.signal()
            try await gate.waitUntilOpen()
        }
        await waiterStarted.wait()
        gate.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await cancellation.wait()
    }
}

private actor RecordingWebSocketTransport: WebSocketTransport {
    private let connection: any WebSocketConnection
    private var requests: [URLRequest] = []

    init(connection: any WebSocketConnection) {
        self.connection = connection
    }

    func connect(request: URLRequest) async throws -> any WebSocketConnection {
        requests.append(request)
        return connection
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private struct FailingWebSocketTransport: WebSocketTransport {
    let error: URLError

    func connect(request: URLRequest) async throws -> any WebSocketConnection {
        throw error
    }
}

private actor MockWebSocketConnection: WebSocketConnection {
    private var messages: [Data]
    private var receiveContinuations: [CheckedContinuation<Data, any Error>] = []
    private var closed = false
    private let receiveStarted = AsyncSignal()

    init(messages: [Data]) {
        self.messages = messages
    }

    func receive() async throws -> Data {
        await receiveStarted.signal()
        if closed { throw CancellationError() }
        if messages.isEmpty == false { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuations.append(continuation)
        }
    }

    func close() {
        guard closed == false else { return }
        closed = true
        let continuations = receiveContinuations
        receiveContinuations.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }

    func wasClosed() -> Bool { closed }
    func receiveStartedSignal() -> AsyncSignal { receiveStarted }
}

private actor AsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard signalled == false else { return }
        signalled = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        guard signalled == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func isSignalled() -> Bool { signalled }
}
