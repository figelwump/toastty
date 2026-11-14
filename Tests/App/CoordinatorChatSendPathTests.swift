@testable import ToasttyApp
import AppKit
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
import SwiftUI
import Testing

/// The one way into the coordinator, with the real controller, store,
/// session store, terminal registry and `RemoteAccessService`. The agent is
/// one whose conversation Toastty reads, so every message is typed through
/// that conversation's send path, as a phone's message is.
@Suite(.serialized)
struct CoordinatorChatSendPathTests {
    static let digest = """
    \(CoordinatorWakeState.digestHeader)
    - [Fix the unread dot](toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F): needsYou (review) at 2026-11-09T18:02:11Z
    \(CoordinatorWakeState.digestFooter)
    """

    @MainActor
    @Test func restartReadsTheNewestPageBeforeShowingHistory() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        for index in 0 ..< 1_000 {
            try fixture.recordUserMessage("History message \(index)")
        }
        var firstShownMessages: [ToasttyTranscriptRow]?
        let observer = fixture.chat.$presentation.sink { presentation in
            guard firstShownMessages == nil,
                  presentation.rows.contains(where: { row in
                      if case .userMessage = row.content { return true }
                      return false
                  }) else { return }
            firstShownMessages = presentation.rows
        }
        defer { observer.cancel() }
        fixture.chat.show(panelID: fixture.panelID)
        // Replay can take much longer than a short pause between batches.
        // Advance the chat's clock while its reader still has work to do.
        fixture.clock.secondsAhead = 60
        try await fixture.waitUntil("the newest history message") {
            fixture.chat.presentation.rows.last?.content
                == .userMessage(text: "History message 999", origin: .unknown, deliveryMode: nil)
        }
        #expect(firstShownMessages?.last?.content
            == .userMessage(text: "History message 999", origin: .unknown, deliveryMode: nil))
        #expect(fixture.chat.presentation.rows.count <= CoordinatorChatModel.pageSize)
        #expect(fixture.chat.presentation.hasOlder)
        let newestRows = fixture.chat.presentation.rows
        fixture.chat.loadOlder()
        #expect(fixture.chat.presentation.rows.count > newestRows.count)
        #expect(fixture.chat.presentation.rows.suffix(newestRows.count) == newestRows[...])

        // Later output still appends; hiding and showing keeps loaded history.
        try fixture.recordUserMessage("Live message")
        try await fixture.waitUntil("the live message") {
            fixture.chat.presentation.rows.last?.content
                == .userMessage(text: "Live message", origin: .unknown, deliveryMode: nil)
        }
        let rows = fixture.chat.presentation.rows
        fixture.chat.hide()
        fixture.chat.show(panelID: fixture.panelID)
        #expect(fixture.chat.presentation.rows == rows)
    }

    @MainActor
    @Test func aMissingTranscriptDoesNotHideTheSessionAndItsLaterHistoryLoadsAsOnePage() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let path = fixture.conversations.resumeRecord.sessionFilePath
        try FileManager.default.removeItem(atPath: path)
        fixture.chat.show(panelID: fixture.panelID)
        fixture.clock.secondsAhead = 60
        try await fixture.waitUntil("a live session without a readable transcript") {
            fixture.chat.summary != nil && fixture.chat.presentation.phase == .live
        }
        fixture.report(.working)
        try await fixture.waitUntil("Stop while the transcript is missing") { fixture.chat.canStop }

        // A provider can report its path before it creates the file. When
        // it becomes readable, its first read must still have a boundary.
        try Data().write(to: URL(filePath: path))
        for index in 0 ..< 1_000 {
            try fixture.recordUserMessage("Delayed history \(index)")
        }
        try await fixture.waitUntil("the newest delayed message") {
            fixture.chat.presentation.rows.last?.content
                == .userMessage(text: "Delayed history 999", origin: .unknown, deliveryMode: nil)
        }
        #expect(fixture.chat.presentation.rows.count <= CoordinatorChatModel.pageSize)
        #expect(fixture.chat.presentation.hasOlder)
    }

    // MARK: - At an open prompt

    @MainActor
    @Test func aMessageFromTheComposerIsTypedAtAnOpenPromptAndShownUntilItsEcho() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }

        fixture.chat.draft = "  Summarize the open tasks\n"
        fixture.chat.send()
        #expect(fixture.chat.draft.isEmpty)
        #expect(fixture.delivered.texts == ["Summarize the open tasks"])
        #expect(fixture.typedThroughStatusGate.isEmpty)
        #expect(fixture.controller.queuedEntries.isEmpty)
        let typed = try #require(fixture.typed.first)
        #expect(fixture.controller.didType(messageID: typed.id))
        // A person sent it, from the composer.
        #expect(fixture.conversations.service.lastRemoteUserInputAt(panelID: fixture.panelID) != nil)
        // The chat shows it as sent until the conversation does. Then the
        // row is the conversation's, with no mark that says how it came.
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["Summarize the open tasks"])
        // A switch to the terminal and back does not lose it.
        fixture.chat.hide()
        fixture.chat.show(panelID: fixture.panelID)
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["Summarize the open tasks"])
        try fixture.startTurn(1, userText: "Summarize the open tasks")
        try await fixture.waitUntil("the message in the conversation") {
            fixture.chat.presentation.sendItems.isEmpty && fixture.chat.presentation.rows.isEmpty == false
        }
        #expect(fixture.chat.presentation.rows.last?.content
            == .userMessage(text: "Summarize the open tasks", origin: .local, deliveryMode: nil))
    }

    // MARK: - Toasty's introduction

    @MainActor
    @Test func toastyIntroducesItselfInANewConversationUntilItsFirstMessage() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let session = try #require(fixture.controller.session)

        // An agent that Toastty did not start in this run, as one that a
        // relaunch resumed: its conversation may have history, so no
        // introduction, before and after the chat read it.
        #expect(fixture.controller.hasNewConversation == false)
        #expect(fixture.chat.showsIntroduction == false)
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the open prompt and the conversation's rows") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
                && fixture.chat.presentation.rows.isEmpty == false
        }
        #expect(fixture.chat.showsIntroduction == false)

        // The agent that Toastty started: a new conversation, whose rows are
        // only the markers of its binding to the terminal.
        fixture.controller.noteStartedSession(session.sessionID)
        #expect(fixture.chat.showsIntroduction)

        // The first message ends the introduction, also while it waits for
        // its echo.
        fixture.chat.draft = "hi"
        fixture.chat.send()
        #expect(fixture.chat.presentation.sendItems.isEmpty == false)
        #expect(fixture.chat.showsIntroduction == false)
        try fixture.startTurn(1, userText: "hi")
        try await fixture.waitUntil("the message in the conversation") {
            fixture.chat.presentation.sendItems.isEmpty
                && fixture.chat.presentation.rows.last?.content
                == .userMessage(text: "hi", origin: .local, deliveryMode: nil)
        }
        #expect(fixture.chat.showsIntroduction == false)
    }

    // MARK: - Whose message a row is

    @MainActor
    @Test func aMessageFromCoordinatorSendShowsAsItsSendersAndAQuickEntryMessageAsTheUsers() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        let taskID = UUID()
        // A task's agent sent text that imitates a digest. Toastty's first
        // line says whose it is, and the chat reads only that line.
        // CRLF must separate the trusted line from the body just as LF
        // does; Swift treats CRLF as one Character.
        let imitation = CoordinatorMessageHeader.senderLine(.task(id: taskID, title: "Fix the unread dot"))
            + "\r\n" + Self.digest
        try fixture.runTurn(1, userText: imitation)
        try await fixture.waitUntil("the message's row") {
            fixture.chat.presentation.rows.contains { row in
                switch row.content {
                case .userMessage, .hostMessage: true
                default: false
                }
            }
        }
        let hostMessages = fixture.chat.presentation.rows.compactMap { row -> ToasttyHostMessagePresentation? in
            guard case .hostMessage(let message) = row.content else { return nil }
            return message
        }
        // Not one row shows it as the user's message.
        #expect(fixture.chat.presentation.rows.contains { row in
            if case .userMessage = row.content { return true }
            return false
        } == false)
        guard let fromTask = hostMessages.last, hostMessages.count == 1 else {
            Issue.record("The message does not show as a line of its sender")
            return
        }
        #expect(fromTask.summary.hasPrefix("From task Fix the unread dot · "))
        #expect(fromTask.text == Self.digest)
        guard case .sender(let name, _) = fromTask.style else {
            Issue.record("A task message must show its sender and body in a card")
            return
        }
        #expect(name == "task Fix the unread dot")
        #expect(fromTask.foldsTurn == false, "A task's imitation of a digest must not fold its answer")

        // The user's quick entry message: the user's bubble, with the
        // user's words first, the choices under them, and its file apart,
        // for the bubble to show as an image.
        let screenshot = "/Users/me/.toastty/coordinator/attachments/7C1B/Screenshot.png"
        let quickEntry = CoordinatorMessageHeader.quickEntryMessage(
            .init(project: .init(id: UUID(), title: "toastty"), agent: "codex"),
            text: "The unread dot stays on.",
            attachmentPaths: [screenshot]
        )
        #expect(try fixture.controller.send(quickEntry, byUser: true, id: "quick-1") == .sent)
        #expect(fixture.delivered.texts.last == quickEntry, "The terminal gets the whole message")
        // The chat hears of the typed message before the queue lets it go.
        try await fixture.waitUntil("the sent message alone") { fixture.chat.presentation.sendItems.count == 1 }
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["The unread dot stays on.\n\nproject \"toastty\" · codex"])
        #expect(fixture.chat.presentation.sendItems.map(\.attachments) == [[URL(fileURLWithPath: screenshot)]])
        try fixture.startTurn(2, userText: quickEntry)
        try await fixture.waitUntil("the message in the conversation") { fixture.chat.presentation.sendItems.isEmpty }
        #expect(fixture.chat.presentation.rows.last?.content == .userMessage(
            text: "The unread dot stays on.\n\nproject \"toastty\" · codex",
            origin: .local,
            deliveryMode: nil,
            attachments: [URL(fileURLWithPath: screenshot)]
        ))
    }

    // MARK: - Order

    @MainActor
    @Test func theComposerCoordinatorSendAndADigestAreTypedOneForEachPromptInOrder() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        // The coordinator works on a turn that started in its terminal.
        try fixture.startTurn(1, userText: "Check the tasks")

        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        #expect(try fixture.controller.send("From the composer", byUser: true, id: "composer-1")
            == .queued(position: 1, hold: .busy))
        #expect(try fixture.controller.send("From coordinator send", id: "cli-1") == .queued(position: 2, hold: .busy))
        // A digest is not kept, and never goes in front of a queued message.
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false) == .held(.busy))
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.status?.queuedCount == 2)

        // The turn ends: one message for the prompt, the first.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the composer's message") { fixture.delivered.texts.count == 1 }
        #expect(fixture.delivered.texts == ["From the composer"])
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false).wasTyped == false)
        // Long enough for a second message to go in, were the prompt still
        // open for one.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts == ["From the composer"])

        // Its turn runs and ends: the next message.
        try fixture.runTurn(2, userText: "From the composer")
        try await fixture.waitUntil("the message from coordinator send") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts == ["From the composer", "From coordinator send"])
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false).wasTyped == false)

        // The queue is empty and the prompt opens again: the digest, once.
        try fixture.runTurn(3, userText: "From coordinator send")
        try await fixture.waitUntil("the digest") {
            (try? fixture.controller.send(Self.digest, queueWhenHeld: false))?.wasTyped == true
        }
        #expect(fixture.delivered.texts == ["From the composer", "From coordinator send", Self.digest])
        // The caller offers the digest again on its next pass. It is not
        // typed a second time: its prompt is used.
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false).wasTyped == false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.count == 3)
        #expect(fixture.typedThroughStatusGate.isEmpty)
        #expect(fixture.typed.prefix(2).map(\.id) == ["composer-1", "cli-1"])
        #expect(fixture.typed.count == 3)
    }

    @MainActor
    @Test func aDigestIsTypedOnceWhenTheCallerOffersItManyTimes() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        // The caller offers the digest on every pass, about once a second.
        // However many offers follow the one that is typed, one is typed.
        var typedCount = 0
        for _ in 0 ..< 40 {
            if try fixture.controller.send(Self.digest, queueWhenHeld: false).wasTyped { typedCount += 1 }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(typedCount == 1)
        #expect(fixture.delivered.texts == [Self.digest])
    }

    // MARK: - An agent that waits in its terminal

    @MainActor
    @Test func anAgentThatHasNotReportedItsStartShowsThatItMayWaitInTheTerminal() async throws {
        // Toastty launched the agent, and the agent asks a question that
        // comes before its first report, such as Claude Code's folder-trust
        // or login question. Toastty has the conversation it made at the
        // launch, and nothing from the agent.
        let fixture = try CoordinatorChatFixture(agentReportsStart: false)
        defer { fixture.tearDown() }
        let session = try #require(fixture.controller.session)
        // Two seconds of the time the agent has to report are left.
        let grace = CoordinatorChatModel.startGrace
        fixture.clock.secondsAhead = session.startedAt.addingTimeInterval(grace - 2).timeIntervalSinceNow
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the conversation of the launch") { fixture.chat.summary?.state == .starting }
        #expect(fixture.controller.status?.agentState == .running)

        // The user's message waits, and the chat says what for.
        fixture.chat.draft = "What needs me?"
        fixture.chat.send()
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.status?.hold == .agentStarting)
        let waiting = try #require(fixture.chat.presentation.sendItems.last)
        guard case .queued(let queued) = waiting.content else {
            Issue.record("The message does not show as waiting")
            return
        }
        #expect(queued.waitingCaption == "Queued 1 \u{00B7} waits for the agent to start")
        #expect(fixture.chat.notice == .agentStarting)

        // The time is over and nothing else changed: the model says that
        // the notice did, and the notice names the terminal.
        var changes = 0
        let observer = fixture.chat.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        let changesBefore = changes
        #expect(fixture.chat.notice == .agentStarting)
        try await fixture.waitUntil("the notice that names the terminal") { changes > changesBefore }
        #expect(fixture.chat.notice == .startWaitsInTerminal)
        if #available(macOS 15.0, *) {
            #expect(CoordinatorChatView.text(for: .startWaitsInTerminal).contains("answer in the terminal"))
        }
        #expect(fixture.delivered.texts.isEmpty)

        // The user answered in the terminal and the agent reports its
        // start: the notice goes, and the message is typed.
        fixture.reportAgentStart()
        try await fixture.waitUntil("the waiting message") { fixture.delivered.texts == ["What needs me?"] }
        try await fixture.waitUntil("the notice to go") { fixture.chat.notice == nil }
    }

    @MainActor
    @Test func anAnswerInTheTerminalBeforeTheStartReportLeavesTheMessageForSendAnyway() async throws {
        // The agent asked a question of its start in the terminal. The
        // user's message waits in the chat.
        let fixture = try CoordinatorChatFixture(agentReportsStart: false)
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the conversation of the launch") { fixture.chat.summary?.state == .starting }
        fixture.chat.draft = "What needs me?"
        fixture.chat.send()
        #expect(fixture.controller.status?.hold == .agentStarting)
        #expect(fixture.chat.notice == .startWaitsInTerminal)

        // The user answers it there with keys, and the agent reports its
        // start. Toastty cannot tell those keys from a draft in the agent's
        // prompt: the notice about the start goes, and the one about a
        // draft in the terminal shows. Nothing is typed.
        fixture.conversations.terminalRuntimeRegistry.handleLocalInput(for: fixture.panelID, kind: .key)
        fixture.reportAgentStart()
        try await fixture.waitUntil("the notice about a draft") { fixture.chat.notice == .terminalDraft }
        #expect(fixture.controller.status?.hold == .userDraft)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)

        // "Send Anyway": the waiting message is typed, once.
        fixture.chat.sendPastTerminalDraft()
        try await fixture.waitUntil("the waiting message") { fixture.delivered.texts == ["What needs me?"] }
        try await fixture.waitUntil("the notice to go") { fixture.chat.notice == nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts == ["What needs me?"])
    }

    @MainActor
    @Test func aDraftSentInTheTerminalAfterTheStartReportLetsTheWaitingMessageGoOnce() async throws {
        // The keys before the start report were a draft for the agent, and
        // the user sends it in the terminal instead of Send Anyway.
        let fixture = try CoordinatorChatFixture(agentReportsStart: false)
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the conversation of the launch") { fixture.chat.summary?.state == .starting }
        #expect(try fixture.controller.send("What needs me?", byUser: true, id: "first")
            == .queued(position: 1, hold: .agentStarting))
        fixture.conversations.terminalRuntimeRegistry.handleLocalInput(for: fixture.panelID, kind: .key)
        fixture.reportAgentStart()
        try await fixture.waitUntil("the notice about a draft") { fixture.chat.notice == .terminalDraft }
        #expect(fixture.delivered.texts.isEmpty)

        // The draft's own turn runs and ends: the waiting message is typed
        // at the next prompt, once.
        try fixture.runTurn(1, userText: "Typed in the terminal")
        try await fixture.waitUntil("the waiting message") { fixture.delivered.texts == ["What needs me?"] }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts == ["What needs me?"])
        #expect(fixture.typedThroughStatusGate.isEmpty)
    }

    // MARK: - The user's text in the terminal

    @MainActor
    @Test func textTypedInTheTerminalHoldsMessagesUntilTheUserReleasesIt() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        // The chat does not show. The controller reads the conversation
        // all the same, so a key in the terminal is seen.
        try await fixture.waitUntil("the open prompt") { fixture.controller.promptIsOpenForTesting }
        fixture.conversations.terminalRuntimeRegistry.handleLocalInput(for: fixture.panelID, kind: .key)
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false) == .held(.userDraft))

        fixture.chat.show(panelID: fixture.panelID)
        #expect(try fixture.controller.send("From the composer", byUser: true, id: "composer-1")
            == .queued(position: 1, hold: .userDraft))
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false) == .held(.userDraft))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.chat.notice == .terminalDraft)

        // "Send Anyway": the user says the prompt holds none of their text.
        fixture.chat.sendPastTerminalDraft()
        #expect(fixture.delivered.texts == ["From the composer"])
        try await fixture.waitUntil("the notice to go") { fixture.chat.notice == nil }
    }

    // MARK: - Stop

    @MainActor
    @Test func stopEndsTheTurnAndSetsWaitingMessagesAside() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        var interrupts = 0
        fixture.conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { panelID in
            #expect(panelID == fixture.panelID)
            interrupts += 1
            return true
        }
        fixture.chat.show(panelID: fixture.panelID)
        // No turn runs: nothing to stop.
        #expect(throws: CoordinatorError.self) { try fixture.controller.stopTurn() }
        #expect(fixture.chat.canStop == false)

        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        #expect(try fixture.controller.send("First", byUser: true, id: "first").isQueued)
        #expect(try fixture.controller.send("Second", byUser: true, id: "second").isQueued)

        fixture.chat.stop()
        #expect(interrupts == 1)
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(fixture.controller.pausedEntries.map(\.id) == ["first", "second"])
        #expect(fixture.controller.status?.queuedCount == 2)

        // The stopped turn ends. Nothing that waited starts a new turn.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
        // A digest does not wait for messages that the user set aside.
        #expect(try fixture.controller.send(Self.digest, queueWhenHeld: false) == .sent)
        #expect(fixture.delivered.texts == [Self.digest])

        // "Send next": they go again, in their order, one for each prompt.
        try fixture.runTurn(2, userText: Self.digest)
        fixture.chat.perform(.resume)
        try await fixture.waitUntil("the first message") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts.last == "First")
        #expect(fixture.controller.queuedEntries.map(\.id) == ["second"])
        try fixture.runTurn(3, userText: "First")
        try await fixture.waitUntil("the second message") { fixture.delivered.texts.count == 3 }
        #expect(fixture.delivered.texts.last == "Second")
    }

    @MainActor
    @Test func aWaitingMessageCanBeRemovedOrTakenBackIntoTheComposer() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        // Command-Return: while a turn runs, Return would steer it.
        fixture.chat.draft = "First"
        fixture.chat.send(queueing: true)
        fixture.chat.draft = "Second"
        fixture.chat.send(queueing: true)
        #expect(fixture.chat.draft.isEmpty)
        let ids = fixture.controller.queuedEntries.map(\.id)
        #expect(fixture.controller.queuedEntries.map(\.text) == ["First", "Second"])
        // The chat lists them as waiting, in order.
        let queued = fixture.chat.presentation.sendItems.filter(\.isQueued)
        #expect(queued.map(\.text) == ["First", "Second"])

        fixture.chat.perform(.remove(clientRequestID: ids[0]))
        fixture.chat.perform(.edit(clientRequestID: ids[1], text: "Second"))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(fixture.chat.draft == "Second")
        #expect(fixture.chat.presentation.sendItems.isEmpty)

        try fixture.endTurn(1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
    }

    // MARK: - Replies

    /// Reply on the coordinator's message: the message bar shows it, the
    /// typed text quotes it whole after Toastty's line, and the row shows
    /// the user's text with a quote that opens the message.
    @MainActor
    @Test func aReplyQuotesTheWholeMessageAndItsRowOpensIt() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        let answer = "I made two tasks.\n\n- Fix the unread dot\n\nShould the dot clear on hover, or only on click?"
        try fixture.startTurn(1, userText: "Make the tasks")
        try fixture.recordAgentMessage(answer)
        try fixture.endTurn(1)
        let agentRow = try await fixture.waitFor("the coordinator's message") {
            fixture.chat.presentation.rows.first { row in
                if case .assistantMessage(answer, _) = row.content { return true }
                return false
            }
        }
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }

        fixture.chat.reply(to: ToasttyMessageReplyRequest(rowID: agentRow.id, text: answer, timestamp: agentRow.timestamp))
        // On one line, as the reply's first line writes it: a narrow space
        // before "AM" becomes a plain one.
        let time = CoordinatorMessageHeader.replyTime(agentRow.timestamp.formatted(date: .omitted, time: .shortened))
        #expect(time.contains("\u{202F}") == false)
        #expect(fixture.chat.replyTarget == CoordinatorReplyTarget(text: answer, time: time))
        fixture.chat.draft = "Only on click."
        fixture.chat.send()

        let typed = CoordinatorMessageHeader.replyMessage(quote: answer, time: time, text: "Only on click.")
        #expect(fixture.delivered.texts == [typed])
        #expect(typed.hasPrefix("[Toastty] Reply from the user | quotes your message of \(time), 5 lines\n> I made two tasks.\n>\n"))
        #expect(fixture.chat.draft.isEmpty)
        #expect(fixture.chat.replyTarget == nil)
        // Until the conversation shows it, the bubble shows the quote too.
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["Only on click."])
        #expect(fixture.chat.presentation.sendItems.first?.quote?.text == answer)

        try fixture.startTurn(2, userText: typed)
        try await fixture.waitUntil("the reply in the conversation") {
            fixture.chat.presentation.sendItems.isEmpty
        }
        #expect(fixture.chat.presentation.rows.last { if case .userMessage = $0.content { true } else { false } }?.content
            == .userMessage(
                text: "Only on click.",
                origin: .local,
                deliveryMode: nil,
                quote: ToasttyMessageQuote(text: answer, timeText: time, sourceRowID: agentRow.id)
            ))
    }

    /// Two messages with one text: the quote opens the one the user replied
    /// to, by its time.
    @MainActor
    @Test func aReplysQuoteOpensTheMessageOfItsTimeWhenTwoSayTheSame() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check task one")
        try fixture.recordAgentMessage("Merge it now?")
        try fixture.endTurn(1)
        fixture.advanceTranscriptClock(seconds: 120)
        try fixture.startTurn(2, userText: "Check task two")
        try fixture.recordAgentMessage("Merge it now?")
        try fixture.endTurn(2)
        let agentRows = try await fixture.waitFor("both messages") { () -> [ToasttyTranscriptRow]? in
            let rows = fixture.chat.presentation.rows.filter {
                if case .assistantMessage("Merge it now?", _) = $0.content { return true }
                return false
            }
            return rows.count == 2 ? rows : nil
        }
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        let earlier = agentRows[0]
        fixture.chat.reply(to: ToasttyMessageReplyRequest(rowID: earlier.id, text: "Merge it now?", timestamp: earlier.timestamp))
        fixture.chat.draft = "Not this one."
        fixture.chat.send()
        let typed = try #require(fixture.delivered.texts.first)
        try fixture.startTurn(3, userText: typed)
        let quote = try await fixture.waitFor("the reply's row") { () -> ToasttyMessageQuote? in
            for row in fixture.chat.presentation.rows {
                if case .userMessage(_, _, _, let quote?, _) = row.content { return quote }
            }
            return nil
        }
        #expect(quote.sourceRowID == earlier.id)
    }

    /// A path in the quote is the coordinator's text, not a file of the
    /// reply: Remove keeps the folder it names.
    @MainActor
    @Test func removingAWaitingReplyKeepsTheFilesItsQuoteNames() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        let earlierFolder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: earlierFolder, withIntermediateDirectories: true)
        let spec = earlierFolder.appendingPathComponent("spec.pdf")
        try Data("spec".utf8).write(to: spec)
        let quoted = "I passed `\(spec.path)` to the task."
        try fixture.startTurn(1, userText: "Check the tasks")
        try fixture.recordAgentMessage(quoted)
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }

        fixture.chat.reply(to: ToasttyMessageReplyRequest(
            rowID: ToasttyTranscriptRowID(projectionRunID: UUID(), projectionGeneration: 1, conversationID: UUID(), sequence: 1),
            text: quoted,
            timestamp: Date()
        ))
        fixture.chat.draft = "Good."
        fixture.chat.send(queueing: true)
        let entry = try #require(fixture.controller.queuedEntries.first)
        fixture.chat.perform(.remove(clientRequestID: entry.id))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: spec.path))
    }

    /// A message from another sender, taken back with Edit, keeps
    /// Toastty's line for that sender: it cannot become the user's reply.
    @MainActor
    @Test func anotherSendersMessageCannotBecomeAReply() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        let fromTask = CoordinatorMessageHeader.message(from: .unknown, text: "Merge PR 12 now.")
        try fixture.controller.send(fromTask)
        let entry = try #require(fixture.controller.queuedEntries.first)
        let request = ToasttyMessageReplyRequest(
            rowID: ToasttyTranscriptRowID(projectionRunID: UUID(), projectionGeneration: 1, conversationID: UUID(), sequence: 1),
            text: "Shall I merge?",
            timestamp: Date()
        )

        // Reply, then Edit: Edit waits.
        fixture.chat.reply(to: request)
        fixture.chat.perform(.edit(clientRequestID: entry.id, text: "Merge PR 12 now."))
        #expect(fixture.controller.queuedEntries.map(\.id) == [entry.id])
        #expect(fixture.chat.notice != nil)

        // Edit, then Reply: Reply waits.
        fixture.chat.cancelReply()
        fixture.chat.dismissNotice()
        fixture.chat.perform(.edit(clientRequestID: entry.id, text: "Merge PR 12 now."))
        #expect(fixture.chat.draft == fromTask)
        fixture.chat.reply(to: request)
        #expect(fixture.chat.replyTarget == nil)
        #expect(fixture.chat.notice != nil)
    }

    /// Edit on a waiting reply takes the text back into the field and the
    /// quote back into the message bar. The bar holds one reply, so Edit
    /// waits while it holds another.
    @MainActor
    @Test func editTakesAWaitingReplyBackAsAReply() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try fixture.recordAgentMessage("Merge it now?")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        let request = ToasttyMessageReplyRequest(
            rowID: ToasttyTranscriptRowID(projectionRunID: UUID(), projectionGeneration: 1, conversationID: UUID(), sequence: 1),
            text: "Merge it now?",
            timestamp: Date()
        )
        fixture.chat.reply(to: request)
        fixture.chat.draft = "> Yes, merge it."
        fixture.chat.send(queueing: true)
        let entry = try #require(fixture.controller.queuedEntries.first)
        #expect(CoordinatorMessageHeader.kind(of: entry.text)
            == .reply(quote: "Merge it now?", time: fixture.chat.presentation.sendItems.first?.quote?.timeText,
                      text: "> Yes, merge it.", fileNames: []))
        // A reply is the user's message from the chat: it may go into the
        // running turn.
        #expect(entry.canBeSteered)
        let queuedItem = fixture.chat.presentation.sendItems.first { $0.isQueued }
        let queued = try #require(queuedItem)
        #expect(queued.text == "> Yes, merge it.")
        #expect(queued.quote?.text == "Merge it now?")

        // The bar replies to another message: Edit waits.
        fixture.chat.reply(to: ToasttyMessageReplyRequest(rowID: request.rowID, text: "Something else", timestamp: Date()))
        fixture.chat.perform(.edit(clientRequestID: entry.id, text: queued.text))
        #expect(fixture.controller.queuedEntries.map(\.id) == [entry.id])
        #expect(fixture.chat.notice != nil)

        fixture.chat.cancelReply()
        fixture.chat.perform(.edit(clientRequestID: entry.id, text: queued.text))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(fixture.chat.draft == "> Yes, merge it.")
        #expect(fixture.chat.replyTarget?.text == "Merge it now?")

        try fixture.endTurn(1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
    }

    // MARK: - Files

    @MainActor
    @Test func aMessageWithFilesFromTheComposerNamesTheCoordinatorsCopiesWithoutAHeader() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        let sourceFolder = URL(filePath: fixture.conversations.runtimeHome + "-attached")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let notes = sourceFolder.appendingPathComponent("notes.txt")
        try Data("socket closed".utf8).write(to: notes)
        let draft = fixture.chat.attachmentDraft

        // A pasted image, and a file dropped on the chat. Pasted text stays
        // text.
        let text = QuickEntryTests.pasteboard()
        text.setString("alt text", forType: .string)
        text.setData(try QuickEntryTests.pngData(), forType: .png)
        #expect(draft.pasteAttachments(from: text) == false)
        let image = QuickEntryTests.pasteboard()
        image.setData(try QuickEntryTests.pngData(), forType: .png)
        #expect(draft.pasteAttachments(from: image))
        let drop = QuickEntryTests.pasteboard()
        drop.writeObjects([notes as NSURL])
        #expect(fixture.chat.attachmentDropTarget.performDrop(drop))
        fixture.chat.draft = "What is wrong here?"
        // A file still being copied holds the message back.
        #expect(fixture.chat.canSend == false)
        try await fixture.waitUntil("both files are in the composer") { draft.attachments.count == 2 }
        #expect(draft.attachments.map(\.displayName) == ["Pasted image.png", "notes.txt"])
        #expect(draft.attachments.first?.thumbnail != nil)
        let draftCopies = draft.attachments.map(\.url)

        fixture.chat.send()
        try await fixture.waitUntil("the message is typed") { fixture.delivered.texts.count == 1 }
        let id = try #require(fixture.typed.first?.id)
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(id)").path
        // No header line: the message is the user's, from the chat.
        #expect(fixture.delivered.texts == ["""
        What is wrong here?

        Read the following files attached to this message on this Mac:
        `\(folder)/Pasted-image.png`
        `\(folder)/notes.txt`
        """])
        #expect(FileManager.default.fileExists(atPath: "\(folder)/notes.txt"))
        // The chat shows the text, and the files apart from it.
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["What is wrong here?"])
        #expect(fixture.chat.presentation.sendItems.map(\.attachments)
            == [["\(folder)/Pasted-image.png", "\(folder)/notes.txt"].map { URL(fileURLWithPath: $0) }])
        // The composer is empty, and its own copies are gone.
        #expect(fixture.chat.draft.isEmpty)
        #expect(draft.attachments.isEmpty)
        #expect(fixture.chat.isSendingFiles == false)
        #expect(draftCopies.allSatisfy { FileManager.default.fileExists(atPath: $0.path) == false })
    }

    @MainActor
    @Test func filesAloneWaitAsAMessageAndRemoveTakesTheirCopies() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        fixture.chat.attachmentDraft.attachText("error: socket closed", named: "terminal log.txt")
        #expect(fixture.chat.canSend)
        // Command-Return: while a turn runs, Return would steer it.
        fixture.chat.send(queueing: true)
        let entry = try await fixture.waitFor("the message waits") { fixture.controller.queuedEntries.first }
        let row = try #require(fixture.chat.presentation.sendItems.first { $0.isQueued })
        #expect(row.text == "terminal-log.txt")
        guard case .queued(let queued) = row.content else {
            Issue.record("The message waits")
            return
        }
        #expect(queued.attachmentCount == 1)
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(entry.id)")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("terminal-log.txt").path))

        fixture.chat.perform(.remove(clientRequestID: entry.id))
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
        try fixture.endTurn(1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
    }

    @MainActor
    @Test func editWaitsUntilTheMessagesFilesFitNextToTheComposers() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        let draft = fixture.chat.attachmentDraft
        draft.attachText("one", named: "one.txt")
        draft.attachText("two", named: "two.txt")
        fixture.chat.draft = "Two files"
        // Command-Return: while a turn runs, Return would steer it.
        fixture.chat.send(queueing: true)
        let entry = try await fixture.waitFor("the message waits") { fixture.controller.queuedEntries.first }

        // Nine files in the composer leave room for one: the message's two
        // do not fit, so it keeps waiting and the composer is as it was.
        for index in 0 ..< 9 {
            draft.attachText("\(index)", named: "note.txt")
        }
        fixture.chat.draft = "Draft"
        fixture.chat.perform(.edit(clientRequestID: entry.id, text: ""))
        #expect(fixture.controller.queuedEntries.map(\.id) == [entry.id])
        #expect(fixture.chat.draft == "Draft")
        #expect(draft.attachments.count == 9)
        #expect(fixture.chat.notice == .failure(
            "This message has 2 files, and a message can have at most 10. Remove files from the message you are writing first."
        ))

        // With room, Edit takes it back: its text in front, its files first.
        for attachment in draft.attachments.dropFirst() {
            draft.remove(id: attachment.id)
        }
        fixture.chat.perform(.edit(clientRequestID: entry.id, text: ""))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(fixture.chat.draft == "Two files\nDraft")
        #expect(draft.attachments.map(\.displayName) == ["one.txt", "two.txt", "note.txt"])
        #expect(draft.attachments.map(\.isDraftCopy) == [false, false, true])
    }

    // MARK: - A paired phone

    @MainActor
    @Test func aPhonesQueuedMessageIsTypedBeforeTheMacs() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        fixture.conversations.enableGateway()
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        let turnEpoch = try await fixture.waitFor("the running turn") {
            fixture.chat.summary?.inputControl?.turnEpoch
        }
        let conversationID = try #require(fixture.chat.summary?.conversationID)

        // The Mac's message is first in time, the phone's second.
        #expect(try fixture.controller.send("From the Mac", byUser: true, id: "mac-1").isQueued)
        let fromPhone = try fixture.conversations.gatewaySend(RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "phone-1",
            expectedInputEpoch: turnEpoch, text: "From the phone", deliveryMode: .queue
        ), credential: fixture.conversations.nativeCredential)
        #expect(fromPhone.result == .queued(position: 1))
        try await fixture.waitUntil("the chat to list both") {
            fixture.chat.presentation.sendItems.filter(\.isQueued).count == 2
        }
        // The phone's message is listed first and the chat cannot change it.
        let queued = fixture.chat.presentation.sendItems.compactMap { item -> (String, Bool)? in
            guard case .queued(let presentation) = item.content else { return nil }
            return (item.text, presentation.canChange)
        }
        #expect(queued.map(\.0) == ["From the phone", "From the Mac"])
        #expect(queued.map(\.1) == [false, true])

        // One prompt, one message: the phone's. Its turn, then the Mac's.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the phone's message") { fixture.delivered.texts.count == 1 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts == ["From the phone"])
        try fixture.runTurn(2, userText: "From the phone")
        try await fixture.waitUntil("the Mac's message") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts == ["From the phone", "From the Mac"])
    }

    // MARK: - Quiet wake turns

    /// Toastty's wakes for the fixture's coordinator, over task states the
    /// test changes, wired as the app wires them.
    @MainActor
    private final class Wakes {
        let service = TaskWebhookService(
            webhooksFileURL: nil,
            outboxFileURL: nil,
            secrets: InMemoryTaskWebhookSecretStore(),
            timing: .init(passInterval: .seconds(3600), startupDelay: 0, settleInterval: 0)
        )
        private final class States {
            var value: [UUID: TaskWebhookTaskState] = [:]
        }
        private let states = States()
        private let task = UUID()

        init(_ fixture: CoordinatorChatFixture) {
            service.taskStates = { [states] in states.value }
            service.attach(coordinator: fixture.controller)
            fixture.conversations.sessionRuntimeStore.isQuietTurnEnd = { [weak controller = fixture.controller] sessionID in
                controller?.turnEndsQuietly(sessionID: sessionID) ?? false
            }
            states.value[task] = state("running")
            service.pass()
        }

        private func state(_ group: String, _ attention: String? = nil) -> TaskWebhookTaskState {
            TaskWebhookTaskState(key: .init(group: group, attention: attention), title: "Fix the unread dot")
        }

        /// The task moves into Needs you for this reason, and the pass
        /// types a digest at the coordinator's open prompt.
        func taskNeedsYou(_ attention: String) {
            states.value[task] = state("needsYou", attention)
            service.pass()
        }
    }

    @MainActor
    private func panelIsUnread(_ fixture: CoordinatorChatFixture) throws -> Bool {
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        return fixture.store.state.workspacesByID[workspaceID]?.unreadPanelIDs.contains(fixture.panelID) == true
    }

    @MainActor
    private func statusKind(_ fixture: CoordinatorChatFixture) -> SessionStatusKind? {
        fixture.conversations.sessionRuntimeStore.sessionRegistry.sessionsByID[fixture.conversations.sessionID]?.status?.kind
    }

    @MainActor
    @Test func aQuietWakeTurnFoldsUnderItsLineAndItsEndAlertsNobody() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        let wakes = Wakes(fixture)
        // As in the app, the session store marks a turn's end in the
        // windows' state.
        fixture.conversations.sessionRuntimeStore.bind(store: fixture.store)
        // The user works in another workspace, so the coordinator's panel is
        // not in front: a turn's end marks it unread, also when the test
        // host is the active app.
        let window = try #require(fixture.store.state.windows.first)
        let elsewhere = try #require(window.workspaceIDs.first { $0 != fixture.store.state.coordinatorWorkspaceID })
        #expect(fixture.store.send(.selectWorkspace(windowID: window.id, workspaceID: elsewhere)))
        // No wake has started a turn: nothing can be quiet.
        #expect(throws: CoordinatorError.self) { try wakes.service.setCoordinatorWake(.clear, quiet: true) }

        // A wake. In its turn, with no other message in it, the coordinator
        // finds nothing for the user and says so.
        wakes.taskNeedsYou("agentFinished")
        let digest = try #require(fixture.delivered.texts.last)
        #expect(digest.hasPrefix(CoordinatorWakeState.digestPrefix))
        try fixture.startTurn(1, userText: digest)
        try await fixture.waitUntil("the wake turn") {
            fixture.chat.presentation.rows.contains { if case .hostMessage = $0.content { true } else { false } }
                && fixture.chat.summary?.state == .working
        }
        try wakes.service.setCoordinatorWake(.clear, quiet: true)
        #expect(fixture.controller.isQuietDigest(digest))
        try fixture.recordAgentMessage("Nothing needs you.")
        fixture.report(.ready)
        // Its end marks nothing unread: the session waits, not Ready.
        #expect(statusKind(fixture) == .idle)
        #expect(try panelIsUnread(fixture) == false)
        try fixture.endTurn(1)

        // The chat folds the whole turn, its answer too, under Toastty's
        // line, which opens it.
        let quietTurn = try await fixture.waitFor("the folded turn") { () -> ToasttyTranscriptTurn? in
            let state = fixture.chat.presentation
            guard let turn = state.turns.first(where: \.foldsWholeTurn),
                  let answer = state.rows.first(where: { row in
                      if case .assistantMessage(let text, _) = row.content { text == "Nothing needs you." } else { false }
                  }),
                  turn.workBlockIDs.contains(where: { $0.rowID == answer.id }) else { return nil }
            return turn
        }
        let digestRow = try #require(fixture.chat.presentation.rows.first { $0.id == quietTurn.id })
        guard case .hostMessage(let line) = digestRow.content else {
            Issue.record("The quiet turn does not start at Toastty's line")
            return
        }
        #expect(line.foldsTurn)
        #expect(line.summary.hasPrefix("Toastty · 1 update · "))

        // The next wake starts a normal turn. A message from the user comes
        // into it, so it cannot be quiet, and its end alerts as usual.
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        wakes.taskNeedsYou("review")
        let next = try #require(fixture.delivered.texts.last)
        #expect(next != digest)
        #expect(next.contains("needsYou (review)"))
        try fixture.startTurn(2, userText: next)
        try fixture.recordUserMessage("Is the release ready?")
        try await fixture.waitUntil("the user's message in the wake turn") {
            let last = fixture.chat.presentation.rows.last?.content
            guard case .userMessage(let text, _, _, _, _)? = last else { return false }
            return text == "Is the release ready?" && fixture.chat.summary?.state == .working
        }
        #expect(throws: CoordinatorError.self) { try wakes.service.setCoordinatorWake(.clear, quiet: true) }
        #expect(fixture.controller.isQuietDigest(next) == false)
        try fixture.recordAgentMessage("The release waits for your yes.")
        fixture.report(.ready)
        #expect(statusKind(fixture) == .ready)
        #expect(try panelIsUnread(fixture))
        try fixture.endTurn(2)
        try await fixture.waitUntil("the second turn's answer") {
            fixture.chat.presentation.rows.contains {
                if case .assistantMessage(let text, _) = $0.content { text == "The release waits for your yes." } else { false }
            }
        }
        let hostLines = fixture.chat.presentation.rows.compactMap { row -> ToasttyHostMessagePresentation? in
            if case .hostMessage(let line) = row.content { return line }
            return nil
        }
        #expect(hostLines.map(\.foldsTurn) == [true, false])
        #expect(fixture.chat.presentation.turns.filter(\.foldsWholeTurn).count == 1)

        // A quiet mark, then the user steers from the chat. The transcript
        // has not shown the message yet, and still the turn's end alerts.
        func quietWakeTurn(_ turn: Int, _ attention: String) async throws -> String {
            try await fixture.waitUntil("the open prompt") {
                fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
            }
            wakes.taskNeedsYou(attention)
            let digest = try #require(fixture.delivered.texts.last)
            try fixture.startTurn(turn, userText: digest)
            try await fixture.waitUntil("the wake turn the chat has read") {
                fixture.controller.canSteer && fixture.chat.presentation.rows.contains {
                    if case .hostMessage(let line) = $0.content { line.text == digest } else { false }
                }
            }
            try wakes.service.setCoordinatorWake(.clear, quiet: true)
            #expect(fixture.controller.turnEndsQuietly(sessionID: fixture.conversations.sessionID))
            return digest
        }
        _ = try await quietWakeTurn(3, "awaitingReply")
        fixture.chat.draft = "Wait, is the release ready?"
        fixture.chat.send()
        #expect(fixture.delivered.texts.last == "Wait, is the release ready?")
        #expect(fixture.controller.turnEndsQuietly(sessionID: fixture.conversations.sessionID) == false)
        try fixture.recordAgentMessage("The release waits for your yes.")
        fixture.report(.ready)
        #expect(statusKind(fixture) == .ready)
        try fixture.endTurn(3)

        // A quiet mark, then a person types in the coordinator's terminal,
        // which the transcript shows only later: the end alerts too.
        _ = try await quietWakeTurn(4, "agentError")
        fixture.conversations.sessionRuntimeStore.noteUserInput(panelID: fixture.panelID)
        #expect(fixture.controller.turnEndsQuietly(sessionID: fixture.conversations.sessionID) == false)
        try fixture.recordAgentMessage("Nothing needs you.")
        fixture.report(.ready)
        #expect(statusKind(fixture) == .ready)
        try fixture.endTurn(4)
    }

    // MARK: - How long the conversation is read

    @MainActor
    @Test func theConversationIsReadWhileTheCoordinatorsTerminalExists() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        // Remote Access is off. The controller reads the conversation of
        // the coordinator's terminal, with nothing waiting and no chat.
        #expect(fixture.conversations.service.activationState == .off)
        #expect(fixture.isReadingConversations)

        // The chat reads while it shows, and keeps its rows when it hides.
        try fixture.runTurn(1, userText: "Check the tasks")
        fixture.chat.show(panelID: fixture.panelID)
        #expect(fixture.chat.shownPanelID == fixture.panelID)
        try await fixture.waitUntil("the chat's rows") { fixture.chat.presentation.rows.isEmpty == false }
        // The view of another terminal, such as the one a restart
        // replaced, does not end this view's reading when it goes away.
        fixture.chat.hide(panelID: UUID())
        #expect(fixture.chat.shownPanelID == fixture.panelID)
        fixture.chat.hide(panelID: fixture.panelID)
        #expect(fixture.chat.shownPanelID == nil)
        #expect(fixture.chat.presentation.rows.isEmpty == false)
        #expect(fixture.isReadingConversations)

        // A message that waits is typed without the chat.
        try fixture.startTurn(2, userText: "More")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        #expect(try fixture.controller.send("Queued", id: "queued-1").isQueued)
        try fixture.endTurn(2)
        try await fixture.waitUntil("the queued message") { fixture.delivered.texts == ["Queued"] }
    }

    @MainActor
    @Test func closingTheCoordinatorsWorkspaceEndsReadingAndDropsWhatWaited() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        #expect(try fixture.controller.send("Queued", id: "queued-1").isQueued)
        fixture.chat.show(panelID: fixture.panelID)
        fixture.controller.showsTerminal = true

        let coordinator = try #require(fixture.store.state.coordinator)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: coordinator.workspaceID)))
        #expect(fixture.controller.status == nil)
        // The controller stops reading at once. The chat's view goes with
        // the workspace, and ends the chat's reading.
        fixture.chat.hide()
        #expect(fixture.isReadingConversations == false)
        // A coordinator opened later starts with the chat and an empty queue.
        #expect(fixture.controller.showsTerminal == false)
        #expect(throws: CoordinatorError.self) { try fixture.controller.send("Later") }
        #expect(fixture.controller.queuedEntries.isEmpty)
        try fixture.endTurn(1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
    }

    // MARK: - The composer's view

    @MainActor
    @Test func returnSendsOrSteersCommandReturnQueuesAndShiftReturnStartsANewLine() async throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let windowID = try #require(fixture.store.state.coordinator?.windowID)
        func host(isOnScreen: Bool) -> NSWindow {
            let view = CoordinatorChatView(
                model: fixture.chat,
                controller: fixture.controller,
                sessionRuntimeStore: fixture.conversations.sessionRuntimeStore,
                board: .disabled,
                store: fixture.store,
                panelID: fixture.panelID,
                windowID: windowID,
                isOnScreen: isOnScreen,
                hasPanelFocus: isOnScreen
            )
            .frame(width: 900, height: 600)
            .environment(\.colorScheme, .dark)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            return window
        }

        // A chat whose workspace is not the selected one stays mounted. It
        // does not read the conversation and does not take the keyboard.
        let hiddenWindow = host(isOnScreen: false)
        let hiddenComposer = try await fixture.waitFor("the hidden composer") { fixture.chat.composerTextView }
        try await Task.sleep(for: .milliseconds(300))
        #expect(hiddenWindow.firstResponder !== hiddenComposer)
        #expect(fixture.chat.shownPanelID == nil)
        hiddenWindow.close()

        let window = host(isOnScreen: true)
        defer { window.close() }
        // The view on screen reads the conversation and has the keyboard.
        try await fixture.waitUntil("the chat to read the conversation") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        let composer = try await fixture.waitFor("the composer") {
            fixture.chat.composerTextView.flatMap { $0.window === window ? $0 : nil }
        }
        #expect(composer is CoordinatorComposerTextView)
        try await fixture.waitUntil("the composer to take the keyboard") { window.firstResponder === composer }

        func key(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
        }
        // Return with nothing typed sends nothing.
        composer.keyDown(with: try key([]))
        #expect(fixture.delivered.texts.isEmpty)

        composer.insertText("First line", replacementRange: composer.selectedRange())
        composer.keyDown(with: try key(.shift))
        composer.insertText("second line", replacementRange: composer.selectedRange())
        #expect(fixture.chat.draft == "First line\nsecond line")
        #expect(fixture.delivered.texts.isEmpty)

        composer.keyDown(with: try key([]))
        #expect(fixture.delivered.texts == ["First line\nsecond line"])
        try await fixture.waitUntil("the composer to clear") { composer.string.isEmpty }
        #expect(fixture.chat.draft.isEmpty)

        // While a turn runs, Command-Return queues and Return steers.
        try fixture.startTurn(1, userText: "First line\nsecond line")
        try await fixture.waitUntil("the chip that says Steer") { fixture.chat.delivery?.steers == true }
        composer.insertText("After the turn", replacementRange: composer.selectedRange())
        composer.keyDown(with: try key(.command))
        try await fixture.waitUntil("the composer to clear") { composer.string.isEmpty }
        #expect(fixture.controller.queuedEntries.map(\.text) == ["After the turn"])
        composer.insertText("Into the turn", replacementRange: composer.selectedRange())
        composer.keyDown(with: try key([]))
        #expect(fixture.delivered.texts == ["First line\nsecond line", "Into the turn"])
        #expect(fixture.controller.queuedEntries.map(\.text) == ["After the turn"])
    }

    // MARK: - The keyboard and the covered terminal

    @MainActor
    @Test func textForTheCoveredTerminalDoesNotMoveTheKeyboardThere() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let registry = fixture.conversations.terminalRuntimeRegistry
        let other = UUID()
        var policies: [UUID: TerminalInputFocusPolicy] = [:]
        registry.setAutomationSendTextHandlerForTesting { _, _, panelID, focusPolicy in
            policies[panelID] = focusPolicy
            return true
        }
        let composerFocus = FocusRequests()
        let controller = fixture.controller
        registry.coveringInputFocus = { panelID in
            guard controller.coversTerminal(panelID: panelID) else { return nil }
            return {
                composerFocus.count += 1
                return true
            }
        }

        // The command that resumes the agent after a relaunch asks for the
        // keyboard. Under the chat it must not get it.
        #expect(registry.sendManagedAgentCommand("claude --resume x", panelID: fixture.panelID, focusPolicy: .focusTarget))
        #expect(registry.sendManagedAgentCommand("claude", panelID: other, focusPolicy: .focusTarget))
        #expect(policies[fixture.panelID] == .preserveFirstResponder)
        #expect(policies[other] == .focusTarget)
        // Focus for the covered terminal goes to the chat.
        #expect(registry.focusPanelIfPossible(panelID: fixture.panelID))
        #expect(composerFocus.count == 1)

        // With the terminal showing, it takes the keyboard as any terminal.
        fixture.controller.showsTerminal = true
        #expect(registry.sendManagedAgentCommand("claude", panelID: fixture.panelID, focusPolicy: .focusTarget))
        #expect(policies[fixture.panelID] == .focusTarget)
        _ = registry.focusPanelIfPossible(panelID: fixture.panelID)
        #expect(composerFocus.count == 1)
    }

    // MARK: - macOS 14

    @MainActor
    @Test func theTerminalShowsWhereTheChatIsNotSupported() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        // macOS 15 and later: the chat covers the coordinator's terminal,
        // and only that terminal.
        #expect(CoordinatorController.systemSupportsChat)
        #expect(fixture.controller.coversTerminal(panelID: fixture.panelID))
        #expect(fixture.controller.coversTerminal(panelID: UUID()) == false)
        // The switch in the panel's header.
        fixture.controller.showsTerminal = true
        #expect(fixture.controller.coversTerminal(panelID: fixture.panelID) == false)
        fixture.controller.showsTerminal = false

        // macOS 14: the terminal shows, whatever the switch says.
        fixture.controller.supportsChat = false
        #expect(fixture.controller.coversTerminal(panelID: fixture.panelID) == false)
    }
}

@MainActor
private final class FocusRequests {
    var count = 0
}

extension CoordinatorController.SendResult {
    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }
}

/// A coordinator whose agent is a Codex session with a transcript file, and
/// the chat model that shows it.
@MainActor
final class CoordinatorChatFixture {
    let conversations: LocalConversationFixture
    private(set) var controller: CoordinatorController
    private(set) var chat: CoordinatorChatModel
    let delivered: DeliveredText
    /// What the controller typed without the conversation. It must stay
    /// empty: this agent's conversation is read.
    var typedThroughStatusGate: [String] { gate.texts }
    private(set) var typed: [CoordinatorController.TypedEntry] = []
    private var typedObserver: Any?
    /// Where the controller saves the user's waiting messages, as the app
    /// does. `nil` saves none.
    let queueFileURL: URL?
    /// The coordinator's folder, which holds the attached files.
    var coordinatorDirectory: URL { Self.coordinatorDirectory(conversations) }

    /// The chat's clock, as seconds ahead of the real time.
    let clock = Clock()

    @MainActor
    final class Clock {
        var secondsAhead: TimeInterval = 0
        var now: Date { Date().addingTimeInterval(secondsAhead) }
    }

    /// Without `agentReportsStart`, Toastty launched the agent and the
    /// agent has reported nothing yet, as while it asks a question that
    /// comes before its first report. `reportAgentStart` reports then.
    init(pairsNativeDevice: Bool = false, savesQueue: Bool = false, agentReportsStart: Bool = true) throws {
        let conversations = try LocalConversationFixture(
            pairsNativeDevice: pairsNativeDevice,
            inCoordinatorWorkspace: true
        )
        self.conversations = conversations
        delivered = conversations.captureDeliveredText()
        let gate = StatusGateTyping()
        self.gate = gate
        // In a folder of its own, so a test can make it unwritable.
        queueFileURL = savesQueue
            ? URL(filePath: conversations.runtimeHome).appendingPathComponent("saved/coordinator-queue.json")
            : nil
        (controller, chat) = Self.makeController(conversations, gate: gate, queueFileURL: queueFileURL, clock: clock)
        typedObserver = controller.typedEntries.sink { [weak self] entry in self?.typed.append(entry) }
        if agentReportsStart { reportAgentStart() }
        #expect(conversations.store.state.coordinator?.panelID == conversations.panelID)
    }

    /// The agent reported its session, as its start hook does.
    func reportAgentStart() {
        #expect(conversations.confirmCurrentLaunchBinding())
    }

    private static func coordinatorDirectory(_ conversations: LocalConversationFixture) -> URL {
        URL(filePath: conversations.runtimeHome).appendingPathComponent("coordinator")
    }

    private static func makeController(
        _ conversations: LocalConversationFixture,
        gate: StatusGateTyping,
        queueFileURL: URL?,
        clock: Clock
    ) -> (CoordinatorController, CoordinatorChatModel) {
        let controller = CoordinatorController(
            store: conversations.store,
            sessionRuntimeStore: conversations.sessionRuntimeStore,
            launcher: nil,
            directoryURL: coordinatorDirectory(conversations),
            queueFileURL: queueFileURL,
            configLoader: { TasksConfig() },
            deliverText: { text, _ in
                gate.texts.append(text)
                return .delivered
            },
            promptState: { [weak registry = conversations.terminalRuntimeRegistry] panelID in
                registry?.promptState(panelID: panelID) ?? .unavailable
            }
        )
        controller.conversationAccess = conversations.service
        let chat = CoordinatorChatModel(controller: controller, access: conversations.service, now: { clock.now })
        controller.chat = chat
        return (controller, chat)
    }

    /// Toastty quit and launched again: a new controller over the same
    /// windows, the same agent conversation and the same saved queue. What
    /// the first controller held in memory is gone.
    func relaunch() {
        chat.hide()
        typedObserver = nil
        (controller, chat) = Self.makeController(conversations, gate: gate, queueFileURL: queueFileURL, clock: clock)
        typedObserver = controller.typedEntries.sink { [weak self] entry in self?.typed.append(entry) }
    }

    private let gate: StatusGateTyping

    @MainActor
    private final class StatusGateTyping {
        var texts: [String] = []
    }

    var store: AppStore { conversations.store }
    var panelID: UUID { conversations.panelID }

    /// Whether Toastty reads any conversation now. With Remote Access off,
    /// it does so only for an in-app subscriber.
    var isReadingConversations: Bool {
        conversations.terminalRuntimeRegistry.localInputObserver != nil
    }

    func tearDown() {
        chat.hide()
        conversations.removeRuntimeFiles()
    }

    // MARK: Transcript

    private static func line(_ payload: String, second: Int, type: String) -> Data {
        let timestamp = String(format: "2026-08-07T10:%02d:%02d.000Z", second / 60, second % 60)
        return Data((#"{"timestamp":"\#(timestamp)","type":"\#(type)","payload":\#(payload)}"# + "\n").utf8)
    }

    private var second = 5

    /// The transcript's next records are `seconds` later.
    func advanceTranscriptClock(seconds: Int) {
        second += seconds
    }

    private func append(_ payload: String, type: String = "event_msg") throws {
        second += 1
        try conversations.appendToTranscript(Self.line(payload, second: second, type: type))
    }

    /// The agent's message in the running turn, as Codex records it.
    func recordAgentMessage(_ text: String) throws {
        let escaped = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        try append(
            #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":\#(escaped)}]}"#,
            type: "response_item"
        )
    }

    func report(_ kind: SessionStatusKind) {
        conversations.sessionRuntimeStore.updateStatus(
            sessionID: conversations.sessionID,
            status: SessionStatus(kind: kind, summary: kind.rawValue),
            at: Date()
        )
    }

    /// A message started turn `turn`: the agent reports that it works, and
    /// its transcript records the message.
    func startTurn(_ turn: Int, userText: String) throws {
        report(.working)
        try recordUserMessage(userText)
        try append(#"{"type":"task_started","turn_id":"turn-\#(turn)","started_at":1786000805,"model_context_window":258400,"collaboration_mode_kind":"default"}"#)
    }

    /// The transcript records a user message, as Codex records a steer
    /// that it took into the running turn.
    func recordUserMessage(_ userText: String) throws {
        let escaped = String(decoding: try JSONEncoder().encode(userText), as: UTF8.self)
        try append(#"{"type":"user_message","message":\#(escaped),"images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}"#)
    }

    func endTurn(_ turn: Int) throws {
        report(.idle)
        try append(#"{"type":"task_complete","turn_id":"turn-\#(turn)","last_agent_message":"Done.","started_at":1786000805,"completed_at":1786000821,"duration_ms":16000}"#)
    }

    func runTurn(_ turn: Int, userText: String) throws {
        try startTurn(turn, userText: userText)
        try endTurn(turn)
    }

    // MARK: Waiting

    func waitFor<Value>(_ description: String, _ probe: @MainActor () -> Value?) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let value = probe() { return value }
        Issue.record("Timed out waiting for \(description)")
        throw LocalConversationFixtureError.timedOut
    }

    func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        _ = try await waitFor(description) { condition() ? true : nil }
    }
}
