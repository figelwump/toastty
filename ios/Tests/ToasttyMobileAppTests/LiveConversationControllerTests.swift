import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class LiveConversationControllerTests: XCTestCase {
    func testPublishesOrderedValuesAndClassifiesAppendAndRebuild() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )

        subject.consume(state(runID: runID(1), events: [event(1), event(2)]))
        XCTAssertEqual(subject.events.map(\.sequence), [1, 2])
        XCTAssertEqual(subject.change, .initial)
        XCTAssertEqual(subject.phase, .resynchronizing(reason: nil))

        subject.consume(state(
            runID: runID(1),
            events: [event(1), event(2), event(3)],
            phase: .live
        ))
        XCTAssertEqual(subject.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(subject.change, .append)
        XCTAssertEqual(subject.phase, .live)
        XCTAssertEqual(subject.cursor?.afterSequence, 3)

        subject.consume(state(
            runID: runID(2),
            events: [event(1, id: "replacement")],
            phase: .catchingUp
        ))
        XCTAssertEqual(subject.events.map(\.sequence), [1])
        XCTAssertEqual(subject.change, .rebuild)
        XCTAssertEqual(subject.phase, .resynchronizing(reason: nil))
        XCTAssertEqual(subject.projectionRunID, runID(2))
    }

    func testConnectionPhaseMakesReadableTranscriptStaleOrFailed() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consume(state(runID: runID(1), events: [event(1)], phase: .live))

        subject.consumeConnectionPhase(.reconnecting(failureCount: 1, showsBanner: false))
        XCTAssertEqual(subject.phase, .stale)
        XCTAssertEqual(subject.events.map(\.sequence), [1])

        subject.consumeConnectionPhase(.authorizationDenied)
        XCTAssertEqual(subject.phase, .failed)
        XCTAssertEqual(subject.events.map(\.sequence), [1])
    }

    func testProjectionGenerationRebuildsRowIdentityWithinTheSameRun() throws {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consume(state(
            runID: runID(1),
            projectionGeneration: 7,
            events: [event(1)],
            phase: .live
        ))
        let firstID = try XCTUnwrap(subject.transcriptPresentation.rows.first?.id)

        subject.consume(state(
            runID: runID(1),
            projectionGeneration: 8,
            events: [event(1)],
            phase: .live
        ))
        let regeneratedID = try XCTUnwrap(subject.transcriptPresentation.rows.first?.id)

        XCTAssertEqual(subject.change, .rebuild)
        XCTAssertNotEqual(firstID, regeneratedID)
        XCTAssertEqual(firstID.projectionRunID, regeneratedID.projectionRunID)
        XCTAssertNotEqual(firstID.projectionGeneration, regeneratedID.projectionGeneration)
        XCTAssertEqual(firstID.conversationID, regeneratedID.conversationID)
        XCTAssertEqual(firstID.sequence, regeneratedID.sequence)
    }

    func testPrependingOlderHistoryPublishesScrollPreservingRevisionAndPagingMetadata() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consume(state(
            runID: runID(1),
            events: [event(7), event(8)],
            oldestObservedSequence: 7,
            firstAvailableSequence: 1
        ))
        XCTAssertTrue(subject.hasOlder)
        XCTAssertTrue(subject.transcriptPresentation.hasOlder)

        subject.consume(state(
            runID: runID(1),
            events: [event(4), event(5), event(6), event(7), event(8)],
            oldestObservedSequence: 4,
            firstAvailableSequence: 1,
            isLoadingOlder: false,
            phase: .live
        ))

        XCTAssertEqual(subject.change, .prepend)
        XCTAssertEqual(subject.transcriptPresentation.revision, .prepended)
        XCTAssertEqual(subject.prependAnchorID?.projectionGeneration, 7)
        XCTAssertEqual(subject.transcriptPresentation.prependAnchorID?.projectionGeneration, 7)
        XCTAssertEqual(subject.events.map(\.sequence), [4, 5, 6, 7, 8])
        XCTAssertTrue(subject.hasOlder)
        XCTAssertFalse(subject.isLoadingOlder)
        XCTAssertTrue(subject.transcriptPresentation.hasOlder)
        XCTAssertFalse(subject.transcriptPresentation.isLoadingOlder)
    }

    func testLoadOlderActionRunsOnlyWhenEligibleAndNotAlreadyLoading() async {
        let recorder = LoadOlderRecorder()
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            loadOlder: { await recorder.record() }
        )

        await subject.loadOlder()
        var loadCount = await recorder.count()
        XCTAssertEqual(loadCount, 0)

        subject.consume(state(
            runID: runID(1),
            events: [event(7), event(8)],
            oldestObservedSequence: 7,
            firstAvailableSequence: 1,
            isLoadingOlder: false,
            phase: .live
        ))
        await subject.loadOlder()
        loadCount = await recorder.count()
        XCTAssertEqual(loadCount, 1)

        subject.consume(state(
            runID: runID(1),
            events: [event(7), event(8)],
            oldestObservedSequence: 7,
            firstAvailableSequence: 1,
            isLoadingOlder: true,
            phase: .live
        ))
        await subject.loadOlder()
        loadCount = await recorder.count()
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(subject.transcriptPresentation.isLoadingOlder)
    }

    func testFiveThousandRowControllerClassifiesTwoHundredRowPrependAndAppendWithinSimulatorBudget() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        let initialEvents = (201...5_200).map { event(UInt64($0)) }
        subject.consume(state(
            runID: runID(1),
            events: initialEvents,
            oldestObservedSequence: 201,
            firstAvailableSequence: 1,
            phase: .live
        ))
        XCTAssertEqual(subject.transcriptPresentation.rows.count, 5_000)

        let clock = ContinuousClock()
        var startedAt = clock.now
        subject.consume(state(
            runID: runID(1),
            events: (1...200).map { event(UInt64($0)) } + initialEvents,
            oldestObservedSequence: 1,
            firstAvailableSequence: 1,
            phase: .live
        ))
        let prependElapsed = startedAt.duration(to: clock.now)
        XCTAssertEqual(subject.change, .prepend)
        XCTAssertEqual(subject.transcriptPresentation.revision, .prepended)

        let prependedEvents = subject.events
        startedAt = clock.now
        subject.consume(state(
            runID: runID(1),
            events: prependedEvents + (5_201...5_400).map { event(UInt64($0)) },
            oldestObservedSequence: 1,
            firstAvailableSequence: 1,
            phase: .live
        ))
        let appendElapsed = startedAt.duration(to: clock.now)

        print(
            "TOASTTY_TRANSCRIPT_CONTROLLER_PERFORMANCE "
                + "baseRows=5000 batchRows=200 prepend=\(prependElapsed) append=\(appendElapsed)"
        )
        XCTAssertEqual(subject.change, .append)
        XCTAssertEqual(subject.transcriptPresentation.revision, .appended)
        XCTAssertEqual(subject.transcriptPresentation.rows.count, 5_400)
        XCTAssertLessThanOrEqual(prependElapsed, .seconds(1))
        XCTAssertLessThanOrEqual(appendElapsed, .seconds(1))
    }

    private func state(
        runID: RemoteProjectionRunID,
        projectionGeneration: UInt64 = 7,
        events: [CompatibleConversationEvent],
        oldestObservedSequence: UInt64? = nil,
        firstAvailableSequence: UInt64? = 1,
        isLoadingOlder: Bool = false,
        phase: ConversationRuntimePhase = .catchingUp
    ) -> ConversationRuntime.State {
        ConversationRuntime.State(
            conversationID: conversationID,
            connectionGeneration: 4,
            projectionRunID: runID,
            projectionGeneration: projectionGeneration,
            events: events,
            cursor: ConversationEventCursor(
                projectionRunID: runID,
                projectionGeneration: projectionGeneration,
                afterSequence: events.last?.sequence ?? 0
            ),
            oldestObservedSequence: oldestObservedSequence ?? events.first?.sequence,
            latestSequence: events.last?.sequence ?? 0,
            firstAvailableSequence: firstAvailableSequence,
            historyTruncated: false,
            isLoadingOlder: isLoadingOlder,
            phase: phase,
            sendReconciliation: SendReconciliation()
        )
    }

    private func event(_ sequence: UInt64, id: String? = nil) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: id ?? "event-\(sequence)",
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
}

private actor LoadOlderRecorder {
    private var value = 0

    func record() { value += 1 }
    func count() -> Int { value }
}
