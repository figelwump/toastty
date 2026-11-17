@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

/// The coordinator's quiet wake turns on the iPhone: when the phone reads
/// the marks that the Mac shares, and how its chat folds a quiet turn and
/// leaves it out of the New line, as the Mac's chat does.
@MainActor
final class ToasttyCoordinatorQuietDigestsTests: XCTestCase {
    // MARK: - Reading the marks

    func testTheKeysAreReadOnceForEachRevisionThatASnapshotNames() {
        var digests = ToasttyCoordinatorQuietDigests()
        // A Mac that does not share them: no read, and no marks.
        XCTAssertFalse(digests.consume(revision: nil))
        XCTAssertNil(digests.keys)

        // One read, and none more while it runs.
        XCTAssertTrue(digests.consume(revision: oneMark.revision))
        digests.willRead()
        XCTAssertFalse(digests.consume(revision: oneMark.revision))
        XCTAssertFalse(digests.didRead(oneMark))
        XCTAssertEqual(digests.keys, Set(oneMark.keys))
        XCTAssertFalse(digests.consume(revision: oneMark.revision))

        // A mark comes, then goes: each revision is read.
        XCTAssertTrue(digests.consume(revision: twoMarks.revision))
        digests.willRead()
        XCTAssertFalse(digests.didRead(twoMarks))
        XCTAssertEqual(digests.keys, Set(twoMarks.keys))
        XCTAssertTrue(digests.consume(revision: oneMark.revision))
        digests.willRead()
        XCTAssertFalse(digests.didRead(oneMark))
        XCTAssertEqual(digests.keys, Set(oneMark.keys))
    }

    func testAFailedReadKeepsTheKeysAndTheNextSnapshotTriesAgain() {
        var digests = ToasttyCoordinatorQuietDigests()
        XCTAssertTrue(digests.consume(revision: oneMark.revision))
        digests.willRead()
        XCTAssertFalse(digests.didRead(oneMark))
        XCTAssertTrue(digests.consume(revision: twoMarks.revision))
        digests.willRead()
        XCTAssertFalse(digests.didRead(nil), "A failed read does not try again at once")
        XCTAssertEqual(digests.keys, Set(oneMark.keys))
        XCTAssertTrue(digests.consume(revision: twoMarks.revision))

        // A reconnect's snapshot comes while a read hangs, and then the read
        // fails: that snapshot's read happens, also if no other comes.
        digests.willRead()
        XCTAssertFalse(digests.consume(revision: twoMarks.revision))
        XCTAssertTrue(digests.didRead(nil))
        digests.willRead()
        XCTAssertFalse(digests.didRead(twoMarks))
        XCTAssertEqual(digests.keys, Set(twoMarks.keys))
    }

    func testAReadThatRacesASnapshotEndsAtTheNewestMarks() {
        // A snapshot names a newer revision while the read runs, and the Mac
        // answered before that change: read again.
        var digests = ToasttyCoordinatorQuietDigests()
        XCTAssertTrue(digests.consume(revision: oneMark.revision))
        digests.willRead()
        XCTAssertFalse(digests.consume(revision: twoMarks.revision))
        XCTAssertTrue(digests.didRead(oneMark))
        digests.willRead()
        XCTAssertFalse(digests.didRead(twoMarks))
        XCTAssertEqual(digests.keys, Set(twoMarks.keys))

        // The Mac answered after a change that its next snapshot names:
        // the answer counts, and the snapshot that asked reads nothing more.
        var late = ToasttyCoordinatorQuietDigests()
        XCTAssertTrue(late.consume(revision: oneMark.revision))
        late.willRead()
        XCTAssertFalse(late.didRead(twoMarks))
        XCTAssertEqual(late.keys, Set(twoMarks.keys))
        XCTAssertFalse(late.consume(revision: twoMarks.revision))

        // The marks change and change back while a read runs (a mark
        // that PR #403 removes): the answer from between does not hide the
        // snapshot that names the earlier marks again.
        var back = ToasttyCoordinatorQuietDigests()
        XCTAssertTrue(back.consume(revision: oneMark.revision))
        back.willRead()
        XCTAssertFalse(back.consume(revision: twoMarks.revision))
        XCTAssertFalse(back.consume(revision: oneMark.revision))
        XCTAssertTrue(back.didRead(twoMarks), "The newest snapshot names other marks than the answer")
        back.willRead()
        XCTAssertFalse(back.didRead(oneMark))
        XCTAssertEqual(back.keys, Set(oneMark.keys))
        XCTAssertFalse(back.consume(revision: oneMark.revision))

        // The Mac stops sharing the marks while a read runs: its answer
        // folds nothing.
        var stopped = ToasttyCoordinatorQuietDigests()
        XCTAssertTrue(stopped.consume(revision: oneMark.revision))
        stopped.willRead()
        XCTAssertFalse(stopped.consume(revision: nil))
        XCTAssertFalse(stopped.didRead(oneMark))
        XCTAssertNil(stopped.keys)
    }

