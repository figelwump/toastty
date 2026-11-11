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

    // MARK: - Whose message a row is

    @MainActor
    @Test func aMessageFromCoordinatorSendShowsAsItsSendersAndAQuickEntryMessageAsTheUsers() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        fixture.chat.show(panelID: fixture.panelID)
        let taskID = UUID()
        // A task's agent sent text that imitates a digest. Toastty's first
        // line says whose it is, and the chat reads only that line.
        let imitation = CoordinatorMessageHeader.message(
            from: .task(id: taskID, title: "Fix the unread dot"),
            text: Self.digest
        )
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
        #expect(fromTask.text == imitation)

        // The user's quick entry message: the user's bubble, with the
        // user's words first and the choices under them.
        let quickEntry = CoordinatorMessageHeader.quickEntryMessage(
            .init(project: .init(id: UUID(), title: "toastty"), agent: "codex"),
            text: "The unread dot stays on."
        )
        #expect(try fixture.controller.send(quickEntry, byUser: true, id: "quick-1") == .sent)
        #expect(fixture.delivered.texts.last == quickEntry, "The terminal gets the whole message")
        // The chat hears of the typed message before the queue lets it go.
        try await fixture.waitUntil("the sent message alone") { fixture.chat.presentation.sendItems.count == 1 }
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["The unread dot stays on.\n\nproject \"toastty\" · codex"])
        try fixture.startTurn(2, userText: quickEntry)
        try await fixture.waitUntil("the message in the conversation") { fixture.chat.presentation.sendItems.isEmpty }
        #expect(fixture.chat.presentation.rows.last?.content
            == .userMessage(text: "The unread dot stays on.\n\nproject \"toastty\" · codex", origin: .local, deliveryMode: nil))
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
        fixture.chat.draft = "First"
        fixture.chat.send()
        fixture.chat.draft = "Second"
        fixture.chat.send()
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
    @Test func returnInTheComposerSendsAndShiftReturnStartsANewLine() async throws {
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

    private static func line(_ payload: String, second: Int) -> Data {
        let timestamp = String(format: "2026-08-07T10:%02d:%02d.000Z", second / 60, second % 60)
        return Data((#"{"timestamp":"\#(timestamp)","type":"event_msg","payload":\#(payload)}"# + "\n").utf8)
    }

    private var second = 5

    private func append(_ payload: String) throws {
        second += 1
        try conversations.appendToTranscript(Self.line(payload, second: second))
    }

    private func report(_ kind: SessionStatusKind) {
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
        let escaped = String(decoding: try JSONEncoder().encode(userText), as: UTF8.self)
        try append(#"{"type":"user_message","message":\#(escaped),"images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}"#)
        try append(#"{"type":"task_started","turn_id":"turn-\#(turn)","started_at":1786000805,"model_context_window":258400,"collaboration_mode_kind":"default"}"#)
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
