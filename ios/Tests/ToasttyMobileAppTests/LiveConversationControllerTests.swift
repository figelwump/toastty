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

    func testEnqueuedSendLatchesReservationUntilFreshCoordinatorAuthority() async {
        let recorder = SendActionRecorder(outcomes: [
            .enqueued(clientRequestID: "request-1"),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { text, stamp in
                await recorder.send(text: text, stamp: stamp)
            }
        )
        let authority = enabledComposerAuthority()
        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: authority
        ))

        let outcome = await subject.send("enqueue me")
        XCTAssertEqual(outcome, .enqueued(clientRequestID: "request-1"))
        XCTAssertEqual(subject.lastSendGateFailure, .sendAlreadyReserved)
        let composer = ToasttyComposerPresentation.make(
            agentDisplayName: "Codex",
            authority: subject.presentedComposerAuthority
        )
        XCTAssertEqual(composer.gate, .disabled(.prompt(.sending)))
        XCTAssertFalse(composer.gate.allowsInput)
        XCTAssertFalse(composer.canSubmit(draft: "another message"))

        subject.consumeSendReconciliation(.init(records: [
            sendRecord("request-1", .pending(.accepted)),
        ]))
        XCTAssertEqual(subject.lastSendGateFailure, .sendAlreadyReserved)
        XCTAssertEqual(subject.transcriptPresentation.sendItems.map(\.id), ["request-1"])
        XCTAssertEqual(
            subject.transcriptPresentation.sendItems.first?.content,
            .optimistic(response: .accepted)
        )

        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: authority
        ))
        XCTAssertEqual(subject.lastSendGateFailure, .sendAlreadyReserved)

        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: enabledComposerAuthority(streamSnapshotOrdinal: 4)
        ))
        XCTAssertNil(subject.lastSendGateFailure)
        XCTAssertNil(subject.presentedComposerAuthority.gateFailure)
        XCTAssertEqual(subject.transcriptPresentation.sendItems.map(\.id), ["request-1"])
        let calls = await recorder.calls()
        XCTAssertEqual(calls.map(\.text), ["enqueue me"])
        XCTAssertEqual(calls.map(\.stamp), [authority.stamp!])
    }

    func testMissingStampDoesNotInvokeSendAndPublishesDomainGateFailure() async {
        let recorder = SendActionRecorder(outcomes: [])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { text, stamp in
                await recorder.send(text: text, stamp: stamp)
            }
        )
        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: ConversationComposerAuthority(
                gateFailure: .deviceSendScopeDenied
            )
        ))

        let outcome = await subject.send("draft remains outside the controller")

        XCTAssertEqual(outcome, .notEnqueued(.deviceSendScopeDenied))
        XCTAssertEqual(subject.lastSendGateFailure, .deviceSendScopeDenied)
        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testNewerRuntimeStateClearsLocalFailureWhenAuthorityIsUnchanged() async {
        let recorder = SendActionRecorder(outcomes: [
            .notEnqueued(.staleComposerAuthority),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { text, stamp in
                await recorder.send(text: text, stamp: stamp)
            }
        )
        let authority = enabledComposerAuthority()
        let initialState = state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: authority
        )
        subject.consume(initialState)
        _ = await subject.send("stale send")
        XCTAssertEqual(subject.lastSendGateFailure, .staleComposerAuthority)

        subject.consume(initialState)
        XCTAssertEqual(
            subject.lastSendGateFailure,
            .staleComposerAuthority,
            "An identical replay is not evidence that the local failure is stale"
        )

        subject.consume(state(
            runID: runID(1),
            events: [event(1), event(2)],
            phase: .live,
            composerAuthority: authority
        ))

        XCTAssertNil(subject.lastSendGateFailure)
        XCTAssertNil(subject.presentedComposerAuthority.gateFailure)
    }

    func testFailureReturningAfterNewerRuntimeStateDoesNotRelatchStaleFeedback() async {
        let sendAction = SuspendedSendAction()
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { text, stamp in
                await sendAction.send(text: text, stamp: stamp)
            }
        )
        let authority = enabledComposerAuthority()
        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: authority
        ))

        let sendTask = Task { await subject.send("stale send") }
        await sendAction.waitUntilStarted()
        subject.consume(state(
            runID: runID(1),
            events: [event(1), event(2)],
            phase: .live,
            composerAuthority: authority
        ))
        await sendAction.finish(.notEnqueued(.staleComposerAuthority))

        let outcome = await sendTask.value
        XCTAssertEqual(outcome, .notEnqueued(.staleComposerAuthority))
        XCTAssertNil(subject.lastSendGateFailure)
    }

    func testEditingClearsOnlyTransientLocalSendFeedback() async {
        let recorder = SendActionRecorder(outcomes: [
            .notEnqueued(.cancelled),
            .notEnqueued(.tooManyUnresolvedSends),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { text, stamp in
                await recorder.send(text: text, stamp: stamp)
            }
        )
        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: enabledComposerAuthority()
        ))

        _ = await subject.send("cancel")
        subject.draftDidChange()
        XCTAssertNil(subject.lastSendGateFailure)

        _ = await subject.send("capacity")
        subject.draftDidChange()
        XCTAssertEqual(subject.lastSendGateFailure, .tooManyUnresolvedSends)
    }

    func testReconciliationProjectionCoversPendingDuplicateConfirmationAndReceipts() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live
        ))

        subject.consumeSendReconciliation(.init(records: [
            sendRecord("pending", .pending(.awaitingResponse)),
            sendRecord("duplicate", .pending(.duplicate)),
            sendRecord("confirmed", .confirmed(sequence: 2)),
            sendRecord("rejected", .rejected(reason: .epochMismatch)),
            sendRecord("uncertain", .uncertain),
            sendRecord("operation-failed", .operationFailed),
            sendRecord("unconfirmed", .deliveryUnconfirmed),
        ]))

        XCTAssertEqual(
            subject.transcriptPresentation.sendItems.map(\.id),
            ["pending", "duplicate", "rejected", "uncertain", "operation-failed", "unconfirmed"]
        )
        XCTAssertEqual(
            subject.transcriptPresentation.sendItems.map(\.content),
            [
                .optimistic(response: .awaitingResponse),
                .optimistic(response: .duplicate),
                .receipt(.init(kind: .rejected(.epochMismatch))),
                .receipt(.init(kind: .uncertain)),
                .receipt(.init(kind: .operationFailed)),
                .receipt(.init(kind: .deliveryUnconfirmed)),
            ]
        )
    }

    func testReconciliationChangeClearsCapacityGateFeedback() async {
        let recorder = SendActionRecorder(outcomes: [
            .notEnqueued(.tooManyUnresolvedSends),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { text, stamp in
                await recorder.send(text: text, stamp: stamp)
            }
        )
        subject.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live,
            composerAuthority: enabledComposerAuthority()
        ))

        _ = await subject.send("capacity")
        XCTAssertEqual(subject.lastSendGateFailure, .tooManyUnresolvedSends)
        subject.consumeSendReconciliation(.init(records: [
            sendRecord("finished", .confirmed(sequence: 2)),
        ]))

        XCTAssertNil(subject.lastSendGateFailure)
        XCTAssertNil(subject.presentedComposerAuthority.gateFailure)
    }

    func testDismissReceiptDelegatesOnlyTheSelectedRequestID() async {
        let recorder = ReceiptDismissRecorder()
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            dismissSendReceipt: { await recorder.dismiss($0) }
        )

        await subject.dismissSendReceipt("receipt-2")

        let dismissed = await recorder.requestIDs()
        XCTAssertEqual(dismissed, ["receipt-2"])
    }

    func testStopCancelsRuntimeAndReconciliationObservers() async {
        let runtime = CancellableLiveConversationRuntime(
            initialState: state(runID: runID(1), events: [event(1)], phase: .live)
        )
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: runtime
        )

        await subject.start()
        await runtime.waitUntilBothStreamsObserved()
        subject.stop()
        await runtime.waitUntilBothStreamsTerminated()

        let terminations = await runtime.terminationCount()
        XCTAssertEqual(terminations, 2)
    }

    func testVisibleReadAcknowledgementAcceptsEmptyAndRearmsForPresentationChange() async {
        let recorder = ReadAcknowledgementRecorder(results: [
            .success(RemoteConversationReadAcknowledgementResponse(result: .acknowledged)),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            acknowledgeRead: { try await recorder.acknowledge($0) }
        )

        subject.acknowledgeVisibleTranscript(presentationStatus: .working)
        subject.consume(state(runID: runID(1), events: [], phase: .live))
        subject.acknowledgeVisibleTranscript(presentationStatus: .working)
        await recorder.waitForRequestCount(1)
        subject.acknowledgeVisibleTranscript(presentationStatus: .working)
        try? await ContinuousClock().sleep(for: .milliseconds(20))
        var requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.observedThroughSequence), [0])

        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        await recorder.waitForRequestCount(2)

        subject.consume(state(runID: runID(1), events: [event(1)], phase: .live))
        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        await recorder.waitForRequestCount(3)
        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        try? await ContinuousClock().sleep(for: .milliseconds(20))

        requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.observedThroughSequence), [0, 0, 1])
        XCTAssertEqual(requests[2].projectionGeneration, 7)
    }

    func testReadAcknowledgementRetriesTransientFailureButNotPermanentFailure() async {
        let recorder = ReadAcknowledgementRecorder(results: [
            .failure(GatewayFailure.network(reason: .offline)),
            .success(RemoteConversationReadAcknowledgementResponse(result: .alreadyRead)),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            acknowledgeRead: { try await recorder.acknowledge($0) }
        )
        subject.consume(state(runID: runID(1), events: [event(1)], phase: .live))

        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        await recorder.waitForRequestCount(2)
        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        try? await ContinuousClock().sleep(for: .milliseconds(20))

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testNewerVisibleBoundaryCancelsOlderAcknowledgement() async {
        let recorder = SupersedingReadAcknowledgementRecorder()
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            acknowledgeRead: { try await recorder.acknowledge($0) }
        )
        subject.consume(state(runID: runID(1), events: [event(1)], phase: .live))
        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        await recorder.waitForRequestCount(1)

        subject.consume(state(
            runID: runID(1),
            events: [event(1), event(2)],
            phase: .live
        ))
        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        await recorder.waitForRequestCount(2)
        await recorder.finish(sequence: 1)
        await recorder.finish(sequence: 2)
        try? await ContinuousClock().sleep(for: .milliseconds(20))

        subject.acknowledgeVisibleTranscript(presentationStatus: .ready)
        try? await ContinuousClock().sleep(for: .milliseconds(20))
        let requests = await recorder.requests()
        XCTAssertEqual(requests.map(\.observedThroughSequence), [1, 2])
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
        phase: ConversationRuntimePhase = .catchingUp,
        composerAuthority: ConversationComposerAuthority = ConversationComposerAuthority()
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
            composerAuthority: composerAuthority,
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

    private func enabledComposerAuthority(
        streamSnapshotOrdinal: UInt64 = 3
    ) -> ConversationComposerAuthority {
        let epoch = RemoteInputEpoch(
            bindingID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            counter: 9
        )
        return ConversationComposerAuthority(
            stamp: ConversationComposerStamp(
                connectionGeneration: 4,
                streamSnapshotOrdinal: streamSnapshotOrdinal,
                projectionRunID: runID(1),
                projectionGeneration: 7,
                latestSequence: 1,
                inputEpoch: epoch
            ),
            inputAvailability: .openPrompt(epoch: epoch)
        )
    }

    private func sendRecord(
        _ requestID: String,
        _ deliveryState: SendDeliveryState
    ) -> SendReconciliationRecord {
        SendReconciliationRecord(
            clientRequestID: requestID,
            text: "text for \(requestID)",
            projectionRunID: runID(1),
            deliveryState: deliveryState
        )
    }
}

private actor LoadOlderRecorder {
    private var value = 0

    func record() { value += 1 }
    func count() -> Int { value }
}

private actor SendActionRecorder {
    struct Call: Equatable {
        var text: String
        var stamp: ConversationComposerStamp
    }

    private var outcomes: [ConversationSendOutcome]
    private var recordedCalls: [Call] = []

    init(outcomes: [ConversationSendOutcome]) {
        self.outcomes = outcomes
    }

    func send(
        text: String,
        stamp: ConversationComposerStamp
    ) -> ConversationSendOutcome {
        recordedCalls.append(Call(text: text, stamp: stamp))
        return outcomes.isEmpty ? .notEnqueued(.conversationNotOpen) : outcomes.removeFirst()
    }

    func calls() -> [Call] { recordedCalls }
}

private actor SuspendedSendAction {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var outcomeContinuation: CheckedContinuation<ConversationSendOutcome, Never>?

    func send(
        text: String,
        stamp: ConversationComposerStamp
    ) async -> ConversationSendOutcome {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { outcomeContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard didStart == false else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(_ outcome: ConversationSendOutcome) {
        outcomeContinuation?.resume(returning: outcome)
        outcomeContinuation = nil
    }
}

private actor ReceiptDismissRecorder {
    private var values: [String] = []

    func dismiss(_ requestID: String) { values.append(requestID) }
    func requestIDs() -> [String] { values }
}

private actor ReadAcknowledgementRecorder {
    private var results: [Result<RemoteConversationReadAcknowledgementResponse, GatewayFailure>]
    private var values: [RemoteConversationReadAcknowledgementRequest] = []

    init(results: [Result<RemoteConversationReadAcknowledgementResponse, GatewayFailure>]) {
        self.results = results
    }

    func acknowledge(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) throws -> RemoteConversationReadAcknowledgementResponse? {
        values.append(request)
        let result = results.isEmpty
            ? .success(RemoteConversationReadAcknowledgementResponse(result: .alreadyRead))
            : results.removeFirst()
        return try result.get()
    }

    func requests() -> [RemoteConversationReadAcknowledgementRequest] { values }

    func waitForRequestCount(_ count: Int) async {
        while values.count < count {
            await Task.yield()
        }
    }
}

private actor SupersedingReadAcknowledgementRecorder {
    private var values: [RemoteConversationReadAcknowledgementRequest] = []
    private var continuations: [UInt64: CheckedContinuation<RemoteConversationReadAcknowledgementResponse?, Error>] = [:]

    func acknowledge(
        _ request: RemoteConversationReadAcknowledgementRequest
    ) async throws -> RemoteConversationReadAcknowledgementResponse? {
        values.append(request)
        return try await withCheckedThrowingContinuation {
            continuations[request.observedThroughSequence] = $0
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while values.count < count {
            await Task.yield()
        }
    }

    func finish(sequence: UInt64) {
        continuations.removeValue(forKey: sequence)?.resume(
            returning: RemoteConversationReadAcknowledgementResponse(result: .acknowledged)
        )
    }

    func requests() -> [RemoteConversationReadAcknowledgementRequest] { values }
}

private actor CancellableLiveConversationRuntime: LiveConversationRuntime {
    private let initialState: ConversationRuntime.State
    private var streamStarts = 0
    private var streamTerminations = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    init(initialState: ConversationRuntime.State) {
        self.initialState = initialState
    }

    func currentState() -> ConversationRuntime.State { initialState }

    func states() -> AsyncStream<ConversationRuntime.State> {
        makeStream()
    }

    func sendReconciliationStates() -> AsyncStream<SendReconciliationState> {
        let stream = AsyncStream<SendReconciliationState> { continuation in
            Task { await self.recordStart() }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.recordTermination() }
            }
        }
        return stream
    }

    private func makeStream() -> AsyncStream<ConversationRuntime.State> {
        AsyncStream { continuation in
            Task { await self.recordStart() }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.recordTermination() }
            }
        }
    }

    private func recordStart() {
        streamStarts += 1
        if streamStarts == 2 {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func recordTermination() {
        streamTerminations += 1
        if streamTerminations == 2 {
            let waiters = terminationWaiters
            terminationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilBothStreamsObserved() async {
        guard streamStarts < 2 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilBothStreamsTerminated() async {
        guard streamTerminations < 2 else { return }
        await withCheckedContinuation { terminationWaiters.append($0) }
    }

    func terminationCount() -> Int { streamTerminations }
}
