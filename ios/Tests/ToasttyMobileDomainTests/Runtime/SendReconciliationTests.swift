import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class SendReconciliationTests: XCTestCase {
    private let firstRunID = RemoteProjectionRunID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    private let secondRunID = RemoteProjectionRunID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    )
    private let conversationID = RemoteConversationID(
        rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    )
    private let epoch = RemoteInputEpoch(
        bindingID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
        counter: 2
    )

    func testAcceptedAndDuplicateRemainPendingExactEcho() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "accepted", text: "one")
        await reconciliation.enqueue(clientRequestID: "duplicate", text: "two")

        await reconciliation.apply(.accepted(epoch: epoch), clientRequestID: "accepted")
        await reconciliation.apply(.duplicate, clientRequestID: "duplicate")

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["accepted"]?.deliveryState, .pending(.accepted))
        XCTAssertEqual(state["duplicate"]?.deliveryState, .pending(.duplicate))
    }

    func testExactUserMessageRequestIDConfirmsWithoutOriginOrContentMatching() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "request-1", text: "optimistic text")
        await reconciliation.apply(.accepted(epoch: epoch), clientRequestID: "request-1")

        await reconciliation.observe([
            .known(makeEvent(
                sequence: 9,
                payload: .userMessage(ConversationUserMessagePayload(
                    text: "host-normalized text differs",
                    origin: .unknown,
                    clientRequestID: "request-1"
                ))
            )),
        ])

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["request-1"]?.deliveryState, .confirmed(sequence: 9))
    }

    func testTextTimestampOriginAndBindingNeverConfirm() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "request-1", text: "same text")
        await reconciliation.apply(.accepted(epoch: epoch), clientRequestID: "request-1")

        await reconciliation.observe([
            .known(makeEvent(
                sequence: 1,
                payload: .userMessage(ConversationUserMessagePayload(
                    text: "same text",
                    origin: .remote,
                    clientRequestID: nil
                ))
            )),
            .known(makeEvent(
                sequence: 2,
                payload: .userMessage(ConversationUserMessagePayload(
                    text: "same text",
                    origin: .remote,
                    clientRequestID: "someone-else"
                ))
            )),
            .known(makeEvent(
                sequence: 3,
                payload: .sessionBindingChanged(ConversationSessionBindingChangedPayload(
                    reason: .runtimeResumed,
                    providerSessionID: "request-1"
                ))
            )),
        ])

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["request-1"]?.deliveryState, .pending(.accepted))
    }

    func testRejectedIsTerminalAndLateEchoCannotReopenIt() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "rejected", text: "hello")
        await reconciliation.apply(
            .rejected(reason: .epochMismatch),
            clientRequestID: "rejected"
        )
        await reconciliation.observe([
            .known(makeUserMessage(sequence: 4, clientRequestID: "rejected")),
        ])

        let state = await reconciliation.currentState()
        XCTAssertEqual(
            state["rejected"]?.deliveryState,
            .rejected(reason: .epochMismatch)
        )
    }

    func testUncertainNeverRetriesButExactEchoCanStillConfirmIt() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "uncertain", text: "hello")
        await reconciliation.apply(.uncertain, clientRequestID: "uncertain")
        await reconciliation.apply(.accepted(epoch: epoch), clientRequestID: "uncertain")

        var state = await reconciliation.currentState()
        XCTAssertEqual(state["uncertain"]?.deliveryState, .uncertain)
        XCTAssertEqual(state["uncertain"]?.deliveryState.allowsRetry, false)

        await reconciliation.observe([
            .known(makeUserMessage(sequence: 4, clientRequestID: "uncertain")),
        ])

        state = await reconciliation.currentState()
        XCTAssertEqual(state["uncertain"]?.deliveryState, .confirmed(sequence: 4))
    }

    func testUncertainWithoutEchoBecomesDeliveryUnconfirmedAtResnapshotBoundary() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "uncertain", text: "hello")
        await reconciliation.apply(.uncertain, clientRequestID: "uncertain")

        await reconciliation.completedResnapshot(
            projectionRunID: firstRunID,
            latestSequence: 5,
            observedThroughSequence: 5
        )

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["uncertain"]?.deliveryState, .deliveryUnconfirmed)
    }

    func testProjectionRunChangeMakesOnlyPendingSendsDeliveryUnconfirmed() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "lost", text: "one")
        await reconciliation.enqueue(clientRequestID: "confirmed", text: "two")
        await reconciliation.observe([
            .known(makeUserMessage(sequence: 5, clientRequestID: "confirmed")),
        ])

        await reconciliation.projectionDidChange(to: secondRunID)

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["lost"]?.deliveryState, .deliveryUnconfirmed)
        XCTAssertEqual(state["confirmed"]?.deliveryState, .confirmed(sequence: 5))
        XCTAssertEqual(state["lost"]?.deliveryState.isDismissible, true)
    }

    func testEstablishingFirstProjectionRunDoesNotInvalidatePendingSend() async {
        let reconciliation = SendReconciliation()
        await reconciliation.enqueue(clientRequestID: "pending", text: "one")

        await reconciliation.projectionDidChange(to: firstRunID)

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["pending"]?.deliveryState, .pending(.awaitingResponse))
    }

    func testResnapshotMustReachLatestSequenceBeforeLostEchoTransition() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "lost", text: "one")

        await reconciliation.completedResnapshot(
            projectionRunID: firstRunID,
            latestSequence: 10,
            observedThroughSequence: 9
        )
        var state = await reconciliation.currentState()
        XCTAssertEqual(state["lost"]?.deliveryState, .pending(.awaitingResponse))

        await reconciliation.completedResnapshot(
            projectionRunID: firstRunID,
            latestSequence: 10,
            observedThroughSequence: 10
        )
        state = await reconciliation.currentState()
        XCTAssertEqual(state["lost"]?.deliveryState, .deliveryUnconfirmed)
    }

    func testMismatchedResnapshotCannotInvalidateCurrentRun() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "pending", text: "one")

        await reconciliation.completedResnapshot(
            projectionRunID: secondRunID,
            latestSequence: 1,
            observedThroughSequence: 1
        )

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["pending"]?.deliveryState, .pending(.awaitingResponse))
    }

    func testDuplicateEnqueueCannotReplaceOriginalRecord() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        let original = await reconciliation.enqueue(
            clientRequestID: "same-id",
            text: "original"
        )
        let duplicate = await reconciliation.enqueue(
            clientRequestID: "same-id",
            text: "replacement"
        )

        XCTAssertEqual(duplicate?.record, original?.record)
        let state = await reconciliation.currentState()
        XCTAssertEqual(state.records.count, 1)
        XCTAssertEqual(state["same-id"]?.text, "original")
    }

    func testSlowStateSubscriberCannotLoseAuthoritativeRecords() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        let stream = await reconciliation.states()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        await reconciliation.enqueue(clientRequestID: "one", text: "1")
        await reconciliation.enqueue(clientRequestID: "two", text: "2")
        await reconciliation.enqueue(clientRequestID: "three", text: "3")

        let newestPublishedState = await iterator.next()
        let authoritativeState = await reconciliation.currentState()
        XCTAssertEqual(newestPublishedState?.records.map(\.clientRequestID), ["one", "two", "three"])
        XCTAssertEqual(authoritativeState.records.map(\.clientRequestID), ["one", "two", "three"])
    }

    func testDismissRemovesOnlyDismissibleTerminalReceipt() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "lost", text: "two")
        await reconciliation.completedResnapshot(
            projectionRunID: firstRunID,
            latestSequence: 0,
            observedThroughSequence: 0
        )
        await reconciliation.enqueue(clientRequestID: "pending", text: "one")

        await reconciliation.dismiss(clientRequestID: "lost")
        await reconciliation.dismiss(clientRequestID: "pending")

        let state = await reconciliation.currentState()
        XCTAssertEqual(state.records.map(\.clientRequestID), ["pending"])
    }

    func testOperationFailureIsDismissibleAndExactEchoCanStillConfirm() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "future-result", text: "hello")

        await reconciliation.markOperationFailed(clientRequestID: "future-result")
        var state = await reconciliation.currentState()
        XCTAssertEqual(state["future-result"]?.deliveryState, .operationFailed)
        XCTAssertTrue(state["future-result"]?.deliveryState.isDismissible == true)

        await reconciliation.observe([
            .known(makeUserMessage(sequence: 12, clientRequestID: "future-result")),
        ])
        state = await reconciliation.currentState()
        XCTAssertEqual(state["future-result"]?.deliveryState, .confirmed(sequence: 12))
    }

    func testEnqueueCapacityBoundsUnresolvedAndTotalRecords() async {
        let unresolved = SendReconciliation(initialProjectionRunID: firstRunID)
        for index in 0..<SendReconciliation.maximumUnresolvedRecords {
            await unresolved.enqueue(clientRequestID: "pending-\(index)", text: "message")
        }
        let refusedUnresolved = await unresolved.enqueue(
            clientRequestID: "one-too-many",
            text: "message"
        )
        XCTAssertNil(refusedUnresolved)

        let retained = SendReconciliation(initialProjectionRunID: firstRunID)
        for index in 0..<SendReconciliation.maximumRetainedRecords {
            let requestID = "rejected-\(index)"
            await retained.enqueue(clientRequestID: requestID, text: "message")
            await retained.apply(.rejected(reason: .epochMismatch), clientRequestID: requestID)
        }
        let refusedRetained = await retained.enqueue(
            clientRequestID: "one-too-many",
            text: "message"
        )
        XCTAssertNil(refusedRetained)
        let retainedState = await retained.currentState()
        XCTAssertEqual(
            retainedState.records.count,
            SendReconciliation.maximumRetainedRecords
        )
    }

    func testDeliveryUnconfirmedCanStillBePromotedByExactEcho() async {
        let reconciliation = SendReconciliation(initialProjectionRunID: firstRunID)
        await reconciliation.enqueue(clientRequestID: "late-echo", text: "hello")
        await reconciliation.completedResnapshot(
            projectionRunID: firstRunID,
            latestSequence: 4,
            observedThroughSequence: 4
        )

        await reconciliation.observe([
            .known(makeUserMessage(sequence: 5, clientRequestID: "late-echo")),
        ])

        let state = await reconciliation.currentState()
        XCTAssertEqual(state["late-echo"]?.deliveryState, .confirmed(sequence: 5))
    }

    private func makeUserMessage(
        sequence: UInt64,
        clientRequestID: String
    ) -> ConversationEvent {
        makeEvent(
            sequence: sequence,
            payload: .userMessage(ConversationUserMessagePayload(
                text: "message",
                origin: .remote,
                clientRequestID: clientRequestID
            ))
        )
    }

    private func makeEvent(
        sequence: UInt64,
        payload: ConversationEventPayload
    ) -> ConversationEvent {
        ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: 1_786_000_000 + TimeInterval(sequence)),
            provider: .codex,
            payload: payload
        )
    }
}
