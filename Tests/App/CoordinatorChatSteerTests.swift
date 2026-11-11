@testable import ToasttyApp
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
import Testing

/// Steering the coordinator's running turn from its chat, with the real
/// controller, store, session store, terminal registry and
/// `RemoteAccessService`, as the send path tests use them. The agent is
/// Codex, which takes a steer.
///
/// Only the user's own messages steer: a message from the chat's composer,
/// and "Steer now" on a waiting message of the user's. Quick entry,
/// `coordinator send` and Toastty's digests always wait for an open prompt.
@Suite(.serialized)
struct CoordinatorChatSteerTests {
    // MARK: - The composer

    @MainActor
    @Test func returnSteersTheRunningTurnWhileOtherSendersWaitInTheQueue() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        // No turn runs: the composer offers no choice, and Send types at the
        // open prompt.
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        #expect(fixture.chat.delivery == nil)
        #expect(fixture.controller.canSteer == false)

        try await startTurnTheChatHasRead(fixture)
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: true, canSteer: true))

        // A message from coordinator send, one from quick entry and a digest
        // wait for the prompt, also now that the turn takes a steer.
        #expect(try fixture.controller.send("From coordinator send", id: "cli-1") == .queued(position: 1, hold: .busy))
        // A quick entry message waits even when its sender asks to steer.
        let quickEntry = CoordinatorUserMessage(text: "From quick entry", quickEntry: .init())
        #expect(try await fixture.controller.sendUserMessage(quickEntry, steering: true) == .queued(position: 2, hold: .busy))
        #expect(try fixture.controller.send(CoordinatorChatSendPathTests.digest, queueWhenHeld: false) == .held(.busy))
        #expect(fixture.delivered.texts.isEmpty)

        // Return in the composer: the message goes into the running turn,
        // in front of what waits.
        fixture.chat.draft = "Also check the docs"
        fixture.chat.send()
        #expect(fixture.chat.draft.isEmpty)
        #expect(fixture.delivered.texts == ["Also check the docs"])
        #expect(fixture.controller.queuedEntries.map(\.id) == ["cli-1", quickEntry.id.uuidString])
        let steered = try #require(fixture.typed.last)
        #expect(steered.text == "Also check the docs")
        #expect(fixture.controller.didType(messageID: steered.id))
        // A person sent it.
        #expect(fixture.conversations.service.lastRemoteUserInputAt(panelID: fixture.panelID) != nil)
        // The chat shows it as sent until the conversation does, and then
        // says that it steered the turn.
        #expect(fixture.chat.presentation.sendItems.first?.text == "Also check the docs")
        #expect(fixture.chat.presentation.sendItems.first?.sentCaption == "steered")
        try fixture.recordUserMessage("Also check the docs")
        try await fixture.waitUntil("the steered message in the conversation") {
            fixture.chat.presentation.rows.last?.content
                == .userMessage(text: "Also check the docs", origin: .local, deliveryMode: .steer)
        }
        // Neither waiting row offers Steer now, and the controller refuses
        // it: a quick entry message is the user's, but it always waits.
        let waiting = fixture.chat.presentation.sendItems.compactMap { item -> ToasttyQueuedSendPresentation? in
            guard case .queued(let queued) = item.content else { return nil }
            return queued
        }
        #expect(waiting.count == 2 && waiting.allSatisfy { $0.canSteer == false })
        #expect(throws: CoordinatorError.self) { try fixture.controller.steerQueuedEntry(id: quickEntry.id.uuidString) }
        #expect(fixture.delivered.texts == ["Also check the docs"])

        // The turn ends: what waits is typed as before, one message for
        // each open prompt, in order.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the message from coordinator send") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts.last == "From coordinator send")
        try fixture.runTurn(2, userText: "From coordinator send")
        try await fixture.waitUntil("the quick entry message") { fixture.delivered.texts.count == 3 }
        #expect(fixture.delivered.texts.last?.hasSuffix("\nFrom quick entry") == true)
        #expect(fixture.typedThroughStatusGate.isEmpty)
    }

    @MainActor
    @Test func queueOnTheChipOrCommandReturnQueuesAndSteerNowTakesAWaitingMessageIntoTheTurn() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await startTurnTheChatHasRead(fixture)
        #expect(fixture.chat.delivery?.steers == true)

        // Queue on the chip: the message waits, and the next one steers
        // again.
        fixture.chat.queueSelected = true
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: false, canSteer: true))
        #expect(CoordinatorComposerView.sendLabel(fixture.chat.delivery) == "Queue")
        fixture.chat.draft = "First"
        fixture.chat.send()
        #expect(fixture.chat.queueSelected == false)
        #expect(fixture.chat.delivery?.steers == true)
        // Command-Return queues, whatever the chip shows.
        fixture.chat.draft = "Second"
        fixture.chat.send(queueing: true)
        #expect(try fixture.controller.send("From coordinator send", id: "cli-1").isQueued)
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.queuedEntries.map(\.text) == ["First", "Second", "From coordinator send"])

        // The user's waiting messages offer Steer now. Another sender's
        // does not.
        func offersSteer() -> [String: Bool] {
            fixture.chat.presentation.sendItems.reduce(into: [:]) { offers, item in
                guard case .queued(let queued) = item.content else { return }
                offers[item.text] = queued.canSteer
            }
        }
        try await fixture.waitUntil("the rows") { offersSteer().count == 3 }
        #expect(offersSteer() == ["First": true, "Second": true, "From coordinator send": false])
        #expect(throws: CoordinatorError.self) { try fixture.controller.steerQueuedEntry(id: "cli-1") }
        #expect(fixture.delivered.texts.isEmpty)

        // Steer now on the second: it goes into the turn and leaves the
        // queue.
        let second = fixture.controller.queuedEntries[1].id
        fixture.chat.perform(.steer(clientRequestID: second, text: "Second"))
        #expect(fixture.chat.notice == nil)
        #expect(fixture.delivered.texts == ["Second"])
        #expect(fixture.typed.last?.id == second)
        #expect(fixture.controller.queuedEntries.map(\.text) == ["First", "From coordinator send"])
        try await fixture.waitUntil("the rows without it") {
            fixture.chat.presentation.sendItems.filter(\.isQueued).map(\.text) == ["First", "From coordinator send"]
        }

        // The turn ends: the rest waits its turn as before.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the first message") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts.last == "First")
    }

    // MARK: - When the turn cannot take a steer

    @MainActor
    @Test func theChipTheButtonAndTheSendFallBackToQueueTogether() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await startTurnTheChatHasRead(fixture)

        // The agent asks for a permission, which the chat cannot answer.
        fixture.report(.needsApproval)
        #expect(fixture.controller.canSteer == false)
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: false, canSteer: false))
        #expect(CoordinatorComposerView.sendLabel(fixture.chat.delivery) == "Queue")
        fixture.chat.draft = "While it asks"
        fixture.chat.send()
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.queuedEntries.map(\.text) == ["While it asks"])
        let waiting = try #require(fixture.controller.queuedEntries.first)
        #expect(throws: CoordinatorError.self) { try fixture.controller.steerQueuedEntry(id: waiting.id) }
        #expect(fixture.controller.queuedEntries.map(\.id) == [waiting.id])

        // A key in the terminal touched the turn: a steer would add to the
        // user's own text there.
        fixture.report(.working)
        #expect(fixture.controller.canSteer)
        let registry = fixture.conversations.terminalRuntimeRegistry
        registry.handleLocalInput(for: fixture.panelID, kind: .key)
        try await fixture.waitUntil("the turn to refuse a steer") { fixture.controller.canSteer == false }
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: false, canSteer: false))
        #expect(try fixture.controller.sendUserText("After a key", steering: true, id: "after-key").isQueued)
        #expect(fixture.delivered.texts.isEmpty)
        try await fixture.waitUntil("rows without Steer now") {
            let queued = fixture.chat.presentation.sendItems.compactMap { item -> ToasttyQueuedSendPresentation? in
                guard case .queued(let queued) = item.content else { return nil }
                return queued
            }
            return queued.count == 2 && queued.allSatisfy { $0.canSteer == false }
        }
    }

    @MainActor
    @Test func aTurnWhoseTerminalRefusesASteerQueuesForTheRestOfIt() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await startTurnTheChatHasRead(fixture)
        let registry = fixture.conversations.terminalRuntimeRegistry

        // A terminal that is not ready for input takes no steer.
        registry.setAutomationPromptStateHandlerForTesting { _ in .unavailable }
        #expect(fixture.controller.canSteer == false)
        registry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        #expect(fixture.controller.canSteer)

        // The terminal refuses the text: the message waits, and the chip,
        // the button and the send say Queue for the rest of the turn.
        registry.setAutomationSendTextHandlerForTesting { _, _, _, _ in false }
        #expect(try fixture.controller.sendUserText("Refused", steering: true, id: "refused").isQueued)
        registry.setAutomationSendTextHandlerForTesting { text, _, _, _ in
            fixture.delivered.texts.append(text)
            return true
        }
        #expect(fixture.controller.canSteer == false)
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: false, canSteer: false))
        #expect(try fixture.controller.sendUserText("Next", steering: true, id: "next").isQueued)
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.queuedEntries.map(\.id) == ["refused", "next"])

        // The next turn takes a steer again.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the first waiting message") { fixture.delivered.texts == ["Refused"] }
        try fixture.startTurn(2, userText: "Refused")
        try await fixture.waitUntil("a turn that takes a steer") { fixture.controller.canSteer }
        #expect(fixture.chat.delivery?.steers == true)
    }

    // MARK: - The choice of Queue

    @MainActor
    @Test func aChoiceOfQueueEndsWithItsTurnAlsoWhileTheChatIsHidden() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await startTurnTheChatHasRead(fixture)
        let firstTurn = try #require(fixture.chat.summary?.inputControl?.turnEpoch)
        fixture.chat.queueSelected = true
        #expect(fixture.chat.delivery?.steers == false)

        // The user shows the terminal. The turn ends there, and the next
        // one starts.
        fixture.chat.hide()
        try fixture.endTurn(1)
        try fixture.startTurn(2, userText: "Typed in the terminal")
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the next turn in the chat") {
            fixture.chat.summary?.inputControl?.turnEpoch.map { $0 != firstTurn } == true
        }
        // Steer again, as the default.
        #expect(fixture.chat.queueSelected == false)
        #expect(fixture.chat.delivery?.steers == true)
    }

    @MainActor
    @Test func aChoiceOfQueueOutlastsAvailabilityChangesAndAFailedSend() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await startTurnTheChatHasRead(fixture)
        fixture.chat.queueSelected = true

        // The agent asks for a permission and then works on: the choice
        // stays. So it does when the chat hides and shows again.
        fixture.report(.needsApproval)
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: false, canSteer: false))
        fixture.report(.working)
        #expect(fixture.chat.queueSelected)
        #expect(fixture.chat.delivery == CoordinatorComposerDelivery(steers: false, canSteer: true))
        fixture.chat.hide()
        fixture.chat.show(panelID: fixture.panelID)
        #expect(fixture.chat.queueSelected)

        // A send that fails keeps the draft and the choice, and steers
        // nothing.
        var waiting: [String] = []
        for index in 0 ..< CoordinatorController.maximumQueuedEntries {
            waiting.append("waiting-\(index)")
            _ = try fixture.controller.sendUserText("Waiting \(index)", steering: false, id: waiting[index])
        }
        fixture.chat.draft = "After the turn"
        fixture.chat.send()
        guard case .failure? = fixture.chat.notice else {
            Issue.record("The full queue did not refuse the message")
            return
        }
        #expect(fixture.chat.draft == "After the turn")
        #expect(fixture.chat.queueSelected)
        #expect(fixture.delivered.texts.isEmpty)

        // A send that empties the draft ends the choice. The message waits.
        fixture.controller.removeQueuedEntry(id: waiting[0])
        fixture.chat.send()
        #expect(fixture.chat.draft.isEmpty)
        #expect(fixture.chat.queueSelected == false)
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.queuedEntries.last?.text == "After the turn")
    }

    // MARK: - Attached files

    /// The chat's composer sends files as their paths in the message's text,
    /// so such a message steers like any other. A quick entry message with
    /// files keeps Toastty's first line and waits, also after Edit put it
    /// back into the composer.
    @MainActor
    @Test func aMessageWithFilesFromTheComposerSteersAndAQuickEntryMessageWaits() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        try await startTurnTheChatHasRead(fixture)
        let draft = fixture.chat.attachmentDraft

        // Return with a file: the text and the file's path go into the turn.
        draft.attachText("error: socket closed", named: "terminal log.txt")
        fixture.chat.draft = "Look at this"
        #expect(fixture.chat.delivery?.steers == true)
        fixture.chat.send()
        try await fixture.waitUntil("the message with its file in the turn") { fixture.delivered.texts.count == 1 }
        let steered = try #require(fixture.delivered.texts.first)
        #expect(steered.hasPrefix("Look at this\n\nRead the following files attached to this message on this Mac:"))
        #expect(steered.contains("/terminal-log.txt`"))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(draft.attachments.isEmpty)
        #expect(fixture.chat.draft.isEmpty)

        // Command-Return with a file: it waits, and Steer now takes it in.
        draft.attachText("two", named: "two.txt")
        fixture.chat.draft = "And this"
        fixture.chat.send(queueing: true)
        let waiting = try await fixture.waitFor("the message waits") { fixture.controller.queuedEntries.first }
        #expect(waiting.canBeSteered)

        // A quick entry message with a file waits, also when its sender asks
        // to steer, and offers no Steer now.
        let source = URL(filePath: fixture.conversations.runtimeHome).appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: source)
        let quickEntry = CoordinatorUserMessage(text: "From quick entry", files: [source], quickEntry: .init())
        #expect(try await fixture.controller.sendUserMessage(quickEntry, steering: true).isQueued)
        try await fixture.waitUntil("Steer now on the chat's message only") {
            let offers = fixture.chat.presentation.sendItems.compactMap { item -> (String, Bool)? in
                guard case .queued(let queued) = item.content else { return nil }
                return (item.clientRequestID, queued.canSteer)
            }
            return offers.map(\.0) == [waiting.id, quickEntry.id.uuidString] && offers.map(\.1) == [true, false]
        }
        #expect(throws: CoordinatorError.self) { try fixture.controller.steerQueuedEntry(id: quickEntry.id.uuidString) }
        // Edit puts it back with Toastty's first line: sent from the
        // composer, it still waits.
        let quickEntryText = try #require(fixture.controller.queuedEntries.last?.text)
        #expect(try fixture.controller.sendUserText(quickEntryText, steering: true, id: "edited-quick-entry").isQueued)

        fixture.chat.perform(.steer(clientRequestID: waiting.id, text: "And this"))
        #expect(fixture.delivered.texts.count == 2)
        #expect(fixture.delivered.texts.last?.hasPrefix("And this\n\nRead the following files") == true)
        #expect(fixture.controller.queuedEntries.map(\.id) == [quickEntry.id.uuidString, "edited-quick-entry"])
    }

    /// A message from the terminal starts a turn, and the chat shows it. The
    /// session reports the turn before the transcript has the message, and
    /// the host matches each message it typed to the next user message in
    /// the transcript. A steer typed before the turn's own message is read
    /// would be matched to that message, and its echo would not confirm it.
    @MainActor
    private func startTurnTheChatHasRead(_ fixture: CoordinatorChatFixture) async throws {
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn and its message") {
            fixture.controller.canSteer && fixture.chat.presentation.rows.contains { row in
                row.content == .userMessage(text: "Check the tasks", origin: .unknown, deliveryMode: nil)
            }
        }
    }
}

