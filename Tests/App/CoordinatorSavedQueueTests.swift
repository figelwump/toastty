@testable import ToasttyApp
import CoreState
import Foundation
import RemoteProtocol
import Testing

/// The user's messages for the coordinator wait on disk until its prompt
/// takes them. These tests use the real controller, store, session store,
/// terminal registry and `RemoteAccessService`, as the send path tests do.
/// A relaunch is a new controller over the same windows, the same agent
/// conversation and the same file.
@Suite(.serialized)
struct CoordinatorSavedQueueTests {
    // MARK: - An app quit

    @MainActor
    @Test func aUsersMessageThatWaitsIsTypedOnceAfterARelaunch() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }

        #expect(try fixture.controller.send("First from the user", byUser: true, id: "user-1").isQueued)
        #expect(try fixture.controller.send("From coordinator send", id: "cli-1").isQueued)
        #expect(try fixture.controller.send("Second from the user", byUser: true, id: "user-2").isQueued)
        // Only a person's messages are saved, in their order.
        let saved = try #require(CoordinatorQueueSnapshot.load(from: file))
        #expect(saved.workspaceID == fixture.store.state.coordinatorWorkspaceID)
        #expect(saved.queued.map(\.id) == ["user-1", "user-2"])
        #expect(saved.queued.map(\.text) == ["First from the user", "Second from the user"])
        #expect(saved.typingEntryID == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

        // Toastty quits and launches again while the turn still runs.
        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.map(\.id) == ["user-1", "user-2"])
        #expect(fixture.controller.queuedEntries.allSatisfy { $0.byUser })
        #expect(fixture.controller.status?.queuedCount == 2)
        #expect(fixture.delivered.texts.isEmpty)
        // The chat shows them again, so the user can see and remove them.
        fixture.chat.show(panelID: fixture.panelID)
        #expect(fixture.chat.presentation.sendItems.map(\.text) == ["First from the user", "Second from the user"])
        #expect(fixture.chat.presentation.sendItems.allSatisfy { $0.isQueued })

        // One message for each open prompt, in order, and each one once.
        try fixture.endTurn(1)
        try await fixture.waitUntil("the first message") { fixture.delivered.texts.count == 1 }
        #expect(fixture.delivered.texts == ["First from the user"])
        #expect(CoordinatorQueueSnapshot.load(from: file)?.queued.map(\.id) == ["user-2"])
        try fixture.runTurn(2, userText: "First from the user")
        try await fixture.waitUntil("the second message") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts == ["First from the user", "Second from the user"])
        #expect(FileManager.default.fileExists(atPath: file.path) == false)

        // A second relaunch has nothing to type.
        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.isEmpty)
        try fixture.runTurn(3, userText: "Second from the user")
        try await fixture.waitUntil("the open prompt") { fixture.controller.promptIsOpenForTesting }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.count == 2)
        #expect(fixture.typedThroughStatusGate.isEmpty)
    }

    @MainActor
    @Test func aMessageTypedAtOnceLeavesNothingToTypeAfterARelaunch() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        try await fixture.waitUntil("the open prompt") { fixture.controller.promptIsOpenForTesting }

        // While the text goes to the terminal, the file says which message
        // is being typed: a crash in this moment cannot type it twice.
        var savedWhileTyping: CoordinatorQueueSnapshot?
        fixture.conversations.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, _, _, _ in
            savedWhileTyping = CoordinatorQueueSnapshot.load(from: file)
            fixture.delivered.texts.append(text)
            return true
        }
        #expect(try fixture.controller.send("Typed at once", byUser: true, id: "user-1") == .sent)
        #expect(savedWhileTyping?.queued.map(\.id) == ["user-1"])
        #expect(savedWhileTyping?.typingEntryID == "user-1")
        // Typed: nothing is saved any more.
        #expect(FileManager.default.fileExists(atPath: file.path) == false)

        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(fixture.controller.pausedEntries.isEmpty)
        try fixture.runTurn(1, userText: "Typed at once")
        try await fixture.waitUntil("the open prompt") { fixture.controller.promptIsOpenForTesting }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts == ["Typed at once"])
    }

    @MainActor
    @Test func aMessageWhoseTypingAQuitInterruptedWaitsForTheUser() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        // The file as a crash leaves it between "typing starts" and "typed".
        try CoordinatorQueueSnapshot(
            workspaceID: workspaceID,
            queued: [.init(id: "interrupted", text: "Create the export task"), .init(id: "later", text: "And a second one")],
            paused: [],
            typingEntryID: "interrupted"
        ).save(to: file)

        fixture.relaunch()
        // Nobody knows whether the coordinator has the first message. It is
        // not typed again: it waits, set aside, and the next one goes on.
        #expect(fixture.controller.pausedEntries.map(\.id) == ["interrupted"])
        #expect(fixture.controller.hasInterruptedEntry)
        try await fixture.waitUntil("the later message") { fixture.delivered.texts.count == 1 }
        #expect(fixture.delivered.texts == ["And a second one"])
        fixture.chat.show(panelID: fixture.panelID)
        try fixture.runTurn(1, userText: "And a second one")
        try await fixture.waitUntil("the notice") { fixture.chat.notice == .typingInterrupted }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.count == 1)
        // The mark is saved too: a second relaunch still does not type it.
        fixture.relaunch()
        #expect(fixture.controller.pausedEntries.map(\.id) == ["interrupted"])
        #expect(fixture.controller.hasInterruptedEntry)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.count == 1)

        // "Send next": the user sends it again. It is typed once.
        fixture.chat.show(panelID: fixture.panelID)
        fixture.chat.perform(.resume)
        try await fixture.waitUntil("the interrupted message") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts.last == "Create the export task")
        #expect(fixture.controller.hasInterruptedEntry == false)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    // MARK: - Steer now

    @MainActor
    @Test func aWaitingMessageThatSteersLeavesTheSavedQueue() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let folder = file.deletingLastPathComponent()
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("a turn that takes a steer") { fixture.controller.canSteer }
        #expect(try fixture.controller.sendUserText("First", steering: false, id: "user-1").isQueued)
        #expect(try fixture.controller.sendUserText("Second", steering: false, id: "user-2").isQueued)
        #expect(CoordinatorQueueSnapshot.load(from: file)?.queued.map(\.id) == ["user-1", "user-2"])

        // While the file cannot be written, the message is not typed: the
        // file would still list it, and a relaunch would type it again.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(throws: CoordinatorError.self) { try fixture.controller.steerQueuedEntry(id: "user-2") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.queuedEntries.map(\.id) == ["user-1", "user-2"])

        // While the text goes to the terminal, the file says which message
        // is being typed: a crash in this moment cannot type it twice.
        var savedWhileTyping: CoordinatorQueueSnapshot?
        fixture.conversations.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { text, _, _, _ in
            savedWhileTyping = CoordinatorQueueSnapshot.load(from: file)
            fixture.delivered.texts.append(text)
            return true
        }
        try fixture.controller.steerQueuedEntry(id: "user-2")
        #expect(savedWhileTyping?.typingEntryID == "user-2")
        #expect(fixture.delivered.texts == ["Second"])
        let saved = try #require(CoordinatorQueueSnapshot.load(from: file))
        #expect(saved.queued.map(\.id) == ["user-1"])
        #expect(saved.typingEntryID == nil)

        // A relaunch has the first message only, and types it once after
        // the turn.
        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.map(\.id) == ["user-1"])
        #expect(fixture.controller.pausedEntries.isEmpty)
        try fixture.endTurn(1)
        try await fixture.waitUntil("the first message") { fixture.delivered.texts.count == 2 }
        #expect(fixture.delivered.texts == ["Second", "First"])
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @MainActor
    @Test func aPausedMessageWhoseSteerAQuitInterruptedWaitsForTheUser() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        // The file as a crash leaves it while "Steer now" typed a message
        // that a Stop had set aside.
        try CoordinatorQueueSnapshot(
            workspaceID: workspaceID,
            queued: [.init(id: "later", text: "And a second one")],
            paused: [.init(id: "steered", text: "Create the export task")],
            typingEntryID: "steered"
        ).save(to: file)

        fixture.relaunch()
        // Nobody knows whether the coordinator has it. It is marked, and it
        // waits for the user as a paused message does.
        #expect(fixture.controller.pausedEntries.map(\.id) == ["steered"])
        #expect(fixture.controller.hasInterruptedEntry)
        try await fixture.waitUntil("the later message") { fixture.delivered.texts.count == 1 }
        #expect(fixture.delivered.texts == ["And a second one"])
        let saved = try #require(CoordinatorQueueSnapshot.load(from: file))
        #expect(saved.paused.map(\.typingWasInterrupted) == [true])
        #expect(saved.typingEntryID == nil)
    }

    @MainActor
    @Test func aMessageIsNotTypedWhileItsTypingCannotBeSaved() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let folder = file.deletingLastPathComponent()
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        #expect(try fixture.controller.send("Create the export task", byUser: true, id: "user-1").isQueued)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // The file cannot be written any more. Typed now, the message would
        // still be listed as waiting, and a relaunch would type it again.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try fixture.endTurn(1)
        try await fixture.waitUntil("the hold") { fixture.controller.hold == .notSaved }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.isEmpty)
        #expect(fixture.controller.queuedEntries.map(\.id) == ["user-1"])
        fixture.chat.show(panelID: fixture.panelID)
        #expect(CoordinatorChatModel.waitingCaption(position: 1, hold: fixture.controller.hold)
            == "Queued 1 · Toastty could not save it, and tries again")
        // A relaunch in this state still has the message, and has it once.
        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.map(\.id) == ["user-1"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.isEmpty)

        // The folder can be written again: the next try types it, once.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(CoordinatorController.saveRetryInterval + 4))
        while fixture.delivered.texts.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(fixture.delivered.texts == ["Create the export task"])
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @MainActor
    @Test func aMessageThatWasNeverSavedIsTypedAlsoWhenNothingCanBeSaved() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try await fixture.waitUntil("the open prompt") { fixture.controller.promptIsOpenForTesting }

        // No file lists it, so no relaunch can type it again: the chat
        // keeps working when Toastty cannot write its files.
        #expect(try fixture.controller.send("Typed at once", byUser: true, id: "user-1") == .sent)
        #expect(fixture.delivered.texts == ["Typed at once"])
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.isEmpty)
    }

    // MARK: - Remove, stop and close

    @MainActor
    @Test func aRemovedMessageLeavesTheFileAndTakesItsFilesWithIt() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        fixture.chat.show(panelID: fixture.panelID)

        // A quick entry message with a file, and one from the chat.
        let sourceFolder = URL(filePath: fixture.conversations.runtimeHome + "-attached")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let source = sourceFolder.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: source)
        let message = CoordinatorUserMessage(text: "With a file", files: [source], quickEntry: .init())
        #expect(try await fixture.controller.sendUserMessage(message).isQueued)
        fixture.chat.draft = "From the chat"
        // Command-Return: while a turn runs, Return would steer it.
        fixture.chat.send(queueing: true)
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(message.id.uuidString)")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shot.png").path))
        #expect(CoordinatorQueueSnapshot.load(from: file)?.queued.count == 2)

        // Stop sets them aside; that is saved too.
        var interrupts = 0
        fixture.conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in
            interrupts += 1
            return true
        }
        fixture.chat.stop()
        #expect(interrupts == 1)
        #expect(CoordinatorQueueSnapshot.load(from: file)?.paused.count == 2)
        fixture.relaunch()
        #expect(fixture.controller.pausedEntries.count == 2)
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(fixture.controller.hasInterruptedEntry == false)

        // Remove in the chat: the message and its files are gone for good.
        fixture.chat.show(panelID: fixture.panelID)
        fixture.chat.perform(.remove(clientRequestID: message.id.uuidString))
        #expect(fixture.controller.pausedEntries.map(\.text) == ["From the chat"])
        #expect(CoordinatorQueueSnapshot.load(from: file)?.paused.map(\.text) == ["From the chat"])
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
        fixture.relaunch()
        #expect(fixture.controller.pausedEntries.map(\.text) == ["From the chat"])
        try fixture.endTurn(1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.isEmpty)
    }

    /// Edit in the chat puts a quick entry message back into the field as
    /// it would be typed, with its files as attachments. Sent again it has
    /// a new ID, and its files are still in the folder of the message it
    /// was.
    @MainActor
    @Test func anEditedMessageKeepsItsFilesUntilItIsTypedOrRemoved() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        fixture.chat.show(panelID: fixture.panelID)
        let sourceFolder = URL(filePath: fixture.conversations.runtimeHome + "-attached")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let source = sourceFolder.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: source)
        let message = CoordinatorUserMessage(text: "With a file", files: [source], quickEntry: .init())
        #expect(try await fixture.controller.sendUserMessage(message).isQueued)
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(message.id.uuidString)")
        // The waiting row shows the text, the file's name and its count.
        let row = try await fixture.waitFor("the waiting row") { fixture.chat.presentation.sendItems.first }
        #expect(row.text == "With a file\n\nshot.png")
        guard case .queued(let queued) = row.content else {
            Issue.record("The message waits")
            return
        }
        #expect(queued.attachmentCount == 1)

        // Edit: the text with Toastty's first line, and the file as an
        // attachment that stays in its folder.
        fixture.chat.perform(.edit(clientRequestID: message.id.uuidString, text: ""))
        #expect(fixture.chat.draft == "[Toastty] Quick entry from the user\nWith a file")
        #expect(fixture.chat.attachmentDraft.attachments.map(\.url.path)
            == [folder.appendingPathComponent("shot.png").path])
        #expect(fixture.chat.attachmentDraft.attachments.map(\.isDraftCopy) == [false])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shot.png").path))
        #expect(CoordinatorQueueSnapshot.load(from: try #require(fixture.queueFileURL)) == nil)
        // Change a word, send again from the chat's field.
        fixture.chat.draft = fixture.chat.draft.replacingOccurrences(of: "With a file", with: "With one file")
        // Command-Return: while a turn runs, Return would steer it.
        fixture.chat.send(queueing: true)
        let resent = try await fixture.waitFor("the message waits again") { fixture.controller.queuedEntries.first }
        #expect(resent.id != message.id.uuidString)
        #expect(resent.text == """
        [Toastty] Quick entry from the user
        With one file

        Read the following files attached to this message on this Mac:
        `\(folder.appendingPathComponent("shot.png").path)`
        """)
        // The saved queue holds the text with the paths, as before, and the
        // folders that the message owns: its own and the edited message's.
        #expect(CoordinatorQueueSnapshot.load(from: try #require(fixture.queueFileURL))?.queued.map(\.text) == [resent.text])
        #expect(resent.attachmentFolders == [resent.id, message.id.uuidString])
        #expect(CoordinatorQueueSnapshot.load(from: try #require(fixture.queueFileURL))?.queued.map(\.attachmentFolders)
            == [[resent.id, message.id.uuidString]])
        #expect(fixture.chat.draft.isEmpty)
        #expect(fixture.chat.attachmentDraft.attachments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shot.png").path))

        // It waits longer than Toastty keeps the files of typed messages.
        // A relaunch keeps the folder: a waiting message names it.
        let old = Date().addingTimeInterval(-CoordinatorAttachments.retention - 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        let unrelated = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unrelated.path)
        fixture.relaunch()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shot.png").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path) == false, "A typed message's old files go")

        // Remove drops the files with the message.
        fixture.chat.show(panelID: fixture.panelID)
        fixture.chat.perform(.remove(clientRequestID: resent.id))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
    }

    @MainActor
    @Test func aQueueSavedForAnotherCoordinatorIsDropped() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        // Saved for a coordinator's workspace that closed since: a message
        // whose text names an earlier message's copy, and one that owns the
        // folder of a message it was edited from.
        let goneMessage = UUID()
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(goneMessage.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let earlier = try Self.earlierCopy(fixture)
        let carried = try Self.earlierCopy(fixture)
        let edited = UUID().uuidString
        try CoordinatorQueueSnapshot(
            workspaceID: UUID(),
            queued: [.init(id: goneMessage.uuidString, text: Self.listing("For the old coordinator", [earlier.file]))],
            paused: [.init(id: edited, text: "Edited", attachmentFolders: [edited, carried.folder.lastPathComponent])]
        ).save(to: file)

        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
        #expect(FileManager.default.fileExists(atPath: carried.folder.path) == false)
        // A folder that a text names is not the message's.
        #expect(FileManager.default.fileExists(atPath: earlier.file.path))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.delivered.texts.isEmpty)
    }

    @MainActor
    @Test func closingTheCoordinatorsWorkspaceDropsTheSavedMessages() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        #expect(try fixture.controller.send("Waits", byUser: true, id: "user-1").isQueued)
        // A message with a file, and one whose text names an earlier
        // message's copy.
        let withFile = CoordinatorUserMessage(
            text: "With a file", files: [try Self.sourceFile(fixture, named: "shot.png")], quickEntry: .init()
        )
        #expect(try await fixture.controller.sendUserMessage(withFile).isQueued)
        let ownFolder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(withFile.id.uuidString)")
        let earlier = try Self.earlierCopy(fixture)
        #expect(try fixture.controller.send(Self.listing("Pasted", [earlier.file]), byUser: true, id: "pasted").isQueued)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: ownFolder.path))

        #expect(fixture.store.send(.closeWorkspace(workspaceID: workspaceID)))
        #expect(fixture.controller.status == nil)
        try await fixture.waitUntil("the file to go") { FileManager.default.fileExists(atPath: file.path) == false }
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: ownFolder.path) == false)
        #expect(FileManager.default.fileExists(atPath: earlier.file.path))
    }

    // MARK: - The folders that a message owns

    /// A list of attached files in a message's text can name the folders
    /// of other messages: pasted into the chat, or written by `coordinator
    /// send`. Remove deletes only the folders that the removed message
    /// owns. A folder that no waiting message owns or names any more goes
    /// with the retention; one that a waiting message owns stays.
    @MainActor
    @Test func removeDeletesOnlyTheFoldersThatTheMessageOwns() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        fixture.chat.show(panelID: fixture.panelID)

        // A quick entry message with a file waits; its folder is its own.
        let owner = CoordinatorUserMessage(
            text: "With a file", files: [try Self.sourceFile(fixture, named: "notes.txt")], quickEntry: .init()
        )
        #expect(try await fixture.controller.sendUserMessage(owner).isQueued)
        let ownerFolder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(owner.id.uuidString)")
        let ownerCopy = ownerFolder.appendingPathComponent("notes.txt")
        #expect(FileManager.default.fileExists(atPath: ownerCopy.path))
        // A copy of a message that was typed earlier.
        let earlier = try Self.earlierCopy(fixture)

        // Both named in a list pasted into the chat, and in one that
        // `coordinator send` brought.
        let list = Self.listing("Pasted", [ownerCopy, earlier.file])
        #expect(try fixture.controller.sendUserText(list, steering: false, id: UUID().uuidString).isQueued)
        let pasted = try #require(fixture.controller.queuedEntries.last)
        #expect(try fixture.controller.send(
            CoordinatorMessageHeader.message(from: .unknown, text: list), id: UUID().uuidString
        ).isQueued)
        let scripted = try #require(fixture.controller.queuedEntries.last)
        #expect(pasted.attachmentFolders == [pasted.id])
        #expect(scripted.attachmentFolders == [scripted.id])
        #expect(CoordinatorQueueSnapshot.load(from: file)?.queued.map(\.attachmentFolders)
            == [[owner.id.uuidString], [pasted.id]])

        fixture.chat.perform(.remove(clientRequestID: pasted.id))
        try fixture.controller.removeQueuedEntry(id: scripted.id, discardingAttachments: true)
        #expect(fixture.controller.queuedEntries.map(\.id) == [owner.id.uuidString])
        #expect(FileManager.default.fileExists(atPath: ownerCopy.path))
        #expect(FileManager.default.fileExists(atPath: earlier.file.path))

        // Both folders are older than the retention. At the next launch the
        // earlier message's goes: no waiting message owns or names it. The
        // waiting message's stays.
        let old = Date().addingTimeInterval(-CoordinatorAttachments.retention - 3600)
        for folder in [ownerFolder, earlier.folder] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }
        fixture.relaunch()
        #expect(FileManager.default.fileExists(atPath: ownerCopy.path))
        #expect(FileManager.default.fileExists(atPath: earlier.folder.path) == false)

        // The message's own Remove deletes its folder.
        fixture.chat.show(panelID: fixture.panelID)
        fixture.chat.perform(.remove(clientRequestID: owner.id.uuidString))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: ownerFolder.path) == false)
    }

    /// Edit takes files back into the field only from folders that the
    /// message owns. A list pasted from another message stays text, and
    /// the message sent from the field does not own that folder.
    @MainActor
    @Test func editTakesBackOnlyFilesFromFoldersThatTheMessageOwns() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        fixture.chat.show(panelID: fixture.panelID)
        let earlier = try Self.earlierCopy(fixture)
        #expect(try fixture.controller.sendUserText(
            Self.listing("Pasted", [earlier.file]), steering: false, id: "pasted"
        ).isQueued)

        fixture.chat.perform(.edit(clientRequestID: "pasted", text: ""))
        #expect(fixture.chat.attachmentDraft.attachments.isEmpty)
        #expect(fixture.chat.draft.contains(earlier.file.path(percentEncoded: false)))
        // Command-Return: while a turn runs, Return would steer it.
        fixture.chat.send(queueing: true)
        let resent = try await fixture.waitFor("the message waits again") { fixture.controller.queuedEntries.first }
        #expect(resent.attachmentFolders == [resent.id])

        fixture.chat.perform(.remove(clientRequestID: resent.id))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: earlier.file.path))
    }

    /// A queue file of a build before the list of owned folders loads.
    /// Each of its entries owns only its own folder: its text adds none.
    @MainActor
    @Test func aQueueFileFromAnOlderBuildLoadsAndEachEntryOwnsOnlyItsFolder() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        let ownID = UUID().uuidString
        let own = try Self.earlierCopy(fixture, folderName: ownID)
        let earlier = try Self.earlierCopy(fixture)
        // As an older build wrote it: no `attachmentFolders`.
        struct OlderEntry: Encodable { var id: String; var text: String }
        struct OlderSnapshot: Encodable {
            var version = 1
            var workspaceID: UUID
            var queued: [OlderEntry]
            var paused: [OlderEntry]
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(OlderSnapshot(
            workspaceID: workspaceID,
            queued: [OlderEntry(id: ownID, text: Self.listing("Mine and an earlier one", [own.file, earlier.file]))],
            paused: [OlderEntry(id: "held", text: "Held")]
        )).write(to: file)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("attachmentFolders") == false)

        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.map(\.id) == [ownID])
        #expect(fixture.controller.queuedEntries.map(\.attachmentFolders) == [[ownID]])
        #expect(fixture.controller.pausedEntries.map(\.attachmentFolders) == [["held"]])
        // The next save writes the list.
        #expect(CoordinatorQueueSnapshot.load(from: file)?.queued.map(\.attachmentFolders) == [[ownID]])

        fixture.chat.show(panelID: fixture.panelID)
        fixture.chat.perform(.remove(clientRequestID: ownID))
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: own.folder.path) == false)
        #expect(FileManager.default.fileExists(atPath: earlier.file.path))
    }

    /// Only a folder that a message's ID names can go: a name from the
    /// saved file that is not one removes nothing, inside the attachments
    /// folder or outside it.
    @Test func discardRemovesOnlyFoldersThatAMessagesIDNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let attachments = CoordinatorAttachments(coordinatorDirectoryURL: root.appendingPathComponent("coordinator"))
        let outside = root.appendingPathComponent("coordinator/outside")
        let notAnID = attachments.directoryURL.appendingPathComponent("not-an-id")
        let message = attachments.directoryURL.appendingPathComponent(UUID().uuidString)
        for folder in [outside, notAnID, message] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        attachments.discard(folders: ["../outside", "not-an-id", "", ".", "..", "\(message.lastPathComponent)/.."])
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: notAnID.path))
        #expect(FileManager.default.fileExists(atPath: message.path))
        #expect(FileManager.default.fileExists(atPath: attachments.directoryURL.path))

        attachments.discard(folders: [message.lastPathComponent, message.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: message.path) == false)
    }

    // MARK: - A Remove that cannot be saved

    /// Remove saves the queue without the message first. When that fails,
    /// the message waits where it was, with its files, the file still
    /// lists it, and the chat says so; Edit too. A message that the file
    /// never held goes. Once the file can be written, Remove works.
    @MainActor
    @Test func aRemoveThatCannotBeSavedKeepsTheMessageAndItsFiles() async throws {
        let fixture = try CoordinatorChatFixture(savesQueue: true)
        defer { fixture.tearDown() }
        let file = try #require(fixture.queueFileURL)
        let savedFolder = file.deletingLastPathComponent()
        try fixture.startTurn(1, userText: "Check the tasks")
        try await fixture.waitUntil("the running turn") { fixture.controller.promptIsOpenForTesting == false }
        fixture.chat.show(panelID: fixture.panelID)
        let withFile = CoordinatorUserMessage(
            text: "With a file", files: [try Self.sourceFile(fixture, named: "notes.txt")], quickEntry: .init()
        )
        #expect(try await fixture.controller.sendUserMessage(withFile).isQueued)
        #expect(try fixture.controller.send("Second", byUser: true, id: "second").isQueued)
        #expect(try fixture.controller.send("From a script", id: "script").isQueued)
        let copy = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(withFile.id.uuidString)/notes.txt")
        // A Stop sets them aside, in this order.
        fixture.conversations.terminalRuntimeRegistry.setAutomationSendInterruptHandlerForTesting { _ in true }
        fixture.chat.stop()
        let order = [withFile.id.uuidString, "second", "script"]
        #expect(fixture.controller.pausedEntries.map(\.id) == order)
        let saved = try #require(CoordinatorQueueSnapshot.load(from: file))
        #expect(saved.paused.map(\.id) == [withFile.id.uuidString, "second"])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: savedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: savedFolder.path) }
        fixture.chat.perform(.remove(clientRequestID: withFile.id.uuidString))
        guard case .failure(let failure)? = fixture.chat.notice else {
            Issue.record("Remove did not say that it failed")
            return
        }
        #expect(failure.contains("still waits"))
        #expect(fixture.controller.pausedEntries.map(\.id) == order)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(CoordinatorQueueSnapshot.load(from: file) == saved)

        // Edit cannot take a message into the field either: the file would
        // still list it, and a relaunch would type it next to the edit.
        fixture.chat.dismissNotice()
        fixture.chat.perform(.edit(clientRequestID: "second", text: ""))
        guard case .failure? = fixture.chat.notice else {
            Issue.record("Edit did not say that it failed")
            return
        }
        #expect(fixture.chat.draft.isEmpty)
        #expect(fixture.controller.pausedEntries.map(\.id) == order)

        // The file never held the script's message, so it can go.
        try fixture.controller.removeQueuedEntry(id: "script", discardingAttachments: true)
        #expect(fixture.controller.pausedEntries.map(\.id) == [withFile.id.uuidString, "second"])
        #expect(CoordinatorQueueSnapshot.load(from: file) == saved)

        // Once the file can be written, Remove takes the message and its
        // files, and a relaunch does not bring it back.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: savedFolder.path)
        fixture.chat.perform(.remove(clientRequestID: withFile.id.uuidString))
        #expect(fixture.controller.pausedEntries.map(\.id) == ["second"])
        #expect(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path) == false)
        #expect(CoordinatorQueueSnapshot.load(from: file)?.paused.map(\.id) == ["second"])
        fixture.relaunch()
        #expect(fixture.controller.pausedEntries.map(\.id) == ["second"])
        try fixture.endTurn(1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.delivered.texts.isEmpty)
    }

    /// A file outside the coordinator's folder, for a message to attach.
    @MainActor
    private static func sourceFile(_ fixture: CoordinatorChatFixture, named name: String) throws -> URL {
        let folder = URL(filePath: fixture.conversations.runtimeHome).appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent(name)
        try Data("attached".utf8).write(to: source)
        return source
    }

    /// The copy of a message that Toastty typed earlier, in that message's
    /// folder.
    @MainActor
    private static func earlierCopy(
        _ fixture: CoordinatorChatFixture,
        folderName: String = UUID().uuidString
    ) throws -> (folder: URL, file: URL) {
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(folderName)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("earlier.txt")
        try Data("earlier".utf8).write(to: file)
        return (folder, file)
    }

    /// The text with Toastty's list of `files`, as the chat writes it.
    private static func listing(_ text: String, _ files: [URL]) -> String {
        RemoteMessageAttachmentStore.Staged.deliveryText(text: text, paths: files.map { $0.path(percentEncoded: false) })
    }
}

/// The same promise through an agent restart, with the real agent launcher
/// and a fake terminal: a message sent while Restart Coordinator runs is
/// kept, saved, and typed once into the new agent.
@MainActor
struct CoordinatorSavedQueueRestartTests {
    typealias Fixture = CoordinatorControllerTests.Fixture

    @Test func aUsersMessageSentDuringARestartIsSavedAndTypedOnceIntoTheNewAgent() async throws {
        let fixture = try Fixture(readinessTimeout: .seconds(5))
        try await fixture.openAtPrompt()
        let oldPanelID = try #require(fixture.store.state.coordinator?.panelID)
        fixture.tasks.router.promptStateByPanelID[oldPanelID] = .idleAtPrompt
        fixture.tasks.router.defaultPromptState = .unavailable
        let restart = Task { try await fixture.controller.restart() }
        await fixture.waitUntil("the restart is under way") { fixture.controller.isStarting }

        // Text typed now would go to the agent that is about to end.
        #expect(try fixture.controller.send("From the user", byUser: true, id: "user-1")
            == .queued(position: 1, hold: .agentStarting))
        #expect(CoordinatorQueueSnapshot.load(from: fixture.queueFileURL)?.queued.map(\.id) == ["user-1"])
        await fixture.settle()
        #expect(fixture.typedTexts.isEmpty)

        fixture.tasks.router.defaultPromptState = .idleAtPrompt
        let restarted = try await restart.value
        try fixture.reportAgentStarted()
        await fixture.waitUntil("the message reaches the new agent") { fixture.typedTexts == ["From the user"] }
        #expect(fixture.typed.first?.panelID == restarted.location.panelID)
        #expect(FileManager.default.fileExists(atPath: fixture.queueFileURL.path) == false)
        // The next prompt gets nothing more.
        try fixture.setStatus(.working)
        try fixture.setStatus(.idle)
        await fixture.settle()
        #expect(fixture.typedTexts == ["From the user"])
    }
}
