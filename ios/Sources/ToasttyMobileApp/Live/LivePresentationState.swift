import Foundation

enum LiveProjectionFreshness: Equatable, Sendable {
    /// A connection attempt is in flight and no projection has ever been
    /// received. Unlike `.reconnecting`/`.unreachable` there is no "last
    /// available update" to show.
    case connecting
    case live
    case reconnecting
    case stale
    case unreachable

    var message: String? {
        switch self {
        case .live:
            nil
        case .connecting:
            "Connecting to your Mac…"
        case .reconnecting:
            "Reconnecting to your Mac. Showing the last available update."
        case .stale:
            "Updates are paused. Showing the last available update."
        case .unreachable:
            "Your Mac is unreachable. Showing the last available update."
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stale: "Stale"
        case .unreachable: "Unreachable"
        }
    }
}
