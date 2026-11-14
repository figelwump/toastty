@testable import ToasttyApp
import CoreState
import Foundation
import RemoteProtocol
import Testing

/// In-app reads and sends through `LocalConversationAccess`, and how they
/// share conversation tracking with the Remote Access gateway.
@Suite(.serialized)
struct LocalConversationAccessTests {
    @MainActor
    @Test func initialReadCompletionNotifiesSubscribersForAnEmptyTranscript() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        #expect(subscription.isReadingInitialTranscript)
        let changes = ChangeCounter()
        let listener = Task { @MainActor in
            for await _ in subscription.changes { changes.count += 1 }
        }
        defer { listener.cancel(); subscription.cancel() }
        try await Self.waitUntil("initial read completion") {
            subscription.isReadingInitialTranscript == false && changes.count > 0
        }
        subscription.cancel()
        #expect(subscription.isReadingInitialTranscript == false)
    }

    // MARK: - Remote Access off

    @MainActor
    @Test func readsAConversationWhileRemoteAccessStaysOff() async throws {
        let fixture = try LocalConversationFixture(addsSecondAgentPanel: true)
        defer { fixture.removeRuntimeFiles() }
        try fixture.appendToTranscript(Self.userMessage("Fix the flicker", at: "2026-08-07T10:00:05.000Z"))

        // With no subscriber and the gateway off, nothing is tracked.
        #expect(fixture.terminalRuntimeRegistry.localInputObserver == nil)
        #expect(fixture.conversationID(ofPanel: fixture.panelID) == nil)

        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }

        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.conversationID(ofPanel: fixture.panelID) == conversationID)
        // Only the subscribed panel gets an identity.
        #expect(fixture.conversationID(ofPanel: try #require(fixture.secondPanelID)) == nil)

        let page = try await Self.waitForPage(subscription) { page in
            page.events.contains { Self.userText($0) == "Fix the flicker" }
        }
        #expect(page.conversationID == conversationID)
        let snapshot = try #require(subscription.snapshot(at: .now))
        #expect(snapshot.summary.conversationID == conversationID)
        #expect(snapshot.summary.provider == .codex)
        #expect(snapshot.summary.placement.panelID == fixture.panelID)
        #expect(snapshot.summary.latestSequence == page.latestSequence)
        guard case .page(let tail) = subscription.events(before: nil, limit: 50) else {
            Issue.record("Expected the newest page")
            return
        }
        #expect(tail.events == page.events)

        // The gateway did not start, and nothing was sent to it.
        #expect(fixture.service.activationState == .off)
        #expect(fixture.server.startCallCount == 0)
        #expect(fixture.server.broadcasts.isEmpty)
        #expect(fixture.service.writeControllableSessions.isEmpty)
    }

    @MainActor
    @Test func subscriberIsToldAboutNewEventsAndSummaryChanges() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let changes = ChangeCounter()
        let listener = Task { @MainActor in
            for await _ in subscription.changes { changes.count += 1 }
            changes.finished = true
        }
        defer { listener.cancel() }
        #expect(fixture.confirmCurrentLaunchBinding())

        // A new transcript line.
        let beforeEvent = changes.count
        try fixture.appendToTranscript(Self.userMessage("First message", at: "2026-08-07T10:00:05.000Z"))
        let first = try await Self.waitForPage(subscription) { page in
            page.events.contains { Self.userText($0) == "First message" }
        }
        try await Self.waitUntil("a change notice for the new event") { changes.count > beforeEvent }

        // A cursor read returns only what came after it.
        let cursor = ConversationEventCursor(
            projectionRunID: first.projectionRunID,
            projectionGeneration: first.projectionGeneration,
            afterSequence: first.latestSequence
        )
        try fixture.appendToTranscript(Self.userMessage("Second message", at: "2026-08-07T10:00:05.050Z"))
        let next = try await Self.waitFor("events after the cursor") { () -> ConversationEventPage? in
            guard case .page(let page) = subscription.events(after: cursor, limit: 50),
                  page.events.isEmpty == false else { return nil }
            return page
        }
        #expect(next.events.contains { Self.userText($0) == "Second message" })
        #expect(next.events.allSatisfy { $0.sequence > first.latestSequence })

        // A change with no transcript event: local typing closes the prompt.
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        try fixture.appendToTranscript(Self.taskComplete(at: "2026-08-07T10:00:21.000Z"))
        try await Self.waitUntil("the open prompt") {
            subscription.snapshot(at: .now)?.summary.inputAvailability.allowsRemoteSend == true
        }
        let beforeTyping = changes.count
        fixture.terminalRuntimeRegistry.handleLocalInput(for: fixture.panelID, kind: .key)
        try await Self.waitUntil("a change notice for the Mac draft") { changes.count > beforeTyping }
        guard case .localDraft = subscription.snapshot(at: .now)?.summary.inputAvailability else {
            Issue.record("Expected the Mac draft to close the prompt")
            return
        }

        subscription.cancel()
        try await Self.waitUntil("the end of the change stream") { changes.finished }
    }

    @MainActor
    @Test func sendsAtAnOpenPromptWithoutAPairedDevice() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = subscription.snapshot(at: .now)?.summary.inputAvailability else {
            Issue.record("Expected the open prompt")
            return
        }
        #expect(fixture.service.devices.isEmpty)

        // The prompt-epoch check is the phone's.
        #expect(subscription.send(.init(
            conversationID: conversationID, clientRequestID: "stale-epoch",
            expectedInputEpoch: epoch.next(), text: "Too late"
        ), byUser: false) == .rejected(reason: .epochMismatch))
        #expect(delivered.texts.isEmpty)

        let request = RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "mac-1",
            expectedInputEpoch: epoch, text: "Summarize the open tasks"
        )
        let sentAt = Date()
        #expect(subscription.send(request, byUser: false) == .accepted(epoch: epoch))
        #expect(delivered.texts == ["Summarize the open tasks"])
        #expect(subscription.send(request, byUser: false) == .duplicate)
        #expect(delivered.texts.count == 1)
        // The delivery consumed the prompt.
        #expect(subscription.snapshot(at: .now)?.summary.inputAvailability.allowsRemoteSend == false)
        // Toastty typed it, so an exit after the turn must see input, but
        // no person acted.
        #expect(fixture.service.hasRemoteInput(panelID: fixture.panelID, since: sentAt.addingTimeInterval(-1)))
        #expect(fixture.service.lastRemoteUserInputAt(panelID: fixture.panelID) == nil)

        // The provider's echo confirms the send under its request ID.
        try fixture.appendToTranscript(Self.userMessage(request.text, at: "2026-08-07T10:00:05.000Z"))
        let page = try await Self.waitForPage(subscription) { page in
            page.events.contains { Self.userText($0) == request.text }
        }
        #expect(page.events.contains { event in
            guard case .userMessage(let payload) = event.payload else { return false }
            return payload.clientRequestID == "mac-1"
        })
        #expect(fixture.server.broadcasts.isEmpty)
    }

    @MainActor
    @Test func aPersonsSendMovesTheLastUserInputTime() throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = subscription.snapshot(at: .now)?.summary.inputAvailability else {
            Issue.record("Expected the open prompt")
            return
        }
        let before = Date()
        #expect(subscription.send(.init(
            conversationID: conversationID, clientRequestID: "composer-1",
            expectedInputEpoch: epoch, text: "Typed in the chat composer"
        ), byUser: true) == .accepted(epoch: epoch))
        #expect(delivered.texts == ["Typed in the chat composer"])
        let userInputAt = try #require(fixture.service.lastRemoteUserInputAt(panelID: fixture.panelID))
        #expect(userInputAt >= before)
    }

    @MainActor
    @Test func queuesWhileBusySteersAndDeliversAtTheNextPrompt() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())

        // The Mac user starts a turn in the terminal.
        try fixture.appendToTranscript(Self.userMessage("Fix the flicker", at: "2026-08-07T10:00:05.000Z"))
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        let turnEpoch = try await Self.waitFor("the running turn") {
            subscription.snapshot(at: .now)?.summary.inputControl?.turnEpoch
        }
        let working = try #require(subscription.snapshot(at: .now)?.summary)
        #expect(working.inputControl?.canQueue == true)
        #expect(working.inputControl?.canSteer == true)

        // A prompt send is refused while the agent works.
        #expect(subscription.send(.init(
            conversationID: conversationID, clientRequestID: "prompt-while-busy",
            expectedInputEpoch: turnEpoch, text: "Now"
        ), byUser: false) == .rejected(reason: .promptNotOpen))

        // Queue: held, listed, not typed.
        let queued = RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "queued-1",
            expectedInputEpoch: turnEpoch, text: "Also add a UI test", deliveryMode: .queue
        )
        #expect(subscription.send(queued, byUser: false) == .queued(position: 1))
        #expect(subscription.send(queued, byUser: false) == .duplicate)
        #expect(subscription.snapshot(at: .now)?.summary.inputControl?.queuedMessages.map(\.clientRequestID) == ["queued-1"])
        #expect(delivered.texts.isEmpty)
        var staleBinding = queued
        staleBinding.clientRequestID = "stale-binding"
        staleBinding.expectedInputEpoch = RemoteInputEpoch(bindingID: UUID(), counter: 1)
        #expect(subscription.send(staleBinding, byUser: false) == .rejected(reason: .turnMismatch))

        // Steer: typed into the running turn now.
        let steer = RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "steer-1",
            expectedInputEpoch: turnEpoch, text: "Use 300 ms", deliveryMode: .steer
        )
        #expect(subscription.send(steer, byUser: false) == .accepted(epoch: turnEpoch))
        #expect(delivered.texts == ["Use 300 ms"])
        var wrongTurn = steer
        wrongTurn.clientRequestID = "steer-2"
        wrongTurn.expectedInputEpoch = turnEpoch.next()
        #expect(subscription.send(wrongTurn, byUser: false) == .rejected(reason: .turnMismatch))

        // The turn ends: the next prompt takes the queued message, once.
        try fixture.appendToTranscript(Self.taskComplete(at: "2026-08-07T10:00:21.000Z"))
        try await Self.waitUntil("the queued delivery") { delivered.texts.count == 2 }
        #expect(delivered.texts == ["Use 300 ms", "Also add a UI test"])
        let drained = try #require(subscription.snapshot(at: .now)?.summary)
        #expect(drained.inputControl?.queuedMessages.isEmpty == true)
        #expect(drained.inputAvailability.allowsRemoteSend == false)
        // No person sent any of it.
        #expect(fixture.service.lastRemoteUserInputAt(panelID: fixture.panelID) == nil)
        #expect(fixture.service.activationState == .off)
    }

    @MainActor
    @Test func noTrackingRemainsAfterTheSubscriberGoes() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        let second = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())
        try fixture.appendToTranscript(Self.userMessage("Go", at: "2026-08-07T10:00:05.000Z"))
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        let turnEpoch = try await Self.waitFor("the running turn") {
            subscription.snapshot(at: .now)?.summary.inputControl?.turnEpoch
        }
        let queued = RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "queued-then-left",
            expectedInputEpoch: turnEpoch, text: "Never typed", deliveryMode: .queue
        )
        #expect(subscription.send(queued, byUser: false) == .queued(position: 1))

        // Another subscriber still holds the panel.
        second.cancel()
        #expect(fixture.terminalRuntimeRegistry.localInputObserver != nil)
        #expect(subscription.snapshot(at: .now)?.summary.inputControl?.queuedMessages.count == 1)
        #expect(second.snapshot(at: .now) == nil)
        #expect(second.send(queued, byUser: false) == .rejected(reason: .notBound))

        subscription.cancel()
        #expect(fixture.terminalRuntimeRegistry.localInputObserver == nil)
        #expect(fixture.service.facadeConversationEvents(for: conversationID, after: nil, limit: 10) == .conversationNotFound)
        #expect(subscription.conversationID == nil)
        #expect(subscription.snapshot(at: .now) == nil)
        #expect(subscription.events(after: nil, limit: 10) == .conversationNotFound)
        #expect(subscription.send(queued, byUser: false) == .rejected(reason: .notBound))
        // The panel keeps its identity for a later subscriber.
        #expect(fixture.conversationID(ofPanel: fixture.panelID) == conversationID)

        // The prompt opens with no one tracking it: nothing is typed.
        try fixture.appendToTranscript(Self.taskComplete(at: "2026-08-07T10:00:21.000Z"))
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(delivered.texts.isEmpty)

        // A later subscriber reads the transcript again, without the
        // dropped message.
        let later = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { later.cancel() }
        #expect(later.conversationID == conversationID)
        _ = try await Self.waitForPage(later) { page in
            page.events.contains { Self.userText($0) == "Go" }
        }
        #expect(later.snapshot(at: .now)?.summary.inputControl?.queuedMessages.isEmpty == true)
        #expect(delivered.texts.isEmpty)
    }

    @MainActor
    @Test func releasingASubscriptionEndsItsTracking() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        var subscription: (any LocalConversationSubscription)? =
            fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        #expect(subscription?.conversationID != nil)
        #expect(fixture.terminalRuntimeRegistry.localInputObserver != nil)
        subscription = nil
        try await Self.waitUntil("tracking to end") {
            fixture.terminalRuntimeRegistry.localInputObserver == nil
        }
    }

    @MainActor
    @Test func restoredPanelKeepsItsConversationIDAndIsReadableWithoutAnAgent() async throws {
        // After a relaunch the panel has its saved identity and resume
        // record, and no agent runs in it yet.
        let saved = RemoteConversationID()
        let fixture = try LocalConversationFixture(startsSession: false, savedConversationID: saved)
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        try fixture.appendToTranscript(Self.userMessage("Before the relaunch", at: "2026-08-07T10:00:05.000Z"))

        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        #expect(subscription.conversationID == saved)
        #expect(fixture.conversationID(ofPanel: fixture.panelID) == saved)
        let page = try await Self.waitForPage(subscription) { page in
            page.events.contains { Self.userText($0) == "Before the relaunch" }
        }
        #expect(page.conversationID == saved)

        // History is readable, but nothing can be typed without an agent.
        let summary = try #require(subscription.snapshot(at: .now)?.summary)
        #expect(summary.inputAvailability.allowsRemoteSend == false)
        #expect(summary.inputControl?.canQueue == false)
        for mode in [RemoteMessageDeliveryMode.prompt, .queue, .steer] {
            #expect(subscription.send(.init(
                conversationID: saved, clientRequestID: "restored-\(mode.rawValue)",
                expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
                text: "No agent runs", deliveryMode: mode
            ), byUser: false) == .rejected(reason: .notBound))
        }
        #expect(delivered.texts.isEmpty)
    }

    // MARK: - Gateway transitions with a subscriber

    @MainActor
    @Test(arguments: [GatewayStop.disabled, .listenerFailed])
    func gatewayStoppingNarrowsTrackingToTheSubscribedPanel(stop: GatewayStop) async throws {
        let fixture = try LocalConversationFixture(addsSecondAgentPanel: true, pairsNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let secondPanelID = try #require(fixture.secondPanelID)
        fixture.enableGateway()
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        let otherConversationID = try #require(fixture.conversationID(ofPanel: secondPanelID))
        #expect(fixture.service.facadeConversationEvents(for: otherConversationID, after: nil, limit: 10) != .conversationNotFound)
        #expect(fixture.confirmCurrentLaunchBinding())

        try fixture.appendToTranscript(Self.userMessage("Go", at: "2026-08-07T10:00:05.000Z"))
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        let turnEpoch = try await Self.waitFor("the running turn") {
            subscription.snapshot(at: .now)?.summary.inputControl?.turnEpoch
        }
        // The phone and the Mac share one queue.
        #expect(fixture.service.performRemoteSend(.init(
            conversationID: conversationID, clientRequestID: "device-queued",
            expectedInputEpoch: turnEpoch, text: "From the phone", deliveryMode: .queue
        ), device: device) == .queued(position: 1))
        #expect(subscription.send(.init(
            conversationID: conversationID, clientRequestID: "mac-queued",
            expectedInputEpoch: turnEpoch, text: "From the Mac", deliveryMode: .queue
        ), byUser: false) == .queued(position: 2))
        let phoneSummary = try #require(fixture.service.facadeSessionList(at: .now).conversations.first {
            $0.conversationID == conversationID
        })
        #expect(phoneSummary.inputControl?.queuedMessages.map(\.clientRequestID) == ["device-queued", "mac-queued"])

        switch stop {
        case .disabled: fixture.service.setEnabled(false, persist: false)
        case .listenerFailed: fixture.server.reportFailure()
        }

        #expect(fixture.service.isEnabled == false)
        #expect(fixture.server.stopCallCount == 1)
        #expect(fixture.service.writeControllableSessions.isEmpty)
        // The subscribed panel stays tracked under the same identity.
        #expect(fixture.terminalRuntimeRegistry.localInputObserver != nil)
        #expect(subscription.conversationID == conversationID)
        // The other panel's conversation is gone.
        #expect(fixture.service.facadeConversationEvents(for: otherConversationID, after: nil, limit: 10) == .conversationNotFound)
        // The device's queued message is dropped and reported. The Mac's stays.
        #expect(subscription.snapshot(at: .now)?.summary.inputControl?.queuedMessages.map(\.clientRequestID) == ["mac-queued"])
        guard case .page(let page) = subscription.events(after: nil, limit: 200) else {
            Issue.record("Expected the subscribed conversation's events")
            return
        }
        #expect(page.events.contains { event in
            guard case .sendDeliveryUnconfirmed(let payload) = event.payload else { return false }
            return payload.clientRequestID == "device-queued"
        })
        // A device send is refused in every mode.
        for mode in [RemoteMessageDeliveryMode.prompt, .queue, .steer] {
            #expect(fixture.service.performRemoteSend(.init(
                conversationID: conversationID, clientRequestID: "device-after-off-\(mode.rawValue)",
                expectedInputEpoch: turnEpoch, text: "Refused", deliveryMode: mode
            ), device: device) == .rejected(reason: .notBound))
        }

        // The Mac's message is still delivered at the next prompt.
        try fixture.appendToTranscript(Self.taskComplete(at: "2026-08-07T10:00:21.000Z"))
        try await Self.waitUntil("the Mac's queued delivery") { delivered.texts.isEmpty == false }
        #expect(delivered.texts == ["From the Mac"])
    }

    @MainActor
    @Test func lastSubscriberLeavingWithTheGatewayOnDropsOnlyTheMacsQueuedMessages() async throws {
        let fixture = try LocalConversationFixture(pairsNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        fixture.enableGateway()
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())
        try fixture.appendToTranscript(Self.userMessage("Go", at: "2026-08-07T10:00:05.000Z"))
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        let turnEpoch = try await Self.waitFor("the running turn") {
            subscription.snapshot(at: .now)?.summary.inputControl?.turnEpoch
        }
        #expect(subscription.send(.init(
            conversationID: conversationID, clientRequestID: "mac-queued",
            expectedInputEpoch: turnEpoch, text: "From the Mac", deliveryMode: .queue
        ), byUser: false) == .queued(position: 1))
        #expect(fixture.service.performRemoteSend(.init(
            conversationID: conversationID, clientRequestID: "device-queued",
            expectedInputEpoch: turnEpoch, text: "From the phone", deliveryMode: .queue
        ), device: device) == .queued(position: 2))

        subscription.cancel()

        // The gateway still tracks the conversation, with the phone's message.
        #expect(fixture.terminalRuntimeRegistry.localInputObserver != nil)
        let phoneSummary = try #require(fixture.service.facadeSessionList(at: .now).conversations.first {
            $0.conversationID == conversationID
        })
        #expect(phoneSummary.inputControl?.queuedMessages.map(\.clientRequestID) == ["device-queued"])
        guard case .page(let page) = fixture.service.facadeConversationEvents(
            for: conversationID, after: nil, limit: 200
        ) else {
            Issue.record("Expected the gateway to keep the conversation")
            return
        }
        #expect(page.events.contains { event in
            guard case .sendDeliveryUnconfirmed(let payload) = event.payload else { return false }
            return payload.clientRequestID == "mac-queued"
        })

        try fixture.appendToTranscript(Self.taskComplete(at: "2026-08-07T10:00:21.000Z"))
        try await Self.waitUntil("the phone's queued delivery") { delivered.texts.isEmpty == false }
        #expect(delivered.texts == ["From the phone"])
    }

    @MainActor
    @Test func aPersonsQueuedMessageMovesTheUserInputTimeOnceAtEnqueue() async throws {
        let fixture = try LocalConversationFixture()
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())
        try fixture.appendToTranscript(Self.userMessage("Go", at: "2026-08-07T10:00:05.000Z"))
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        let turnEpoch = try await Self.waitFor("the running turn") {
            subscription.snapshot(at: .now)?.summary.inputControl?.turnEpoch
        }
        #expect(fixture.service.lastRemoteUserInputAt(panelID: fixture.panelID) == nil)
        #expect(subscription.send(.init(
            conversationID: conversationID, clientRequestID: "composer-queued",
            expectedInputEpoch: turnEpoch, text: "Queued by a person", deliveryMode: .queue
        ), byUser: true) == .queued(position: 1))
        let queuedAt = try #require(fixture.service.lastRemoteUserInputAt(panelID: fixture.panelID))

        // Toastty types it later. That delivery is not the person's action.
        try fixture.appendToTranscript(Self.taskComplete(at: "2026-08-07T10:00:21.000Z"))
        try await Self.waitUntil("the queued delivery") { delivered.texts.isEmpty == false }
        #expect(delivered.texts == ["Queued by a person"])
        #expect(fixture.service.lastRemoteUserInputAt(panelID: fixture.panelID) == queuedAt)
    }

    @MainActor
    @Test func gatewayTurningOnWithASubscriberKeepsOneTailerAndOneConversationID() async throws {
        let fixture = try LocalConversationFixture(addsSecondAgentPanel: true, pairsNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        let secondPanelID = try #require(fixture.secondPanelID)
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.conversationID(ofPanel: secondPanelID) == nil)
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = subscription.snapshot(at: .now)?.summary.inputAvailability else {
            Issue.record("Expected the open prompt")
            return
        }
        let request = RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "mac-before-gateway",
            expectedInputEpoch: epoch, text: "Sent before the gateway started"
        )
        #expect(subscription.send(request, byUser: false) == .accepted(epoch: epoch))
        guard case .page(let before) = subscription.events(after: nil, limit: 200) else {
            Issue.record("Expected events before the gateway started")
            return
        }
        let cursor = ConversationEventCursor(
            projectionRunID: before.projectionRunID,
            projectionGeneration: before.projectionGeneration,
            afterSequence: before.latestSequence
        )

        fixture.enableGateway()

        // One identity, and the same event sequence: the old cursor works.
        #expect(subscription.conversationID == conversationID)
        #expect(fixture.conversationID(ofPanel: fixture.panelID) == conversationID)
        guard case .page = subscription.events(after: cursor, limit: 200) else {
            Issue.record("The event sequence restarted when the gateway started")
            return
        }
        let listed = fixture.service.facadeSessionList(at: .now).conversations
        #expect(listed.filter { $0.conversationID == conversationID }.count == 1)
        // The gateway now tracks the other panel too.
        let otherConversationID = try #require(fixture.conversationID(ofPanel: secondPanelID))
        #expect(listed.contains { $0.conversationID == otherConversationID })

        // A second tailer would start from the first byte and drop the
        // pending send, so its echo would arrive without the request ID.
        try fixture.appendToTranscript(Self.userMessage(request.text, at: "2026-08-07T10:00:05.000Z"))
        let page = try await Self.waitForPage(subscription) { page in
            page.events.contains { Self.userText($0) == request.text }
        }
        let echoes = page.events.filter { Self.userText($0) == request.text }
        #expect(echoes.count == 1)
        guard case .userMessage(let echo) = try #require(echoes.first).payload else { return }
        #expect(echo.clientRequestID == "mac-before-gateway")
        #expect(delivered.texts == [request.text])

        // The phone's path works on the conversation the Mac already tracked.
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        try fixture.appendToTranscript(Self.taskStarted(at: "2026-08-07T10:00:05.100Z"))
        let turnEpoch = try await Self.waitFor("the running turn") {
            subscription.snapshot(at: .now)?.summary.inputControl?.turnEpoch
        }
        #expect(fixture.service.performRemoteSend(.init(
            conversationID: conversationID, clientRequestID: "device-after-on",
            expectedInputEpoch: turnEpoch, text: "From the phone", deliveryMode: .queue
        ), device: device) == .queued(position: 1))
    }

    // MARK: - Trust boundary

    @MainActor
    @Test func gatewayRequestsCannotUseTheMacOrigin() async throws {
        let fixture = try LocalConversationFixture(pairsNativeDevice: true)
        defer { fixture.removeRuntimeFiles() }
        let delivered = fixture.captureDeliveredText()
        fixture.enableGateway()
        let subscription = fixture.service.subscribeToConversation(inPanel: fixture.panelID)
        defer { subscription.cancel() }
        let conversationID = try #require(subscription.conversationID)
        #expect(fixture.confirmCurrentLaunchBinding())
        guard case .openPrompt(let epoch) = subscription.snapshot(at: .now)?.summary.inputAvailability else {
            Issue.record("Expected the open prompt")
            return
        }
        let credential = try #require(fixture.nativeCredential)
        let device = try #require(fixture.service.devices.first { $0.authKind == .native })
        func request(_ id: String) -> RemoteMessageSendRequest {
            RemoteMessageSendRequest(
                conversationID: conversationID, clientRequestID: id,
                expectedInputEpoch: epoch, text: "From the network"
            )
        }

        // The Mac could send at this prompt, but a request with no paired
        // device, or with an unknown credential, never reaches the send path.
        let unpaired = try fixture.gatewaySend(request("no-credential"), credential: nil)
        #expect(unpaired.status == 403)
        #expect(unpaired.result == nil)
        let unpairedBrowser = try fixture.gatewaySend(
            request("no-credential-allowed-origin"), credential: nil, origin: "http://127.0.0.1:42996"
        )
        #expect(unpairedBrowser.status == 401)
        #expect(unpairedBrowser.result == nil)
        let unknown = try fixture.gatewaySend(request("unknown-credential"), credential: "not-a-paired-device")
        #expect(unknown.status == 401)
        #expect(unknown.result == nil)
        #expect(delivered.texts.isEmpty)

        // A paired device still needs its own send scope.
        fixture.service.setDeviceSendScope(false, for: device.id)
        let unscoped = try fixture.gatewaySend(request("no-send-scope"), credential: credential)
        #expect(unscoped.status == 403)
        #expect(unscoped.result == .rejected(reason: .sendScopeDenied))
        let unscopedDevice = try #require(fixture.service.devices.first { $0.id == device.id })
        #expect(fixture.service.performRemoteSend(request("no-send-scope-direct"), device: unscopedDevice)
            == .rejected(reason: .sendScopeDenied))
        fixture.service.setDeviceSendScope(true, for: device.id)

        // The per-session write switch limits remote devices, not the Mac.
        fixture.service.setSessionWriteEnabled(false, for: conversationID)
        let readOnly = try fixture.gatewaySend(request("writes-disabled"), credential: credential)
        #expect(readOnly.status == 200)
        #expect(readOnly.result == .rejected(reason: .sessionWritesDisabled))
        let phoneSummary = try #require(fixture.service.facadeSessionList(at: .now).conversations.first {
            $0.conversationID == conversationID
        })
        #expect(phoneSummary.inputAvailability == .unavailable(reason: .sessionWritesDisabled))
        #expect(subscription.snapshot(at: .now)?.summary.inputAvailability == .openPrompt(epoch: epoch))
        #expect(delivered.texts.isEmpty)

        // With the gateway off, a paired device's request is refused while
        // the Mac's subscriber keeps the conversation tracked.
        fixture.service.setSessionWriteEnabled(true, for: conversationID)
        fixture.service.setEnabled(false, persist: false)
        #expect(subscription.snapshot(at: .now)?.summary.inputAvailability == .openPrompt(epoch: epoch))
        let afterOff = try fixture.gatewaySend(request("gateway-off"), credential: credential)
        #expect(afterOff.result == .rejected(reason: .notBound))
        #expect(delivered.texts.isEmpty)

        // Only the in-process subscription sends as the Mac.
        var macRequest = request("mac-origin")
        macRequest.text = "From the Mac"
        #expect(subscription.send(macRequest, byUser: false) == .accepted(epoch: epoch))
        #expect(delivered.texts == ["From the Mac"])
    }

    // MARK: - Helpers

    static func codexLine(_ payload: String, at timestamp: String) -> Data {
        Data((#"{"timestamp":"\#(timestamp)","type":"event_msg","payload":\#(payload)}"# + "\n").utf8)
    }

    static func userMessage(_ text: String, at timestamp: String) -> Data {
        codexLine(
            #"{"type":"user_message","message":"\#(text)","images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}"#,
            at: timestamp
        )
    }

    static func taskStarted(at timestamp: String) -> Data {
        codexLine(
            #"{"type":"task_started","turn_id":"turn-1","started_at":1786000805,"model_context_window":258400,"collaboration_mode_kind":"default"}"#,
            at: timestamp
        )
    }

    static func taskComplete(at timestamp: String) -> Data {
        codexLine(
            #"{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Done.","started_at":1786000805,"completed_at":1786000821,"duration_ms":16000}"#,
            at: timestamp
        )
    }

    private static func userText(_ event: ConversationEvent) -> String? {
        guard case .userMessage(let payload) = event.payload else { return nil }
        return payload.text
    }

    @MainActor
    static func waitFor<Value>(
        _ description: String,
        _ probe: @MainActor () -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let value = probe() { return value }
        Issue.record("Timed out waiting for \(description)")
        throw LocalConversationFixtureError.timedOut
    }

    @MainActor
    static func waitUntil(
        _ description: String,
        _ condition: @MainActor () -> Bool
    ) async throws {
        _ = try await waitFor(description) { condition() ? true : nil }
    }

    @MainActor
    private static func waitForPage(
        _ subscription: any LocalConversationSubscription,
        _ predicate: @MainActor (ConversationEventPage) -> Bool
    ) async throws -> ConversationEventPage {
        try await waitFor("conversation events") {
            guard case .page(let page) = subscription.events(after: nil, limit: 200),
                  predicate(page) else { return nil }
            return page
        }
    }
}

enum GatewayStop: Sendable {
    case disabled
    case listenerFailed
}

enum LocalConversationFixtureError: Error {
    case couldNotPublishResumeRecord
    case couldNotAddSecondPanel
    case timedOut
    case unexpectedGatewayOutcome
}

@MainActor
private final class ChangeCounter {
    var count = 0
    var finished = false
}

@MainActor
final class DeliveredText {
    var texts: [String] = []
}

/// One Codex session in the bootstrap panel, with Remote Access off until a
/// test turns it on. With `inCoordinatorWorkspace`, the session is in the
/// terminal of a coordinator's workspace instead.
@MainActor
final class LocalConversationFixture {
    let store: AppStore
    let sessionRuntimeStore: SessionRuntimeStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let server: LocalConversationGatewayServerSpy
    let gatewayHandler: RemoteGatewayRequestHandler
    let service: RemoteAccessService
    let panelID: UUID
    let secondPanelID: UUID?
    let sessionID: String
    let resumeRecord: ManagedAgentResumeRecord
    let confirmedAt: Date
    let runtimeHome: String
    let nativeCredential: String?
    private var transcript: FileHandle?

    init(
        addsSecondAgentPanel: Bool = false,
        pairsNativeDevice: Bool = false,
        startsSession: Bool = true,
        savedConversationID: RemoteConversationID? = nil,
        inCoordinatorWorkspace: Bool = false,
        initialTranscript: Data = Data()
    ) throws {
        store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        if inCoordinatorWorkspace {
            let windowID = try #require(store.state.windows.first?.id)
            #expect(store.send(.createCoordinatorWorkspace(
                windowID: windowID, workspaceID: UUID(), panelID: UUID(), terminalCWD: "/repo"
            )))
            let coordinator = try #require(store.state.coordinator)
            #expect(store.send(.selectWorkspace(windowID: windowID, workspaceID: coordinator.workspaceID)))
        }
        let selection = try #require(store.state.selectedWorkspaceSelection())
        panelID = try #require(selection.workspace.focusedPanelID)
        sessionID = "local-conversation-\(UUID().uuidString)"
        confirmedAt = Date(timeIntervalSince1970: 1_786_000_000)
        runtimeHome = "/tmp/toastty-local-conversation-\(UUID().uuidString)"
        let transcriptURL = URL(filePath: runtimeHome + "-transcript.jsonl")
        try initialTranscript.write(to: transcriptURL)
        resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "native-\(UUID().uuidString)",
            sessionFilePath: transcriptURL.path,
            cwd: "/repo",
            capturedAt: confirmedAt
        )

        sessionRuntimeStore = SessionRuntimeStore()
        if startsSession {
            sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: panelID,
                windowID: selection.windowID,
                workspaceID: selection.workspaceID,
                usesSessionStatusNotifications: false,
                codexStatusTrackingSource: .externallyReported,
                cwd: "/repo",
                repoRoot: "/repo",
                at: confirmedAt
            )
            sessionRuntimeStore.updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .idle, summary: "idle"),
                at: confirmedAt
            )
        }
        if let savedConversationID {
            _ = store.send(.updateTerminalPanelRemoteConversationID(
                panelID: panelID, remoteConversationID: savedConversationID
            ))
        }

        if addsSecondAgentPanel {
            let panelsBefore = Set(store.state.workspacesByID[selection.workspaceID]?.allPanelsByID.keys.map { $0 } ?? [])
            guard store.send(.createWorkspaceTab(workspaceID: selection.workspaceID, seed: nil, activate: false)),
                  let added = store.state.workspacesByID[selection.workspaceID]?.allPanelsByID.keys
                    .first(where: { panelsBefore.contains($0) == false }) else {
                throw LocalConversationFixtureError.couldNotAddSecondPanel
            }
            secondPanelID = added
            sessionRuntimeStore.startSession(
                sessionID: "local-conversation-other-\(UUID().uuidString)",
                agent: .codex,
                panelID: added,
                windowID: selection.windowID,
                workspaceID: selection.workspaceID,
                usesSessionStatusNotifications: false,
                codexStatusTrackingSource: .externallyReported,
                cwd: "/repo",
                repoRoot: "/repo",
                at: confirmedAt
            )
        } else {
            secondPanelID = nil
        }

        terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let gatewayServer = LocalConversationGatewayServerSpy()
        server = gatewayServer
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        if pairsNativeDevice {
            let devices = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
            let now = Date()
            let offer = try devices.issueNativePairingOffer(
                gatewayURL: URL(string: "https://test.tailnet.ts.net")!, at: now
            )
            guard case .paired(_, let token) = try devices.redeemNativePairingOffer(
                using: .qr(offerID: offer.id, secret: offer.qrPayload.secret),
                deviceName: "Test phone", tailscaleLogin: "owner@example.com", at: now
            ) else { throw CocoaError(.coderInvalidValue) }
            nativeCredential = token
        } else {
            nativeCredential = nil
        }
        var capturedHandler: RemoteGatewayRequestHandler?
        service = RemoteAccessService(
            store: store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            sessionRuntimeStore: sessionRuntimeStore,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            port: 42_996,
            initiallyEnabled: false,
            pushConfiguration: nil,
            gatewayServerFactory: { handler in
                capturedHandler = handler
                return gatewayServer
            }
        )
        gatewayHandler = try #require(capturedHandler)
        terminalRuntimeRegistry.setAutomationPromptStateHandlerForTesting { _ in .idleAtPrompt }
        guard publishResumeRecord(capturedAt: confirmedAt.addingTimeInterval(-60)) else {
            throw LocalConversationFixtureError.couldNotPublishResumeRecord
        }
    }

    func enableGateway() {
        service.setEnabled(true, persist: false)
        server.reportReady(port: 42_996)
    }

    /// Records what the service types into the terminal.
    func captureDeliveredText() -> DeliveredText {
        let delivered = DeliveredText()
        let expectedPanelID = panelID
        terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, submit, panelID, _ in
            #expect(submit)
            #expect(panelID == expectedPanelID)
            delivered.texts.append(text)
            return true
        }
        return delivered
    }

    func conversationID(ofPanel panelID: UUID) -> RemoteConversationID? {
        for workspace in store.state.workspacesByID.values {
            guard case .terminal(let terminalState) = workspace.allPanelsByID[panelID] else { continue }
            return terminalState.remoteConversationID
        }
        return nil
    }

    func appendToTranscript(_ data: Data) throws {
        if transcript == nil {
            let handle = try FileHandle(forWritingTo: URL(filePath: resumeRecord.sessionFilePath))
            try handle.seekToEnd()
            transcript = handle
        }
        try transcript?.write(contentsOf: data)
    }

    func confirmCurrentLaunchBinding() -> Bool {
        let confirmed = sessionRuntimeStore.confirmNativeSessionBinding(
            managedSessionID: sessionID,
            panelID: panelID,
            record: resumeRecord
        )
        let published = publishResumeRecord()
        return confirmed && published
    }

    func publishResumeRecord(capturedAt: Date? = nil) -> Bool {
        var record = resumeRecord
        if let capturedAt {
            record.capturedAt = capturedAt
        }
        return store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: record))
    }

    /// Sends through the gateway's own request handler, as a socket would.
    func gatewaySend(
        _ request: RemoteMessageSendRequest,
        credential: String?,
        origin: String? = nil
    ) throws -> (status: Int, result: RemoteMessageSendResult?) {
        var headers = ["tailscale-user-login": "owner@example.com"]
        if let credential { headers["authorization"] = "Bearer \(credential)" }
        if let origin { headers["origin"] = origin }
        let http = RemoteGatewayHTTPRequest(
            method: "POST",
            path: "/api/conversation.message.send",
            headers: headers,
            body: try ConversationEventCoding.makeEncoder().encode(request)
        )
        guard case .respond(let response) = gatewayHandler.handle(http, at: .now) else {
            throw LocalConversationFixtureError.unexpectedGatewayOutcome
        }
        let result = try? ConversationEventCoding.makeDecoder().decode(RemoteMessageSendResult.self, from: response.body)
        return (response.status, result)
    }

    func removeRuntimeFiles() {
        try? transcript?.close()
        service.setEnabled(false, persist: false)
        try? FileManager.default.removeItem(atPath: runtimeHome)
        try? FileManager.default.removeItem(atPath: resumeRecord.sessionFilePath)
    }
}

@MainActor
final class LocalConversationGatewayServerSpy: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: ((RemoteAccessListenerFailure) -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var broadcasts: [RemoteGatewayStreamMessage] = []

    func start(port _: UInt16) throws {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func disconnectWebSockets(for _: UUID) {}
    func disconnectAllWebSockets() {}

    func broadcast(_ message: RemoteGatewayStreamMessage) {
        broadcasts.append(message)
    }

    func reportReady(port: UInt16) {
        onListenerReady?(port)
    }

    func reportFailure() {
        onListenerFailed?(.unavailable)
    }
}
