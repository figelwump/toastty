import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Identifies one request to keep the process running after the scene
/// backgrounds.
struct BackgroundExecutionHoldID: Hashable, Sendable {
    let rawValue: Int
}

/// Keeps the process running for a bounded time after the scene backgrounds.
/// iOS otherwise suspends the app within about a second and aborts its open
/// sockets, which defeats a retained stream.
@MainActor
protocol BackgroundExecutionHolding: AnyObject {
    /// Returns nil when the system refuses more background time. The
    /// expiration callback fires once if the system reclaims the time first;
    /// the caller must then end the hold.
    func begin(name: String, onExpiration: @escaping @MainActor () -> Void) -> BackgroundExecutionHoldID?
    func end(_ id: BackgroundExecutionHoldID)
}

#if canImport(UIKit)
@MainActor
final class UIApplicationBackgroundExecutionHolder: BackgroundExecutionHolding {
    func begin(name: String, onExpiration: @escaping @MainActor () -> Void) -> BackgroundExecutionHoldID? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            onExpiration()
        }
        guard identifier != .invalid else { return nil }
        return BackgroundExecutionHoldID(rawValue: identifier.rawValue)
    }

    func end(_ id: BackgroundExecutionHoldID) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id.rawValue))
    }
}
#endif
