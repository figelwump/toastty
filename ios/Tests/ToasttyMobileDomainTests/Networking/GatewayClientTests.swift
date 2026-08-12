import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class GatewayClientTests: XCTestCase {
    func testGatewayCredentialDescriptionsAndReflectionsAreFullyRedacted() {
        let credentials: [GatewayCredential] = [
            .cookie(name: "sentinel_cookie_name", value: "SENTINEL_COOKIE_SECRET"),
            .bearer(token: "SENTINEL_BEARER_SECRET"),
        ]

        for credential in credentials {
            for output in [String(describing: credential), String(reflecting: credential)] {
                XCTAssertEqual(output, "<redacted gateway credential>")
                XCTAssertFalse(output.localizedCaseInsensitiveContains("sentinel"))
                XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
            }
        }
    }

    func testGatewayFailureDescriptionsAndReflectionsDoNotExposeHostMessages() {
        let failures: [GatewayFailure] = [
            .unauthenticated(code: .unauthorized, message: "SENTINEL private login"),
            .authorizationDenied(code: .originDenied, message: "SENTINEL private hostname"),
            .rateLimited(message: "SENTINEL account detail"),
            .server(statusCode: 503, code: .persistenceFailed, message: "SENTINEL path detail"),
            .http(statusCode: 418, code: nil, message: "SENTINEL transcript detail"),
        ]

        for failure in failures {
            for output in [String(describing: failure), String(reflecting: failure)] {
                XCTAssertEqual(output, "<redacted gateway failure>")
                XCTAssertFalse(output.localizedCaseInsensitiveContains("sentinel"))
                XCTAssertFalse(output.localizedCaseInsensitiveContains("private"))
                XCTAssertFalse(output.localizedCaseInsensitiveContains("transcript"))
            }
        }
    }

    func testExactRoutesMethodsOriginAndCookieCredential() async throws {
        let transport = RecordingHTTPTransport(responses: [
            .json(Self.helloJSON),
            .json(Self.pairJSON),
            .json(try CompatibilityFixture.data("session-unknown-display-input")),
            .json(Self.notFoundEventsJSON),
            .json(Self.duplicateSendJSON),
        ])
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://toastty.tail.example/base?ignored=true")),
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(
                .cookie(name: RemoteGatewayProtocol.credentialCookieName, value: "credential-secret")
            )
        )
        _ = try await client.hello()
        _ = try await client.pair(RemoteGatewayPairRequest(code: "123456", deviceName: "Phone"))
        _ = try await client.sessions()
        _ = try await client.events(conversationID: Self.conversationID, cursor: nil, limit: 50)
        _ = try await client.send(Self.sendRequest)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/hello",
            "/api/pair",
            "/api/sessions",
            "/api/conversation.events.get",
            "/api/conversation.message.send",
        ])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "POST", "POST"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Origin"), "https://toastty.tail.example")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Cookie"),
            "\(RemoteGatewayProtocol.credentialCookieName)=credential-secret"
        )
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Origin"), "https://toastty.tail.example")

        let eventsBody = try XCTUnwrap(requests[3].httpBody)
        let events = try ConversationEventCoding.makeDecoder().decode(RemoteGatewayEventsRequest.self, from: eventsBody)
        XCTAssertEqual(events.conversationID, Self.conversationID)
        XCTAssertEqual(events.limit, 50)

        let sendBody = try XCTUnwrap(requests[4].httpBody)
        XCTAssertEqual(
            try ConversationEventCoding.makeDecoder().decode(RemoteMessageSendRequest.self, from: sendBody),
            Self.sendRequest
        )
    }

    func testBearerCredentialSeamUsesAuthorizationWithoutCookie() async throws {
        let transport = RecordingHTTPTransport(responses: [.json(Self.helloJSON)])
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://toastty.example")),
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "bearer-secret"))
        )
        // Hello is intentionally unauthenticated even when a credential exists.
        _ = try await client.hello()
        let helloRequests = await transport.recordedRequests()
        XCTAssertNil(helloRequests[0].value(forHTTPHeaderField: "Authorization"))

        let sessionsTransport = RecordingHTTPTransport(responses: [
            .json(try CompatibilityFixture.data("session-unknown-display-input")),
        ])
        let sessionsClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://toastty.example")),
            transport: sessionsTransport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "bearer-secret"))
        )
        _ = try await sessionsClient.sessions()
        let sessionRequests = await sessionsTransport.recordedRequests()
        let request = sessionRequests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testSendScopeDenied403IsNormalSendResult() async throws {
        let body = Data(#"{"reason":"send_scope_denied","status":"rejected"}"#.utf8)
        let transport = RecordingHTTPTransport(responses: [HTTPTransportResponse(statusCode: 403, body: body)])
        let client = GatewayClient(baseURL: try XCTUnwrap(URL(string: "https://toastty.example")), transport: transport)

        let result = try await client.send(Self.sendRequest)
        XCTAssertEqual(result, .rejected(reason: .sendScopeDenied))
    }

    func testUnknown403SendRejectionReasonIsOperationScopedCompatibilityFailure() async throws {
        let body = Data(#"{"reason":"future_send_policy","status":"rejected"}"#.utf8)
        let transport = RecordingHTTPTransport(responses: [HTTPTransportResponse(statusCode: 403, body: body)])
        let client = GatewayClient(baseURL: try XCTUnwrap(URL(string: "https://toastty.example")), transport: transport)

        do {
            _ = try await client.send(Self.sendRequest)
            XCTFail("Expected compatibility failure")
        } catch let failure as GatewayFailure {
            XCTAssertEqual(
                failure,
                .operationCompatibility(.unsupportedSendRejectionReason("future_send_policy"))
            )
        }
    }

    func testHTTPStatusClassificationPreservesAuthSemantics() async throws {
        try await assertFailure(status: 401, body: Self.errorJSON(code: "unauthorized")) {
            guard case .unauthenticated(code: .unauthorized, message: "failure") = $0 else { return false }
            return true
        }
        try await assertFailure(status: 403, body: Self.errorJSON(code: "origin_denied")) {
            guard case .authorizationDenied(code: .originDenied, message: "failure") = $0 else { return false }
            return true
        }
        try await assertFailure(status: 429, body: Self.errorJSON(code: "rate_limited")) {
            guard case .rateLimited(message: "failure") = $0 else { return false }
            return true
        }
        try await assertFailure(status: 503, body: Self.errorJSON(code: "persistence_failed")) {
            guard case .server(statusCode: 503, code: .persistenceFailed, message: "failure") = $0 else {
                return false
            }
            return $0.isRetryable
        }
        try await assertFailure(status: 503, body: Self.errorJSON(code: "future_gateway_error")) {
            guard case .server(statusCode: 503, code: nil, message: "failure") = $0 else {
                return false
            }
            return $0.isRetryable
        }
    }

    func testUnknownAPIErrorCodeIsOperationScopedCompatibilityFailure() async throws {
        let transport = RecordingHTTPTransport(responses: [
            HTTPTransportResponse(
                statusCode: 400,
                body: try CompatibilityFixture.data("error-unknown-code")
            ),
        ])
        let client = GatewayClient(baseURL: try XCTUnwrap(URL(string: "https://toastty.example")), transport: transport)
        do {
            _ = try await client.sessions()
            XCTFail("Expected compatibility failure")
        } catch let failure as GatewayFailure {
            XCTAssertEqual(failure, .operationCompatibility(.unsupportedAPIErrorCode("future_gateway_error")))
        }
    }

    private func assertFailure(
        status: Int,
        body: Data,
        matches: (GatewayFailure) -> Bool
    ) async throws {
        let transport = RecordingHTTPTransport(responses: [HTTPTransportResponse(statusCode: status, body: body)])
        let client = GatewayClient(baseURL: try XCTUnwrap(URL(string: "https://toastty.example")), transport: transport)
        do {
            _ = try await client.sessions()
            XCTFail("Expected GatewayFailure")
        } catch let failure as GatewayFailure {
            XCTAssertTrue(matches(failure), "Unexpected failure: \(failure)")
        }
    }

    private static func errorJSON(code: String) -> Data {
        Data("{\"code\":\"\(code)\",\"message\":\"failure\",\"protocolVersion\":\"1.0\"}".utf8)
    }

    private static let conversationID = RemoteConversationID(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    private static let sendRequest = RemoteMessageSendRequest(
        conversationID: conversationID,
        clientRequestID: "request-1",
        expectedInputEpoch: RemoteInputEpoch(
            bindingID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            counter: 42
        ),
        text: "Hello"
    )
    private static let helloJSON = Data(
        #"{"capabilities":["browser_cookie_pairing"],"minimumSupportedProtocolVersion":"1.0","protocolVersion":"1.0"}"#.utf8
    )
    private static let pairJSON = Data(
        #"{"device":{"id":"66666666-6666-6666-6666-666666666666","name":"Phone","scopes":["read","send"]},"protocolVersion":"1.0"}"#.utf8
    )
    private static let notFoundEventsJSON = Data(#"{"outcome":"not_found","protocolVersion":"1.0"}"#.utf8)
    private static let duplicateSendJSON = Data(#"{"status":"duplicate"}"#.utf8)
}

private actor RecordingHTTPTransport: HTTPTransport {
    enum StubError: Error { case missingResponse }

    private var responses: [HTTPTransportResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPTransportResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard responses.isEmpty == false else { throw StubError.missingResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private extension HTTPTransportResponse {
    static func json(_ body: Data) -> Self {
        HTTPTransportResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body)
    }
}