    // MARK: - The chat

    /// A quiet turn folds whole under its digest's line, its answer too,
    /// and the New line counts only the normal turn's answer. Without the
    /// marks, nothing folds and both answers count.
    func testAQuietTurnFoldsWholeAndTheNewLineLeavesItOut() {
        let quiet = presentation(quietDigestKeys: [CoordinatorMessageHeader.digestKey(quietDigest)])
        XCTAssertEqual(hostLines(quiet).map(\.foldsTurn), [true, false])
        XCTAssertEqual(quiet.turns.map(\.foldsWholeTurn), [true, false])
        XCTAssertEqual(quiet.turns.first?.toolCallCount, 2)
        XCTAssertTrue(quiet.turns[0].workBlockIDs.contains { $0.rowID.sequence == 6 }, "The quiet answer folds")
        XCTAssertFalse(quiet.turns[1].workBlockIDs.contains { $0.rowID.sequence == 8 }, "The normal answer shows")
        let read = RemoteCoordinatorChatReadPoint(eventID: "event-0", timestamp: time(0))
        let normalLine = quiet.rows.first { $0.id.sequence == 7 }
        XCTAssertEqual(
            CoordinatorChatReadPoint.marker(in: quiet.rows, after: read),
            normalLine.map { ToasttyNewMessagesMarker(firstRowID: $0.id, count: 1) }
        )

        for keys: Set<String>? in [nil, [], [CoordinatorMessageHeader.digestKey(normalDigest + " ")]] {
            let open = presentation(quietDigestKeys: keys)
            XCTAssertEqual(hostLines(open).map(\.foldsTurn), [false, false], "keys: \(String(describing: keys))")
            XCTAssertEqual(open.turns.map(\.foldsWholeTurn), [false, false])
            XCTAssertEqual(CoordinatorChatReadPoint.marker(in: open.rows, after: read)?.count, 2)
        }
    }

    /// In the open chat, a mark that comes folds the turn and one that goes
    /// opens it again, with the New line's count, without a reload. Another
    /// session's chat never folds.
    func testAMarkThatComesOrGoesFoldsOrOpensTheTurnInTheOpenChat() {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue, runtime: ConversationRuntime(conversationID: conversationID)
        )
        subject.consumeIsCoordinatorChat(true)
        // The app is not active, so the chat reads nothing and the line
        // counts every answer after the Mac's read point.
        subject.consumeSceneActivity(isActive: false)
        subject.consumeCoordinatorChatRead(
            isSupported: true, readPoint: RemoteCoordinatorChatReadPoint(eventID: "event-0", timestamp: time(0))
        )
        subject.consume(liveState(events))
        XCTAssertEqual(hostLines(subject.transcriptPresentation).map(\.foldsTurn), [false, false])
        XCTAssertEqual(subject.coordinatorNewMessages?.count, 2)

