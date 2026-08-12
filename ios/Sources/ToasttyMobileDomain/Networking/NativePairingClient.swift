import Foundation
import RemoteProtocol

public protocol NativePairingClientProtocol: Sendable {
    /// Called only after the UI has shown and the user has confirmed the
    /// candidate hostname. Admission and exchange are one ordered operation so
    /// no proof is sent to an incompatible gateway.
    func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse
}

public struct NativePairingClient: NativePairingClientProtocol, Sendable {
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    public func exchangeConfirmed(
        candidate: PairingCandidate,
        deviceName: String
    ) async throws -> RemoteGatewayNativePairingExchangeResponse {
        guard Self.isValidDeviceName(deviceName) else {
            throw NativeGatewayFailure.pairingRejected(.invalidRequest)
        }
        if case .qr(_, _, let expiresAt) = candidate.proof, expiresAt <= now() {
            throw NativeGatewayFailure.pairingRejected(.invalidOrExpiredOffer)
        }
        try await admit(candidate.gatewayURL)

        let requestBody: RemoteGatewayNativePairingExchangeRequest
        switch candidate.proof {
        case .qr(let offerID, let secret, _):
            requestBody = RemoteGatewayNativePairingExchangeRequest(
                deviceName: deviceName,
                offerID: offerID,
                secret: secret
            )
        case .manual(let fallbackCode):
            requestBody = RemoteGatewayNativePairingExchangeRequest(
                deviceName: deviceName,
                fallbackCode: fallbackCode
            )
        }

        let operation = NativeGatewayOperation.pairingExchange
        let request = try NativeGatewayRequestBuilder.request(
            baseURL: candidate.gatewayURL,
            method: "POST",
            path: "/v1/native-pairing/exchange",
            body: requestBody,
            credential: nil,
            operation: operation
        )
        let response = try await NativeGatewayRequestBuilder.send(
            request,
            transport: transport,
            operation: operation
        )
        let value: RemoteGatewayNativePairingExchangeResponse = try NativeGatewayRequestBuilder.decode(
            response.body,
            operation: operation
        )
        guard value.protocolVersion == RemoteGatewayProtocol.version else {
            throw NativeGatewayFailure.protocolMismatch(version: value.protocolVersion)
        }
        guard PairingInputParser.isValidCredentialMaterial(value.credential) else {
            throw NativeGatewayFailure.invalidResponse(operation: operation)
        }
        return value
    }

    private static func isValidDeviceName(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.count <= RemoteGatewayProtocol.maximumDeviceNameLength
            && value.utf8.count <= RemoteGatewayProtocol.maximumDeviceNameLength * 4
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func admit(_ gatewayURL: URL) async throws {
        let operation = NativeGatewayOperation.pairingExchange
        let request = try NativeGatewayRequestBuilder.request(
            baseURL: gatewayURL,
            method: "GET",
            path: "/api/hello",
            body: Optional<RemoteGatewayRevokeCurrentDeviceRequest>.none,
            credential: nil,
            operation: operation
        )
        let response = try await NativeGatewayRequestBuilder.send(
            request,
            transport: transport,
            operation: operation
        )
        let hello: NativePairingHelloAdmission = try NativeGatewayRequestBuilder.decode(
            response.body,
            operation: operation
        )
        guard hello.protocolVersion == RemoteGatewayProtocol.version,
              hello.minimumSupportedProtocolVersion == RemoteGatewayProtocol.minimumSupportedVersion else {
            throw NativeGatewayFailure.protocolMismatch(version: hello.protocolVersion)
        }
        guard hello.capabilities.contains(RemoteGatewayCapability.nativeBearerPairing.rawValue) else {
            throw NativeGatewayFailure.capabilityUnavailable
        }
    }
}

private struct NativePairingHelloAdmission: Decodable {
    let protocolVersion: String
    let minimumSupportedProtocolVersion: String
    let capabilities: [String]
}

enum NativeGatewayRequestBuilder {
    static func request<Body: Encodable>(
        baseURL: URL,
        method: String,
        path: String,
        body: Body?,
        credential: GatewayCredential?,
        operation: NativeGatewayOperation
    ) throws -> URLRequest {
        guard let url = endpoint(baseURL: baseURL, path: path) else {
            throw NativeGatewayFailure.invalidResponse(operation: operation)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            do {
                request.httpBody = try ConversationEventCoding.makeEncoder().encode(body)
            } catch {
                throw NativeGatewayFailure.invalidResponse(operation: operation)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credential {
            GatewayClient.apply(credential, to: &request)
        }
        return request
    }

    static func send(
        _ request: URLRequest,
        transport: any HTTPTransport,
        operation: NativeGatewayOperation
    ) async throws -> HTTPTransportResponse {
        let response: HTTPTransportResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as NativeGatewayFailure {
            throw failure
        } catch {
            throw NativeGatewayFailure.network(
                operation: operation,
                reason: NativeGatewayResponseClassifier.transportFailure(error)
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NativeGatewayResponseClassifier.failure(for: response, operation: operation)
        }
        return response
    }

    static func decode<Value: Decodable>(
        _ data: Data,
        operation: NativeGatewayOperation
    ) throws -> Value {
        do {
            return try ConversationEventCoding.makeDecoder().decode(Value.self, from: data)
        } catch {
            throw NativeGatewayFailure.invalidResponse(operation: operation)
        }
    }

    private static func endpoint(baseURL: URL, path: String) -> URL? {
        guard let canonical = try? PairingInputParser.canonicalGatewayURL(baseURL.absoluteString),
              canonical == baseURL,
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
