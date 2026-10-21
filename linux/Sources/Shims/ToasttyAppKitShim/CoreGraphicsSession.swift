import Foundation

// CoreGraphics session/presence calls used by Remote Access push gating
// (`RemotePushMacPresence`). Backed by `LinuxPlatformServices`
// (Mutter idle monitor and logind `LockedHint` by default).

public let kCGSessionOnConsoleKey = "kCGSSessionOnConsoleKey"

/// The session dictionary: always on-console, with the lock state when the
/// platform reports one (absent keys mean "unknown", as on macOS).
public func CGSessionCopyCurrentDictionary() -> NSDictionary? {
    var dictionary: [String: Any] = [kCGSessionOnConsoleKey: true]
    let locked: Bool? = LinuxMainQueue.isCurrent
        ? MainActor.assumeIsolated { LinuxPlatform.services.isScreenLocked() }
        : LinuxSessionPresence.isScreenLocked()
    if let locked {
        dictionary["CGSSessionScreenIsLocked"] = locked
    }
    return NSDictionary(dictionary: dictionary)
}

public struct CGEventType: RawRepresentable, Sendable {
    public var rawValue: UInt32
    public init?(rawValue: UInt32) { self.rawValue = rawValue }
}

public enum CGEventSourceStateID: Int32, Sendable {
    case privateState = -1
    case combinedSessionState = 0
    case hidSystemState = 1
}

public enum CGEventSource {
    /// Seconds since the last input event; `.nan` when unknown (callers treat
    /// non-finite values as "no presence data").
    public static func secondsSinceLastEventType(_ stateID: CGEventSourceStateID, eventType: CGEventType) -> Double {
        _ = stateID
        _ = eventType
        let idle: TimeInterval? = LinuxMainQueue.isCurrent
            ? MainActor.assumeIsolated { LinuxPlatform.services.userIdleSeconds() }
            : LinuxSessionPresence.idleSeconds()
        return idle ?? .nan
    }
}
