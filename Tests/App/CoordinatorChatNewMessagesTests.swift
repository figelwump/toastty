@testable import ToasttyApp
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The line above the coordinator's messages that the user has not seen,
/// with the real controller and a Codex conversation read from its
/// transcript file.
@Suite(.serialized)
struct CoordinatorChatNewMessagesTests {
    @MainActor
    private func row(_ text: String, in fixture: CoordinatorChatFixture) -> ToasttyTranscriptRowID? {
        fixture.chat.presentation.rows.last { row in
            if case .assistantMessage(let rowText, _) = row.content { return rowText == text }
            return false
        }?.id
    }

    @MainActor
    private func waitForRow(_ text: String, in fixture: CoordinatorChatFixture) async throws -> ToasttyTranscriptRowID {
        try await fixture.waitFor("the row \"\(text)\"") { row(text, in: fixture) }
    }

    /// Toastty reads the coordinator's conversation while the chat is
    /// hidden too, a moment after the agent writes it. A test that shows
    /// the chat waits for that read first, as a user who comes back later
    /// does.
    @MainActor
    private func waitUntilToasttyRead(_ text: String, in fixture: CoordinatorChatFixture) async throws {
        let subscription = fixture.conversations.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        try await fixture.waitUntil("Toastty to read \"\(text)\"") {
            guard case .page(let page) = subscription.events(before: nil, limit: 50) else { return false }
            return page.events.contains { event in
                if case .assistantMessage(let payload) = event.payload { return payload.text == text }
                return false
            }
        }
    }

