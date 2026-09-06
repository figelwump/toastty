import Foundation

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

    var category: ToasttyDiagnosticCategory {
        switch self {
        case .gatewayRequestStarted, .gatewayRequestSucceeded, .gatewayRequestFailed:
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
        }
    }
}

struct ToasttyConnectionDiagnosticEntry: Equatable, Identifiable, Sendable {
    var id: UInt64 { sequence }

    let sequence: UInt64
    let recordedAt: Date
    let event: ToasttyConnectionDiagnosticEvent
}

struct ToasttyConnectionDiagnosticLog: Equatable, Sendable {
    static let defaultCapacity = 40

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
        recordedAt: Date = .now
    ) {
        let entry = ToasttyConnectionDiagnosticEntry(
            sequence: nextSequence,
            recordedAt: recordedAt,
            event: event
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
        recordedAt: Date = .now
    ) {
        connectionLog.append(event, recordedAt: recordedAt)
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
