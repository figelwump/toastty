import Foundation
import OSLog

enum ToasttyDiagnosticLogger {
    private static let subsystem = Bundle.main.bundleIdentifier
        ?? "com.giantthings.toastty.mobile"
    private static let gateway = Logger(subsystem: subsystem, category: "gateway")
    private static let stream = Logger(subsystem: subsystem, category: "stream")
    private static let send = Logger(subsystem: subsystem, category: "send")
    private static let auth = Logger(subsystem: subsystem, category: "auth")

    /// Records the categorical event in memory and, when the user has enabled its
    /// category, mirrors that same fixed value to the system log.
    static func record(
        _ event: ToasttyConnectionDiagnosticEvent,
        recordedAt: Date = .now,
        pushDetails: ToasttyPushDiagnosticDetails? = nil,
        pushSnapshot: ToasttyPushSetupSnapshot? = nil,
        in state: inout ToasttyDiagnosticsState
    ) {
        state.record(event, recordedAt: recordedAt, pushDetails: pushDetails, pushSnapshot: pushSnapshot)
        ToasttyDiagnosticRecorder.shared.submit(log: state.connectionLog)
        guard state.isSystemLoggingEnabled(event.category) else { return }
        // Every string is a fixed enum value. These numbers contain no stable
        // registration identity or private server/phone data.
        logger(for: event.category).notice("\(event.rawValue, privacy: .public) registration=\(pushDetails?.registrationNumber ?? 0, privacy: .public) http=\(pushDetails?.relay?.statusCode ?? 0, privacy: .public) relay=\(pushDetails?.relay?.code?.rawValue ?? "unavailable", privacy: .public) rate_source=\(pushDetails?.relay?.rateLimitSource?.rawValue ?? "unavailable", privacy: .public) provider_refresh=\(pushDetails?.relay?.providerRefreshAttempted ?? false, privacy: .public) retry_seconds=\(pushDetails?.retryAfterSeconds ?? 0, privacy: .public)")
    }

    static func record(
        _ event: ToasttyConnectionDiagnosticEvent,
        recordedAt: Date = .now,
        in state: inout ToasttyDiagnosticsState,
        emit: (_ category: ToasttyDiagnosticCategory, _ event: ToasttyConnectionDiagnosticEvent) -> Void
    ) {
        state.record(event, recordedAt: recordedAt)
        guard state.isSystemLoggingEnabled(event.category) else { return }
        emit(event.category, event)
    }

    private static func logger(for category: ToasttyDiagnosticCategory) -> Logger {
        switch category {
        case .gateway: gateway
        case .stream: stream
        case .send: send
        case .auth: auth
        }
    }
}
