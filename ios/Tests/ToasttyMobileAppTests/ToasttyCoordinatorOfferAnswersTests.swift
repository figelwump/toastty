@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

/// The offer cards of the phone's coordinator chat: an answer counts from
/// the tap on Send answers, while its message waits on the phone or in the
/// Mac's queue, until the conversation shows it.
@MainActor
final class ToasttyCoordinatorOfferAnswersTests: XCTestCase {
    /// A sending answer counts until its send fails; a queued answer counts
    /// until it leaves the queue without its row; the conversation's own
    /// answer counts once it shows. Another chat has no answers.
    func testAWaitingAnswerCountsUntilItsSendFailsOrItLeavesTheQueue() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue, runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consumeIsCoordinatorChat(true)
        subject.consume(liveState([offersEvent]))
        XCTAssertNil(subject.offerAnswers.choice(for: "signup-check", offeredAt: 1))

        // Sending, then accepted: the card shows the answer.
        let yes = answers([("signup-check", .yes)])
        for state: SendDeliveryState in [.pending(.awaitingResponse), .pending(.accepted), .pending(.queued(position: 1))] {
            subject.consumeSendReconciliation(records([("send-1", yes, state)]))
            XCTAssertEqual(subject.offerAnswers.choice(for: "signup-check", offeredAt: 1), .yes, "\(state)")
        }
        // A send that failed gives the card its buttons back.
        for state: SendDeliveryState in [.rejected(reason: .epochMismatch), .uncertain, .operationFailed, .deliveryUnconfirmed] {
            subject.consumeSendReconciliation(records([("send-1", yes, state)]))
            XCTAssertNil(subject.offerAnswers.choice(for: "signup-check", offeredAt: 1), "\(state)")
        }

        // Queued on the Mac, also from before a relaunch of the phone.
        let skip = answers([("docs-rule", .skip)])
        subject.consumeSendReconciliation(SendReconciliationState())
        subject.consumeInputControl(RemoteConversationInputControl(
            canQueue: true, queuedMessages: [.init(clientRequestID: "send-2", text: skip, enqueuedAt: Date())]
        ))
        XCTAssertEqual(subject.offerAnswers.choice(for: "docs-rule", offeredAt: 1), .skip)
        // Removed from the queue: the buttons come back.
        subject.consumeInputControl(RemoteConversationInputControl(canQueue: true))
        XCTAssertNil(subject.offerAnswers.choice(for: "docs-rule", offeredAt: 1))

        // Typed: the conversation's row holds the answer.
        let typed = event(2, .userMessage(.init(text: skip, origin: .remote, clientRequestID: "send-2")))
        subject.consume(liveState([offersEvent, typed]))
        XCTAssertEqual(subject.offerAnswers.choice(for: "docs-rule", offeredAt: 1), .skip)

        let other = LiveConversationController(
            conversationID: conversationID.rawValue, runtime: ConversationRuntime(conversationID: conversationID)
        )
        other.consume(liveState([offersEvent, typed]))
        other.consumeSendReconciliation(records([("send-1", yes, .pending(.accepted))]))
        XCTAssertEqual(other.offerAnswers, ToasttyOfferAnswers(), "Another chat draws no cards")
    }

    /// Answers that send or wait show one line for each, as their row
    /// will; Edit and Steer now still act on the text as sent.
    func testWaitingAnswersShowOneLineForEachAnswer() {
        let sent = answers([("signup-check", .yes), ("docs-rule", .skip)])
        let items = ToasttySendPresentationAdapter.makeItems(
            from: records([("send-1", sent, .pending(.accepted))]),
            inputControl: RemoteConversationInputControl(
                queuedMessages: [.init(clientRequestID: "send-2", text: sent, enqueuedAt: Date())]
            ),
            readsCoordinatorMessages: true
        )
        let shown = "Yes: A check of the sign-up page\nSkip: Merge docs-only pull requests"
        XCTAssertEqual(items.map(\.text), [shown, shown])
        XCTAssertEqual(items.map(\.quote), [nil, nil])
    }

    // MARK: - Helpers

    private var conversationID: RemoteConversationID {
        RemoteConversationID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
    }

    private var runID: RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555500")!)
    }

    private var offersEvent: ConversationEvent {
        event(1, .assistantMessage(.init(text: """
            Here are today's offers.

            ```toastty-offers
            {"offers": [
              {"id": "signup-check", "kind": "task", "title": "A check of the sign-up page"},
              {"id": "docs-rule", "kind": "rule", "title": "Merge docs-only pull requests"}
            ]}
            ```
            """, phase: .final)))
    }

    private func answers(_ choices: [(String, CoordinatorOfferAnswer.Choice)]) -> String {
        let titles = ["signup-check": "A check of the sign-up page", "docs-rule": "Merge docs-only pull requests"]
        return CoordinatorMessageHeader.answersMessage(
            choices.map { CoordinatorOfferAnswer(offerID: $0.0, title: titles[$0.0] ?? "", choice: $0.1) },
            time: "14:05"
        )
    }

    private func records(_ values: [(String, String, SendDeliveryState)]) -> SendReconciliationState {
        SendReconciliationState(records: values.map { id, text, state in
            SendReconciliationRecord(clientRequestID: id, text: text, projectionRunID: runID, deliveryState: state)
        })
    }

    private func event(_ sequence: UInt64, _ payload: ConversationEventPayload) -> ConversationEvent {
        ConversationEvent(
            conversationID: conversationID, sequence: sequence, eventID: "event-\(sequence)",
            timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000 + TimeInterval(sequence) * 60),
            provider: .claude, payload: payload
        )
    }

    private func liveState(_ events: [ConversationEvent]) -> ConversationRuntime.State {
        ConversationRuntime.State(
            conversationID: conversationID,
            connectionGeneration: 4,
            projectionRunID: runID,
            projectionGeneration: 7,
            events: events.map(CompatibleConversationEvent.known),
            cursor: ConversationEventCursor(
                projectionRunID: runID, projectionGeneration: 7, afterSequence: events.last?.sequence ?? 0
            ),
            oldestObservedSequence: events.first?.sequence,
            latestSequence: events.last?.sequence ?? 0,
            firstAvailableSequence: 1,
            historyTruncated: false,
            isLoadingOlder: false,
            phase: .live,
            composerAuthority: ConversationComposerAuthority(),
            sendReconciliation: SendReconciliation()
        )
    }
}
