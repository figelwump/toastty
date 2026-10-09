import Foundation
import RemoteProtocol

public protocol NativePushClientProtocol: Sendable {
    func configuration() async throws -> RemoteGatewayPushConfigurationResponse
    func setRegistration(_ registration: RemoteGatewayPushRegistration?) async throws -> RemoteGatewayPushRegistrationResponse
}

/// Push uses the existing native authentication surface without changing
/// the current-device client or its callers.
public struct NativePushClient: NativePushClientProtocol {
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let credentialProvider: any GatewayCredentialProvider

    public init(baseURL: URL, transport: any HTTPTransport = URLSessionHTTPTransport(),
                credentialProvider: any GatewayCredentialProvider) {
        self.baseURL = baseURL; self.transport = transport; self.credentialProvider = credentialProvider
    }

    public func configuration() async throws -> RemoteGatewayPushConfigurationResponse {
        let response = try await perform(method: "GET", path: "/v1/native-device/push-configuration",
            body: Optional<RemoteGatewayPushRegistrationRequest>.none, operation: .pushConfiguration)
        let value: RemoteGatewayPushConfigurationResponse = try NativeGatewayRequestBuilder.decode(response.body, operation: .pushConfiguration)
        guard value.protocolVersion == RemoteGatewayProtocol.version else {
            throw NativeGatewayFailure.protocolMismatch(version: value.protocolVersion)
        }
        return value
    }

    public func setRegistration(_ registration: RemoteGatewayPushRegistration?) async throws -> RemoteGatewayPushRegistrationResponse {
        let response = try await perform(method: "POST", path: "/v1/native-device/push",
            body: RemoteGatewayPushRegistrationRequest(registration: registration), operation: .pushRegistration)
        let value: RemoteGatewayPushRegistrationResponse = try NativeGatewayRequestBuilder.decode(response.body, operation: .pushRegistration)
        guard value.protocolVersion == RemoteGatewayProtocol.version else {
            throw NativeGatewayFailure.protocolMismatch(version: value.protocolVersion)
        }
        guard value.registrationID == registration?.registrationID else {
            throw NativeGatewayFailure.invalidResponse(operation: .pushRegistration)
        }
        return value
    }

    private func perform<Body: Encodable>(method: String, path: String, body: Body?, operation: NativeGatewayOperation) async throws -> HTTPTransportResponse {
        guard let credential = try await credentialProvider.credential() else {
            throw NativeGatewayFailure.unauthenticated(operation: operation, reason: .credentialInvalid)
        }
        var request = try NativeGatewayRequestBuilder.request(baseURL: baseURL, method: method, path: path,
                                                              body: body, credential: credential, operation: operation)
        request.timeoutInterval = 10
        let response = try await NativeGatewayRequestBuilder.send(request, transport: transport, operation: operation)
        guard response.body.count <= RemotePushPolicy.maximumBodyBytes else {
            throw NativeGatewayFailure.invalidResponse(operation: operation)
        }
        return response
    }
}