    @MainActor
    @Test func theLineMarksWhatArrivedWhileTheUserWasAwayAndStaysWhileTheUserReads() async throws {
        let suiteName = "toastty.tests.coordinator-new-messages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorChatFixture(chatDefaults: defaults)
        defer { fixture.tearDown() }

        // The first read shows no line: nothing was read before.
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        #expect(fixture.chat.newMessages == nil)

        // The coordinator answers a task while the chat is hidden. The line
        // goes above its turn's first row that is not the user's, and
        // counts its message.
        fixture.chat.hide()
        try fixture.startTurn(2, userText: "A message from the phone")
        try fixture.recordAgentMessage("The sidebar fix is ready for review.")
        try fixture.endTurn(2)
        try await waitUntilToasttyRead("The sidebar fix is ready for review.", in: fixture)
        fixture.chat.show(panelID: fixture.panelID)
        let away = try await waitForRow("The sidebar fix is ready for review.", in: fixture)
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: away, count: 1))

        // A message that arrives while the user reads is below the line,
        // and the line stays where it is.
        try fixture.startTurn(3, userText: "And the iOS build?")
        try fixture.recordAgentMessage("The iOS build passed.")
        try fixture.endTurn(3)
        _ = try await waitForRow("The iOS build passed.", in: fixture)
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: away, count: 2))

        // Back with nothing new: everything was read, and the line is gone.
        fixture.chat.hide()
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the line to go") { fixture.chat.newMessages == nil }

        // A chat on screen behind another app is not read: what arrives
        // then is new, and the line stays when the user comes back.
        fixture.clock.appIsActive = false
        fixture.chat.appActivityChanged()
        try fixture.startTurn(4, userText: "Anything else?")
        try fixture.recordAgentMessage("A task needs your answer.")
        try fixture.endTurn(4)
        let behind = try await waitForRow("A task needs your answer.", in: fixture)
        try await fixture.waitUntil("the line above the message from while Toastty was in the background") {
            fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: behind, count: 1)
        }
        fixture.clock.appIsActive = true
        fixture.chat.appActivityChanged()
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: behind, count: 1))

        // The user's own message answers: the line goes.
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        fixture.chat.draft = "Thanks"
        fixture.chat.send()
        #expect(fixture.chat.newMessages == nil)
        try fixture.startTurn(5, userText: "Thanks")
        try fixture.endTurn(5)

        // What the user read survives a relaunch.
        fixture.chat.hide()
        try fixture.startTurn(6, userText: "Status?")
        try fixture.recordAgentMessage("All tasks are done.")
        try fixture.endTurn(6)
        try await waitUntilToasttyRead("All tasks are done.", in: fixture)
        fixture.relaunch()
        fixture.chat.show(panelID: fixture.panelID)
        let afterRelaunch = try await waitForRow("All tasks are done.", in: fixture)
        try await fixture.waitUntil("the line after the relaunch") {
            fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: afterRelaunch, count: 1)
        }
    }

    /// After a relaunch the chat reads only the newest page. The line still
    /// goes where the user stopped, also when more than a page came since.
    @MainActor
    @Test func afterARelaunchTheLineGoesWhereTheUserStoppedAlsoPagesBack() async throws {
        let suiteName = "toastty.tests.coordinator-new-messages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorChatFixture(chatDefaults: defaults)
        defer { fixture.tearDown() }

        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        fixture.chat.hide()

        let unreadCount = CoordinatorChatModel.pageSize + 30
        try fixture.startTurn(2, userText: "Report each check")
        for index in 1 ... unreadCount {
            try fixture.recordAgentMessage("Check \(index) passed.")
        }
        try fixture.endTurn(2)
        try await waitUntilToasttyRead("Check \(unreadCount) passed.", in: fixture)
        fixture.relaunch()
        fixture.chat.show(panelID: fixture.panelID)
        _ = try await waitForRow("Check \(unreadCount) passed.", in: fixture)
        let first = try #require(row("Check 1 passed.", in: fixture), "The chat did not read back to where the user stopped")
        #expect(fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: first, count: unreadCount))
    }

    // MARK: - Reads on a paired device

    /// The coordinator's newest event that `matches`, as a device that
    /// shows its row names it.
    @MainActor
    private func phoneRead(
        in fixture: CoordinatorChatFixture,
        where matches: (ConversationEvent) -> Bool
    ) throws -> RemoteCoordinatorChatReadRequest {
        let subscription = fixture.conversations.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        guard case .page(let page) = subscription.events(before: nil, limit: 200) else {
            throw LocalConversationFixtureError.timedOut
        }
        let event = try #require(page.events.last(where: matches))
        return RemoteCoordinatorChatReadRequest(
            conversationID: page.conversationID, eventID: event.eventID,
            projectionRunID: page.projectionRunID, projectionGeneration: page.projectionGeneration
        )
    }

    @MainActor
    private func phoneRead(of text: String, in fixture: CoordinatorChatFixture) throws -> RemoteCoordinatorChatReadRequest {
        try phoneRead(in: fixture) { event in
            if case .assistantMessage(let payload) = event.payload { return payload.text == text }
            return false
        }
    }

    /// The event of the coordinator's message `text`.
    @MainActor
    private func eventID(of text: String, in fixture: CoordinatorChatFixture) throws -> String {
        try phoneRead(of: text, in: fixture).eventID
    }

    @MainActor
    private func readOnPhone(
        _ text: String,
        in fixture: CoordinatorChatFixture
    ) throws -> (status: Int, result: RemoteCoordinatorChatReadResult?) {
        try fixture.conversations.gatewayCoordinatorChatRead(
            phoneRead(of: text, in: fixture), credential: fixture.conversations.nativeCredential
        )
    }

    @MainActor
    private func publishedReadPoint(in fixture: CoordinatorChatFixture) -> RemoteCoordinatorChatReadPoint? {
        fixture.conversations.service.facadeSessionList(at: .now).workspaces.first(where: \.isCoordinator)?
            .coordinatorChatRead
    }

    /// Messages that the phone showed are read on the Mac too: the Mac
    /// shows no line for them when the user comes back to its chat.
    @MainActor
    @Test func aReadOnThePhoneMovesTheSharedReadPointAndTheMacsLine() async throws {
        let suiteName = "toastty.tests.coordinator-new-messages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true, chatDefaults: defaults)
        defer { fixture.tearDown() }
        fixture.conversations.enableGateway()
        fixture.conversations.service.installCoordinatorChatRead(fixture.controller.chatReadThrough)

        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        let readOnMac = try eventID(of: "Two tasks are open.", in: fixture)
        // The Mac sends its own read with the coordinator's workspace.
        #expect(publishedReadPoint(in: fixture)?.eventID == readOnMac)
        fixture.chat.hide()

        // The coordinator answers while the Mac's chat is hidden, and the
        // user reads the answer on the phone.
        try fixture.startTurn(2, userText: "Status?")
        try fixture.recordAgentMessage("The sidebar fix merged.")
        try fixture.endTurn(2)
        try await waitUntilToasttyRead("The sidebar fix merged.", in: fixture)
        let phoneRead = try readOnPhone("The sidebar fix merged.", in: fixture)
        #expect(phoneRead.status == 200)
        #expect(phoneRead.result == .moved)
        let readByPhone = try eventID(of: "The sidebar fix merged.", in: fixture)
        #expect(fixture.controller.chatReadThrough.point?.eventID == readByPhone)
        #expect(publishedReadPoint(in: fixture)?.eventID == readByPhone)

        // A repeat, or a read that arrives late, never moves it back.
        #expect(try readOnPhone("The sidebar fix merged.", in: fixture).result == .alreadyRead)
        #expect(try readOnPhone("Two tasks are open.", in: fixture).result == .alreadyRead)
        #expect(fixture.controller.chatReadThrough.point?.eventID == readByPhone)

        // Back in the Mac's chat: no line for what the phone showed.
        fixture.chat.show(panelID: fixture.panelID)
        _ = try await waitForRow("The sidebar fix merged.", in: fixture)
        #expect(fixture.chat.newMessages == nil)

        // What neither read is new on the Mac.
        fixture.chat.hide()
        try fixture.startTurn(3, userText: "And the iOS build?")
        try fixture.recordAgentMessage("The iOS build passed.")
        try fixture.endTurn(3)
        try await waitUntilToasttyRead("The iOS build passed.", in: fixture)
        fixture.chat.show(panelID: fixture.panelID)
        let unread = try await waitForRow("The iOS build passed.", in: fixture)
        try await fixture.waitUntil("the line above what neither read") {
            fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: unread, count: 1)
        }

        // The read point, with the row's event, survives a relaunch.
        let saved = fixture.controller.chatReadThrough.point
        fixture.relaunch()
        #expect(fixture.controller.chatReadThrough.point == saved)
        #expect(saved?.eventID == (try eventID(of: "The iOS build passed.", in: fixture)))
    }

    /// The Mac's line on screen follows the Mac's rule: a read on the phone
    /// does not move it while the user reads on the Mac, and when the user
    /// comes back to Toastty, the line leaves out what the phone showed.
    @MainActor
    @Test func aReadOnThePhoneWhileTheMacChatIsOnScreen() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        fixture.conversations.enableGateway()
        fixture.conversations.service.installCoordinatorChatRead(fixture.controller.chatReadThrough)

        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        fixture.chat.hide()
        try fixture.startTurn(2, userText: "Status?")
        try fixture.recordAgentMessage("The sidebar fix merged.")
        try fixture.endTurn(2)
        try await waitUntilToasttyRead("The sidebar fix merged.", in: fixture)
        fixture.chat.show(panelID: fixture.panelID)
        let away = try await waitForRow("The sidebar fix merged.", in: fixture)
        let line = ToasttyNewMessagesMarker(firstRowID: away, count: 1)
        #expect(fixture.chat.newMessages == line)

        // The Mac read it when the chat showed: the phone's read of it
        // changes nothing, and the line stays while the user reads.
        #expect(try readOnPhone("The sidebar fix merged.", in: fixture).result == .alreadyRead)
        #expect(fixture.chat.newMessages == line)

        // Toastty is in the background: the Mac does not read what arrives.
        fixture.clock.appIsActive = false
        fixture.chat.appActivityChanged()
        try fixture.startTurn(3, userText: "And the iOS build?")
        try fixture.recordAgentMessage("The iOS build passed.")
        try fixture.endTurn(3)
        let behind = try await waitForRow("The iOS build passed.", in: fixture)
        try await fixture.waitUntil("the line above what arrived while Toastty was in the background") {
            fixture.chat.newMessages == ToasttyNewMessagesMarker(firstRowID: behind, count: 1)
        }
        // The user reads it on the phone, then comes back to Toastty.
        #expect(try readOnPhone("The iOS build passed.", in: fixture).result == .moved)
        fixture.clock.appIsActive = true
        fixture.chat.appActivityChanged()
        try await fixture.waitUntil("no line for what the phone showed") { fixture.chat.newMessages == nil }
    }

    /// The route reads the coordinator's own conversation, for a paired
    /// device only, and a Mac without the coordinator does not offer it.
    @MainActor
    @Test func theChatReadRouteChecksTheDeviceAndTheCoordinator() async throws {
        // A Mac whose windows have no coordinator workspace.
        let plain = try LocalConversationFixture(pairsNativeDevice: true)
        defer { plain.removeRuntimeFiles() }
        plain.enableGateway()
        #expect(plain.gatewayCapabilities().contains(.coordinatorChatRead) == false)
        plain.service.installCoordinatorChatRead(CoordinatorChatReadThrough(defaults: nil))
        #expect(plain.gatewayCapabilities().contains(.coordinatorChatRead))
        let subscription = plain.service.subscribeToConversation(inPanel: plain.panelID)
        defer { subscription.cancel() }
        let plainConversation = try #require(subscription.conversationID)
        let noCoordinator = try plain.gatewayCoordinatorChatRead(
            RemoteCoordinatorChatReadRequest(
                conversationID: plainConversation, eventID: "codex:msg_1",
                projectionRunID: RemoteProjectionRunID(rawValue: UUID()), projectionGeneration: 1
            ),
            credential: plain.nativeCredential
        )
        #expect(noCoordinator.status == 200)
        #expect(noCoordinator.result == .noCoordinator)

        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        fixture.conversations.enableGateway()
        fixture.conversations.service.installCoordinatorChatRead(fixture.controller.chatReadThrough)
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "What is open?")
        try fixture.recordAgentMessage("Two tasks are open.")
        try fixture.endTurn(1)
        _ = try await waitForRow("Two tasks are open.", in: fixture)
        fixture.chat.hide()
        let request = try phoneRead(of: "Two tasks are open.", in: fixture)
        let before = fixture.controller.chatReadThrough.point

        // Without a paired device's credential nothing moves.
        let unpaired = try fixture.conversations.gatewayCoordinatorChatRead(request, credential: nil)
        #expect(unpaired.status == 401)
        #expect(unpaired.result == nil)
        let unknown = try fixture.conversations.gatewayCoordinatorChatRead(request, credential: "not-a-paired-device")
        #expect(unknown.status == 401)
        #expect(unknown.result == nil)
        // An event that the conversation does not have.
        var missingEvent = request
        missingEvent.eventID = "codex:not-in-this-conversation"
        let missing = try fixture.conversations.gatewayCoordinatorChatRead(
            missingEvent, credential: fixture.conversations.nativeCredential
        )
        #expect(missing.result == .eventNotFound)
        // A runtime event's identity from another run of the Mac's reader
        // can name another event now: refused. From this run it counts.
        var runtimeEvent = try phoneRead(in: fixture) { $0.eventID.hasPrefix("rt:") }
        let thisRun = runtimeEvent
        runtimeEvent.projectionRunID = RemoteProjectionRunID(rawValue: UUID())
        let earlierRun = try fixture.conversations.gatewayCoordinatorChatRead(
            runtimeEvent, credential: fixture.conversations.nativeCredential
        )
        #expect(earlierRun.result == .eventNotFound)
        #expect(fixture.controller.chatReadThrough.point == before)
        let sameRun = try fixture.conversations.gatewayCoordinatorChatRead(
            thisRun, credential: fixture.conversations.nativeCredential
        )
        #expect(sameRun.result == .alreadyRead || sameRun.result == .moved)

        // A revoked device is refused.
        let device = try #require(fixture.conversations.service.devices.first { $0.authKind == .native })
        fixture.conversations.service.revokeDevice(device.id)
        let revoked = try fixture.conversations.gatewayCoordinatorChatRead(
            request, credential: fixture.conversations.nativeCredential
        )
        #expect(revoked.status == 401)
        #expect(revoked.result == nil)
    }

    // MARK: - Which rows are new

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let runID = UUID()

    private static func row(
        _ sequence: UInt64,
        _ content: ToasttyTranscriptRow.Content,
        at timestamp: Date? = nil
    ) -> ToasttyTranscriptRow {
        ToasttyTranscriptRow(
            id: rowID(sequence),
            timestamp: timestamp ?? start.addingTimeInterval(TimeInterval(sequence)),
            provider: .claude,
            content: content,
            eventID: "claude:record-\(sequence)"
        )
    }

    private static func rowID(_ sequence: UInt64) -> ToasttyTranscriptRowID {
        ToasttyTranscriptRowID(projectionRunID: runID, projectionGeneration: 1, conversationID: runID, sequence: sequence)
    }

    private static func readPoint(_ row: ToasttyTranscriptRow) -> RemoteCoordinatorChatReadPoint {
        RemoteCoordinatorChatReadPoint(eventID: row.eventID, timestamp: row.timestamp)
    }

    private static func digest(foldsTurn: Bool) -> ToasttyTranscriptRow.Content {
        .hostMessage(ToasttyHostMessagePresentation(summary: "2 task updates", text: "digest", foldsTurn: foldsTurn))
    }

    @Test func aQuietWakeTurnAndTheUsersOwnMessagesAreNotNew() {
        let rows = [
            Self.row(1, .assistantMessage(text: "Read before", phase: .final)),
            // A wake turn that the coordinator marked quiet.
            Self.row(2, Self.digest(foldsTurn: true)),
            Self.row(3, .assistantMessage(text: "Nothing for you", phase: .final)),
            // The user's message from the phone, then the coordinator's
            // work and answer.
            Self.row(4, .userMessage(text: "Status?", origin: .remote)),
            Self.row(5, .toolStarted(callID: "1", name: "Bash", detail: nil)),
            Self.row(6, .assistantMessage(text: "Checking", phase: .commentary)),
            Self.row(7, .assistantMessage(text: "All green", phase: .final)),
            // A wake turn that has something for the user.
            Self.row(8, Self.digest(foldsTurn: false)),
            Self.row(9, .assistantMessage(text: "A task needs you", phase: .final)),
        ]
        let readThrough = Self.readPoint(rows[0])

        #expect(CoordinatorChatReadPoint.marker(in: rows, after: readThrough)
            == ToasttyNewMessagesMarker(firstRowID: Self.rowID(5), count: 2))
        // Nothing read yet: no line.
        #expect(CoordinatorChatReadPoint.marker(in: rows, after: nil) == nil)
        // Only the quiet turn and the user's message are new: no line.
        #expect(CoordinatorChatReadPoint.marker(in: Array(rows.prefix(4)), after: readThrough) == nil)
        // Work without a message yet: no line.
        #expect(CoordinatorChatReadPoint.marker(in: Array(rows.prefix(6)), after: readThrough) == nil)
    }

    /// The read point names its row by the row's event, so rows with the
    /// same time are told apart, and a row that the chat has not loaded is
    /// placed by its time.
    @Test func theReadRowIsNamedByItsEventAndATimeOnlyOrdersWhatTheChatLacks() {
        let sameTime = Self.start.addingTimeInterval(1)
        let rows = [
            Self.row(1, .assistantMessage(text: "First", phase: .final), at: sameTime),
            Self.row(2, .assistantMessage(text: "Second", phase: .final), at: sameTime),
            Self.row(3, .assistantMessage(text: "Third", phase: .final), at: sameTime),
        ]
        // Read through the first: the two after it are new, though all
        // three have one time.
        #expect(CoordinatorChatReadPoint.marker(in: rows, after: Self.readPoint(rows[0]))
            == ToasttyNewMessagesMarker(firstRowID: Self.rowID(2), count: 2))
        #expect(CoordinatorChatReadPoint.marker(in: rows, after: Self.readPoint(rows[2])) == nil)

        // A read row older than the loaded rows: the rows after its time
        // are new, and the chat reads older pages to reach it.
        let older = RemoteCoordinatorChatReadPoint(eventID: "claude:not-loaded", timestamp: Self.start)
        #expect(CoordinatorChatReadPoint.marker(in: rows, after: older)
            == ToasttyNewMessagesMarker(firstRowID: Self.rowID(1), count: 3))
        #expect(CoordinatorChatReadPoint.needsOlderRows(rows, toReach: older))
        // The rows have the read row, or reach back past its time.
        #expect(CoordinatorChatReadPoint.needsOlderRows(rows, toReach: Self.readPoint(rows[1])) == false)
        let byTimeOnly = RemoteCoordinatorChatReadPoint(eventID: nil, timestamp: sameTime.addingTimeInterval(30))
        #expect(CoordinatorChatReadPoint.needsOlderRows(rows, toReach: byTimeOnly) == false)

        // A runtime event's identity restarts with each run of the Mac's
        // reader, so the read point keeps only its time.
        #expect(RemoteCoordinatorChatReadPoint(eventID: "rt:1:3", timestamp: sameTime).eventID == nil)
    }

    /// A row at the read point is not new on the Mac nor on the iPhone.
    /// The wire carries times as text with milliseconds, and a time that a
    /// device decoded can encode one millisecond earlier, so the read
    /// point names the row by its event.
    @Test func aRowAtTheReadPointIsNotNewOnTheMacNorOnThePhone() throws {
        let conversationID = RemoteConversationID(rawValue: Self.runID)
        // A transcript time between milliseconds, as a decoded transcript
        // time often is.
        let macTimes = [
            Date(timeIntervalSinceReferenceDate: 800_000_000.002_011_4),
            Date(timeIntervalSinceReferenceDate: 800_000_001.004_998_7),
        ]
        let macEvents = macTimes.enumerated().map { index, time in
            ConversationEvent(
                conversationID: conversationID,
                sequence: UInt64(index + 1),
                eventID: "codex:msg_\(index + 1)",
                timestamp: time,
                provider: .codex,
                payload: .assistantMessage(ConversationAssistantMessagePayload(text: "Message \(index + 1)", phase: .final))
            )
        }
        // The phone's events are the Mac's, through the wire.
        let phoneEvents = try ConversationEventCoding.makeDecoder().decode(
            [ConversationEvent].self, from: ConversationEventCoding.makeEncoder().encode(macEvents)
        )
        func rows(_ events: [ConversationEvent]) -> [ToasttyTranscriptRow] {
            CoordinatorChatTranscript.rows(
                from: events, projectionRunID: RemoteProjectionRunID(rawValue: Self.runID), projectionGeneration: 1,
                isSentFromThisMac: { _ in false }, timeText: { _ in "" }
            )
        }
        let macRows = rows(macEvents)
        let phoneRows = rows(phoneEvents)
        #expect(phoneRows[0].timestamp < macRows[0].timestamp, "The wire keeps milliseconds only")

        // The phone read the first message; the Mac takes the read point
        // from its own event of that row.
        let fromThePhone = try #require(CoordinatorChatReadPoint.readPoint(through: Array(phoneRows.prefix(1))))
        let macEvent = try #require(macEvents.first { $0.eventID == fromThePhone.eventID })
        let shared = RemoteCoordinatorChatReadPoint(eventID: macEvent.eventID, timestamp: macEvent.timestamp)
        let expectedOnMac = ToasttyNewMessagesMarker(firstRowID: macRows[1].id, count: 1)
        #expect(CoordinatorChatReadPoint.marker(in: macRows, after: shared) == expectedOnMac)
        #expect(CoordinatorChatReadPoint.marker(in: phoneRows, after: shared)?.firstRowID == phoneRows[1].id)

        // The Mac's read point, through the wire to the phone.
        let published = try ConversationEventCoding.makeDecoder().decode(
            RemoteCoordinatorChatReadPoint.self, from: ConversationEventCoding.makeEncoder().encode(shared)
        )
        #expect(CoordinatorChatReadPoint.marker(in: phoneRows, after: published)?.firstRowID == phoneRows[1].id)

        // Why not the time: the phone's time of the read row, through the
        // wire again, is earlier than the Mac's, so the Mac would show the
        // read row as new.
        let phoneTime = try ConversationEventCoding.makeDecoder().decode(
            [Date].self, from: ConversationEventCoding.makeEncoder().encode([phoneRows[0].timestamp])
        )[0]
        let byTimeOnly = RemoteCoordinatorChatReadPoint(eventID: nil, timestamp: phoneTime)
        #expect(CoordinatorChatReadPoint.marker(in: macRows, after: byTimeOnly)?.firstRowID == macRows[0].id)
    }

    @Test func aReadIsNewerByItsPlaceAndOtherwiseByItsTime() {
        let rows = (1 ... 3).map { Self.row(UInt64($0), .assistantMessage(text: "M\($0)", phase: .final)) }
        let first = Self.readPoint(rows[0]), last = Self.readPoint(rows[2])
        #expect(CoordinatorChatReadPoint.isNewer(last, than: first, in: rows))
        #expect(CoordinatorChatReadPoint.isNewer(first, than: last, in: rows) == false)
        #expect(CoordinatorChatReadPoint.isNewer(first, than: first, in: rows) == false)
        #expect(CoordinatorChatReadPoint.isNewer(first, than: nil, in: rows))
        // A read row that these rows lack: the times decide.
        let elsewhere = RemoteCoordinatorChatReadPoint(eventID: "claude:other", timestamp: Self.start.addingTimeInterval(10))
        #expect(CoordinatorChatReadPoint.isNewer(elsewhere, than: last, in: rows))
        #expect(CoordinatorChatReadPoint.isNewer(last, than: elsewhere, in: rows) == false)
        #expect(CoordinatorChatReadPoint.newer(first, last, in: rows) == last)
        #expect(CoordinatorChatReadPoint.newer(last, first, in: rows) == last)
    }

    // MARK: - The saved read point

    /// Toastty saved the read point as a time before it named rows. That
    /// value still places the line after an update, by its time, and the
    /// next read adds the row's event. A value that an older Toastty moved
    /// since is read by its time again.
    @MainActor
    @Test func theSavedReadPointSurvivesTheMoveToTheRowsEventAndAnOlderToastty() throws {
        let suiteName = "toastty.tests.coordinator-read-point.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rows = (1 ... 3).map { Self.row(UInt64($0), .assistantMessage(text: "M\($0)", phase: .final)) }

        // Nothing saved: nothing read.
        #expect(CoordinatorChatReadThrough(defaults: defaults).point == nil)

        // The value an earlier Toastty saved.
        defaults.set(rows[0].timestamp.timeIntervalSinceReferenceDate, forKey: CoordinatorChatReadThrough.timeDefaultsKey)
        let migrated = CoordinatorChatReadThrough(defaults: defaults)
        #expect(migrated.point == RemoteCoordinatorChatReadPoint(eventID: nil, timestamp: rows[0].timestamp))
        #expect(CoordinatorChatReadPoint.marker(in: rows, after: migrated.point)
            == ToasttyNewMessagesMarker(firstRowID: Self.rowID(2), count: 2))

        // A read saves the row's event with its time, and never goes back.
        #expect(migrated.advance(to: Self.readPoint(rows[1])) { CoordinatorChatReadPoint.index(of: $0, in: rows) })
        #expect(migrated.advance(to: Self.readPoint(rows[0])) { CoordinatorChatReadPoint.index(of: $0, in: rows) } == false)
        #expect(migrated.point == Self.readPoint(rows[1]))
        let relaunched = CoordinatorChatReadThrough(defaults: defaults)
        #expect(relaunched.point == Self.readPoint(rows[1]))
        #expect(defaults.double(forKey: CoordinatorChatReadThrough.timeDefaultsKey)
            == rows[1].timestamp.timeIntervalSinceReferenceDate)

        // An older Toastty read further and saved only the time: the event
        // saved with the earlier time no longer counts.
        defaults.set(rows[2].timestamp.timeIntervalSinceReferenceDate, forKey: CoordinatorChatReadThrough.timeDefaultsKey)
        #expect(CoordinatorChatReadThrough(defaults: defaults).point
            == RemoteCoordinatorChatReadPoint(eventID: nil, timestamp: rows[2].timestamp))
    }
}

