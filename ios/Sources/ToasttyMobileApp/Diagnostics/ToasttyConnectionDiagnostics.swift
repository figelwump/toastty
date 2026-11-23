import Foundation
import ToasttyMobileDomain

enum ToasttyDiagnosticCategory: String, CaseIterable, Identifiable, Sendable {
    case gateway
    case stream
    case send
    case auth

    var id: Self { self }

    var displayName: String {
        switch self {
        case .gateway: "Gateway"
        case .stream: "Stream"
        case .send: "Send"
        case .auth: "Authentication"
        }
    }
}

/// A closed set of connection events keeps diagnostics categorical by construction.
/// Do not add associated strings or raw errors; sensitive connection context belongs
/// outside both the in-app buffer and system logging.
enum ToasttyConnectionDiagnosticEvent: String, CaseIterable, Sendable {
    case gatewayRequestStarted = "request_started"
    case gatewayRequestSucceeded = "request_succeeded"
    case gatewayRequestFailed = "request_failed"
    case streamConnecting = "connecting"
    case streamConnected = "connected"
    case streamReconnecting = "reconnecting"
    case streamDisconnected = "disconnected"
    case sendStarted = "send_started"
    case sendEnqueued = "send_enqueued"
    case sendAccepted = "send_accepted"
    case sendRejected = "send_rejected"
    case sendUncertain = "send_uncertain"
    case authStarted = "auth_started"
    case authSucceeded = "auth_succeeded"
    case authRequired = "auth_required"
    case authRevoked = "auth_revoked"

    case pushRegistrationRestored = "push_registration_restored"
    case pushTokenRequested = "push_token_requested"
    case pushTokenReceived = "push_token_received"
    case pushTokenRequestFailed = "push_token_request_failed"
    case pushBridgeAttached = "push_bridge_attached"
    case pushPayloadInvalid = "push_payload_invalid"
    case pushProofBuffered = "push_proof_buffered"
    case pushVerificationStarted = "push_verification_started"
    case pushVerificationResponse = "push_verification_response"
    case pushSetupContextChanged = "push_setup_context_changed"
    case pushProofReceived = "push_proof_received"
    case pushProofInvalid = "push_proof_invalid"
    case pushProofNoPending = "push_proof_no_pending"
    case pushProofOtherRegistration = "push_proof_other_registration"
    case pushProofOtherPairing = "push_proof_other_pairing"
    case pushProofDisabled = "push_proof_disabled"
    case pushProofSaveFailed = "push_proof_save_failed"
    case pushProofDeferredBackground = "push_proof_deferred_background"
    case pushProofDeferredDisconnected = "push_proof_deferred_disconnected"
    case pushProofDeferredPairing = "push_proof_deferred_pairing"
    case pushProofDeferredConfiguration = "push_proof_deferred_configuration"
    case pushProofAlreadyVerified = "push_proof_already_verified"
    case pushProofCompletionStarted = "push_proof_completion_started"
    case pushProofCompleted = "push_proof_completed"
    case pushMacHandoffStarted = "push_mac_handoff_started"
    case pushRegistrationMissing = "push_registration_missing"
    case pushTokenChanged = "push_token_changed"
    case pushRelayChanged = "push_relay_changed"
    case pushPairingChanged = "push_pairing_changed"
    case pushProofExpired = "push_proof_expired"
    case pushRegistrationExpired = "push_registration_expired"
    case pushStateUnavailable = "push_state_unavailable"
    case pushMacConfigurationFailed = "push_mac_configuration_failed"
    case pushRelayStatusFailed = "push_relay_status_failed"
    case pushRelayBeginFailed = "push_relay_begin_failed"
    case pushRelayCompleteFailed = "push_relay_complete_failed"
    case pushMacRegistrationFailed = "push_mac_registration_failed"
    case pushRelayRevokeFailed = "push_relay_revoke_failed"
    case pushRateLimited = "push_rate_limited"
    case pushRegistrationEnabled = "push_registration_enabled"
    case pushRegistrationReused = "push_registration_reused"

