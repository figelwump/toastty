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

    func testUnknownMiddleCompatibilityFixtureAdvancesRuntimeCursorWithoutRenderingUnknownRow() async throws {
        let response = try GatewayCompatibilityDecoder().decodeEventsResponse(
            CompatibilityFixture.data("events-unknown-middle")
        )
        guard case .page(let fixturePage) = response else {
            return XCTFail("Expected the unknown-middle fixture to contain a page")
        }
        let runtime = ConversationRuntime(conversationID: conversationID)
        var accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        let directive = await runtime.applyREST(fixturePage, connectionGeneration: 1)
        XCTAssertEqual(directive, .none)
        accepted = await runtime.finishCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1, 3])
        XCTAssertEqual(state.events.map(\.kind), ["user_message", "assistant_message"])
        XCTAssertEqual(state.cursor?.afterSequence, 3)
        XCTAssertEqual(state.latestSequence, 3)
        XCTAssertEqual(state.phase, .live)
    }

    func testGapReconnectAndProjectionRestartProduceExactlyOnceOrderedReplacement() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let originalRun = runID(1)
        let restartedRun = runID(2)
        await loadInitial(runtime, runID: originalRun, events: [event(1, prefix: "original")])

        var directive = await runtime.applyLive(
            page(
                runID: originalRun,
                events: [event(3, prefix: "original")],
                latestSequence: 3
            ),
            connectionGeneration: 1
        )
        XCTAssertEqual(
            directive,
            .fetchREST(cursor: ConversationEventCursor(
                projectionRunID: originalRun,
                projectionGeneration: 4,
                afterSequence: 1
            ))
        )

        var accepted = await runtime.beginCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)
        directive = await runtime.applyREST(
            page(
                runID: originalRun,
                events: [event(2, prefix: "stale")],
                latestSequence: 3
            ),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none, "The disconnected generation must not mutate the projection")

        directive = await runtime.applyLive(
            page(
                runID: originalRun,
                events: [event(3, prefix: "original")],
                latestSequence: 3
            ),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .none)
        directive = await runtime.applyREST(
            page(
                runID: originalRun,
                events: [event(2, prefix: "original")],
                latestSequence: 3
            ),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .none)
        accepted = await runtime.finishCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)

        var state = await runtime.currentState()
        XCTAssertEqual(eventIDs(in: state.events), [
            "original-event-1",
            "original-event-2",
            "original-event-3",
        ])

        directive = await runtime.applyLive(
            page(
                runID: restartedRun,
                events: [event(1, prefix: "restarted")],
                latestSequence: 2
            ),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .resnapshot(reason: .projectionChanged))
        accepted = await runtime.beginCatchUp(connectionGeneration: 2, resnapshot: true)
        XCTAssertTrue(accepted)
        directive = await runtime.applyREST(
            page(
                runID: restartedRun,
                events: [
                    event(1, prefix: "restarted"),
                    event(2, prefix: "restarted"),
                ],
                latestSequence: 2
            ),
            connectionGeneration: 2
        )
        XCTAssertEqual(directive, .none)
        accepted = await runtime.finishCatchUp(connectionGeneration: 2)
        XCTAssertTrue(accepted)

        state = await runtime.currentState()
        XCTAssertEqual(state.projectionRunID, restartedRun)
        XCTAssertEqual(eventIDs(in: state.events), [
            "restarted-event-1",
            "restarted-event-2",
        ])
        XCTAssertEqual(Set(eventIDs(in: state.events)).count, state.events.count)
        XCTAssertEqual(state.events.map(\.sequence), [1, 2])
        XCTAssertEqual(state.cursor?.afterSequence, 2)
        XCTAssertEqual(state.phase, .live)
    }

    func testRetentionLossKeepsStaleTranscriptUntilResnapshotStartsThenPublishesTruncatedSuffix() async {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        var accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)
        var directive = await runtime.applyREST(
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
        accepted = await runtime.finishCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        directive = await runtime.applyLive(
            page(
                runID: run,
                events: [event(8), event(9)],
                latestSequence: 9,
                firstAvailableSequence: 8,
                historyTruncated: true
            ),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .resnapshot(reason: .retentionLost))

        var state = await runtime.currentState()
        XCTAssertEqual(state.phase, .resnapshotRequired(.retentionLost))
        XCTAssertEqual(state.events.map(\.sequence), [5, 6], "Readable stale rows remain until resync begins")
        XCTAssertTrue(state.historyTruncated)
        XCTAssertEqual(state.firstAvailableSequence, 5)

        accepted = await runtime.beginCatchUp(connectionGeneration: 1, resnapshot: true)
        XCTAssertTrue(accepted)
        state = await runtime.currentState()
        XCTAssertEqual(state.phase, .catchingUp)
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertFalse(state.historyTruncated)
        XCTAssertNil(state.firstAvailableSequence)

        directive = await runtime.applyREST(
            page(
                runID: run,
                events: [event(8), event(9)],
                latestSequence: 9,
                firstAvailableSequence: 8,
                historyTruncated: true
            ),
            connectionGeneration: 1
        )
        XCTAssertEqual(directive, .none)
        accepted = await runtime.finishCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)

        state = await runtime.currentState()
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.events.map(\.sequence), [8, 9])
        XCTAssertEqual(state.cursor?.afterSequence, 9)
        XCTAssertEqual(state.firstAvailableSequence, 8)
        XCTAssertTrue(state.historyTruncated)
    }

    func testTailOpenAndOlderPagePreserveAscendingOrderAndLiveCursor() async throws {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadTail(
            runtime,
            runID: run,
            events: [event(7), event(8), event(9), event(10)],
            latestSequence: 10
        )

        var state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [7, 8, 9, 10])
        XCTAssertEqual(state.oldestObservedSequence, 7)
        XCTAssertEqual(state.cursor?.afterSequence, 10)
        XCTAssertTrue(state.hasOlder)

        let pendingRequest = await runtime.beginLoadingOlder(connectionGeneration: 1)
        let request = try XCTUnwrap(pendingRequest)
        XCTAssertEqual(request.beforeSequence, 7)
        XCTAssertEqual(request.cursor.beforeSequence, 7)
        state = await runtime.currentState()
        XCTAssertTrue(state.isLoadingOlder)
        let duplicateRequest = await runtime.beginLoadingOlder(connectionGeneration: 1)
        XCTAssertNil(
            duplicateRequest,
            "Only one older-page request may be active"
        )

        let directive = await runtime.applyOlderREST(
            page(
                runID: run,
                events: [event(4), event(5), event(6)],
                latestSequence: 10,
                firstAvailableSequence: 1
            ),
            request: request
        )
        XCTAssertEqual(directive, .none)

        state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(Set(eventIDs(in: state.events)).count, state.events.count)
        XCTAssertEqual(state.oldestObservedSequence, 4)
        XCTAssertEqual(state.cursor?.afterSequence, 10, "Backward paging must not move the live cursor")
        XCTAssertTrue(state.hasOlder)
        XCTAssertFalse(state.isLoadingOlder)
        XCTAssertEqual(state.phase, .live)
    }

    func testUnknownOnlyOlderPageContinuesWithoutRenderingAndThenStopsAtRetainedHead() async throws {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadTail(
            runtime,
            runID: run,
            events: [event(7), event(8)],
            latestSequence: 8
        )
        let pendingRequest = await runtime.beginLoadingOlder(connectionGeneration: 1)
        let request = try XCTUnwrap(pendingRequest)

        let unknowns: [CompatibleConversationEvent] = (4...6).map { sequence in
            .unknown(
                conversationID: conversationID,
                sequence: UInt64(sequence),
                kind: "future_optional_event"
            )
        }
        var directive = await runtime.applyOlderREST(
            page(
                runID: run,
                events: unknowns,
                latestSequence: 8,
                firstAvailableSequence: 1
            ),
            request: request
        )
        guard case .continueLoading(let continuation) = directive else {
            return XCTFail("An unknown-only page should advance to the next exclusive boundary")
        }
        XCTAssertEqual(continuation.beforeSequence, 4)

        var state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [7, 8])
        XCTAssertEqual(state.oldestObservedSequence, 4)
        XCTAssertEqual(state.cursor?.afterSequence, 8)
        XCTAssertTrue(state.isLoadingOlder)

        directive = await runtime.applyOlderREST(
            page(
                runID: run,
                events: [event(1), event(2), event(3)],
                latestSequence: 8,
                firstAvailableSequence: 1
            ),
            request: continuation
        )
        XCTAssertEqual(directive, .none)

        state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [1, 2, 3, 7, 8])
        XCTAssertEqual(state.oldestObservedSequence, 1)
        XCTAssertEqual(state.cursor?.afterSequence, 8)
        XCTAssertFalse(state.hasOlder)
        XCTAssertFalse(state.isLoadingOlder)
    }

    func testStaleOlderRequestCannotMutateNewConnectionGeneration() async throws {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadTail(runtime, runID: run, events: [event(7), event(8)], latestSequence: 8)
        let pendingRequest = await runtime.beginLoadingOlder(connectionGeneration: 1)
        let staleRequest = try XCTUnwrap(pendingRequest)

        let beganNewGeneration = await runtime.beginCatchUp(connectionGeneration: 2)
        XCTAssertTrue(beganNewGeneration)
        let directive = await runtime.applyOlderREST(
            page(
                runID: run,
                events: [event(4), event(5), event(6)],
                latestSequence: 8,
                firstAvailableSequence: 1
            ),
            request: staleRequest
        )

        XCTAssertEqual(directive, .none)
        let finishedStaleRequest = await runtime.finishLoadingOlder(request: staleRequest)
        XCTAssertFalse(finishedStaleRequest)
        let state = await runtime.currentState()
        XCTAssertEqual(state.events.map(\.sequence), [7, 8])
        XCTAssertEqual(state.connectionGeneration, 2)
        XCTAssertEqual(state.phase, .catchingUp)
        XCTAssertFalse(state.isLoadingOlder)
    }

    func testOlderPageProjectionMismatchRequiresResnapshotWithoutReplacingReadableRows() async throws {
        let runtime = ConversationRuntime(conversationID: conversationID)
        let run = runID(1)
        await loadTail(runtime, runID: run, events: [event(7), event(8)], latestSequence: 8)
        let pendingRequest = await runtime.beginLoadingOlder(connectionGeneration: 1)
        let request = try XCTUnwrap(pendingRequest)

        let directive = await runtime.applyOlderREST(
            page(
                runID: runID(2),
                events: [event(4), event(5), event(6)],
                latestSequence: 8,
                firstAvailableSequence: 1
            ),
            request: request
        )

        XCTAssertEqual(directive, .resnapshot(reason: .projectionChanged))
        let state = await runtime.currentState()
        XCTAssertEqual(state.phase, .resnapshotRequired(.projectionChanged))
        XCTAssertEqual(state.events.map(\.sequence), [7, 8])
        XCTAssertFalse(state.isLoadingOlder)
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

    private func loadTail(
        _ runtime: ConversationRuntime,
        runID: RemoteProjectionRunID,
        events: [CompatibleConversationEvent],
        latestSequence: UInt64
    ) async {
        let accepted = await runtime.beginCatchUp(connectionGeneration: 1)
        XCTAssertTrue(accepted)
        let directive = await runtime.applyRESTTail(
            page(
                runID: runID,
                events: events,
                latestSequence: latestSequence,
                firstAvailableSequence: 1
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

    private func event(
        _ sequence: UInt64,
        prefix: String = "event"
    ) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "\(prefix)-event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .codex,
            payload: .assistantMessage(ConversationAssistantMessagePayload(
                text: "message \(sequence)",
                phase: .final
            ))
        ))
    }

    private func eventIDs(in events: [CompatibleConversationEvent]) -> [String] {
        events.compactMap { event in
            guard case .known(let known) = event else { return nil }
            return known.eventID
        }
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
