import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class PushRelayClientTests: XCTestCase {
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
