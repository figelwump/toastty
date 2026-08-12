import Foundation
import RemoteProtocol
@testable import ToasttyMobileDomain
import XCTest

final class NativePairingClientTests: XCTestCase {
    func testConfirmedExchangeAdmitsThenSendsQRProofWithoutOriginCookiesOrAuthorization() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(Self.helloJSON),
            .nativeJSON(Self.exchangeJSON),
        ])
        let client = NativePairingClient(transport: transport, now: { Self.now })

        let response = try await client.exchangeConfirmed(
            candidate: Self.qrCandidate,
            deviceName: "Native phone"
        )

        XCTAssertEqual(response.device.name, "Native phone")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/hello", "/v1/native-pairing/exchange"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        let request = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayNativePairingExchangeRequest.self,
            from: try XCTUnwrap(requests[1].httpBody)
        )
        XCTAssertEqual(request.offerID, Self.offerID)
        XCTAssertEqual(request.secret, Self.secret)
        XCTAssertNil(request.fallbackCode)
    }

    func testManualExchangeUsesCanonicalFallbackProof() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(Self.helloJSON), .nativeJSON(Self.exchangeJSON),
        ])
        let candidate = try PairingInputParser().parseManual(
            gateway: "mac.example-tailnet.ts.net",
            code: "23456789abcd"
        )

        _ = try await NativePairingClient(transport: transport).exchangeConfirmed(
            candidate: candidate,
            deviceName: "Native phone"
        )

        let recorded = await transport.recordedRequests()
        let request = try XCTUnwrap(recorded.last)
        let body = try ConversationEventCoding.makeDecoder().decode(
            RemoteGatewayNativePairingExchangeRequest.self,
            from: try XCTUnwrap(request.httpBody)
        )
        XCTAssertNil(body.offerID)
        XCTAssertNil(body.secret)
        XCTAssertEqual(body.fallbackCode, "2345-6789-ABCD")
    }

    func testMissingNativeCapabilityNeverSendsPairingProof() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(Data(#"{"capabilities":["browser_cookie_pairing"],"minimumSupportedProtocolVersion":"1.0","protocolVersion":"1.0"}"#.utf8)),
        ])

        do {
            _ = try await NativePairingClient(transport: transport, now: { Self.now }).exchangeConfirmed(
                candidate: Self.qrCandidate,
                deviceName: "Native phone"
            )
            XCTFail("Expected missing capability")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, .capabilityUnavailable)
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/hello"])
    }

    func testIncompatibleHelloNeverSendsPairingProof() async throws {
        for hello in [
            #"{"capabilities":["native_bearer_pairing"],"minimumSupportedProtocolVersion":"1.0","protocolVersion":"2.0"}"#,
            #"{"capabilities":["native_bearer_pairing"],"minimumSupportedProtocolVersion":"2.0","protocolVersion":"1.0"}"#,
        ] {
            let transport = NativeRecordingHTTPTransport(responses: [.nativeJSON(Data(hello.utf8))])
            do {
                _ = try await NativePairingClient(transport: transport, now: { Self.now }).exchangeConfirmed(
                    candidate: Self.qrCandidate,
                    deviceName: "Native phone"
                )
                XCTFail("Expected version mismatch")
            } catch let failure as NativeGatewayFailure {
                guard case .protocolMismatch = failure else {
                    return XCTFail("Unexpected failure: \(failure)")
                }
            }
            let requestCount = await transport.recordedRequests().count
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testExpiredCandidateAndInvalidDeviceNameCauseNoNetworkActivity() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [])
        let expired = PairingCandidate(
            gatewayURL: Self.gatewayURL,
            proof: .qr(offerID: Self.offerID, secret: Self.secret, expiresAt: Self.now)
        )
        let client = NativePairingClient(transport: transport, now: { Self.now })

        await assertPairingFailure(.pairingRejected(.invalidOrExpiredOffer)) {
            _ = try await client.exchangeConfirmed(candidate: expired, deviceName: "Native phone")
        }
        await assertPairingFailure(.pairingRejected(.invalidRequest)) {
            _ = try await client.exchangeConfirmed(candidate: Self.qrCandidate, deviceName: " bad ")
        }
        let recorded = await transport.recordedRequests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testPairingHTTPFailuresAreOperationAwareAndMessagesAreNotExposed() async throws {
        let failureBody = Data(
            #"{"code":"invalid_pairing_offer","message":"SENTINEL HOST DETAIL","protocolVersion":"1.0"}"#.utf8
        )
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(Self.helloJSON), HTTPTransportResponse(statusCode: 403, body: failureBody),
        ])
        do {
            _ = try await NativePairingClient(transport: transport, now: { Self.now }).exchangeConfirmed(
                candidate: Self.qrCandidate,
                deviceName: "Native phone"
            )
            XCTFail("Expected rejected offer")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, .pairingRejected(.invalidOrExpiredOffer))
            XCTAssertFalse(String(describing: failure).contains("SENTINEL"))
            XCTAssertFalse(String(reflecting: failure).contains("SENTINEL"))
        }
    }

    private func assertPairingFailure(
        _ expected: NativeGatewayFailure,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    static let now = Date(timeIntervalSince1970: 1_786_200_000)
    static let gatewayURL = URL(string: "https://mac.example-tailnet.ts.net")!
    static let offerID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    static let secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let qrCandidate = PairingCandidate(
        gatewayURL: gatewayURL,
        proof: .qr(offerID: offerID, secret: secret, expiresAt: now.addingTimeInterval(120))
    )
    static let helloJSON = Data(
        #"{"capabilities":["browser_cookie_pairing","native_bearer_pairing"],"minimumSupportedProtocolVersion":"1.0","protocolVersion":"1.0"}"#.utf8
    )
    static let exchangeJSON = Data(
        #"{"credential":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","credentialCreatedAt":"2026-08-08T14:40:00.125Z","device":{"id":"66666666-6666-6666-6666-666666666666","name":"Native phone","scopes":["read","send"]},"protocolVersion":"1.0"}"#.utf8
    )
}

actor NativeRecordingHTTPTransport: HTTPTransport {
    enum StubError: Error { case missingResponse }
    private var responses: [HTTPTransportResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPTransportResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw StubError.missingResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

extension HTTPTransportResponse {
    static func nativeJSON(_ body: Data) -> Self {
        HTTPTransportResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body)
    }
}
