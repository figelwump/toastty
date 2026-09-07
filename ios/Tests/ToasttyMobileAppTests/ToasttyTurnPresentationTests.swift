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

    func testTurnsWithoutWorkOrWithoutUserAnchorAreNotFoldable() {
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
        XCTAssertTrue(state.turns.isEmpty)
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