        let key = CoordinatorMessageHeader.digestKey(quietDigest)
        subject.consumeCoordinatorQuietDigests([key])
        XCTAssertEqual(hostLines(subject.transcriptPresentation).map(\.foldsTurn), [true, false])
        XCTAssertEqual(subject.transcriptPresentation.revision, .appended, "The reader's place and open turns stay")
        XCTAssertEqual(subject.transcriptPresentation.turns.first?.foldsWholeTurn, true)
        XCTAssertEqual(subject.coordinatorNewMessages?.count, 1)

        // PR #403: a later wake call in the same turn removes the mark.
        subject.consumeCoordinatorQuietDigests([])
        XCTAssertEqual(hostLines(subject.transcriptPresentation).map(\.foldsTurn), [false, false])
        XCTAssertEqual(subject.coordinatorNewMessages?.count, 2)
        subject.consumeCoordinatorQuietDigests([key])
        subject.consumeCoordinatorQuietDigests(nil)
        XCTAssertEqual(hostLines(subject.transcriptPresentation).map(\.foldsTurn), [false, false])

        let other = LiveConversationController(
            conversationID: conversationID.rawValue, runtime: ConversationRuntime(conversationID: conversationID)
        )
        other.consume(liveState(events))
        other.consumeCoordinatorQuietDigests([key])
        XCTAssertTrue(hostLines(other.transcriptPresentation).isEmpty, "Another chat shows the digests as messages")
    }

    // MARK: - Helpers

    private let oneMark = RemoteCoordinatorQuietDigests(keys: ["key-1"])
    private let twoMarks = RemoteCoordinatorQuietDigests(keys: ["key-1", "key-2"])

    private let quietDigest = """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - [Fix the login](toastty://task/1): idle at 2026-11-16T15:25:00Z
        Read `toastty task list` for details.
        """
    private let normalDigest = """
        \(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.
        - [Fix the unread dot](toastty://task/2): needsYou (review) at 2026-11-16T15:31:00Z
        Read `toastty task list` for details.
        """

    private var conversationID: RemoteConversationID {
        RemoteConversationID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    }

    private var runID: RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333300")!)
    }

    private func time(_ sequence: UInt64) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + TimeInterval(sequence) * 60)
    }

    /// A quiet wake turn with two tool calls and its answer, then a normal
    /// wake turn and its answer.
    private var events: [ConversationEvent] {
        let payloads: [ConversationEventPayload] = [
            .userMessage(.init(text: quietDigest, origin: .remote)),
            .toolStarted(.init(callID: "call-1", toolName: "Bash", detail: "toastty task list")),
            .toolFinished(.init(callID: "call-1", toolName: "Bash", outcome: .succeeded)),
            .toolStarted(.init(callID: "call-2", toolName: "Bash", detail: "toastty coordinator wake --clear --quiet")),
            .toolFinished(.init(callID: "call-2", toolName: "Bash", outcome: .succeeded)),
            .assistantMessage(.init(text: "Nothing needs you.", phase: .final)),
            .userMessage(.init(text: normalDigest, origin: .remote)),
            .assistantMessage(.init(text: "Fix the unread dot is ready for your review.", phase: .final)),
        ]
        return payloads.enumerated().map { index, payload in
            let sequence = UInt64(index + 1)
            return ConversationEvent(
                conversationID: conversationID, sequence: sequence, eventID: "event-\(sequence)",
                timestamp: time(sequence), provider: .claude, payload: payload
            )
        }
    }

    private func presentation(quietDigestKeys: Set<String>?) -> ToasttyConversationPresentationState {
        ToasttyConversationPresentationAdapter.makeState(
            events: events.map(CompatibleConversationEvent.known),
            projectionRunID: runID, projectionGeneration: 1, phase: .live, revision: .initial,
            historyTruncated: false,
            coordinatorMessages: ToasttyConversationPresentationAdapter.coordinatorMessages(quietDigestKeys: quietDigestKeys)
        )
    }

    private func hostLines(_ state: ToasttyConversationPresentationState) -> [ToasttyHostMessagePresentation] {
        state.rows.compactMap { row in
            if case .hostMessage(let line) = row.content { return line }
            return nil
        }
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
