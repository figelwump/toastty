import Foundation
import ToasttyMobileDomain

struct ToasttyPushDiagnosticDetails: Equatable, Sendable {
    /// A registration number local to this controller lifetime, not a request
    /// count, quota count, token, or persistent registration identifier.
    let registrationNumber: UInt64?
    let relay: PushRelayDiagnostic?
    let retryAfterSeconds: UInt32?

    init(registrationNumber: UInt64? = nil, relay: PushRelayDiagnostic? = nil,
         retryAfter: TimeInterval? = nil) {
        self.registrationNumber = registrationNumber
        self.relay = relay
        retryAfterSeconds = retryAfter.flatMap { value in
            guard value.isFinite else { return nil }
            return UInt32(max(1, min(value.rounded(.up), 86_400)))
        }
    }

    var displayText: String {
        var parts: [String] = []
        if let registrationNumber { parts.append("Registration \(registrationNumber) this run") }
        if let status = relay?.statusCode {
            parts.append("HTTP \(status)")
            if status == 202 { parts.append("Existing registration; no new verification sent") }
        }
        if let code = relay?.code {
            parts.append(relay?.statusCode == 202 ? "Original result: \(code.displayName)" : code.displayName)
        }
        if relay?.providerRefreshAttempted == true { parts.append("Apple provider-token refresh attempted") }
        if relay?.statusCode == 429, relay?.code == nil {
            parts.append(relay?.rateLimitSource == .relay
                ? "Relay cooldown; scope unavailable" : "Cooldown response; source unidentified")
        }
        if let retryAfterSeconds { parts.append("Retry delay: \(retryAfterSeconds)s") }
        return parts.joined(separator: " · ")
    }
}

struct ToasttyDiagnosticRecord: Equatable, Sendable {
    let event: ToasttyConnectionDiagnosticEvent
    let pushDetails: ToasttyPushDiagnosticDetails?
    let recordedAt: Date
    let pushSnapshot: ToasttyPushSetupSnapshot?

    init(event: ToasttyConnectionDiagnosticEvent, pushDetails: ToasttyPushDiagnosticDetails? = nil,
         recordedAt: Date = .now, pushSnapshot: ToasttyPushSetupSnapshot? = nil) {
        self.event = event
        self.pushSnapshot = pushSnapshot
        self.pushDetails = pushDetails
        self.recordedAt = recordedAt
    }
}

/// The network client writes one bounded value before returning. Reading it on
/// MainActor adds no suspension point to the registration state machine.
final class ToasttyPushDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PushRelayDiagnostic?
    var value: PushRelayDiagnostic? { lock.withLock { stored } }
    func record(_ value: PushRelayDiagnostic) { lock.withLock { stored = value } }
}

extension PushRelayDiagnosticCode {
    var displayName: String {
        switch self {
        case .appleAccepted: "Apple accepted verification"
        case .appleBadDeviceToken: "Apple rejected the device token"
        case .appleTokenTopicMismatch: "Apple token does not match the app topic"
        case .appleUnregistered: "Apple reports the destination is unregistered"
        case .appleProviderExpired: "Apple rejected an expired provider token"
        case .appleProviderRejected: "Apple rejected provider authorization"
        case .appleRateLimited: "Apple rate-limited verification"
        case .appleProviderUpdatesLimited: "Apple limited provider-token updates"
        case .appleServerError: "Apple returned a server error"
        case .appleRejected: "Apple rejected verification"
        case .appleResponseUnknown: "Apple response did not establish delivery"
        case .appleTransportUnknown: "Apple transport outcome is unknown"
        case .providerUnavailable: "Relay could not prepare Apple authorization"
        case .verificationResultUnknown: "Original Apple result is unavailable or still pending"
        case .existingActive: "Registration already active"
        case .verificationTokenLimit: "Relay verification limit: device token"
        case .verificationIPLimit: "Relay verification limit: network address"
        case .verificationGlobalLimit: "Relay verification limit: service"
        }
    }
}

struct ToasttyPushFailureDiagnosticKey: Hashable {
    let event: ToasttyConnectionDiagnosticEvent
    let registrationNumber: UInt64?
}
