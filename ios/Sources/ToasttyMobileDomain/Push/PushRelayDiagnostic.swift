import Foundation

/// Only fixed relay categories cross the HTTP boundary. Never retain a raw
/// header, provider reason, response body, or registration identifier here.
public enum PushRelayDiagnosticCode: String, CaseIterable, Sendable {
    case appleAccepted = "apple_accepted"
    case appleBadDeviceToken = "apple_bad_device_token"
    case appleTokenTopicMismatch = "apple_token_topic_mismatch"
    case appleUnregistered = "apple_unregistered"
    case appleProviderExpired = "apple_provider_expired"
    case appleProviderRejected = "apple_provider_rejected"
    case appleRateLimited = "apple_rate_limited"
    case appleProviderUpdatesLimited = "apple_provider_updates_limited"
    case appleServerError = "apple_server_error"
    case appleRejected = "apple_rejected"
    case appleResponseUnknown = "apple_response_unknown"
    case appleTransportUnknown = "apple_transport_unknown"
    case providerUnavailable = "provider_unavailable"
    case verificationResultUnknown = "verification_result_unknown"
    case existingActive = "existing_active"
    case verificationTokenLimit = "verification_token_limit"
    case verificationIPLimit = "verification_ip_limit"
    case verificationGlobalLimit = "verification_global_limit"
}

public struct PushRelayDiagnostic: Equatable, Sendable {
    public enum RateLimitSource: String, Sendable { case relay, unidentified }
    public let statusCode: Int?
    public let code: PushRelayDiagnosticCode?
    public let rateLimitSource: RateLimitSource?
    public let providerRefreshAttempted: Bool

    public init(statusCode: Int, code: PushRelayDiagnosticCode? = nil,
                rateLimitSource: RateLimitSource? = nil, providerRefreshAttempted: Bool = false) {
        self.statusCode = (100...599).contains(statusCode) ? statusCode : nil
        self.code = code
        self.rateLimitSource = statusCode == 429 ? rateLimitSource : nil
        self.providerRefreshAttempted = providerRefreshAttempted
    }
}

extension PushRelayDiagnosticCode {
    func isCompatible(status: Int, error: String?) -> Bool {
        switch self {
        case .appleAccepted: status == 201 || status == 202
        case .existingActive: status == 200
        case .verificationResultUnknown: status == 202
        case .verificationTokenLimit, .verificationIPLimit, .verificationGlobalLimit:
            status == 429 && error == "rate_limited"
        case .appleBadDeviceToken, .appleTokenTopicMismatch, .appleUnregistered:
            status == 422 && error == "invalid_device_token"
        case .appleProviderExpired, .appleProviderRejected, .appleRateLimited, .appleProviderUpdatesLimited,
             .appleServerError, .appleRejected, .appleResponseUnknown, .appleTransportUnknown, .providerUnavailable:
            // A pending retry can report the original failure without a new send.
            status == 202 || (status == 503 && error == "verification_unavailable")
        }
    }
}
