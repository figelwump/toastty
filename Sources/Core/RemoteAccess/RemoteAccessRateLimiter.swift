import Foundation

/// Failure-driven lockout for pairing and authentication attempts.
///
/// The gateway is loopback-only behind Tailscale Serve, so every peer address
/// is 127.0.0.1 and per-IP limiting is meaningless; limits are global. The
/// policy is a sliding window with a hard lockout: more than
/// `maximumFailures` failures inside `windowDuration` locks the guarded
/// operation for `lockoutDuration`. Successes do not reset the window —
/// only time does.
public struct RemoteAccessRateLimiter: Sendable {
    public let maximumFailures: Int
    public let windowDuration: TimeInterval
    public let lockoutDuration: TimeInterval

    private var failureTimes: [Date] = []
    private var lockedOutUntil: Date?

    public init(
        maximumFailures: Int = 5,
        windowDuration: TimeInterval = 60,
        lockoutDuration: TimeInterval = 300
    ) {
        self.maximumFailures = maximumFailures
        self.windowDuration = windowDuration
        self.lockoutDuration = lockoutDuration
    }

    public func isLockedOut(at date: Date) -> Bool {
        guard let lockedOutUntil else { return false }
        return date < lockedOutUntil
    }

    /// Records a failed attempt; returns true when this failure triggered a
    /// lockout.
    @discardableResult
    public mutating func recordFailure(at date: Date) -> Bool {
        let windowStart = date.addingTimeInterval(-windowDuration)
        failureTimes.append(date)
        failureTimes.removeAll { $0 < windowStart }
        guard failureTimes.count > maximumFailures else { return false }
        lockedOutUntil = date.addingTimeInterval(lockoutDuration)
        failureTimes.removeAll()
        return true
    }
}
