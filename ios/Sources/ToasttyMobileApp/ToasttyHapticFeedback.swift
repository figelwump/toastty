import SwiftUI
import ToasttyMobileDomain

/// The result of a user action that finished asynchronously. Controllers
/// number each result, so a repeated outcome still changes the value that
/// `.sensoryFeedback(trigger:)` observes. Views never infer a result from
/// intermediate frames, which SwiftUI can skip when a response is fast.
struct ToasttyOutcomeFeedback: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case success
        case warning
        case failure
    }

    let sequence: UInt64
    let outcome: Outcome

    static func next(
        after previous: ToasttyOutcomeFeedback?,
        _ outcome: Outcome
    ) -> ToasttyOutcomeFeedback {
        ToasttyOutcomeFeedback(sequence: (previous?.sequence ?? 0) &+ 1, outcome: outcome)
    }

    var sensoryFeedback: SensoryFeedback {
        switch outcome {
        case .success: .success
        case .warning: .warning
        case .failure: .error
        }
    }
}

enum ToasttyHapticFeedback {
    /// A send that just became a failure receipt. Rejected and failed sends
    /// outrank unconfirmed ones when several change at once.
    static func sendOutcome(
        from previous: SendReconciliationState,
        to state: SendReconciliationState
    ) -> ToasttyOutcomeFeedback.Outcome? {
        var outcome: ToasttyOutcomeFeedback.Outcome?
        for record in state.records {
            guard let current = receiptOutcome(record.deliveryState),
                  previous[record.clientRequestID].flatMap({ receiptOutcome($0.deliveryState) }) == nil
            else { continue }
            if current == .failure { return .failure }
            outcome = current
        }
        return outcome
    }

    /// A phone submission finished, or the user changed an answer choice.
    /// Typing a custom answer does not count as a choice change.
    static func interactionAnswer(
        from old: ToasttyInteractionAnswerState?,
        to new: ToasttyInteractionAnswerState?
    ) -> SensoryFeedback? {
        guard let old, let new, old.key == new.key else { return nil }
        if let submission = new.lastSubmission, submission != old.lastSubmission {
            return submission.sensoryFeedback
        }
        let choicesChanged =
            old.drafts.mapValues(\.selectedOptionIDs) != new.drafts.mapValues(\.selectedOptionIDs)
            || old.drafts.mapValues(\.usesCustomText) != new.drafts.mapValues(\.usesCustomText)
        return choicesChanged ? .selection : nil
    }

    /// A scanned code was accepted, or a pairing step failed. Completed
    /// pairing replaces the pairing view, so the root view plays that haptic.
    static func pairing(from old: PairingState, to new: PairingState) -> SensoryFeedback? {
        switch (old, new) {
        case (_, .failure): .error
        case (.scanning, .confirming): .impact(weight: .medium)
        default: nil
        }
    }

    static func pairingCompleted(from old: AppSessionState, to new: AppSessionState) -> SensoryFeedback? {
        old == .pairing && new.isPaired ? .success : nil
    }

    private static func receiptOutcome(_ state: SendDeliveryState) -> ToasttyOutcomeFeedback.Outcome? {
        switch state {
        case .pending, .confirmed: nil
        case .rejected, .operationFailed: .failure
        case .uncertain, .deliveryUnconfirmed: .warning
        }
    }
}
