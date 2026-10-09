import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class NativePushClientTests: XCTestCase {
    func testNativeConfigurationHandoffAndClearUseExactAuthenticatedRoutes() async throws {
        let id = UUID()
        let transport = NativeRecordingHTTPTransport(responses: [
            .nativeJSON(try ConversationEventCoding.makeEncoder().encode(RemoteGatewayPushConfigurationResponse(
                relayID: "toastty-push-dev-v1", apnsEnvironment: .development))),
            .nativeJSON(try ConversationEventCoding.makeEncoder().encode(RemoteGatewayPushRegistrationResponse(registrationID: id))),
            .nativeJSON(try ConversationEventCoding.makeEncoder().encode(RemoteGatewayPushRegistrationResponse(registrationID: nil))),
        ])
        let client = NativePushClient(baseURL: NativePairingClientTests.gatewayURL, transport: transport,
            credentialProvider: StaticGatewayCredentialProvider(.bearer(token: "native-token")))
        _ = try await client.configuration()
        _ = try await client.setRegistration(RemoteGatewayPushRegistration(registrationID: id,
            sendToken: String(repeating: "A", count: 43), relayID: "toastty-push-dev-v1"))
        _ = try await client.setRegistration(nil)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/native-device/push-configuration", "/v1/native-device/push", "/v1/native-device/push"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertTrue(cleared["registration"] is NSNull)
        XCTAssertEqual(Set(cleared.keys), ["protocolVersion", "registration"])
    }
}
