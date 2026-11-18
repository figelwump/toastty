@testable import ToasttyApp
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The coordinator's own queue on a paired device: the read route, the
/// revision on the coordinator's workspace, and the device's Resume and
/// Remove, with the real controller, chat, session store and
/// `RemoteAccessService` behind the gateway's own request handler.
@Suite(.serialized)
struct CoordinatorQueueGatewayTests {
    // MARK: - Reading

    /// Only a Mac that installs the queue advertises it. The coordinator's
    /// workspace, and no other, carries the revision, and only a paired
    /// native device reads the queue: never a request without a credential,
    /// an unknown token or a revoked device.
    @MainActor
    @Test func onlyAPairedDeviceReadsTheQueueOfTheCoordinator() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        #expect(conversations.gatewayCapabilities().contains(.coordinatorQueue) == false)
        #expect(conversations.service.facadeSessionList(at: .now).workspaces.allSatisfy { $0.coordinatorQueueRevision == nil })
        #expect(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).status == 404)

        conversations.service.installCoordinatorQueue(from: fixture.controller)
        #expect(conversations.gatewayCapabilities().contains(.coordinatorQueue))
        fixture.chat.show(panelID: fixture.panelID)
        let conversationID = try await fixture.waitFor("the live conversation") {
            conversations.conversationID(ofPanel: fixture.panelID)
        }
        let published = conversations.service.facadeSessionList(at: .now).workspaces
            .filter { $0.coordinatorQueueRevision != nil }
        #expect(published.map(\.isCoordinator) == [true])

        // 0 entries: an empty queue, named by its revision.
        let empty = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        #expect(empty.entries.isEmpty)
        #expect(empty.heldSetToken == nil)
        #expect(empty.conversationID == conversationID)
        #expect(published.first?.coordinatorQueueRevision == empty.revision)

        #expect(try conversations.gatewayCoordinatorQueue(credential: nil).status == 401)
        #expect(try conversations.gatewayCoordinatorQueue(credential: "not-a-paired-device").status == 401)

