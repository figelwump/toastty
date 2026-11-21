import Foundation

/// The result of a user action that finished asynchronously. Controllers
/// number each result, so a repeated outcome still changes the value that
/// `.sensoryFeedback(trigger:)` observes. Views never infer a result from
/// intermediate frames, which SwiftUI can skip when a response is fast.
public struct ToasttyOutcomeFeedback: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case success
        case warning
        case failure
    }

    public let sequence: UInt64
    public let outcome: Outcome

    public init(sequence: UInt64, outcome: Outcome) {
        self.sequence = sequence
        self.outcome = outcome
    }

    public static func next(
        after previous: ToasttyOutcomeFeedback?,
        _ outcome: Outcome
    ) -> ToasttyOutcomeFeedback {
        ToasttyOutcomeFeedback(sequence: (previous?.sequence ?? 0) &+ 1, outcome: outcome)
    }
}
