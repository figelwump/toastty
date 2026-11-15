import Foundation

/// The coordinator's state as the Coordinator tab shows it, from its
/// session's status, as the Mac's coordinator row marks it.
public enum MobileCoordinatorMark: Equatable, Sendable {
    /// Its workspace lists no session: the coordinator does not run, or it
    /// is starting. The Mac starts it.
    case notRunning
    /// At rest, with nothing unread.
    case quiet
    case working
    /// A finished turn that the user has not read.
    case unread
    case needsApproval
    case error

    public init(session: MobileConversation?) {
        guard let session else {
            self = .notRunning
            return
        }
        self = switch session.state.bucket {
        case .needsApproval: .needsApproval
        case .error: .error
        case .working: .working
        // On the wire, `ready` is a finished turn that is still unread.
        case .ready: .unread
        case .idle: .quiet
        }
    }

    /// Unread output, an approval or an error: the states that the tab's
    /// badge shows while the tab is not on screen.
    public var callsForUser: Bool {
        switch self {
        case .unread, .needsApproval, .error: true
        case .notRunning, .quiet, .working: false
        }
    }
}

extension MobileHomeSnapshot {
    /// The coordinator's session: the one session its workspace lists, or
    /// the most urgent while a restart briefly lists two. `nil` when the
    /// coordinator does not run, or when the phone has no Coordinator tab.
    public var coordinatorConversation: MobileConversation? {
        coordinator?.conversations.first
    }

    /// The coordinator's mark, or `nil` when the phone has no Coordinator
    /// tab.
    public var coordinatorMark: MobileCoordinatorMark? {
        coordinator.map { _ in MobileCoordinatorMark(session: coordinatorConversation) }
    }
}
