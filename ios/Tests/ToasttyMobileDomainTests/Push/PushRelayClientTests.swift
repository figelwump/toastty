import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class PushRelayClientTests: XCTestCase {
    // Unknown optional diagnostics must never change enrollment or errors.
    func testVerificationDiagnosticsDoNotChangeResponsesOrRateLimitErrors() async throws {
        let item = MobilePushStateTests.registration()
        for header in ["apple_accepted", "SENTINEL_PRIVATE_HEADER", String(repeating: "x", count: 4097), "null", ""] {
            let transport = NativeRecordingHTTPTransport(responses: [
                HTTPTransportResponse(statusCode: 201, headers: ["x-toastty-push-diagnostic": header],
                    body: try JSONEncoder().encode(PushRelayBeginResponse(registrationID: item.registrationID,
                        state: "pending", expiresAt: 1_800_000_000))),
                HTTPTransportResponse(statusCode: 429, headers: ["retry-after": "90", "x-toastty-push-diagnostic": header],
                    body: Data(#"{"error":"rate_limited","diagnostic":{"SENTINEL":"ignored"}}"#.utf8)),
            ])
            let capture = RelayDiagnosticCapture()
            let client = PushRelayClient(baseURL: item.relayURL, transport: transport)
            let response = try await client.begin(item, onDiagnostic: capture.record)
            XCTAssertEqual(response.state, "pending")
            XCTAssertEqual(capture.value?.statusCode, 201)
            XCTAssertEqual(capture.value?.code, header == "apple_accepted" ? .appleAccepted : nil)
            do { _ = try await client.begin(item, onDiagnostic: capture.record); XCTFail("Expected cooldown") }
            catch { XCTAssertEqual(error as? PushRelayFailure, .rateLimited(retryAfter: 90)) }
            XCTAssertEqual(capture.value?.rateLimitSource, .relay)
            XCTAssertFalse(String(describing: capture.value).contains("SENTINEL"))
        }
    }

    func testDiagnosticCategoriesFollowTheCurrentAndOriginalResponseContracts() async throws {
        let item = MobilePushStateTests.registration()
        for (status, header, expected): (Int, String, PushRelayDiagnosticCode?) in [
            (201, "apple_bad_device_token", nil), (201, "provider_unavailable", nil),
            (200, "apple_accepted", nil), (200, "existing_active", .existingActive),
            (202, "apple_accepted", .appleAccepted), (202, "provider_unavailable", .providerUnavailable),
            (202, "existing_active", nil), (202, "apple_bad_device_token", nil),
            (503, "verification_token_limit", nil), (503, "apple_provider_updates_limited", .appleProviderUpdatesLimited),
        ] {
            let body: Data
            if status >= 400 { body = Data(#"{"error":"verification_unavailable"}"#.utf8) }
            else {
                body = try JSONEncoder().encode(PushRelayBeginResponse(registrationID: item.registrationID,
                    state: status == 200 ? "active" : "pending", expiresAt: 1_800_000_000))
            }
            let capture = RelayDiagnosticCapture()
            let client = PushRelayClient(baseURL: item.relayURL, transport: NativeRecordingHTTPTransport(responses: [
                HTTPTransportResponse(statusCode: status, headers: ["x-toastty-push-diagnostic": header,
                    "x-toastty-push-provider-refresh": "attempted"], body: body),
            ]))
            _ = try? await client.begin(item, onDiagnostic: capture.record)
            XCTAssertEqual(capture.value?.code, expected)
            XCTAssertEqual(capture.value?.providerRefreshAttempted, expected != nil && status != 200)
        }
    }

    func testRateLimitWithoutRelayEnvelopeRemainsUnidentified() async throws {
        let item = MobilePushStateTests.registration()
        let capture = RelayDiagnosticCapture()
        let client = PushRelayClient(baseURL: item.relayURL, transport: NativeRecordingHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 429, headers: ["retry-after": "inf"], body: Data("<html>upstream</html>".utf8)),
        ]))
        do { _ = try await client.begin(item, onDiagnostic: capture.record); XCTFail("Expected cooldown") }
        catch { XCTAssertEqual(error as? PushRelayFailure, .rateLimited(retryAfter: 60)) }
        XCTAssertEqual(capture.value?.rateLimitSource, .unidentified)
        XCTAssertNil(capture.value?.code)
    }
    func testBeginProofStatusAndDeleteUseBoundedRoutesAndSeparateManagementCredential() async throws {
        let registration = MobilePushStateTests.registration()
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(try JSONEncoder().encode(PushRelayBeginResponse(registrationID: registration.registrationID,
                state: "pending", expiresAt: 1_800_000_000))),
            .nativeJSON(try JSONEncoder().encode(PushRelayStatus(registrationID: registration.registrationID,
                pairingID: registration.pairingID, state: "active"))),
            .nativeJSON(try JSONEncoder().encode(PushRelayStatus(registrationID: registration.registrationID,
                pairingID: registration.pairingID, state: "active"))),
            HTTPTransportResponse(statusCode: 204, body: Data()),
        ])
        let client = PushRelayClient(baseURL: registration.relayURL, transport: transport)
        let result = try await client.begin(registration)
        XCTAssertEqual(result.expiresAt, 1_800_000_000)
        _ = try await client.complete(registration, nonce: String(repeating: "A", count: 43))
        _ = try await client.status(registration)
        try await client.revoke(registration)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "DELETE"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer " + registration.managementToken)
        let begin = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(begin.keys), ["registrationID", "pairingID", "deviceToken", "managementToken", "sendToken"])
        XCTAssertEqual(begin["registrationID"] as? String, registration.registrationID.uuidString.lowercased())
        XCTAssertEqual(begin["pairingID"] as? String, registration.pairingID.uuidString.lowercased())
        let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(Set(proof.keys), ["nonce"])
        for request in requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertEqual(request.url?.host, "push.example.com")
        }
    }

    func testRateLimitTokenErrorsAndExpiredCleanupHaveDistinctSemantics() async throws {
        let item = MobilePushStateTests.registration()
        let transport = NativeRecordingHTTPTransport(responses: [
            HTTPTransportResponse(statusCode: 429, headers: ["retry-after": "90"], body: Data()),
            HTTPTransportResponse(statusCode: 422, body: Data(#"{"error":"invalid_device_token"}"#.utf8)),
            HTTPTransportResponse(statusCode: 404, body: Data()),
        ])
        let client = PushRelayClient(baseURL: item.relayURL, transport: transport)
        do { _ = try await client.begin(item); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? PushRelayFailure, .rateLimited(retryAfter: 90)) }
        do { _ = try await client.begin(item); XCTFail("Expected token failure") }
        catch { XCTAssertEqual(error as? PushRelayFailure, .invalidDeviceToken) }
        try await client.revoke(item)
    }

    func testInvalidOriginNeverSendsCapabilities() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [])
        let client = PushRelayClient(baseURL: URL(string: "https://push.example.com/redirect")!, transport: transport)
        do { _ = try await client.begin(MobilePushStateTests.registration()); XCTFail("Expected invalid origin") }
        catch { XCTAssertEqual(error as? PushRelayFailure, .invalidResponse) }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testTerminalRegistrationResponsesRequireRenewalAndCompleteRequiresActiveProof() async throws {
        let item = MobilePushStateTests.registration()
        let responses = [404, 409, 410].map { HTTPTransportResponse(statusCode: $0, body: Data()) }
            + [.nativeJSON(try JSONEncoder().encode(PushRelayStatus(registrationID: item.registrationID,
                pairingID: item.pairingID, state: "pending")))]
        let client = PushRelayClient(baseURL: item.relayURL,
            transport: NativeRecordingHTTPTransport(responses: responses))
        for _ in 0..<3 {
            do { _ = try await client.begin(item); XCTFail("Expected a retired registration") }
            catch { XCTAssertEqual(error as? PushRelayFailure, .expired) }
        }
        do {
            _ = try await client.complete(item, nonce: String(repeating: "A", count: 43))
            XCTFail("A pending response cannot prove delivery")
        } catch { XCTAssertEqual(error as? PushRelayFailure, .invalidResponse) }
    }

    func testOversizedRateLimitResponseStillHonorsRetryAfterAndNonfiniteHeaderUsesDefault() async throws {
        let item = MobilePushStateTests.registration()
        let client = PushRelayClient(baseURL: item.relayURL,
            transport: NativeRecordingHTTPTransport(responses: [
                HTTPTransportResponse(statusCode: 429, headers: ["retry-after": "90"], body: Data(repeating: 0, count: 4097)),
                HTTPTransportResponse(statusCode: 429, headers: ["retry-after": "inf"], body: Data()),
            ]))
        for delay in [TimeInterval(90), TimeInterval(60)] {
            do { _ = try await client.begin(item); XCTFail("Expected rate limit") }
            catch { XCTAssertEqual(error as? PushRelayFailure, .rateLimited(retryAfter: delay)) }
        }
    }
}

private final class RelayDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PushRelayDiagnostic?
    var value: PushRelayDiagnostic? { lock.withLock { stored } }
    func record(_ value: PushRelayDiagnostic) { lock.withLock { stored = value } }
}