extension LocalConversationFixture {
    /// Sends a device's read of the coordinator's chat through the
    /// gateway's own request handler, as a socket would.
    func gatewayCoordinatorChatRead(
        _ request: RemoteCoordinatorChatReadRequest,
        credential: String?
    ) throws -> (status: Int, result: RemoteCoordinatorChatReadResult?) {
        var headers = ["tailscale-user-login": "owner@example.com"]
        if let credential { headers["authorization"] = "Bearer \(credential)" }
        let http = RemoteGatewayHTTPRequest(
            method: "POST",
            path: RemoteCoordinatorChatReadPolicy.readPath,
            headers: headers,
            body: try ConversationEventCoding.makeEncoder().encode(request)
        )
        guard case .respond(let response) = gatewayHandler.handle(http, at: .now) else {
            throw LocalConversationFixtureError.unexpectedGatewayOutcome
        }
        let decoded = try? ConversationEventCoding.makeDecoder().decode(
            RemoteCoordinatorChatReadResponse.self, from: response.body
        )
        return (response.status, decoded?.result)
    }

    /// The capabilities the gateway's hello advertises.
    func gatewayCapabilities() -> [RemoteGatewayCapability] {
        let http = RemoteGatewayHTTPRequest(method: "GET", path: "/api/hello", headers: [:], body: Data())
        guard case .respond(let response) = gatewayHandler.handle(http, at: .now),
              let hello = try? ConversationEventCoding.makeDecoder().decode(RemoteGatewayHelloResponse.self, from: response.body)
        else { return [] }
        return hello.capabilities
    }
}
