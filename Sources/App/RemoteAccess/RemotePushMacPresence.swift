import CoreGraphics
import Foundation

/// A one-time presence sample for an accepted agent event. No input contents are read.
struct RemotePushMacPresence {
    let screenIsLocked: Bool
    let idleSeconds: TimeInterval?

    var allowsPush: Bool {
        if screenIsLocked { return true }
        // Do not lose notifications when macOS cannot supply usable presence data.
        guard let idleSeconds, idleSeconds.isFinite, idleSeconds >= 0 else { return true }
        return idleSeconds >= 120
    }

    static func current() -> Self {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let anyInput = CGEventType(rawValue: UInt32.max) else {
            return Self(screenIsLocked: false, idleSeconds: nil)
        }
        return from(session: session, idleSeconds: CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyInput
        ))
    }

    static func from(session: [String: Any]?, idleSeconds: TimeInterval) -> Self {
        guard let session, session[kCGSessionOnConsoleKey as String] as? Bool != false else {
            return Self(screenIsLocked: false, idleSeconds: nil)
        }
        // This session-dictionary key is undocumented. If absent or unrecognized,
        // use the idle rule; do not confuse fast user switching with screen lock.
        return Self(screenIsLocked: session["CGSSessionScreenIsLocked"] as? Bool ?? false,
                    idleSeconds: idleSeconds)
    }
}