    var category: ToasttyDiagnosticCategory {
        switch self {
        case .gatewayRequestStarted, .gatewayRequestSucceeded, .gatewayRequestFailed,
             .pushRegistrationRestored, .pushTokenRequested, .pushTokenReceived, .pushTokenRequestFailed,
             .pushBridgeAttached, .pushPayloadInvalid, .pushProofBuffered, .pushVerificationStarted,
             .pushVerificationResponse, .pushSetupContextChanged, .pushProofReceived, .pushProofInvalid,
             .pushProofNoPending, .pushProofOtherRegistration, .pushProofOtherPairing, .pushProofDisabled,
             .pushProofSaveFailed, .pushProofDeferredBackground, .pushProofDeferredDisconnected,
             .pushProofDeferredPairing, .pushProofDeferredConfiguration, .pushProofAlreadyVerified, .pushProofCompletionStarted, .pushProofCompleted,
             .pushMacHandoffStarted,
             .pushRegistrationMissing, .pushTokenChanged, .pushRelayChanged,
             .pushPairingChanged, .pushProofExpired, .pushRegistrationExpired,
             .pushStateUnavailable, .pushMacConfigurationFailed, .pushRelayStatusFailed,
             .pushRelayBeginFailed, .pushRelayCompleteFailed, .pushMacRegistrationFailed,
             .pushRelayRevokeFailed, .pushRateLimited, .pushRegistrationEnabled,
             .pushRegistrationReused:
            .gateway
        case .streamConnecting, .streamConnected, .streamReconnecting, .streamDisconnected:
            .stream
        case .sendStarted, .sendEnqueued, .sendAccepted, .sendRejected, .sendUncertain:
            .send
        case .authStarted, .authSucceeded, .authRequired, .authRevoked:
            .auth
        }
    }

    var displayName: String {
        switch self {
        case .gatewayRequestStarted: "Request started"
        case .gatewayRequestSucceeded: "Request succeeded"
        case .gatewayRequestFailed: "Request failed"
        case .streamConnecting: "Connecting"
        case .streamConnected: "Connected"
        case .streamReconnecting: "Reconnecting"
        case .streamDisconnected: "Disconnected"
        case .sendStarted: "Send started"
        case .sendEnqueued: "Send queued locally"
        case .sendAccepted: "Send accepted"
        case .sendRejected: "Send rejected"
        case .sendUncertain: "Delivery uncertain"
        case .authStarted: "Authentication started"
        case .authSucceeded: "Authentication succeeded"
        case .authRequired: "Authentication required"
        case .authRevoked: "Access revoked"
        case .pushRegistrationRestored: "Push registration restored"
        case .pushTokenRequested: "Requesting Apple notification token"
        case .pushTokenReceived: "Apple notification token received"
        case .pushTokenRequestFailed: "Apple notification token request failed"
        case .pushBridgeAttached: "Push notification handler attached"
        case .pushPayloadInvalid: "Push payload ignored: invalid format"
        case .pushProofBuffered: "Push verification buffered before setup was ready"
        case .pushVerificationStarted: "Push verification request started"
        case .pushVerificationResponse: "Push verification response received"
        case .pushSetupContextChanged: "Push setup result belongs to an earlier connection"
        case .pushProofReceived: "Push verification received"
        case .pushProofInvalid: "Push verification ignored: invalid proof"
        case .pushProofNoPending: "Push verification ignored: no pending registration"
        case .pushProofOtherRegistration: "Push verification ignored: another registration"
        case .pushProofOtherPairing: "Push verification ignored: another pairing"
        case .pushProofDisabled: "Push verification ignored: alerts off"
        case .pushProofSaveFailed: "Push verification could not be saved"
        case .pushProofDeferredBackground: "Push verification saved: app is in background"
        case .pushProofDeferredDisconnected: "Push verification saved: Mac is disconnected"
        case .pushProofDeferredPairing: "Push verification saved: pairing changed"
        case .pushProofDeferredConfiguration: "Push verification saved: relay settings do not match"
        case .pushProofAlreadyVerified: "Push verification ignored: proof already completed"
        case .pushProofCompletionStarted: "Push verification completion started"
        case .pushProofCompleted: "Push verification completed"
        case .pushMacHandoffStarted: "Push registration handoff started"
        case .pushRegistrationMissing: "Push setup: no registration"
        case .pushTokenChanged: "Push token changed"
        case .pushRelayChanged: "Push service changed"
        case .pushPairingChanged: "Push pairing changed"
        case .pushProofExpired: "Push delivery verification expired"
        case .pushRegistrationExpired: "Push registration expired"
        case .pushStateUnavailable: "Push settings unavailable"
        case .pushMacConfigurationFailed: "Push Mac settings request failed"
        case .pushRelayStatusFailed: "Push registration check failed"
        case .pushRelayBeginFailed: "Push delivery verification request failed"
        case .pushRelayCompleteFailed: "Push delivery verification completion failed"
        case .pushMacRegistrationFailed: "Push registration handoff failed"
        case .pushRelayRevokeFailed: "Push registration removal failed"
        case .pushRateLimited: "Push service requested a cooldown"
        case .pushRegistrationEnabled: "Push registration enabled"
        case .pushRegistrationReused: "Push registration reused"
        }
    }
}

