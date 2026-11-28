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
            "Toastty is still trying to connect to your Mac. Make sure the Mac is awake, Toastty is running with Remote Access enabled, and Tailscale is connected on both devices. If those are already true, restart Toastty. After making changes, tap Retry or wait for Toastty to try automatically."
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

/// What a chat shows about its connection to the Mac. A chat shows it in
/// one place, its header, and never changes its layout for it.
enum ToasttyChatConnection: Equatable, Sendable {
    /// Live, or not live for so short a time that the chat shows nothing.
    case live
    /// Reconnecting: the header says so in place of the session's status.
    case reconnecting
    /// Not live for a long time, or failed: the header shows the last
    /// status the Mac reported, and a Retry notice floats over the chat.
    case offline

    /// The signal for a projection that has no timeline, as in fixtures.
    init(freshness: LiveProjectionFreshness) {
        self = switch freshness {
        case .live: .live
        case .connecting, .reconnecting: .reconnecting
        case .stale, .unreachable: .offline
        }
    }
}

/// When a chat's connection signal changes. It counts from when the
/// projection stopped being live, or from the return to the foreground if
/// that is later, so time in the background never counts: most returns
/// reconnect before the chat shows anything.
struct ToasttyChatConnectionTimeline: Sendable {
    static let defaultReconnectingDelay: Duration = .milliseconds(1500)
    static let defaultOfflineDelay: Duration = .seconds(15)

    let reconnectingDelay: Duration
    let offlineDelay: Duration
    private(set) var connection: ToasttyChatConnection = .live
    private var notLiveSince: ContinuousClock.Instant?
    private var isInBackground = false

    init(
        reconnectingDelay: Duration = Self.defaultReconnectingDelay,
        offlineDelay: Duration = Self.defaultOfflineDelay
    ) {
        self.reconnectingDelay = reconnectingDelay
        self.offlineDelay = offlineDelay
    }

    /// Applies the projection's freshness at `now`. Returns when the signal
    /// changes next by itself, if it does.
    mutating func update(
        freshness: LiveProjectionFreshness,
        now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        switch freshness {
        case .live:
            notLiveSince = nil
            connection = .live
            return nil
        case .unreachable:
            // A failure that only Retry or a new pairing ends.
            notLiveSince = notLiveSince ?? now
            connection = .offline
            return nil
        case .connecting, .reconnecting, .stale:
            // In the background the chat keeps what it showed, so the
            // screen that comes back is the one that left.
            guard isInBackground == false else { return nil }
            let since = notLiveSince ?? now
            notLiveSince = since
            let elapsed = since.duration(to: now)
            if elapsed >= offlineDelay {
                connection = .offline
                return nil
            }
            if elapsed >= reconnectingDelay {
                connection = .reconnecting
                return since.advanced(by: offlineDelay)
            }
            connection = .live
            return since.advanced(by: reconnectingDelay)
        }
    }

    mutating func enterBackground() {
        isInBackground = true
    }

    /// Counts again from `now` after a time in the background. A chat that
    /// left live starts quiet; one that left reconnecting or offline goes on
    /// saying it reconnects, so the header does not go blank and come back.
    /// A return from the inactive state (Control Center, a system alert)
    /// keeps the count, so it cannot hide Retry during an outage. Call
    /// `update` next.
    mutating func enterForeground(now: ContinuousClock.Instant) {
        guard isInBackground else { return }
        isInBackground = false
        guard notLiveSince != nil else { return }
        notLiveSince = connection == .live ? now : now.advanced(by: .zero - reconnectingDelay)
    }

    /// The user asked to reconnect: the chat says it reconnects at once.
    /// Call `update` next.
    mutating func retry(now: ContinuousClock.Instant) {
        if notLiveSince != nil { notLiveSince = now.advanced(by: .zero - reconnectingDelay) }
    }
}
