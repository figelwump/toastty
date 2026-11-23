import Foundation

/// The session status, reduced to what the transcript uses: whether the agent
/// is ready or working, and a value that changes when the host's status does.
public struct ToasttyTranscriptSessionStatus: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        /// The agent finished its turn and waits for the reader.
        case ready
        case working
        case other
    }

    public let activity: Activity
    /// Tells apart host statuses that share an activity. A reader who stays at
    /// the live edge acknowledges each new status once.
    public let epoch: String

    public init(activity: Activity, epoch: String) {
        self.activity = activity
        self.epoch = epoch
    }

    public static let ready = Self(activity: .ready, epoch: "ready")
    public static let working = Self(activity: .working, epoch: "working")
}
