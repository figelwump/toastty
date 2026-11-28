import CoreState
import Foundation

/// Which square mark a task's row draws, in the sidebar and the Tasks view.
/// `TaskStageMark` (macOS) and the GTK marks draw each kind.
enum TaskStageMarkKind: Equatable, Sendable {
    /// A dashed square: the task is starting.
    case starting
    /// A blue dot in a tinted box: its pull request or ready mark waits for
    /// review.
    case review
    /// A ? in a tinted box: a question waits for the user's reply.
    case question
    /// A dashed amber square: setup waits for a workspace, or failed.
    case setupProblem
    /// A red square: the agent reported an error.
    case error
    /// The ready square: a finished turn the user has not read.
    case ready
    /// An amber square with a halo: the agent needs the user.
    case needsInput
    /// The spinner: the agent works.
    case working
    /// The clock: the task rests while it waits outside Toastty.
    case waiting
    /// An outlined square: nothing is going on.
    case quiet
    /// An ↑ in a tinted box: merged, waiting for a release.
    case toShip
    /// A ✓ in a tinted box.
    case done
    /// An ✕ in a tinted box.
    case archived

    init(_ item: TaskBoardItem) {
        switch item.stage {
        case .starting:
            self = .starting
        case .needsYou(let attention):
            switch attention {
            case .review, .readyForReview: self = .review
            case .awaitingReply: self = .question
            case .pickWorkspace, .setupFailed, .moveFailed: self = .setupProblem
            case .agentError: self = .error
            case .agentFinished: self = .ready
            case .agentNeedsInput, .startWaitsInTerminal, .taskSpaceClosed, .cleanupStopped: self = .needsInput
            }
        case .running, .idle:
            if TaskBoardPresentation.showsUnreadTurnOverStage(item) {
                self = .ready
            } else if item.agent == .working {
                self = .working
            } else if TaskBoardPresentation.restingWait(item) != nil {
                self = .waiting
            } else {
                self = .quiet
            }
        case .toShip:
            self = .toShip
        case .done:
            self = .done
        case .archived:
            self = .archived
        }
    }
}