struct ToasttyConnectionDiagnosticEntry: Equatable, Identifiable, Sendable {
    var id: UInt64 { sequence }

    let sequence: UInt64
    let recordedAt: Date
    let event: ToasttyConnectionDiagnosticEvent
    var pushDetails: ToasttyPushDiagnosticDetails? = nil
}

struct ToasttyConnectionDiagnosticLog: Equatable, Sendable {
    static let defaultCapacity = 128

    let capacity: Int
    private(set) var entries: [ToasttyConnectionDiagnosticEntry] = []
    private var nextSequence: UInt64 = 0

    init(capacity: Int = defaultCapacity) {
        precondition(capacity > 0, "Diagnostic log capacity must be positive.")
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    mutating func append(
        _ event: ToasttyConnectionDiagnosticEvent,
        recordedAt: Date = .now,
        pushDetails: ToasttyPushDiagnosticDetails? = nil
    ) {
        let entry = ToasttyConnectionDiagnosticEntry(
            sequence: nextSequence,
            recordedAt: recordedAt,
            event: event,
            pushDetails: pushDetails
        )
        nextSequence &+= 1

        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

struct ToasttyDiagnosticLoggingPreferences: Equatable, Sendable {
    private var enabledCategories: Set<ToasttyDiagnosticCategory>

    init(enabledCategories: Set<ToasttyDiagnosticCategory> = []) {
        self.enabledCategories = enabledCategories
    }

    func isEnabled(_ category: ToasttyDiagnosticCategory) -> Bool {
        enabledCategories.contains(category)
    }

    mutating func setEnabled(_ enabled: Bool, for category: ToasttyDiagnosticCategory) {
        if enabled {
            enabledCategories.insert(category)
        } else {
            enabledCategories.remove(category)
        }
    }
}

struct ToasttyDiagnosticsState: Equatable, Sendable {
    private(set) var connectionLog: ToasttyConnectionDiagnosticLog
    private(set) var loggingPreferences: ToasttyDiagnosticLoggingPreferences

    init(
        logCapacity: Int = ToasttyConnectionDiagnosticLog.defaultCapacity,
        loggingPreferences: ToasttyDiagnosticLoggingPreferences = .init()
    ) {
        connectionLog = ToasttyConnectionDiagnosticLog(capacity: logCapacity)
        self.loggingPreferences = loggingPreferences
    }

    mutating func record(
        _ event: ToasttyConnectionDiagnosticEvent,
        recordedAt: Date = .now,
        pushDetails: ToasttyPushDiagnosticDetails? = nil
    ) {
        connectionLog.append(event, recordedAt: recordedAt, pushDetails: pushDetails)
    }

    func isSystemLoggingEnabled(_ category: ToasttyDiagnosticCategory) -> Bool {
        loggingPreferences.isEnabled(category)
    }

    mutating func setSystemLoggingEnabled(
        _ enabled: Bool,
        for category: ToasttyDiagnosticCategory
    ) {
        loggingPreferences.setEnabled(enabled, for: category)
    }
}
