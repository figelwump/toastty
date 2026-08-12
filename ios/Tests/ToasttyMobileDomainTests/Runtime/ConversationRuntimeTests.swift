import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class ConversationRuntimeTests: XCTestCase {
    func testSubscribeBeforeRESTBuffersAndDrainsMatchingLivePage() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        var accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        var directive = await runtime.applyLive(
            page(runID: run, events: [event(2)], latestSequence: 2),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)

        directive = await runtime.applyREST(
            page(runID: run, events: [event(1)], latestSequence: 1),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)
        accepted = await runtime.finishCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1, 2])
        XCTAssertEqual(
            state.cursor,
            ConversationEventCursor(
                projectionRunID: run,
                projectionGeneration: 4,
                afterSequence: 2
            )
        )
        XCTAssertEqual(state.phase, .live)
    }

    func testGapRequestsRESTAndBufferedPageDrainsAfterMissingSequence() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadInitial(runtime, runID: run, events: [event(1)])

        var directive = await runtime.applyLive(
            page(runID: run, events: [event(3)], latestSequence: 3),
            connectionGeneration: 1
        )
        XCTAssertEqual(
            directive,
            .fetchREST(cursor: ConversationEventCursor(
                projectionRunID: run,
                projectionGeneration: 4,
                afterSequence: 1
            ))
        )

        directive = await runtime.applyREST(
            page(runID: run, events: [event(2)], latestSequence: 3),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)
        let accepted = await runtime.finishCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(state.cursor?.afterSequence, 3)
    }

    func testDuplicateEventsAreIgnoredWithoutBlockingNewEvents() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadInitial(runtime, runID: run, events: [event(1), event(2)])

        let directive = await runtime.applyLive(
            page(runID: run, events: [event(2), event(3)], latestSequence: 3),
            connectionGeneration: 1
        )

        XCTAssertEqual(directive, .none)
        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1, 2, 3])
    }

    func testRunAndGenerationChangesRequireResnapshot() async {
        let runChanged = ConversationRuntime(conversationID: conversationID)
        await loadInitial(runChanged, runID: runID(1), events: [event(1)])
        var directive = await runChanged.applyLive(
            page(runID: runID(2), events: [event(2)], latestSequence: 2),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .resnapshot(reason: .projectionChanged))

        let generationChanged = ConversationRuntime(conversationID: conversationID)
        await loadInitial(generationChanged, runID: runID(1), events: [event(1)])
        directive = await generationChanged.applyLive(
            page(
                runID: runID(1),
                projectionGeneration: 5,
                events: [event(2)],
                latestSequence: 2
            ),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .resnapshot(reason: .projectionChanged))
    }

    func testNilCursorCanAdoptRetainedSuffixAndMarksHistoryTruncated() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        let accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        let directive = await runtime.applyREST(
            page(
                runID: run,
                events: [event(5), event(6)],
                latestSequence: 6,
                firstAvailableSequence: 5,
                historyTruncated: true
            ),
            connectionGeneration: 1
        )

        XCTAssertEqual(directive, .none)
        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [5, 6])
        XCTAssertEqual(state.cursor?.afterSequence, 6)
        XCTAssertEqual(state.firstAvailableSequence, 5)
        XCTAssertTrue(state.historyTruncated)
    }

    func testRetentionAdvancingPastCursorRequiresResnapshot() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadInitial(runtime, runID: run, events: [event(1)])

        let directive = await runtime.applyLive(
            page(
                runID: run,
                events: [event(3)],
                latestSequence: 3,
                firstAvailableSequence: 3,
                historyTruncated: true
            ),
            connectionGeneration: 1
        )

        XCTAssertEqual(directive, .resnapshot(reason: .retentionLost))
    }

    func testLiveBoundaryBufferOverflowRequiresResnapshot() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        let accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        for _ in 0..<ConversationRuntime.maximumBufferedLivePages {
            let directive = await runtime.applyLive(
                page(runID: run, events: [], latestSequence: 0),
                connectionGeneration: 1
            )
            XCTAssertEqual(directive, .none)
        }

        let directive = await runtime.applyLive(
            page(runID: run, events: [], latestSequence: 0),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .resnapshot(reason: .liveBufferOverflow))
        let state = await runtime.currentState()
        XCTAssertEqual(state.phase, .resnapshotRequired(.liveBufferOverflow))
    }

    func testExplicitResnapshotDirectiveAndStaleGenerationAreIndependent() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        var accepted = await runtime.beginCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)

        var directive = await runtime.requireResnapshot(
            .explicit,
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)
        var state = await runtime.currentState()
        XCTAssertEqual(state.phase, .catchingUp)

        directive = await runtime.requireResnapshot(
            .explicit,
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .resnapshot(reason: .explicit))
        state = await runtime.currentState()
        XCTAssertEqual(state.phase, .resnapshotRequired(.explicit))

        accepted = await runtime.beginCatchUp(connectionGeneration: 3, resnapshot: true)
        XCTAssertTrue(accepted)
        directive = await runtime.applyREST(
            page(runID: runID(9), events: [event(1)], latestSequence: 1),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .none)
        state = await runtime.currentState()
        XCTAssertNil(state.projectionRunID)
        XCTAssertEqual(state.connectionGeneration, 3)
    }

    func testNewConnectionGenerationDiscardsPreviouslyBufferedLivePages() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        var accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)
        var directive = await runtime.applyLive(
            page(runID: run, events: [event(2)], latestSequence: 2),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)

        accepted = await runtime.beginCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)
        directive = await runtime.applyREST(
            page(runID: run, events: [event(1)], latestSequence: 1),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .none)
        accepted = await runtime.finishCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)

        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1])
        XCTAssertEqual(state.cursor?.afterSequence, 1)
    }

    func testUnknownEventAdvancesCursorButIsNotRendered() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        let accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        let directive = await runtime.applyREST(
            page(
                runID: run,
                events: [
                    event(1),
                    .unknown(
                        conversationID: conversationID,
                        sequence: 2,
                        kind: "future_optional_event"
                    ),
                    event(3),
                ],
                latestSequence: 3
            ),
            connectionGeneration: 1
        )

        XCTAssertEqual(directive, .none)
        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1, 3])
        XCTAssertEqual(state.cursor?.afterSequence, 3)
    }

    func testSameProjectionResnapshotPreservesOptimisticSendDuringCatchUp() async throws {
        let reconciliation = SendReconciliation()
        let runtime = ConversationRuntime(
            conversationID: conversationID,
            sendReconciliation: reconciliation
        )
        let run = runID(1)
        await loadInitial(runtime, runID: run, events: [event(1)])
        _ = await reconciliation.enqueue(
            clientRequestID: "request-1",
            text: "hello",
            projectionRunID: run
        )
        await reconciliation.apply(
            .accepted(epoch: RemoteInputEpoch(bindingID: bindingID)),
            clientRequestID: "request-1"
        )

        var accepted = await runtime.beginCatchUp(connectionGeneration: 2, resnapshot: true)
        XCTAssertTrue(accepted)
        let directive = await runtime.applyREST(
            page(runID: run, events: [event(1)], latestSequence: 1),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .none)

        var reconciliationState = await reconciliation.currentState()
        var record = try XCTUnwrap(reconciliationState["request-1"])
        XCTAssertEqual(record.deliveryState, .pending(.accepted))
        let stateDuringCatchUp = await runtime.currentState()
        XCTAssertTrue(stateDuringCatchUp.sendReconciliation === reconciliation)

        accepted = await runtime.finishCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)
        reconciliationState = await reconciliation.currentState()
        record = try XCTUnwrap(reconciliationState["request-1"])
        XCTAssertEqual(record.deliveryState, .deliveryUnconfirmed)
    }

    private func loadInitial(
        _ runtime: ConversationRuntime,
        runID: RemoteProjectionRunID,
        events: [CompatibleConversationEvent]
    ) async {
        let accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)
        let directive = await runtime.applyREST(
            page(
                runID: runID,
                events: events,
                latestSequence: events.last?.sequence ?? 0
            ),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)
        let finished = await runtime.finishCatchUp(connectionGeneration: 1)
        XCTAssertTrue(finished)
    }

    private func page(
        runID: RemoteProjectionRunID,
        projectionGeneration: UInt64 = 4,
        events: [CompatibleConversationEvent],
        latestSequence: UInt64,
        firstAvailableSequence: UInt64? = nil,
        historyTruncated: Bool = false
    ) -> CompatibleConversationEventPage {
        CompatibleConversationEventPage(
            conversationID: conversationID,
            projectionRunID: runID,
            projectionGeneration: projectionGeneration,
            events: events,
            latestSequence: latestSequence,
            firstAvailableSequence: firstAvailableSequence,
            historyTruncated: historyTruncated
        )
    }

    private func event(_ sequence: UInt64) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .codex,
            payload: .assistantMessage(ConversationAssistantMessagePayload(
                text: "message \(sequence)",
                phase: .final
            ))
        ))
    }

    private func runID(_ suffix: UInt8) -> RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix
        )))
    }

    private var conversationID: RemoteConversationID {
        RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    private var bindingID: UUID {
        UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    }
}
