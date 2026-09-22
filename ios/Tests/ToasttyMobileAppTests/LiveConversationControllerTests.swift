import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class LiveConversationControllerTests: XCTestCase {
    func testAttachmentSendRequiresCapabilityAndPassesExactBytesWithComposerStamp() async throws {
        let attachment = RemoteMessageAttachment(filename: "notes.txt", data: Data("inspect me".utf8))
        let authority = enabledComposerAuthority()
        let expectedStamp = try XCTUnwrap(authority.stamp)
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            sendAttachments: { text, attachments, stamp in
                XCTAssertEqual(text, "")
                XCTAssertEqual(attachments, [attachment])
                XCTAssertEqual(stamp, expectedStamp)
                return .enqueued(clientRequestID: "attachment-request")
            }
        )
        subject.consume(state(runID: runID(1), events: [event(1)], phase: .live,
                              composerAuthority: authority))
        let unsupported = await subject.send("", attachments: [attachment])
        XCTAssertEqual(unsupported, .notEnqueued(.attachmentsUnsupported))
        subject.consumeConnectionState(.init(phase: .live, capabilities: [.messageAttachments]))
        let outcome = await subject.send("", attachments: [attachment])
        XCTAssertEqual(outcome, .enqueued(clientRequestID: "attachment-request"))
    }

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

    func testMetadataUpdatesReusePreparedTranscriptAndContentAppendRebuildsIt() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        let events = (1...5000).map { event(UInt64($0)) }
        subject.consume(state(runID: runID(1), events: events, phase: .live))
        let prepared = subject.transcriptPresentation.preparedTranscript
        var diagnosticEvents: [ToasttyConnectionDiagnosticEvent] = []
        subject.onDiagnosticEvent = { diagnosticEvents.append($0) }
        subject.consumeConnectionPhase(.reconnecting(failureCount: 1, showsBanner: false))
        XCTAssertTrue(subject.transcriptPresentation.preparedTranscript === prepared)
        subject.consumeSendReconciliation(.init(records: [.init(
            clientRequestID: "test", text: "draft", projectionRunID: runID(1),
            deliveryState: .pending(.accepted)
        )]))
        XCTAssertTrue(subject.transcriptPresentation.preparedTranscript === prepared)
        XCTAssertEqual(subject.transcriptPresentation.sendItems.count, 1)
        XCTAssertEqual(diagnosticEvents, [.sendAccepted])
        subject.consume(state(runID: runID(1), events: events, phase: .live))
        XCTAssertTrue(subject.transcriptPresentation.preparedTranscript === prepared)
        subject.consume(state(runID: runID(1), events: events + [event(5001)], phase: .live))
        XCTAssertFalse(subject.transcriptPresentation.preparedTranscript === prepared)
        XCTAssertEqual(subject.transcriptPresentation.rows.count, 5001)
    }

    func testSustainedSmallAppendsPreserveAllRowsAndReportPreparationTime() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        var events = (1...5000).map { event(UInt64($0)) }
        subject.consume(state(runID: runID(1), events: events, phase: .live))
        let clock = ContinuousClock()
        let startedAt = clock.now
        for batch in 0..<200 {
            let firstSequence = UInt64(5001 + batch * 5)
            events.append(contentsOf: (firstSequence..<(firstSequence + 5)).map { event($0) })
            subject.consume(state(runID: runID(1), events: events, phase: .live))
        }
        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertEqual(subject.transcriptPresentation.rows.count, 6000)
        XCTAssertEqual(subject.transcriptPresentation.rows.last?.id.sequence, 6000)
        XCTAssertEqual(subject.change, .append)
        let evidence = "Initial rows: 5000; updates: 200; rows per update: 5; elapsed: \(elapsed). "
            + "Includes fixture state construction and main-actor presentation preparation; excludes SwiftUI rendering and network transport."
        print("TOASTTY_TRANSCRIPT_APPEND_PREPARATION \(evidence)")
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "sustained-transcript-preparation"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testPrependingHistoryAnchorsToMessageAfterHiddenStatus() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        let status = CompatibleConversationEvent.statusChanged(CompatibleStatusChangedEvent(
            conversationID: conversationID,
            sequence: 7,
            eventID: "status-7",
            schemaVersion: 1,
            timestamp: Date(timeIntervalSince1970: 7),
            provider: .codex,
            providerIdentity: nil,
            turnID: nil,
            state: .known(.working),
            inputAvailability: .unavailable(reason: .known(.working))
        ))
        subject.consume(state(runID: runID(1), events: [status, event(8)]))
        let visibleID = subject.transcriptPresentation.rows.first?.id
        XCTAssertEqual(visibleID?.sequence, 8)

        subject.consume(state(runID: runID(1), events: [event(6), status, event(8)]))

        XCTAssertEqual(subject.change, .prepend)
        XCTAssertEqual(subject.prependAnchorID, visibleID)
        XCTAssertEqual(subject.transcriptPresentation.prependAnchorID, visibleID)
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
            [
                "pending", "duplicate", "confirmed", "rejected", "uncertain",
                "operation-failed", "unconfirmed",
            ]
        )
        XCTAssertEqual(
            subject.transcriptPresentation.sendItems.map(\.content),
            [
                .optimistic(response: .awaitingResponse),
                .optimistic(response: .duplicate),
                .optimistic(response: .accepted),
                .receipt(.init(kind: .rejected(.epochMismatch))),
                .receipt(.init(kind: .uncertain)),
                .receipt(.init(kind: .operationFailed)),
                .receipt(.init(kind: .deliveryUnconfirmed)),
            ]
        )
    }

    func testOptimisticSendHandsOffToCanonicalUserRowWithoutMissingOrDuplicateFrame() {
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
            sendRecord("request-1", .pending(.accepted)),
        ]))
        XCTAssertEqual(subject.transcriptPresentation.sendItems.map(\.id), ["request-1"])

        subject.consumeSendReconciliation(.init(records: [
            sendRecord("request-1", .confirmed(sequence: 2)),
        ]))
        XCTAssertEqual(
            subject.transcriptPresentation.sendItems.map(\.id),
            ["request-1"],
            "Confirmation must retain the optimistic row until the canonical row is present"
        )

        subject.consume(state(
            runID: runID(1),
            events: [event(1), userEvent(2, clientRequestID: "request-1")],
            phase: .live
        ))
        XCTAssertTrue(subject.transcriptPresentation.sendItems.isEmpty)
        XCTAssertEqual(subject.transcriptPresentation.rows.map(\.id.sequence), [1, 2])

        let canonicalFirst = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        canonicalFirst.consume(state(
            runID: runID(1),
            events: [event(1)],
            phase: .live
        ))
        canonicalFirst.consumeSendReconciliation(.init(records: [
            sendRecord("request-2", .pending(.accepted)),
        ]))
        canonicalFirst.consume(state(
            runID: runID(1),
            events: [event(1), userEvent(2, clientRequestID: "request-2")],
            phase: .live
        ))
        XCTAssertTrue(
            canonicalFirst.transcriptPresentation.sendItems.isEmpty,
            "An exact canonical echo must suppress a stale optimistic row"
        )
        XCTAssertEqual(canonicalFirst.transcriptPresentation.rows.map(\.id.sequence), [1, 2])
    }

    func testConfirmedSendFromAnotherOrUnknownProjectionDoesNotBecomeGhostBubble() {
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
            SendReconciliationRecord(
                clientRequestID: "unknown-run",
                text: "unknown run",
                projectionRunID: nil,
                deliveryState: .confirmed(sequence: 2)
            ),
            SendReconciliationRecord(
                clientRequestID: "old-run",
                text: "old run",
                projectionRunID: runID(2),
                deliveryState: .confirmed(sequence: 2)
            ),
        ]))

        XCTAssertTrue(subject.transcriptPresentation.sendItems.isEmpty)
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

    func testQuestionDraftSurvivesReconnectAndRetryReusesRequestIdentity() async throws {
        let recorder = QuestionAnswerRecorder(results: [
            .failure(GatewayFailure.network(reason: .connectionLost)),
            .success(.submitted),
        ])
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            answerQuestion: { request in try await recorder.answer(request) }
        )
        subject.consumeConnectionState(ConnectionCoordinator.State(
            connectionGeneration: 4,
            phase: .live,
            capabilities: [.questionAnswers]
        ))
        subject.consume(state(
            runID: runID(1),
            events: [questionPresentedEvent(1)],
            phase: .live
        ))
        subject.editInteractionAnswer(
            interactionID: questionInteraction.id,
            edit: .toggleOption(questionID: "0", optionID: "1")
        )

        subject.consumeConnectionState(ConnectionCoordinator.State(
            connectionGeneration: 5,
            phase: .reconnecting(failureCount: 1, showsBanner: false),
            capabilities: []
        ))
        let reconnecting = try XCTUnwrap(subject.interactionAnswerStates[questionInteraction.id])
        XCTAssertEqual(reconnecting.drafts["0"]?.selectedOptionIDs, ["1"])
        XCTAssertFalse(reconnecting.canSubmit)

        subject.consume(state(
            runID: runID(1),
            events: [],
            phase: .catchingUp
        ))
        XCTAssertEqual(
            subject.interactionAnswerStates[questionInteraction.id]?.drafts["0"]?.selectedOptionIDs,
            ["1"],
            "A transient empty resnapshot must not discard the current response draft"
        )
        subject.consume(state(
            runID: runID(1),
            events: [questionPresentedEvent(1)],
            phase: .live
        ))

        subject.consumeConnectionState(ConnectionCoordinator.State(
            connectionGeneration: 5,
            phase: .live,
            capabilities: [.questionAnswers]
        ))
        await subject.submitInteractionAnswer(interactionID: questionInteraction.id)
        guard case .failed = subject.interactionAnswerStates[questionInteraction.id]?.status else {
            return XCTFail("Expected retryable failure")
        }
        await subject.submitInteractionAnswer(interactionID: questionInteraction.id)
        XCTAssertEqual(subject.interactionAnswerStates[questionInteraction.id]?.status, .awaitingClaude)
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
    }

    func testQuestionClosureRevokesFormAndCanonicalResolutionWins() async throws {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consumeConnectionState(ConnectionCoordinator.State(
            phase: .live,
            capabilities: [.questionAnswers]
        ))
        subject.consume(state(
            runID: runID(1),
            events: [questionPresentedEvent(1)],
            phase: .live
        ))
        XCTAssertNotNil(subject.interactionAnswerStates[questionInteraction.id])

        subject.consume(state(
            runID: runID(1),
            events: [questionPresentedEvent(1), questionClosedEvent(2)],
            phase: .live
        ))
        guard case .unavailable = subject.interactionAnswerStates[questionInteraction.id]?.status else {
            return XCTFail("Expected closed response channel")
        }
        guard case .interaction(let closedCard) = subject.transcriptPresentation.rows[0].content else {
            return XCTFail("Expected interaction card")
        }
        XCTAssertNil(closedCard.interaction.responseID)
        XCTAssertEqual(closedCard.interaction.state, .pending)

        let accepted = [RemoteInteractionAnswer(questionID: "0", selectedOptionIDs: ["0"])]
        subject.consume(state(
            runID: runID(1),
            events: [
                questionPresentedEvent(1),
                questionClosedEvent(2),
                questionResolvedEvent(3, resolution: .resolved, answers: nil),
                questionResolvedEvent(4, resolution: .superseded, answers: nil),
                questionResolvedEvent(5, resolution: .resolved, answers: accepted),
            ],
            phase: .live
        ))
        guard case .interaction(let resolvedCard) = subject.transcriptPresentation.rows[0].content else {
            return XCTFail("Expected resolved card")
        }
        XCTAssertEqual(resolvedCard.interaction.state, .resolved)
        XCTAssertEqual(resolvedCard.interaction.answers, accepted)
        XCTAssertEqual(subject.interactionAnswerStates[questionInteraction.id]?.status, .resolved(accepted))
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

    private func userEvent(
        _ sequence: UInt64,
        clientRequestID: String
    ) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .codex,
            payload: .userMessage(ConversationUserMessagePayload(
                text: "sent message",
                origin: .remote,
                clientRequestID: clientRequestID
            ))
        ))
    }

    private func questionPresentedEvent(_ sequence: UInt64) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "question-presented-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .claude,
            payload: .interactionPresented(questionInteraction)
        ))
    }

    private func questionClosedEvent(_ sequence: UInt64) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "question-closed-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .claude,
            payload: .interactionResponseClosed(.init(
                interactionID: questionInteraction.id,
                reason: .expired
            ))
        ))
    }

    private func questionResolvedEvent(
        _ sequence: UInt64,
        resolution: RemotePendingInteraction.State,
        answers: [RemoteInteractionAnswer]?
    ) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "question-resolved-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .claude,
            payload: .interactionResolved(.init(
                interactionID: questionInteraction.id,
                resolution: resolution,
                answers: answers
            ))
        ))
    }

    private var questionInteraction: RemotePendingInteraction {
        RemotePendingInteraction(
            id: RemotePendingInteraction.ID(rawValue: "question-1"),
            kind: .question,
            prompt: "Choose one",
            inputEpoch: RemoteInputEpoch(
                bindingID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                counter: 2
            ),
            presentedAt: Date(timeIntervalSince1970: 1),
            questions: [RemoteInteractionQuestion(
                id: "0",
                header: "Choice",
                question: "Which one?",
                options: [
                    .init(id: "0", label: "First"),
                    .init(id: "1", label: "Second"),
                ]
            )],
            responseID: "response-1"
        )
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

private actor QuestionAnswerRecorder {
    private var results: [Result<RemoteQuestionAnswerResult, GatewayFailure>]
    private var recordedRequests: [RemoteQuestionAnswerRequest] = []

    init(results: [Result<RemoteQuestionAnswerResult, GatewayFailure>]) {
        self.results = results
    }

    func answer(_ request: RemoteQuestionAnswerRequest) async throws -> RemoteQuestionAnswerResult {
        recordedRequests.append(request)
        return try results.removeFirst().get()
    }

    func requests() -> [RemoteQuestionAnswerRequest] { recordedRequests }
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
