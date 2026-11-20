@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyTurnPresentationTests: XCTestCase {
    func testTurnCollectsWorkBetweenUserMessageAndFirstFinalResponse() throws {
        let rows: [ToasttyTranscriptRow] = [
            row(1, .sessionBindingChanged(reason: .runtimeBound)),
            row(2, .userMessage(text: "question", origin: .local)),
            row(3, .assistantMessage(text: "checking", phase: .commentary)),
            row(4, .toolStarted(callID: "call-1", name: "Read", detail: nil)),
            row(5, .toolFinished(callID: "call-1", name: "Read", outcome: .succeeded, detail: nil)),
            row(6, .interaction(ToasttyInteractionPresentation(interaction: pendingInteraction))),
            row(7, .toolStarted(callID: "call-2", name: "Bash", detail: nil)),
            row(8, .assistantMessage(text: "the answer", phase: .final)),
            row(9, .toolStarted(callID: "call-3", name: "Read", detail: nil)),
        ]
        let state = ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )

        let turn = try XCTUnwrap(state.turns.first)
        XCTAssertEqual(state.turns.count, 1)
        XCTAssertEqual(turn.id.sequence, 2)
        XCTAssertTrue(turn.hasResponse)
        XCTAssertEqual(turn.toolCallCount, 2, "Unique call IDs before the response")
        XCTAssertEqual(turn.noteCount, 1)
        XCTAssertEqual(
            turn.workBlockIDs.map(\.rowID.sequence),
            [3, 4, 7],
            "Commentary and tool batches fold; the interaction card and post-response work stay out"
        )
    }

    func testChunkedCommentaryFoldsAsOneNoteAcrossItsChunkBlocks() throws {
        let giant = (1 ... 14).map { index in
            "Paragraph \(index): " + Array(repeating: "chunked transcript body", count: 20)
                .joined(separator: " ")
        }.joined(separator: "\n\n")
        let rows: [ToasttyTranscriptRow] = [
            row(1, .userMessage(text: "question", origin: .local)),
            row(2, .assistantMessage(text: giant, phase: .commentary)),
            row(3, .assistantMessage(text: "answer", phase: .final)),
        ]
        let state = ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )

        let turn = try XCTUnwrap(state.turns.first)
        XCTAssertGreaterThan(turn.workBlockIDs.count, 1)
        XCTAssertTrue(turn.workBlockIDs.allSatisfy { $0.rowID.sequence == 2 })
        XCTAssertEqual(turn.noteCount, 1)
    }

    func testUnknownPhaseAssistantMessageCountsAsResponseNotWork() throws {
        // Codex transcripts deliver assistant messages without a phase field;
        // they must settle the turn like a final message or the work strip
        // spins forever and the answer renders demoted.
        let rows: [ToasttyTranscriptRow] = [
            row(1, .userMessage(text: "question", origin: .local)),
            row(2, .toolStarted(callID: "call-1", name: "Bash", detail: nil)),
            row(3, .assistantMessage(text: "the codex answer", phase: .unknown)),
        ]
        let state = ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )

        let turn = try XCTUnwrap(state.turns.first)
        XCTAssertTrue(turn.hasResponse)
        XCTAssertEqual(turn.workBlockIDs.map(\.rowID.sequence), [2])
        XCTAssertEqual(turn.noteCount, 0)
    }

    func testWorklessUserTurnsStayInTimelineWithoutFoldableBlocks() throws {
        let rows: [ToasttyTranscriptRow] = [
            row(1, .toolStarted(callID: "call-0", name: "Read", detail: nil)),
            row(2, .userMessage(text: "instant question", origin: .local)),
            row(3, .assistantMessage(text: "instant answer", phase: .final)),
        ]
        let state = ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
        XCTAssertEqual(state.turns.map(\.id.sequence), [2])
        XCTAssertTrue(try XCTUnwrap(state.turns.first).workBlockIDs.isEmpty)
    }

    func testNewSendKeepsCompletedWorkCollapsedInBothEventOrders() {
        let previousRows: [ToasttyTranscriptRow] = [
            row(1, .userMessage(text: "first question", origin: .local)),
            row(2, .assistantMessage(text: "previous work", phase: .commentary)),
            row(3, .assistantMessage(text: "first answer", phase: .final)),
        ]
        let pending = ToasttySendPresentationItem(
            clientRequestID: "new-send", text: "next question", content: .optimistic(response: .accepted)
        )
        let previousID = rowID(1)
        let nextID = rowID(4)

        for statusFirst in [true, false] {
            var fold = ToasttyTurnFoldState()
            func reconcile(
                _ rows: [ToasttyTranscriptRow],
                sends: [ToasttySendPresentationItem] = [],
                working: Bool,
                revision: ToasttyTranscriptRevision = .appended
            ) {
                let state = ToasttyConversationPresentationState(
                    rows: rows, sendItems: sends, phase: .live, revision: revision, historyTruncated: false
                )
                fold.reconcile(
                    turns: state.turns, settledIDs: state.settledTurnIDs(isSessionWorking: working),
                    revision: revision, previousBoundarySequence: nil
                )
                XCTAssertFalse(fold.isExpanded(previousID), "Previous completed work stays collapsed")
            }

            reconcile(previousRows, working: false, revision: .initial)
            reconcile(previousRows, sends: [pending], working: false, revision: .metadataOnly)
            if statusFirst {
                reconcile(previousRows, sends: [pending], working: true, revision: .metadataOnly)
            }
            let echoedRows = previousRows + [row(4, .userMessage(text: pending.text, origin: .remote))]
            reconcile(echoedRows, working: statusFirst)
            reconcile(echoedRows, working: true, revision: .metadataOnly)

            let workingRows = echoedRows + [row(5, .toolStarted(callID: "new-tool", name: "Read", detail: nil))]
            reconcile(workingRows, working: true)
            XCTAssertTrue(fold.isExpanded(nextID), "The new turn shows its work")

            let responseRows = workingRows + [row(6, .assistantMessage(text: "next answer", phase: .final))]
            reconcile(responseRows, working: true)
            XCTAssertTrue(fold.isExpanded(nextID), "Work stays open while its response streams")
            reconcile(responseRows, working: false, revision: .metadataOnly)
            XCTAssertFalse(fold.isExpanded(nextID), "The new turn folds when the session settles")
        }
    }

    func testSubmissionKeepsCompletedWorkCollapsedBeforeOptimisticPublication() {
        let state = ToasttyConversationPresentationState(
            rows: [
                row(1, .userMessage(text: "question", origin: .local)),
                row(2, .assistantMessage(text: "previous work", phase: .commentary)),
                row(3, .assistantMessage(text: "answer", phase: .final)),
            ],
            phase: .live, revision: .metadataOnly, historyTruncated: false
        )
        var fold = ToasttyTurnFoldState()
        fold.reconcile(
            turns: state.turns,
            settledIDs: state.settledTurnIDs(isSessionWorking: true, isSubmitting: true),
            revision: .initial, previousBoundarySequence: nil
        )
        XCTAssertFalse(fold.isExpanded(rowID(1)))
    }

    func testSendReceiptDoesNotCloseTheCurrentStreamingWork() {
        let state = ToasttyConversationPresentationState(
            rows: [
                row(1, .userMessage(text: "question", origin: .local)),
                row(2, .assistantMessage(text: "current work", phase: .commentary)),
                row(3, .assistantMessage(text: "streaming answer", phase: .final)),
            ],
            sendItems: [ToasttySendPresentationItem(
                clientRequestID: "old-rejection", text: "rejected draft",
                content: .receipt(.init(kind: .rejected(.epochMismatch)))
            )],
            phase: .live, revision: .initial, historyTruncated: false
        )
        var fold = ToasttyTurnFoldState()
        fold.reconcile(
            turns: state.turns, settledIDs: state.settledTurnIDs(isSessionWorking: true),
            revision: .initial, previousBoundarySequence: nil
        )
        XCTAssertTrue(fold.isExpanded(rowID(1)))
    }

    func testFoldStateSettledTurnsCollapseAndLiveTurnStaysOpen() {
        let settled = turnStub(id: 2, workSequences: [3, 4], hasResponse: true)
        let live = turnStub(id: 8, workSequences: [9], hasResponse: false)
        var fold = ToasttyTurnFoldState()

        fold.reconcile(
            turns: [settled, live],
            settledIDs: [settled.id],
            revision: .initial,
            previousBoundarySequence: nil
        )
        XCTAssertFalse(fold.isExpanded(settled.id))
        XCTAssertTrue(fold.isExpanded(live.id))

        let nowSettled = turnStub(id: 8, workSequences: [9], hasResponse: true)
        fold.reconcile(
            turns: [settled, nowSettled],
            settledIDs: [settled.id, nowSettled.id],
            revision: .appended,
            previousBoundarySequence: nil
        )
        XCTAssertFalse(fold.isExpanded(nowSettled.id), "A live turn auto-folds once settled")

        fold.toggle(nowSettled.id)
        XCTAssertTrue(fold.isExpanded(nowSettled.id))
        fold.reconcile(
            turns: [settled, nowSettled],
            settledIDs: [settled.id, nowSettled.id],
            revision: .appended,
            previousBoundarySequence: nil
        )
        XCTAssertTrue(
            fold.isExpanded(nowSettled.id),
            "An explicit expand survives later reconciles"
        )
    }

    func testPrependKeepsTurnsReachingTheVisibleRegionExpanded() {
        var fold = ToasttyTurnFoldState()
        fold.reconcile(
            turns: [],
            settledIDs: [],
            revision: .initial,
            previousBoundarySequence: nil
        )

        let spanningTurn = turnStub(id: 8, workSequences: [9, 10], hasResponse: true)
        let olderTurn = turnStub(id: 4, workSequences: [5, 6], hasResponse: true)
        fold.reconcile(
            turns: [olderTurn, spanningTurn],
            settledIDs: [spanningTurn.id, olderTurn.id],
            revision: .prepended,
            previousBoundarySequence: 9
        )
        XCTAssertTrue(
            fold.isExpanded(spanningTurn.id),
            "Work that was already on screen must not vanish into a fold on prepend"
        )
        XCTAssertFalse(
            fold.isExpanded(olderTurn.id),
            "Purely historical turns arrive folded"
        )
    }

    /// Where the host folds running work, as the coordinator's chats do, a
    /// running turn stays folded from its start to its end. The reader can
    /// still open it, and work that was on screen before a prepend still
    /// does not vanish.
    func testFoldStateKeepsRunningWorkFoldedWhereTheHostFoldsIt() {
        let settled = turnStub(id: 2, workSequences: [3, 4], hasResponse: true)
        let live = turnStub(id: 8, workSequences: [9], hasResponse: false)
        var fold = ToasttyTurnFoldState()

        for revision in [ToasttyTranscriptRevision.initial, .appended, .metadataOnly, .rebuilt] {
            fold.reconcile(
                turns: [settled, live], settledIDs: [settled.id], revision: revision,
                previousBoundarySequence: nil, opensRunningTurns: false
            )
            XCTAssertFalse(fold.isExpanded(live.id), "\(revision)")
            XCTAssertFalse(fold.isExpanded(settled.id), "\(revision)")
        }

        fold.toggle(live.id)
        fold.reconcile(
            turns: [settled, live], settledIDs: [settled.id], revision: .appended,
            previousBoundarySequence: nil, opensRunningTurns: false
        )
        XCTAssertTrue(fold.isExpanded(live.id), "The reader's open survives later work")

        var history = ToasttyTurnFoldState()
        history.reconcile(turns: [], settledIDs: [], revision: .initial, previousBoundarySequence: nil,
                          opensRunningTurns: false)
        let spanning = turnStub(id: 8, workSequences: [9, 10], hasResponse: false)
        history.reconcile(
            turns: [spanning], settledIDs: [], revision: .prepended,
            previousBoundarySequence: 9, opensRunningTurns: false
        )
        XCTAssertTrue(history.isExpanded(spanning.id), "Work that was on screen must not vanish on prepend")
        history.reconcile(
            turns: [spanning], settledIDs: [], revision: .appended,
            previousBoundarySequence: nil, opensRunningTurns: false
        )
        XCTAssertTrue(history.isExpanded(spanning.id), "Work that was on screen must not vanish on the next update")
    }

    /// One place shows that the agent works: the end of the running turn.
    /// With folded work that is the turn's own line, or the line of a
    /// digest that was typed and is not in the transcript yet. Otherwise,
    /// it is the working row: while the reader has the turn open, and after
    /// the turn's answer, when the agent works on a message that the
    /// transcript does not show yet. A failed send's receipt changes
    /// nothing.
    func testTheWorkingLineSitsAtTheEndOfTheRunningTurn() {
        let live = rowID(8)
        let running = turnStub(id: 8, workSequences: [9], hasResponse: false)
        let answered = turnStub(id: 8, workSequences: [9], hasResponse: true)
        let receipt = ToasttySendPresentationItem(
            clientRequestID: "failed", text: "Merge it", content: .receipt(.init(kind: .rejected(.promptNotOpen)))
        )
        let typedDigest = ToasttySendPresentationItem(
            clientRequestID: "wake", text: "[Toastty] Wake", content: .optimistic(response: .accepted),
            hostMessage: ToasttyHostMessagePresentation(summary: "Toastty · 1 update · 2:01 PM", text: "[Toastty] Wake")
        )
        let typedSender = ToasttySendPresentationItem(
            clientRequestID: "send", text: "[Toastty] From task", content: .optimistic(response: .accepted),
            hostMessage: ToasttyHostMessagePresentation(
                summary: "From task · 2:01 PM", text: "Done", style: .sender(name: "task", timeText: "2:01 PM")
            )
        )
        let typedByUser = ToasttySendPresentationItem(
            clientRequestID: "user", text: "Also check CI", content: .optimistic(response: .accepted)
        )
        let waitingDigest = ToasttySendPresentationItem(
            clientRequestID: "later", text: "[Toastty] Wake",
            content: .queued(ToasttyQueuedSendPresentation(position: 1, attachmentCount: 0, isPaused: false, canSteer: false)),
            hostMessage: typedDigest.hostMessage
        )
        func place(
            isWorking: Bool = true, folds: Bool = true, sends: [ToasttySendPresentationItem] = [],
            liveTurn: ToasttyTranscriptTurn? = running, expanded: Bool = false
        ) -> ToasttyTranscriptWorkingLine {
            .place(isWorking: isWorking, foldsRunningWork: folds, sendItems: sends,
                   liveTurn: liveTurn, isLiveTurnExpanded: expanded)
        }

        XCTAssertEqual(place(isWorking: false), .none)
        XCTAssertEqual(place(folds: false), .row, "Open work ends with the working row")
        XCTAssertEqual(place(folds: false, sends: [typedDigest]), .row)
        XCTAssertEqual(place(), .turn(live))
        XCTAssertEqual(place(expanded: true), .row, "An open turn's end is the row under its work")
        XCTAssertEqual(place(liveTurn: nil), .row, "Before the turn's message comes")
        XCTAssertEqual(place(sends: [typedDigest]), .send("wake"))
        XCTAssertEqual(place(sends: [typedDigest, waitingDigest]), .send("wake"), "Waiting messages come after it")
        XCTAssertEqual(place(sends: [waitingDigest]), .turn(live))
        XCTAssertEqual(place(sends: [typedSender]), .row, "A card is not a line")
        XCTAssertEqual(place(sends: [typedDigest, typedByUser]), .row)
        XCTAssertEqual(place(liveTurn: answered), .row, "After its answer the turn may not be the one that runs")
        XCTAssertEqual(place(sends: [receipt]), .turn(live))
        XCTAssertEqual(place(sends: [typedDigest, receipt]), .send("wake"))
    }

    /// A digest's line is its turn's line where running work folds: no work
    /// strip, and a click opens the digest and the work. A sender's card and
    /// the user's message do not stand in for the strip. A quiet turn's
    /// line opens it in every chat.
    func testADigestsLineStandsInForTheWorkStripWhereRunningWorkFolds() {
        let rows: [ToasttyTranscriptRow] = [
            row(1, .hostMessage(.init(summary: "Toastty · 1 update · 2:01 PM", text: "[Toastty] Wake"))),
            row(2, .toolStarted(callID: "a", name: "Bash", detail: "toastty task list")),
            row(3, .assistantMessage(text: "Ready for review.", phase: .final)),
            row(4, .hostMessage(.init(summary: "From task · 2:02 PM", text: "Done",
                                      style: .sender(name: "task", timeText: "2:02 PM")))),
            row(5, .toolStarted(callID: "b", name: "Bash", detail: "gh pr view")),
            row(6, .assistantMessage(text: "Noted.", phase: .final)),
            row(7, .hostMessage(.init(summary: "Toastty · 1 update · 2:05 PM", text: "[Toastty] Wake", foldsTurn: true))),
            row(8, .toolStarted(callID: "c", name: "Bash", detail: "toastty task list")),
            row(9, .userMessage(text: "Status?", origin: .local)),
            row(10, .toolStarted(callID: "d", name: "Bash", detail: "toastty task list")),
        ]
        let turns = ToasttyConversationPresentationState(
            rows: rows, phase: .live, revision: .initial, historyTruncated: false
        ).turns

        XCTAssertEqual(turns.map(\.anchorIsLine), [true, false, true, false])
        XCTAssertEqual(turns.map { $0.opensFromAnchorLine(foldsRunningWork: true) }, [true, false, true, false])
        XCTAssertEqual(turns.map { $0.opensFromAnchorLine(foldsRunningWork: false) }, [false, false, true, false])
        XCTAssertFalse(turns[0].workBlockIDs.contains { $0.rowID.sequence == 3 }, "A digest turn's answer stays out")
    }

    /// The coordinator's chat shows each tool call as one line: a call's end
    /// updates the line its start made, and the calls keep their order.
    func testToolCallsMergeTheirStartAndEnd() {
        let calls = ToasttyToolCall.calls(in: [
            row(1, .toolStarted(callID: "a", name: "Bash", detail: "toastty task list")),
            row(2, .toolStarted(callID: "b", name: "Read", detail: "policy.md")),
            row(3, .toolFinished(callID: "a", name: "Bash", outcome: .failed, detail: "exit 1")),
            row(4, .toolFinished(callID: "c", name: "Tool", outcome: .succeeded, detail: nil)),
            row(5, .toolFinished(callID: "b", name: "Read", outcome: .succeeded, detail: "policy.md")),
        ])
        XCTAssertEqual(calls.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(calls.map(\.name), ["Bash", "Read", "Tool"])
        XCTAssertEqual(calls.map(\.outcome), [.failed, .succeeded, .succeeded])
        XCTAssertEqual(calls.map(\.details), [["toastty task list", "exit 1"], ["policy.md"], []])

        let running = ToasttyToolCall.calls(in: [row(1, .toolStarted(callID: "a", name: "Bash", detail: nil))])
        XCTAssertEqual(running.map(\.outcome), [nil])

        // An approval between a call's start and its end splits them into
        // two batches: the call shows once, where it starts, with its end.
        let state = ToasttyConversationPresentationState(rows: [
            row(1, .userMessage(text: "Merge it", origin: .local)),
            row(2, .toolStarted(callID: "merge", name: "Bash", detail: "toastty task request-merge")),
            row(3, .interaction(ToasttyInteractionPresentation(interaction: pendingInteraction))),
            row(4, .toolFinished(callID: "merge", name: "Bash", outcome: .succeeded, detail: nil)),
        ], phase: .live, revision: .initial, historyTruncated: false)
        let batches = state.blocks.compactMap { block -> ToasttyTranscriptBlockID? in
            if case .toolBatch = block.content { return block.id }
            return nil
        }
        XCTAssertEqual(batches.count, 2)
        let split = batches.map { state.preparedTranscript.toolCallsByBlock[$0] ?? [] }
        XCTAssertEqual(split[0].map(\.outcome), [.succeeded])
        XCTAssertEqual(split[0].map(\.details), [["toastty task request-merge"]])
        XCTAssertEqual(split[1], [])
    }

    private func turnStub(
        id sequence: UInt64,
        workSequences: [UInt64],
        hasResponse: Bool
    ) -> ToasttyTranscriptTurn {
        ToasttyTranscriptTurn(
            id: rowID(sequence),
            workBlockIDs: workSequences.map { ToasttyTranscriptBlockID(rowID: rowID($0)) },
            toolCallCount: workSequences.count,
            noteCount: 0,
            hasResponse: hasResponse
        )
    }

    private func row(
        _ sequence: UInt64,
        _ content: ToasttyTranscriptRow.Content
    ) -> ToasttyTranscriptRow {
        ToasttyTranscriptRow(
            id: rowID(sequence),
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .codex,
            content: content
        )
    }

    /// The transcript's working row and the session list show one turn age,
    /// so both must format it the same way.
    func testWorkingRowElapsedLabelMatchesTheSessionList() {
        let hundredYears = Int(MobileConversation.maximumDurationSeconds)
        for seconds in [0, 59, 60, 61, 3_599, 3_600, hundredYears, hundredYears + 5] {
            let age = MobileActivityAge(secondsAtReceipt: seconds, receivedAtMonotonicTime: 100)
            let indicator = ToasttyTranscriptWorkingIndicator(turnElapsed: .init(age))
            for now in [40.0, 100, 100.9, 161.5, .infinity] {
                XCTAssertEqual(
                    indicator.elapsedLabel(atMonotonicTime: now),
                    MobileConversation.durationLabel(seconds: TimeInterval(age.seconds(atMonotonicTime: now))),
                    "\(seconds) s at \(now)"
                )
            }
        }
        XCTAssertNil(ToasttyTranscriptWorkingIndicator(turnElapsed: nil).elapsedLabel(atMonotonicTime: 1))
    }

    private func rowID(_ sequence: UInt64) -> ToasttyTranscriptRowID {
        ToasttyTranscriptRowID(
            projectionRunID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            projectionGeneration: 1,
            conversationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sequence: sequence
        )
    }

    private var pendingInteraction: RemotePendingInteraction {
        RemotePendingInteraction(
            id: RemotePendingInteraction.ID(rawValue: "turn-interaction"),
            kind: .question,
            prompt: "Choose on the Mac",
            inputEpoch: RemoteInputEpoch(
                bindingID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                counter: 1
            ),
            presentedAt: Date(timeIntervalSince1970: 6),
            state: .pending
        )
    }
}
