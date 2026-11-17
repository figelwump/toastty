@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

/// The coordinator chat's New line on the iPhone, from the read point that
/// the Mac shares, and the reads that this phone sends back.
@MainActor
final class ToasttyCoordinatorChatReadingTests: XCTestCase {
    // MARK: - The line

    func testTheLineMarksWhatWasNotReadAndStaysWhileTheUserReads() {
        var reading = ToasttyCoordinatorChatReading()
        let all = rows([.user, .coordinator, .user, .coordinator, .coordinator, .coordinator])
        reading.consumeMacReadPoint(readPoint(all[1]))

        XCTAssertEqual(reading.update(rows: Array(all.prefix(5)), hasOlder: false, isLoadingOlder: false, isReading: true), .none)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[3].id, count: 2))
        XCTAssertEqual(reading.report(in: Array(all.prefix(5)))?.eventID, all[4].eventID)

        // A message that arrives while the user reads goes below the line
        // and is read.
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[3].id, count: 3))
        let report = try? XCTUnwrap(reading.report(in: all))
        XCTAssertEqual(report?.eventID, all[5].eventID)

        // Sent: nothing more to send until a later read.
        if let report { reading.didReport(report) }
        XCTAssertNil(reading.report(in: all))
        // The Mac's read point comes back: the line stays while the user
        // reads.
        reading.consumeMacReadPoint(readPoint(all[5]))
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[3].id, count: 3))
        XCTAssertNil(reading.report(in: all))
    }

    func testWhatArrivesWhileTheAppIsInactiveIsNewAndTheLineIsPlacedOnReturn() {
        var reading = ToasttyCoordinatorChatReading()
        let all = rows([.user, .coordinator, .coordinator, .coordinator])
        reading.consumeMacReadPoint(readPoint(all[1]))
        _ = reading.update(rows: Array(all.prefix(2)), hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertNil(reading.newMessages)
        XCTAssertNil(reading.report(in: Array(all.prefix(2))), "The Mac already read it")

        // In the background, or under Notification Center: not read.
        _ = reading.update(rows: Array(all.prefix(3)), hasOlder: false, isLoadingOlder: false, isReading: false)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[2].id, count: 1))
        XCTAssertNil(reading.report(in: Array(all.prefix(3))))

        // Back in the app: the line is where the user stopped, and what is
        // on screen is read now.
        reading.userCameBack()
        _ = reading.update(rows: Array(all.prefix(3)), hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[2].id, count: 1))
        XCTAssertEqual(reading.report(in: Array(all.prefix(3)))?.eventID, all[2].eventID)

        // Away and back with nothing new: no line.
        _ = reading.update(rows: Array(all.prefix(3)), hasOlder: false, isLoadingOlder: false, isReading: false)
        reading.userCameBack()
        _ = reading.update(rows: Array(all.prefix(3)), hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertNil(reading.newMessages)
    }

    func testASendRemovesTheLineAndReadsTheChat() {
        var reading = ToasttyCoordinatorChatReading()
        let all = rows([.coordinator, .coordinator, .coordinator])
        reading.consumeMacReadPoint(readPoint(all[0]))
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertNotNil(reading.newMessages)
        reading.userSent(rows: all)
        XCTAssertNil(reading.newMessages)
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertNil(reading.newMessages, "The line does not come back while the user stays")
        XCTAssertEqual(reading.report(in: all)?.eventID, all[2].eventID)
    }

    func testWithoutAReadPointThereIsNoLineAndTheFirstReadIsSent() {
        var reading = ToasttyCoordinatorChatReading()
        let all = rows([.user, .coordinator])
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertNil(reading.newMessages)
        XCTAssertEqual(reading.report(in: all)?.eventID, all[1].eventID)
    }

    /// A late snapshot can carry an older read point than this phone's own
    /// read. The later read stays, and is not sent twice.
    func testAnOlderReadPointFromTheMacDoesNotUndoThisPhonesRead() {
        var reading = ToasttyCoordinatorChatReading()
        let all = rows([.coordinator, .coordinator, .coordinator])
        reading.consumeMacReadPoint(readPoint(all[0]))
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        let report = try? XCTUnwrap(reading.report(in: all))
        if let report { reading.didReport(report) }
        reading.consumeMacReadPoint(readPoint(all[1]))
        XCTAssertEqual(reading.readPoint(in: all)?.eventID, all[2].eventID)
        XCTAssertNil(reading.report(in: all))
        // Back later: no line for what this phone read.
        reading.userCameBack()
        _ = reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertNil(reading.newMessages)
    }

    /// The phone reads the newest page first. The line goes where the user
    /// stopped once older pages reach it, at most five pages back.
    func testOlderPagesAreReadUntilTheRowsReachTheReadPoint() {
        var reading = ToasttyCoordinatorChatReading()
        let all = rows(Array(repeating: .coordinator, count: 40))
        reading.consumeMacReadPoint(readPoint(all[2]))
        func page(from start: Int) -> [ToasttyTranscriptRow] { Array(all[start...]) }

        XCTAssertEqual(reading.update(rows: page(from: 30), hasOlder: true, isLoadingOlder: false, isReading: true), .loadOlder)
        // Meanwhile the line is above the oldest loaded message.
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[30].id, count: 10))
        XCTAssertEqual(reading.update(rows: page(from: 30), hasOlder: true, isLoadingOlder: true, isReading: true), .none)
        // A page that did not come is asked for again, a few times.
        XCTAssertEqual(reading.update(rows: page(from: 30), hasOlder: true, isLoadingOlder: false, isReading: true), .loadOlder)
        XCTAssertEqual(reading.update(rows: page(from: 20), hasOlder: true, isLoadingOlder: false, isReading: true), .loadOlder)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[20].id, count: 20))
        // The rows reach the read point: the line goes after it.
        XCTAssertEqual(reading.update(rows: page(from: 0), hasOlder: false, isLoadingOlder: false, isReading: true), .none)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[3].id, count: 37))
        // The user read on meanwhile, and the line stays.
        XCTAssertEqual(reading.report(in: all)?.eventID, all[39].eventID)
        XCTAssertEqual(reading.update(rows: all, hasOlder: false, isLoadingOlder: false, isReading: true), .none)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: all[3].id, count: 37))

        // Pages that never reach the read point: five, then no more. The
        // line stays above the oldest loaded message.
        var far = ToasttyCoordinatorChatReading()
        far.consumeMacReadPoint(readPoint(all[0]))
        var steps: [ToasttyCoordinatorChatReading.Step] = []
        for start in [35, 30, 25, 20, 15, 10, 5] {
            steps.append(far.update(rows: page(from: start), hasOlder: true, isLoadingOlder: false, isReading: true))
        }
        XCTAssertEqual(steps, [.loadOlder, .loadOlder, .loadOlder, .loadOlder, .loadOlder, .none, .none])
        XCTAssertEqual(far.newMessages, ToasttyNewMessagesMarker(firstRowID: all[5].id, count: 35))
    }

    /// A row at the read point is not new on the phone, though the wire
    /// keeps its time to milliseconds only.
    func testTheReadRowIsNotNewThoughTheWireRoundsItsTime() throws {
        let macTimes = [
            Date(timeIntervalSinceReferenceDate: 800_000_000.002_011_4),
            Date(timeIntervalSinceReferenceDate: 800_000_000.500_998),
            Date(timeIntervalSinceReferenceDate: 800_000_005.5),
        ]
        let macEvents = macTimes.enumerated().map { index, time in
            assistantEvent(UInt64(index + 1), at: time)
        }
        let phoneRows = presentationRows(try throughTheWire(macEvents))
        XCTAssertLessThan(phoneRows[0].timestamp, macTimes[0])

        // The Mac's read point: the row's event, with the Mac's own time.
        var reading = ToasttyCoordinatorChatReading()
        reading.consumeMacReadPoint(RemoteCoordinatorChatReadPoint(eventID: macEvents[0].eventID, timestamp: macTimes[0]))
        _ = reading.update(rows: phoneRows, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertEqual(reading.newMessages, ToasttyNewMessagesMarker(firstRowID: phoneRows[1].id, count: 2))

        // A read point that an older Toastty saved, by time only: the read
        // row is not new either.
        var saved = ToasttyCoordinatorChatReading()
        saved.consumeMacReadPoint(RemoteCoordinatorChatReadPoint(eventID: nil, timestamp: macTimes[0]))
        _ = saved.update(rows: phoneRows, hasOlder: false, isLoadingOlder: false, isReading: true)
        XCTAssertEqual(saved.newMessages?.firstRowID, phoneRows[1].id)
    }

    // MARK: - The controller

    func testTheLineShowsOnlyInTheCoordinatorsChatWithAMacThatSharesItsReadPoint() {
        let subject = LiveConversationController(conversationID: conversationID.rawValue, runtime: ConversationRuntime(conversationID: conversationID))
        let events = [userEvent(1), assistantEvent(2), assistantEvent(3)]
        subject.consumeIsCoordinatorChat(true)
        subject.consume(liveState(events))
        let readPoint = RemoteCoordinatorChatReadPoint(eventID: "event-2", timestamp: events[1].timestamp)

        // An older Mac: no capability.
        subject.consumeCoordinatorChatRead(isSupported: false, readPoint: readPoint)
        XCTAssertNil(subject.coordinatorNewMessages)
        subject.consumeCoordinatorChatRead(isSupported: true, readPoint: readPoint)
        XCTAssertEqual(subject.coordinatorNewMessages?.count, 1)
        XCTAssertEqual(subject.coordinatorNewMessages?.firstRowID.sequence, 3)
        // Another session's chat shows no line.
        subject.consumeIsCoordinatorChat(false)
        XCTAssertNil(subject.coordinatorNewMessages)
    }

    func testReadsGoToTheMacTogetherAndWhenTheChatCloses() async throws {
        let recorder = ChatReadRecorder()
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            readCoordinatorChat: { request in await recorder.record(request) }
        )
        subject.consumeIsCoordinatorChat(true)
        subject.consumeCoordinatorChatRead(isSupported: true, readPoint: nil)
        subject.consume(liveState([assistantEvent(1)]))
        // Two more messages arrive before the wait ends: one request.
        subject.consume(liveState([assistantEvent(1), assistantEvent(2)]))
        subject.consume(liveState([assistantEvent(1), assistantEvent(2), assistantEvent(3)]))
        let first = try await recorder.waitForRequests(count: 1)
        XCTAssertEqual(first.map(\.eventID), ["event-3"])
        XCTAssertEqual(first.first?.conversationID, conversationID)

        // A message that arrives just before the chat closes is sent at once.
        subject.consume(liveState((1 ... 4).map { assistantEvent($0) }))
        subject.stop()
        let all = try await recorder.waitForRequests(count: 2, within: .milliseconds(500))
        XCTAssertEqual(all.map(\.eventID), ["event-3", "event-4"])
    }

    func testAnInactiveAppReadsNothingUntilTheUserComesBack() async throws {
        let recorder = ChatReadRecorder()
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            readCoordinatorChat: { request in await recorder.record(request) }
        )
        subject.consumeIsCoordinatorChat(true)
        let events = [assistantEvent(1), assistantEvent(2)]
        subject.consumeCoordinatorChatRead(
            isSupported: true,
            readPoint: RemoteCoordinatorChatReadPoint(eventID: "event-1", timestamp: events[0].timestamp)
        )
        subject.consumeSceneActivity(isActive: false)
        subject.consume(liveState(events))
        XCTAssertEqual(subject.coordinatorNewMessages?.firstRowID.sequence, 2)
        try await Task.sleep(for: .milliseconds(1_300))
        let none = await recorder.requests()
        XCTAssertTrue(none.isEmpty)

        subject.consumeSceneActivity(isActive: true)
        XCTAssertEqual(subject.coordinatorNewMessages?.firstRowID.sequence, 2)
        let sent = try await recorder.waitForRequests(count: 1)
        XCTAssertEqual(sent.map(\.eventID), ["event-2"])
    }

    func testASendInTheCoordinatorsChatRemovesTheLine() async {
        let subject = LiveConversationController(
            conversationID: conversationID.rawValue,
            runtime: ConversationRuntime(conversationID: conversationID),
            send: { _, _ in .enqueued(clientRequestID: "sent") }
        )
        subject.consumeIsCoordinatorChat(true)
        let events = [assistantEvent(1), assistantEvent(2)]
        subject.consumeCoordinatorChatRead(
            isSupported: true,
            readPoint: RemoteCoordinatorChatReadPoint(eventID: "event-1", timestamp: events[0].timestamp)
        )
        subject.consume(liveState(events, composerAuthority: enabledComposerAuthority()))
        XCTAssertNotNil(subject.coordinatorNewMessages)
        let outcome = await subject.send("Thanks")
        XCTAssertEqual(outcome, .enqueued(clientRequestID: "sent"))
        XCTAssertNil(subject.coordinatorNewMessages)
    }

    // MARK: - Helpers

    private enum Kind { case user, coordinator }

    private var conversationID: RemoteConversationID {
        RemoteConversationID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    }

    private var runID: RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333300")!)
    }

    private func time(_ sequence: UInt64) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + TimeInterval(sequence) * 60)
    }

    private func assistantEvent(_ sequence: UInt64, at timestamp: Date? = nil) -> ConversationEvent {
        ConversationEvent(
            conversationID: conversationID, sequence: sequence, eventID: "event-\(sequence)",
            timestamp: timestamp ?? time(sequence), provider: .claude,
            payload: .assistantMessage(ConversationAssistantMessagePayload(text: "Message \(sequence)", phase: .final))
        )
    }

    private func userEvent(_ sequence: UInt64) -> ConversationEvent {
        ConversationEvent(
            conversationID: conversationID, sequence: sequence, eventID: "event-\(sequence)",
            timestamp: time(sequence), provider: .claude,
            payload: .userMessage(ConversationUserMessagePayload(text: "Question \(sequence)", origin: .remote))
        )
    }

    private func rows(_ kinds: [Kind]) -> [ToasttyTranscriptRow] {
        presentationRows(kinds.enumerated().map { index, kind in
            kind == .user ? userEvent(UInt64(index + 1)) : assistantEvent(UInt64(index + 1))
        })
    }

    private func presentationRows(_ events: [ConversationEvent]) -> [ToasttyTranscriptRow] {
        ToasttyConversationPresentationAdapter.makeState(
            events: events.map(CompatibleConversationEvent.known),
            projectionRunID: runID, projectionGeneration: 1, phase: .live, revision: .initial,
            historyTruncated: false, coordinatorMessages: ToasttyConversationPresentationAdapter.coordinatorMessages()
        ).rows
    }

    private func throughTheWire(_ events: [ConversationEvent]) throws -> [ConversationEvent] {
        try ConversationEventCoding.makeDecoder().decode(
            [ConversationEvent].self, from: ConversationEventCoding.makeEncoder().encode(events)
        )
    }

    private func readPoint(_ row: ToasttyTranscriptRow) -> RemoteCoordinatorChatReadPoint {
        RemoteCoordinatorChatReadPoint(eventID: row.eventID, timestamp: row.timestamp)
    }

    private func liveState(
        _ events: [ConversationEvent],
        composerAuthority: ConversationComposerAuthority = ConversationComposerAuthority()
    ) -> ConversationRuntime.State {
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
            composerAuthority: composerAuthority,
            sendReconciliation: SendReconciliation()
        )
    }

    private func enabledComposerAuthority() -> ConversationComposerAuthority {
        let epoch = RemoteInputEpoch(bindingID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, counter: 9)
        return ConversationComposerAuthority(
            stamp: ConversationComposerStamp(
                connectionGeneration: 4, streamSnapshotOrdinal: 3, projectionRunID: runID,
                projectionGeneration: 7, latestSequence: 2, inputEpoch: epoch
            ),
            inputAvailability: .openPrompt(epoch: epoch)
        )
    }
}

private actor ChatReadRecorder {
    private var recorded: [RemoteCoordinatorChatReadRequest] = []

    func record(_ request: RemoteCoordinatorChatReadRequest) -> RemoteCoordinatorChatReadResponse {
        recorded.append(request)
        return RemoteCoordinatorChatReadResponse(result: .moved)
    }

    func requests() -> [RemoteCoordinatorChatReadRequest] { recorded }

    func waitForRequests(
        count: Int,
        within limit: Duration = .seconds(3)
    ) async throws -> [RemoteCoordinatorChatReadRequest] {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while recorded.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(recorded.count, count)
        return recorded
    }
}
