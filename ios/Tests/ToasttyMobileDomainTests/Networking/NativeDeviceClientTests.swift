import Foundation
import RemoteProtocol
@testable import ToasttyMobileDomain
import XCTest

final class NativeDeviceClientTests: XCTestCase {
    func testCurrentAndRevokeUseExactRoutesBearerAndNoBrowserHeaders() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(Self.currentJSON), .nativeJSON(Self.revokeJSON),
        ])
        let client = NativeDeviceClient(
            baseURL: NativePairingClientTests.gatewayURL,
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "bearer-secret"))
        )

        let current = try await client.currentDevice()
        let revoked = try await client.revokeCurrentDevice()

        XCTAssertEqual(current.device.scopes, [.read, .send])
        XCTAssertEqual(revoked.revokedDeviceID, current.device.id)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/native-device", "/v1/native-device/revoke"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-secret")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        }
        XCTAssertNil(requests[0].httpBody)
        XCTAssertEqual(requests[1].timeoutInterval, NativeDeviceClient.revokeRequestTimeout)
        XCTAssertEqual(
            try ConversationEventCoding.makeDecoder().decode(
                RemoteGatewayRevokeCurrentDeviceRequest.self,
                from: try XCTUnwrap(requests[1].httpBody)
            ).protocolVersion,
            "1.0"
        )
    }

    func testMissingCredentialIsUnauthenticatedWithoutSending() async throws {
        let transport = NativeRecordingHTTPTransport(responses: [])
        let client = NativeDeviceClient(
            baseURL: NativePairingClientTests.gatewayURL,
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(nil)
        )

        do {
            _ = try await client.currentDevice()
            XCTFail("Expected unauthenticated")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, .unauthenticated(operation: .currentDevice, reason: .credentialInvalid))
        }
        let recorded = await transport.recordedRequests()
        XCTAssertTrue(recorded.isEmpty)
    }

    func test401And403KeepOperationAndAuthorizationSemanticsDistinct() async throws {
        let unauthorized = NativeRecordingHTTPTransport(responses: [
            HTTPTransportResponse(
                statusCode: 401,
                body: Data(#"{"code":"identity_mismatch","message":"private detail","protocolVersion":"1.0"}"#.utf8)
            ),
        ])
        let unauthorizedClient = makeClient(transport: unauthorized)
        do {
            _ = try await unauthorizedClient.currentDevice()
            XCTFail("Expected 401")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, .unauthenticated(operation: .currentDevice, reason: .identityMismatch))
        }

        let forbidden = NativeRecordingHTTPTransport(responses: [
            HTTPTransportResponse(
                statusCode: 403,
                body: Data(#"{"code":"read_scope_denied","message":"private detail","protocolVersion":"1.0"}"#.utf8)
            ),
        ])
        let forbiddenClient = makeClient(transport: forbidden)
        do {
            _ = try await forbiddenClient.revokeCurrentDevice()
            XCTFail("Expected 403")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(
                failure,
                .authorizationDenied(operation: .revokeCurrentDevice, reason: .scopeDenied)
            )
        }
    }

    func testTransportErrorsAreClassifiedWithoutLeakingURLError() async throws {
        let transport = FailingNativeHTTPTransport(error: URLError(.serverCertificateUntrusted))
        do {
            _ = try await makeClient(transport: transport).currentDevice()
            XCTFail("Expected TLS failure")
        } catch let failure as NativeGatewayFailure {
            XCTAssertEqual(failure, .network(operation: .currentDevice, reason: .tls))
        }
    }

    private func makeClient(transport: any HTTPTransport) -> NativeDeviceClient {
        NativeDeviceClient(
            baseURL: NativePairingClientTests.gatewayURL,
            transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "bearer-secret"))
        )
    }

    private static let currentJSON = Data(
        #"{"credentialCreatedAt":"2026-08-08T14:40:00.125Z","device":{"id":"66666666-6666-6666-6666-666666666666","name":"Native phone","scopes":["read","send"]},"protocolVersion":"1.0"}"#.utf8
    )
    private static let revokeJSON = Data(
        #"{"protocolVersion":"1.0","revokedDeviceID":"66666666-6666-6666-6666-666666666666"}"#.utf8
    )
}

private struct FailingNativeHTTPTransport: HTTPTransport {
    let error: URLError
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse { throw error }
}
