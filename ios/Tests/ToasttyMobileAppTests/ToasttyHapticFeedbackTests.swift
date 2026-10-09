import Foundation
import RemoteProtocol
import SwiftUI
import XCTest
@testable import ToasttyMobileApp

final class ToasttyHapticFeedbackTests: XCTestCase {
    func testAnswerPlaysForEachFinishedSubmissionOnly() {
        let initial = answerState()
        var failed = initial
        failed.status = .failed("Try again")
        failed.lastSubmission = .next(after: nil, .failure)
        XCTAssertEqual(ToasttyHapticFeedback.interactionAnswer(from: initial, to: failed), .error)

        var sent = failed
        sent.status = .awaitingClaude
        sent.lastSubmission = .next(after: failed.lastSubmission, .success)
        XCTAssertEqual(ToasttyHapticFeedback.interactionAnswer(from: failed, to: sent), .success)

        // A later status change, such as a closed response channel or a
        // resolution from the desktop, does not play again.
        var closed = sent
        closed.status = .unavailable("Closed")
        XCTAssertNil(ToasttyHapticFeedback.interactionAnswer(from: sent, to: closed))
    }

    func testAnswerChoiceChangesPlaySelectionButTypingDoesNot() {
        let initial = answerState()
        var chosen = initial
        chosen.apply(.toggleOption(questionID: "0", optionID: "1"))
        XCTAssertEqual(ToasttyHapticFeedback.interactionAnswer(from: initial, to: chosen), .selection)

        var custom = chosen
        custom.apply(.toggleCustomText(questionID: "0"))
        XCTAssertEqual(ToasttyHapticFeedback.interactionAnswer(from: chosen, to: custom), .selection)

        var typed = custom
        typed.apply(.setCustomText(questionID: "0", text: "Third"))
        XCTAssertNil(ToasttyHapticFeedback.interactionAnswer(from: custom, to: typed))
    }

    func testAnswerStateThatAppearsOrIsReplacedStaysSilent() {
        let state = answerState()
        XCTAssertNil(ToasttyHapticFeedback.interactionAnswer(from: nil, to: state))
        XCTAssertNil(ToasttyHapticFeedback.interactionAnswer(from: state, to: nil))

        var replaced = answerState(counter: 3)
        replaced.lastSubmission = .next(after: nil, .success)
        XCTAssertNil(ToasttyHapticFeedback.interactionAnswer(from: state, to: replaced))
    }

    func testPairingPlaysForAcceptedScansFailuresAndCompletion() {
        XCTAssertEqual(
            ToasttyHapticFeedback.pairing(from: .scanning, to: .confirming(confirmation(.scannedCode))),
            .impact(weight: .medium)
        )
        XCTAssertNil(
            ToasttyHapticFeedback.pairing(from: .manual, to: .confirming(confirmation(.manualCode)))
        )
        XCTAssertEqual(ToasttyHapticFeedback.pairing(from: .scanning, to: .failure(.invalidPairingDetails)), .error)
        XCTAssertEqual(
            ToasttyHapticFeedback.pairing(from: .exchanging(hostname: "mac"), to: .failure(.hostUnreachable)),
            .error
        )
        XCTAssertNil(ToasttyHapticFeedback.pairing(from: .failure(.hostUnreachable), to: .intro))

        XCTAssertEqual(
            ToasttyHapticFeedback.pairingCompleted(from: .pairing, to: .paired(.connecting)),
            .success
        )
        // Restoring an existing pairing at launch is not a new pairing.
        XCTAssertNil(ToasttyHapticFeedback.pairingCompleted(from: .restoring, to: .paired(.connecting)))
        XCTAssertNil(ToasttyHapticFeedback.pairingCompleted(from: .pairing, to: .unpaired))
    }

    private func answerState(counter: UInt64 = 2) -> ToasttyInteractionAnswerState {
        ToasttyInteractionAnswerState(
            key: ToasttyInteractionAnswerKey(
                interactionID: RemotePendingInteraction.ID(rawValue: "question-1"),
                responseID: "response-1",
                inputEpoch: RemoteInputEpoch(
                    bindingID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    counter: counter
                )
            ),
            questions: [RemoteInteractionQuestion(
                id: "0",
                header: "Choice",
                question: "Which one?",
                options: [
                    .init(id: "0", label: "First"),
                    .init(id: "1", label: "Second"),
                ]
            )]
        )
    }

    private func confirmation(_ method: PairingConfirmation.Method) -> PairingConfirmation {
        PairingConfirmation(hostname: "mac.tailnet.ts.net", method: method)
    }
}
