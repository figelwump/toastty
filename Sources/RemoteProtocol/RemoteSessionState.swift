import Foundation

/// Protocol-facing lifecycle state for one conversation.
///
/// Derived from — but deliberately not identical to — the presentation-oriented
/// sidebar `SessionStatusKind`. This state describes what a remote client may
/// trust about the conversation; it never authorizes input by itself. Input is
/// governed exclusively by `RemoteInputAvailability`.
public enum RemoteSessionState: String, Codable, Equatable, Sendable {
    case starting
    case working
    /// The provider is authoritatively waiting for input. The accompanying
    /// `RemoteInputAvailability` says whether that input may come from remote.
    case awaitingInput = "awaiting_input"
    case ready
    case interrupted
    case ended
    case error
    /// The conversation exists (its projection is readable) but no live managed
    /// runtime is bound to it — for example after a Toastty relaunch before an
    /// explicit native resume.
    case offline
}
