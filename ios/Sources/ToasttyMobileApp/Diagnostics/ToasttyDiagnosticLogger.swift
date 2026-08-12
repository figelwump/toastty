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
        in state: inout ToasttyDiagnosticsState
    ) {
        record(event, recordedAt: recordedAt, in: &state) { category, event in
            logger(for: category).notice("\(event.rawValue, privacy: .public)")
        }
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
