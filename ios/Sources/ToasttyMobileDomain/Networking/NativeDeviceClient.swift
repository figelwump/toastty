import Foundation
import RemoteProtocol

public protocol NativeDeviceClientProtocol: Sendable {
    func currentDevice() async throws -> RemoteGatewayCurrentDeviceResponse
    func revokeCurrentDevice() async throws -> RemoteGatewayRevokeCurrentDeviceResponse
}

public struct NativeDeviceClient: NativeDeviceClientProtocol, Sendable {
    static let revokeRequestTimeout: TimeInterval = 5

    public let baseURL: URL

    private let transport: any HTTPTransport
    private let credentialProvider: any GatewayCredentialProvider

    public init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        credentialProvider: any GatewayCredentialProvider
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.credentialProvider = credentialProvider
    }

    public func currentDevice() async throws -> RemoteGatewayCurrentDeviceResponse {
        let operation = NativeGatewayOperation.currentDevice
        let response = try await perform(
            method: "GET",
            path: "/v1/native-device",
            body: Optional<RemoteGatewayRevokeCurrentDeviceRequest>.none,
            operation: operation
        )
        let value: RemoteGatewayCurrentDeviceResponse = try NativeGatewayRequestBuilder.decode(
            response.body,
            operation: operation
        )
        guard value.protocolVersion == RemoteGatewayProtocol.version else {
            throw NativeGatewayFailure.protocolMismatch(version: value.protocolVersion)
        }
        return value
    }

    public func revokeCurrentDevice() async throws -> RemoteGatewayRevokeCurrentDeviceResponse {
        let operation = NativeGatewayOperation.revokeCurrentDevice
        let response = try await perform(
            method: "POST",
            path: "/v1/native-device/revoke",
            body: RemoteGatewayRevokeCurrentDeviceRequest(),
            operation: operation
        )
        let value: RemoteGatewayRevokeCurrentDeviceResponse = try NativeGatewayRequestBuilder.decode(
            response.body,
            operation: operation
        )
        guard value.protocolVersion == RemoteGatewayProtocol.version else {
            throw NativeGatewayFailure.protocolMismatch(version: value.protocolVersion)
        }
        return value
    }

    private func perform<Body: Encodable>(
        method: String,
        path: String,
        body: Body?,
        operation: NativeGatewayOperation
    ) async throws -> HTTPTransportResponse {
        guard let credential = try await credentialProvider.credential() else {
            throw NativeGatewayFailure.unauthenticated(
                operation: operation,
                reason: .credentialInvalid
            )
        }
        var request = try NativeGatewayRequestBuilder.request(
            baseURL: baseURL,
            method: method,
            path: path,
            body: body,
            credential: credential,
            operation: operation
        )
        if operation == .revokeCurrentDevice {
            // Local credential deletion must not be held hostage by an
            // unreachable Mac during the best-effort unpair request.
            request.timeoutInterval = Self.revokeRequestTimeout
        }
        return try await NativeGatewayRequestBuilder.send(
            request,
            transport: transport,
            operation: operation
        )
    }
}