        let device = try #require(conversations.service.devices.first { $0.authKind == .native })
        conversations.service.revokeDevice(device.id)
        #expect(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).status == 401)
    }

    /// A message waits in the queue as the Mac chat's waiting bubble shows
    /// it: the sender of a message that `coordinator send` brought, the
    /// quote of a reply, and the names of attached files, never their
    /// folder. The revision changes with the queue and a session list
    /// carries it, also while the Mac's chat is closed.
    @MainActor
    @Test func theQueueCarriesDisplayTextAndFileNamesWithoutPaths() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQuietDigests(from: fixture.controller)
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        let before = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)

        fixture.chat.attachmentDraft.attachText("error: socket closed", named: "terminal log.txt")
        fixture.chat.draft = "Look at this log"
        fixture.chat.send(queueing: true)
        let withFile = try await fixture.waitFor("the message with a file") { fixture.controller.queuedEntries.first }
        let fromTask = CoordinatorMessageHeader.message(
            from: .task(id: UUID(), title: "Fix the unread dot"), text: "The fix is ready for review."
        )
        #expect(try fixture.controller.send(fromTask, id: "from-task").isQueued)
        let reply = CoordinatorMessageHeader.replyMessage(quote: "Merge PR 431?", time: "9:41", text: "Yes, merge it.")
        #expect(try fixture.controller.sendUserText(reply, steering: false, id: "reply").isQueued)

        // The Mac's chat is closed: the queue still changes the revision.
        fixture.chat.hide()
        let beforeBroadcast = conversations.server.broadcasts.count
        #expect(try fixture.controller.send("After the chat closed", byUser: true, id: "closed").isQueued)
        try await fixture.waitUntil("a session list with the new revision") {
            conversations.server.broadcasts.dropFirst(beforeBroadcast).contains { message in
                guard case .sessionList(let snapshot) = message else { return false }
                return snapshot.workspaces.first(where: \.isCoordinator)?.coordinatorQueueRevision != before.revision
            }
        }

        let read = try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential)
        let queue = try #require(read.queue)
        #expect(queue.revision != before.revision)
        #expect(conversations.service.facadeSessionList(at: .now).workspaces.first(where: \.isCoordinator)?
            .coordinatorQueueRevision == queue.revision)
        #expect(queue.entries.map(\.id) == [withFile.id, "from-task", "reply", "closed"])
        #expect(queue.entries.allSatisfy { $0.isHeld == false })
        let file = queue.entries[0]
        #expect(file.fileNames == ["terminal-log.txt"])
        #expect(file.text.contains("Look at this log"))
        let task = queue.entries[1]
        #expect(task.sender == "task Fix the unread dot")
        #expect(task.text == "The fix is ready for review.")
        let replyEntry = queue.entries[2]
        #expect(replyEntry.quote == "Merge PR 431?")
        #expect(replyEntry.quoteTime == "9:41")
        #expect(replyEntry.text == "Yes, merge it.")
        // The body names no folder of this Mac.
        let body = String(decoding: read.body, as: UTF8.self)
        #expect(body.contains(fixture.coordinatorDirectory.path) == false)
        #expect(body.contains("/attachments/") == false)
        #expect(body.contains(conversations.runtimeHome) == false)
    }

    /// 5 and 6 entries, where the conversation's own queue stops, and 50,
    /// the coordinator's limit, all come in order. A text longer than the
    /// limit comes shortened.
    @MainActor
    @Test func everyEntryUpToTheLimitComesInOrderAndLongTextIsShortened() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }

        func read() throws -> RemoteCoordinatorQueue {
            try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        }
        let long = String(repeating: "x", count: RemoteCoordinatorQueuePolicy.maximumTextLength + 500)
        #expect(try fixture.controller.send(long, byUser: true, id: "m1").isQueued)
        for index in 2 ... 5 {
            #expect(try fixture.controller.send("Message \(index)", byUser: true, id: "m\(index)").isQueued)
        }
        #expect(try read().entries.map(\.id) == (1 ... 5).map { "m\($0)" })
        let first = try read().entries[0]
        #expect(first.isTextShortened)
        #expect(first.text.count == RemoteCoordinatorQueuePolicy.maximumTextLength)
        #expect(first.text.hasSuffix("…"))

        #expect(try fixture.controller.send("Message 6", byUser: true, id: "m6").isQueued)
        #expect(try read().entries.map(\.id) == (1 ... 6).map { "m\($0)" })

        for index in 7 ... CoordinatorController.maximumQueuedEntries {
            #expect(try fixture.controller.send("Message \(index)", id: "m\(index)").isQueued)
        }
        let full = try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential)
        #expect(try #require(full.queue).entries.map(\.id) == (1 ... 50).map { "m\($0)" })
        #expect(full.body.count < 200_000)
        #expect(throws: CoordinatorError.self) { try fixture.controller.send("Message 51", id: "m51") }
    }

    // MARK: - Resume

    /// The user's case: a phone's Stop holds messages in both of the
    /// coordinator's queues. Nothing starts a new turn. One Resume from the
    /// phone lets them all go, the conversation's first, one for each
    /// prompt; a second Resume for the same Stop changes nothing. The Mac's
    /// chat lists the same rows as before.
    @MainActor
    @Test func oneResumeFromThePhoneLetsGoWhatAStopHoldsInBothQueues() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in true }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        let turnEpoch = try await fixture.waitFor("the running turn") { fixture.chat.summary?.inputControl?.turnEpoch }
        let conversationID = try #require(fixture.chat.summary?.conversationID)

        let fromPhone = try conversations.gatewaySend(RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "phone-1",
            expectedInputEpoch: turnEpoch, text: "From the phone", deliveryMode: .queue
        ), credential: conversations.nativeCredential)
        #expect(fromPhone.result == .queued(position: 1))
        #expect(try fixture.controller.send("From the Mac", byUser: true, id: "mac-1").isQueued)
        let fromScript = CoordinatorMessageHeader.message(from: .unknown, text: "From a script")
        #expect(try fixture.controller.send(fromScript, id: "script").isQueued)
        try await fixture.waitUntil("the chat to list all three") {
            fixture.chat.presentation.sendItems.filter(\.isQueued).count == 3
        }
        let waiting = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        #expect(waiting.heldSetToken == nil)

        let stop = try conversations.gatewayInterrupt(
            RemoteConversationInterruptRequest(conversationID: conversationID, expectedTurnEpoch: turnEpoch),
            credential: conversations.nativeCredential
        )
        #expect(stop.result == .accepted)
        let held = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        let token = try #require(held.heldSetToken)
        #expect(held.entries.map(\.id) == ["mac-1", "script"])
        #expect(held.entries.allSatisfy { $0.isHeld })
        #expect(held.revision != waiting.revision)
        try await fixture.waitUntil("the conversation's paused queue") {
            fixture.chat.summary?.inputControl?.isQueuePaused == true
        }

        // The Mac's chat: the controller's held rows, then the phone's
        // queue, which it cannot change, as before.
        try await fixture.waitUntil("the chat to show the Stop") {
            fixture.chat.presentation.sendItems.compactMap(Self.queued).allSatisfy { $0.isPaused }
        }
        #expect(fixture.chat.presentation.sendItems.filter(\.isQueued).map(\.clientRequestID) == ["mac-1", "script", "phone-1"])
        #expect(fixture.chat.presentation.sendItems.compactMap(Self.queued).map(\.canChange) == [true, true, false])

        try fixture.endTurn(1)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)

        let wrongToken = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: "an-earlier-stop"
        ), credential: conversations.nativeCredential)
        #expect(wrongToken.result == .stale)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.delivered.texts.isEmpty)

        let resume = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: token
        ), credential: conversations.nativeCredential)
        #expect(resume.result == .updated)
        try await fixture.waitUntil("the phone's message") { fixture.delivered.texts == ["From the phone"] }
        let again = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: token
        ), credential: conversations.nativeCredential)
        #expect(again.result == .unchanged)
        let released = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        #expect(released.heldSetToken == nil)
        #expect(released.entries.map(\.id) == ["mac-1", "script"])
        #expect(released.entries.allSatisfy { $0.isHeld == false })

        try fixture.runTurn(2, userText: "From the phone")
        try await fixture.waitUntil("the Mac's message") { fixture.delivered.texts.count == 2 }
        try fixture.runTurn(3, userText: "From the Mac")
        try await fixture.waitUntil("the script's message") { fixture.delivered.texts.count == 3 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts == ["From the phone", "From the Mac", fromScript])
    }

    /// A Resume names its Stop: one that comes after a later Stop does not
    /// let that Stop's messages go. Resume from the Mac's chat and from the
    /// phone at nearly the same time lets each message go once.
    @MainActor
    @Test func aLateResumeLeavesALaterStopsMessagesAndARacingResumeSendsEachOnce() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in true }
        fixture.chat.show(panelID: fixture.panelID)

        // The first Stop holds one message; the Mac's chat lets it go.
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        #expect(try fixture.controller.send("First", byUser: true, id: "first").isQueued)
        fixture.chat.stop()
        let firstToken = try #require(
            try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue?.heldSetToken
        )
        fixture.chat.perform(.resume)
        try fixture.endTurn(1)
        try await fixture.waitUntil("the first message") { fixture.delivered.texts == ["First"] }

        // A second Stop, in the turn the first message started.
        try fixture.startTurn(2, userText: "First")
        let turnEpoch = try await fixture.waitFor("the second turn") { fixture.chat.summary?.inputControl?.turnEpoch }
        let conversationID = try #require(fixture.chat.summary?.conversationID)
        let fromPhone = try conversations.gatewaySend(RemoteMessageSendRequest(
            conversationID: conversationID, clientRequestID: "phone-2",
            expectedInputEpoch: turnEpoch, text: "Second from the phone", deliveryMode: .queue
        ), credential: conversations.nativeCredential)
        #expect(fromPhone.result == .queued(position: 1))
        #expect(try fixture.controller.send("Second", byUser: true, id: "second").isQueued)
        fixture.chat.stop()
        let secondToken = try #require(
            try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue?.heldSetToken
        )
        #expect(secondToken != firstToken)
        try fixture.endTurn(2)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }

        let late = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: firstToken
        ), credential: conversations.nativeCredential)
        #expect(late.result == .stale)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts == ["First"])

        // The Mac's chat and the phone resume together.
        fixture.chat.perform(.resume)
        let phoneResume = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: secondToken
        ), credential: conversations.nativeCredential)
        #expect(phoneResume.result == .updated || phoneResume.result == .unchanged)
        try await fixture.waitUntil("one message for the open prompt") { fixture.delivered.texts.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.count == 2)
        let typedSecond = try #require(fixture.delivered.texts.last)
        try fixture.runTurn(3, userText: typedSecond)
        try await fixture.waitUntil("the other message") { fixture.delivered.texts.count == 3 }
        try fixture.runTurn(4, userText: try #require(fixture.delivered.texts.last))
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.count == 3)
        #expect(Set(fixture.delivered.texts.dropFirst()) == ["Second from the phone", "Second"])
        let empty = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        #expect(empty.entries.isEmpty)
        #expect(empty.heldSetToken == nil)
    }

    /// Held messages wait across a relaunch, under a new token: a Resume
    /// with the token from before the relaunch is stale, and the new one
    /// lets them go.
    @MainActor
    @Test func heldMessagesWaitAcrossARelaunchUnderANewToken() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true, savesQueue: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in true }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        #expect(try fixture.controller.send("Held over the relaunch", byUser: true, id: "kept").isQueued)
        fixture.chat.stop()
        let before = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        let oldToken = try #require(before.heldSetToken)
        try fixture.endTurn(1)

        fixture.relaunch()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        fixture.chat.show(panelID: fixture.panelID)
        try await fixture.waitUntil("the open prompt") {
            fixture.chat.summary?.inputAvailability.allowsRemoteSend == true
        }
        let after = try #require(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue)
        #expect(after.entries.map(\.id) == ["kept"])
        #expect(after.entries.allSatisfy { $0.isHeld })
        let newToken = try #require(after.heldSetToken)
        #expect(newToken != oldToken)
        #expect(after.revision != before.revision)
        let conversationID = try #require(after.conversationID)

        let stale = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: oldToken
        ), credential: conversations.nativeCredential)
        #expect(stale.result == .stale)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
        let resume = try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: newToken
        ), credential: conversations.nativeCredential)
        #expect(resume.result == .updated)
        try await fixture.waitUntil("the kept message") { fixture.delivered.texts == ["Held over the relaunch"] }
    }

    // MARK: - Remove

    /// Remove takes a held or waiting entry out with its files, as the Mac
    /// chat's Remove does. A message that left already is unchanged.
    @MainActor
    @Test func removeTakesAnEntryWithItsFilesAndAMessageThatLeftIsUnchanged() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        let conversationID = try #require(fixture.chat.summary?.conversationID)
        fixture.chat.attachmentDraft.attachText("error: socket closed", named: "terminal log.txt")
        fixture.chat.send(queueing: true)
        let withFile = try await fixture.waitFor("the message with a file") { fixture.controller.queuedEntries.first }
        #expect(try fixture.controller.send("Stays", byUser: true, id: "stays").isQueued)
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(withFile.id)")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        func remove(_ id: String) throws -> RemoteConversationQueueUpdateResult? {
            try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
                conversationID: conversationID, action: .coordinatorRemove, clientRequestID: id
            ), credential: conversations.nativeCredential).result
        }
        #expect(try remove(withFile.id) == .updated)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
        #expect(fixture.controller.queuedEntries.map(\.id) == ["stays"])
        #expect(try remove(withFile.id) == .unchanged)
        #expect(try remove("never-queued") == .unchanged)

        // The phone's own queue answers its own Remove only.
        #expect(try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .remove, clientRequestID: "stays"
        ), credential: conversations.nativeCredential).result == .unchanged)
        #expect(fixture.controller.queuedEntries.map(\.id) == ["stays"])

        // A message that was typed has left.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the message") { fixture.delivered.texts == ["Stays"] }
        #expect(try remove("stays") == .unchanged)
    }

    // MARK: - Authorization and compatibility

    /// A device without send access, or a coordinator session that takes no
    /// writes from devices, still reads the queue and cannot change it. A
    /// coordinator action on another conversation finds nothing, and a
    /// request of another protocol version is refused.
    @MainActor
    @Test func onlyADeviceThatMayWriteToTheCoordinatorChangesItsQueue() async throws {
        let fixture = try CoordinatorChatFixture(pairsNativeDevice: true)
        defer { fixture.tearDown() }
        let conversations = fixture.conversations
        conversations.enableGateway()
        conversations.service.installCoordinatorQueue(from: fixture.controller)
        conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in true }
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.chat.canStop }
        let conversationID = try #require(fixture.chat.summary?.conversationID)
        #expect(try fixture.controller.send("Held", byUser: true, id: "held").isQueued)
        fixture.chat.stop()
        let token = try #require(
            try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).queue?.heldSetToken
        )
        let resume = RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorResume, heldSetToken: token
        )
        let remove = RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .coordinatorRemove, clientRequestID: "held"
        )

        // Writes off for the coordinator's session.
        conversations.service.setSessionWriteEnabled(false, for: conversationID)
        #expect(try conversations.gatewayQueueUpdate(resume, credential: conversations.nativeCredential).result == .sessionWritesDisabled)
        #expect(try conversations.gatewayQueueUpdate(remove, credential: conversations.nativeCredential).result == .sessionWritesDisabled)
        #expect(try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential).status == 200)
        conversations.service.setSessionWriteEnabled(true, for: conversationID)

        // Read-only: the gateway refuses before the queue is touched.
        let device = try #require(conversations.service.devices.first { $0.authKind == .native })
        conversations.service.setDeviceSendScope(false, for: device.id)
        #expect(try conversations.gatewayQueueUpdate(resume, credential: conversations.nativeCredential).status == 403)
        #expect(try conversations.gatewayQueueUpdate(remove, credential: conversations.nativeCredential).status == 403)
        let readOnly = try conversations.gatewayCoordinatorQueue(credential: conversations.nativeCredential)
        #expect(readOnly.status == 200)
        #expect(readOnly.queue?.entries.map(\.id) == ["held"])
        conversations.service.setDeviceSendScope(true, for: device.id)

        // Unpaired.
        #expect(try conversations.gatewayQueueUpdate(resume, credential: nil).status == 401)

        // Another conversation is not the coordinator's.
        var elsewhere = resume
        elsewhere.conversationID = RemoteConversationID(rawValue: UUID())
        #expect(try conversations.gatewayQueueUpdate(elsewhere, credential: conversations.nativeCredential).result == .conversationNotFound)

        // Another protocol version.
        var older = resume
        older.protocolVersion = "0"
        #expect(try conversations.gatewayQueueUpdate(older, credential: conversations.nativeCredential).status == 409)

        // An older phone's Resume lets only the conversation's own queue go.
        #expect(try conversations.gatewayQueueUpdate(RemoteConversationQueueUpdateRequest(
            conversationID: conversationID, action: .resume
        ), credential: conversations.nativeCredential).result == .unchanged)
        #expect(fixture.controller.pausedEntries.map(\.id) == ["held"])

        #expect(try conversations.gatewayQueueUpdate(resume, credential: conversations.nativeCredential).result == .updated)
        #expect(fixture.controller.pausedEntries.isEmpty)
    }

    /// An older Mac's action decoder has no coordinator actions: it refuses
    /// the request whole rather than act on part of it.
    @Test func aCoordinatorActionIsUnreadableWithoutItsValue() throws {
        let body = try ConversationEventCoding.makeEncoder().encode(RemoteConversationQueueUpdateRequest(
            conversationID: RemoteConversationID(rawValue: UUID()), action: .coordinatorResume, heldSetToken: "t"
        ))
        struct OlderRequest: Decodable {
            enum Action: String, Decodable { case remove, resume }
            var action: Action
        }
        #expect(throws: DecodingError.self) { try ConversationEventCoding.makeDecoder().decode(OlderRequest.self, from: body) }
        let generic = try ConversationEventCoding.makeEncoder().encode(RemoteConversationQueueUpdateRequest(
            conversationID: RemoteConversationID(rawValue: UUID()), action: .resume
        ))
        #expect(try ConversationEventCoding.makeDecoder().decode(OlderRequest.self, from: generic).action == .resume)
        #expect(String(decoding: generic, as: UTF8.self).contains("heldSetToken") == false)
    }

    private static func queued(_ item: ToasttySendPresentationItem) -> ToasttyQueuedSendPresentation? {
        guard case .queued(let queued) = item.content else { return nil }
        return queued
    }
}

