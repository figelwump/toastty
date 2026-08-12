import Foundation
import RemoteProtocol

public enum NativeGatewayOperation: String, Equatable, Sendable {
    case pairingExchange
    case currentDevice
    case revokeCurrentDevice
}

public enum NativeTransportFailure: Equatable, Sendable {
    case offline
    case dns
    case cannotConnect
    case tls
    case timedOut
    case connectionLost
    case other
}

public enum NativePairingRejection: Equatable, Sendable {
    case invalidOrExpiredOffer
    case deviceLimitReached
    case invalidRequest
}

public enum NativeAuthenticationRejection: Equatable, Sendable {
    case credentialInvalid
    case identityUnavailable
    case identityMismatch
    case unknown
}

public enum NativeAuthorizationRejection: Equatable, Sendable {
    case scopeDenied
    case unknown
}

public enum NativeGatewayFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case network(operation: NativeGatewayOperation, reason: NativeTransportFailure)
    case unauthenticated(operation: NativeGatewayOperation, reason: NativeAuthenticationRejection)
    case authorizationDenied(operation: NativeGatewayOperation, reason: NativeAuthorizationRejection)
    case pairingRejected(NativePairingRejection)
    case rateLimited(operation: NativeGatewayOperation)
    case capabilityUnavailable
    case protocolMismatch(version: String?)
    case server(operation: NativeGatewayOperation, statusCode: Int)
    case http(operation: NativeGatewayOperation, statusCode: Int)
    case invalidResponse(operation: NativeGatewayOperation)

    public var description: String { "<redacted native gateway failure>" }
    public var debugDescription: String { description }

    public var isRetryable: Bool {
        switch self {
        case .network, .server:
            true
        case .unauthenticated, .authorizationDenied, .pairingRejected,
             .rateLimited, .capabilityUnavailable, .protocolMismatch, .http, .invalidResponse:
            false
        }
    }
}

enum NativeGatewayResponseClassifier {
    static func failure(
        for response: HTTPTransportResponse,
        operation: NativeGatewayOperation
    ) -> NativeGatewayFailure {
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let code = body?["code"] as? String
        let version = body?["protocolVersion"] as? String

        if code == "protocol_mismatch" || (version != nil && version != RemoteGatewayProtocol.version) {
            return .protocolMismatch(version: version)
        }
        if response.statusCode == 401 {
            let reason: NativeAuthenticationRejection = switch code {
            case "credential_invalid": .credentialInvalid
            case "identity_unavailable": .identityUnavailable
            case "identity_mismatch": .identityMismatch
            default: .unknown
            }
            return .unauthenticated(operation: operation, reason: reason)
        }
        if response.statusCode == 403 {
            if operation == .pairingExchange, code == "invalid_pairing_offer" {
                return .pairingRejected(.invalidOrExpiredOffer)
            }
            let reason: NativeAuthorizationRejection = switch code {
            case "read_scope_denied", "send_scope_denied": .scopeDenied
            default: .unknown
            }
            return .authorizationDenied(operation: operation, reason: reason)
        }
        if response.statusCode == 429 {
            return .rateLimited(operation: operation)
        }
        if operation == .pairingExchange, response.statusCode == 409, code == "device_limit_reached" {
            return .pairingRejected(.deviceLimitReached)
        }
        if operation == .pairingExchange, response.statusCode == 400, code == "invalid_body" {
            return .pairingRejected(.invalidRequest)
        }
        if (500...599).contains(response.statusCode) {
            return .server(operation: operation, statusCode: response.statusCode)
        }
        return .http(operation: operation, statusCode: response.statusCode)
    }

    static func transportFailure(_ error: Error) -> NativeTransportFailure {
        guard let urlError = error as? URLError else { return .other }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .dns
        case .cannotConnectToHost:
            return .cannotConnect
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .tls
        case .timedOut:
            return .timedOut
        case .networkConnectionLost:
            return .connectionLost
        default:
            return .other
        }
    }
}
