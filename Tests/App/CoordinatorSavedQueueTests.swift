@testable import ToasttyApp
import CoreState
import Foundation
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
        fixture.chat.send()
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
        fixture.chat.send()
        let resent = try await fixture.waitFor("the message waits again") { fixture.controller.queuedEntries.first }
        #expect(resent.id != message.id.uuidString)
        #expect(resent.text == """
        [Toastty] Quick entry from the user
        With one file

        Read the following files attached to this message on this Mac:
        `\(folder.appendingPathComponent("shot.png").path)`
        """)
        // The saved queue holds the text with the paths, as before.
        #expect(CoordinatorQueueSnapshot.load(from: try #require(fixture.queueFileURL))?.queued.map(\.text) == [resent.text])
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
        // Saved for a coordinator's workspace that closed since.
        let goneMessage = UUID()
        let folder = fixture.coordinatorDirectory.appendingPathComponent("attachments/\(goneMessage.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try CoordinatorQueueSnapshot(
            workspaceID: UUID(),
            queued: [.init(id: goneMessage.uuidString, text: "For the old coordinator")],
            paused: []
        ).save(to: file)

        fixture.relaunch()
        #expect(fixture.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
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
        #expect(FileManager.default.fileExists(atPath: file.path))

        #expect(fixture.store.send(.closeWorkspace(workspaceID: workspaceID)))
        #expect(fixture.controller.status == nil)
        try await fixture.waitUntil("the file to go") { FileManager.default.fileExists(atPath: file.path) == false }
        #expect(fixture.controller.queuedEntries.isEmpty)
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