extension LocalConversationFixture {
    /// Reads the coordinator's own queue through the gateway's own request
    /// handler, as a device would.
    func gatewayCoordinatorQueue(
        credential: String?
    ) throws -> (status: Int, queue: RemoteCoordinatorQueue?, body: Data) {
        var headers = ["tailscale-user-login": "owner@example.com"]
        if let credential { headers["authorization"] = "Bearer \(credential)" }
        let http = RemoteGatewayHTTPRequest(
            method: "GET", path: RemoteCoordinatorQueuePolicy.path, headers: headers, body: Data()
        )
        guard case .respond(let response) = gatewayHandler.handle(http, at: .now) else {
            throw LocalConversationFixtureError.unexpectedGatewayOutcome
        }
        let decoded = try? ConversationEventCoding.makeDecoder().decode(RemoteCoordinatorQueue.self, from: response.body)
        return (response.status, decoded, response.body)
    }

    /// Changes a queue through the gateway's own request handler, as a
    /// device would.
    func gatewayQueueUpdate(
        _ request: RemoteConversationQueueUpdateRequest,
        credential: String?
    ) throws -> (status: Int, result: RemoteConversationQueueUpdateResult?) {
        var headers = ["tailscale-user-login": "owner@example.com"]
        if let credential { headers["authorization"] = "Bearer \(credential)" }
        let http = RemoteGatewayHTTPRequest(
            method: "POST",
            path: "/api/conversation.queue.update",
            headers: headers,
            body: try ConversationEventCoding.makeEncoder().encode(request)
        )
        guard case .respond(let response) = gatewayHandler.handle(http, at: .now) else {
            throw LocalConversationFixtureError.unexpectedGatewayOutcome
        }
        let decoded = try? ConversationEventCoding.makeDecoder().decode(
            RemoteConversationQueueUpdateResponse.self, from: response.body
        )
        return (response.status, decoded?.result)
    }
}
