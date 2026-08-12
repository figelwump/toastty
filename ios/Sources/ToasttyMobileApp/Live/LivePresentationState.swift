import Foundation

enum LiveProjectionFreshness: Equatable, Sendable {
    case live
    case reconnecting
    case stale
    case unreachable

    var message: String? {
        switch self {
        case .live:
            nil
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
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stale: "Stale"
        case .unreachable: "Unreachable"
        }
    }
}
