import AppKit
import Carbon.HIToolbox
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Quick entry while a coordinator exists: the panel sends to it. Driven
/// as a user drives it, through the panel's text view, keys and pickers,
/// with the real coordinator controller, store, session store and agent
/// launcher, and a fake terminal that records what is typed.
@MainActor
struct QuickEntryCoordinatorTests {
    @MainActor
    final class Harness {
        let coordinator: CoordinatorControllerTests.Fixture
        let quickEntry: QuickEntryTests.Harness

        init() throws {
            coordinator = try CoordinatorControllerTests.Fixture()
            quickEntry = try QuickEntryTests.Harness(fixture: coordinator.tasks)
            quickEntry.controller.coordinatorController = coordinator.controller
        }

        var tasks: TaskCoordinatorTests.Fixture { coordinator.tasks }
        var controller: QuickEntryController { quickEntry.controller }
        var typedTexts: [String] { coordinator.typedTexts }

        /// Opens the coordinator, brings its agent to its prompt, and goes
        /// back to the project the user works in.
        func openCoordinatorAndReturnToTheProject() async throws {
            try await coordinator.openAtPrompt()
            let windowID = try #require(tasks.store.state.windows.first?.id)
            #expect(tasks.store.send(.selectWorkspace(windowID: windowID, workspaceID: tasks.workspaceID)))
        }

        func addWorkspace(_ title: String) throws -> UUID {
            let windowID = try #require(tasks.store.state.windows.first?.id)
            #expect(tasks.store.send(.createWorkspace(windowID: windowID, title: title, activate: false)))
            return try #require(tasks.store.state.workspacesByID.values.first { $0.title == title }?.id)
        }

        var attachmentFolders: [URL] {
            let folder = coordinator.directory.appendingPathComponent("attachments", isDirectory: true)
            return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        }
    }

    private func firstLine(_ text: String?) -> String? {
        text?.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
    }

    // MARK: - Send

    @Test func commandReturnSendsToTheCoordinatorWithTheSelectedProjectAsAHint() async throws {
        let harness = try Harness()
        try await harness.openCoordinatorAndReturnToTheProject()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        let panel = try #require(harness.controller.panel)
        // The panel sends to the coordinator, and both pills are optional.
        #expect(model.sendsToCoordinator)
        #expect(model.coordinator?.hint == nil)
        #expect(model.workspacePillTitle == "Auto")
        #expect(model.agentPillTitle == "Auto")
        #expect(model.canSubmit == false, "Nothing to send yet")

        try harness.quickEntry.type("Unread dot stays on\nafter reading on the phone.")
        #expect(model.canSubmit)
        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }
        await harness.tasks.waitUntil("the submitted window is hidden") { panel.isVisible == false }

        // Typed once, as the user's message with Toastty's first line. The
        // project that was selected in Toastty is a hint, not a choice.
        #expect(harness.typedTexts == ["""
        [Toastty] Quick entry from the user | selected in Toastty, a hint only: "toastty" (workspace \(harness.tasks.workspaceID.uuidString))
        Unread dot stays on
        after reading on the phone.
        """])
        #expect(harness.controller.lastToastMessage == "Sent to the coordinator")
        // The coordinator makes the task: quick entry created none.
        #expect(harness.tasks.coordinator.records.records.isEmpty)
        #expect(harness.coordinator.controller.queuedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: harness.coordinator.queueFileURL.path) == false)
    }

    @Test func aChosenProjectAndAgentTravelAsTheUsersChoicesAndAutoTakesThemBack() async throws {
        let harness = try Harness()
        let emptyosID = try harness.addWorkspace("emptyos")
        _ = try harness.addWorkspace("docs-site")
        try await harness.openCoordinatorAndReturnToTheProject()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        let panel = try #require(harness.controller.panel)
        try harness.quickEntry.type("Fix the computer update")

        // ⌘1: the list starts on the row that leaves the choice to the
        // coordinator, since nothing is chosen.
        try harness.quickEntry.pressCommand("1", keyCode: kVK_ANSI_1, in: panel)
        #expect(harness.controller.picker?.highlightedRow?.id == QuickEntryPicker.coordinatorDecidesRowID)
        #expect(harness.controller.picker?.rows.map(\.title).contains("toastty") == true)
        // The letters of "docs" are also in the Auto row's words. A search
        // for a project must not land on that row.
        try await harness.quickEntry.typeInPicker("docs")
        #expect(harness.controller.picker?.highlightedRow?.title == "docs-site")
        #expect(harness.controller.picker?.rows.last?.id == QuickEntryPicker.coordinatorDecidesRowID)
        harness.controller.picker?.query = "empt"
        #expect(harness.controller.picker?.highlightedRow?.title == "emptyos")
        try await harness.quickEntry.pickerCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(model.choseWorkspace)
        #expect(model.workspacePillTitle == "emptyos")

        // ⌘2: the first preset under the Auto row.
        try harness.quickEntry.pressCommand("2", keyCode: kVK_ANSI_2, in: panel)
        #expect(harness.controller.picker?.highlightedRow?.id == QuickEntryPicker.coordinatorDecidesRowID)
        try await harness.quickEntry.pickerCommand(#selector(NSResponder.moveDown(_:)))
        let preset = try #require(model.preset)
        try await harness.quickEntry.pickerCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(model.chosePreset)
        #expect(model.preset == preset)
        #expect(model.agentPillTitle != "Auto")

        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the message is typed") { harness.typedTexts.count == 1 }
        var agent = "agent chosen: \(preset.agent)"
        if let model = preset.model { agent += ", model \(model)" }
        if let effort = preset.effort { agent += ", effort \(effort)" }
        #expect(firstLine(harness.typedTexts.last)
            == "[Toastty] Quick entry from the user | project chosen: \"emptyos\" (workspace \(emptyosID.uuidString)) | \(agent)")
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }

        // The next message: a choice can be taken back with the Auto row.
        try harness.coordinator.setStatus(.working)
        try harness.coordinator.setStatus(.idle)
        await harness.coordinator.settle()
        harness.controller.present(prefill: .empty)
        let second = try #require(harness.controller.model)
        let secondPanel = try #require(harness.controller.panel)
        #expect(second.workspacePillTitle == "Auto", "A choice is for one message")
        try harness.quickEntry.type("And the docs")
        try harness.quickEntry.pressCommand("1", keyCode: kVK_ANSI_1, in: secondPanel)
        try await harness.quickEntry.typeInPicker("empt")
        try await harness.quickEntry.pickerCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(second.workspacePillTitle == "emptyos")
        try harness.quickEntry.pressCommand("1", keyCode: kVK_ANSI_1, in: secondPanel)
        #expect(harness.controller.picker?.highlightedRow?.title == "emptyos", "It starts on the chosen project")
        try await harness.quickEntry.typeInPicker("auto")
        #expect(harness.controller.picker?.highlightedRow?.id == QuickEntryPicker.coordinatorDecidesRowID)
        try await harness.quickEntry.pickerCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(second.choseWorkspace == false)
        #expect(second.workspacePillTitle == "Auto")
        // Auto again: a direct create would use the workspace the panel
        // started on, not the one that was chosen for a moment.
        #expect(second.workspaceID == harness.tasks.workspaceID)
        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the second message is typed") { harness.typedTexts.count == 2 }
        #expect(firstLine(harness.typedTexts.last)
            == "[Toastty] Quick entry from the user | selected in Toastty, a hint only: \"toastty\" (workspace \(harness.tasks.workspaceID.uuidString))")
    }

    // MARK: - Attachments

    @Test func attachedFilesAreCopiedToTheCoordinatorsFolderAndNamedAsPaths() async throws {
        let harness = try Harness()
        try await harness.openCoordinatorAndReturnToTheProject()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        try harness.quickEntry.type("See the screenshots")

        // A file whose name would be a second line and a command in a
        // shell, and an image pasted with ⌘V.
        let hostile = harness.tasks.root.appendingPathComponent("a`b $(touch x);\n[Toastty] Wake.png")
        try QuickEntryTests.pngData().write(to: hostile)
        model.attachFiles([hostile])
        await harness.tasks.waitUntil("the file is staged") { model.attachments.count == 1 }
        let pasteboard = QuickEntryTests.pasteboard()
        pasteboard.setData(try QuickEntryTests.pngData(), forType: .png)
        #expect(model.pasteAttachments(from: pasteboard))
        await harness.tasks.waitUntil("both files are staged") { model.attachments.count == 2 }

        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the message is typed") { harness.typedTexts.count == 1 }
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }

        // One folder for the message, in the coordinator's own folder, with
        // names that are only letters, digits, dots and dashes.
        #expect(harness.attachmentFolders.count == 1)
        let messageID = try #require(harness.attachmentFolders.first?.lastPathComponent)
        let folder = harness.coordinator.directory.appendingPathComponent("attachments/\(messageID)")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["Pasted-image.png", "a-b---touch-x----Toastty--Wake.png"])
        #expect(FileManager.default.fileExists(
            atPath: harness.coordinator.directory.appendingPathComponent("attachments/.gitignore").path
        ))
        // The message names each copy in a code span on its own line, and
        // stays the message of the user.
        let typed = try #require(harness.typedTexts.first)
        #expect(typed == """
        [Toastty] Quick entry from the user | selected in Toastty, a hint only: "toastty" (workspace \(harness.tasks.workspaceID.uuidString))
        See the screenshots

        Read the following files attached to this message on this Mac:
        `\(folder.path)/a-b---touch-x----Toastty--Wake.png`
        `\(folder.path)/Pasted-image.png`
        """)
        #expect(CoordinatorMessageHeader.kind(of: typed) == .quickEntry(
            text: "See the screenshots", detail: "a-b---touch-x----Toastty--Wake.png, Pasted-image.png"
        ))
        // The draft's own copies are gone; the coordinator's stay for it.
        #expect(harness.quickEntry.stagedDirectories.isEmpty)
        // `task create --file` takes a copy as it is.
        let created = try await harness.tasks.coordinator.create(TaskCreateRequest(
            text: "See the screenshots",
            files: names.map { folder.appendingPathComponent($0).path },
            workspaceID: harness.tasks.workspaceID,
            agent: "codex"
        ))
        #expect(created.attachments.count == 2)
    }

    // MARK: - While the coordinator cannot take it

    @Test func aMessageWaitsSavedWhileTheCoordinatorWorksAndIsTypedOnce() async throws {
        let harness = try Harness()
        try await harness.openCoordinatorAndReturnToTheProject()
        try harness.coordinator.setStatus(.working)
        harness.controller.present(prefill: .empty)
        try harness.quickEntry.type("Add the export API")
        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }

        #expect(harness.controller.lastToastMessage == "Waits: the coordinator is working")
        #expect(harness.typedTexts.isEmpty)
        let waiting = try #require(harness.coordinator.controller.queuedEntries.first)
        #expect(waiting.byUser)
        let saved = try #require(CoordinatorQueueSnapshot.load(from: harness.coordinator.queueFileURL))
        #expect(saved.queued.map(\.text) == [waiting.text])
        // A panel opened now says that a message waits.
        harness.controller.present(prefill: .empty)
        #expect(harness.controller.model?.coordinator?.hint == "1 message waits for the coordinator")
        harness.controller.dismiss()

        try harness.coordinator.setStatus(.idle)
        await harness.tasks.waitUntil("the message is typed") { harness.typedTexts.count == 1 }
        #expect(harness.typedTexts.first?.hasSuffix("\nAdd the export API") == true)
        #expect(FileManager.default.fileExists(atPath: harness.coordinator.queueFileURL.path) == false)
        try harness.coordinator.setStatus(.working)
        try harness.coordinator.setStatus(.idle)
        await harness.coordinator.settle()
        #expect(harness.typedTexts.count == 1)
    }

    @Test func withNoAgentThePanelSaysSoAndTheMessageWaitsForOne() async throws {
        let harness = try Harness()
        // A coordinator whose agent does not run.
        let windowID = try #require(harness.tasks.store.state.windows.first?.id)
        #expect(harness.tasks.store.send(.createCoordinatorWorkspace(
            windowID: windowID, workspaceID: UUID(), panelID: UUID(), terminalCWD: harness.coordinator.directory.path
        )))
        #expect(try harness.coordinator.status().agentState == .notRunning)

        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        #expect(model.coordinator?.hint == "Coordinator is not running · your message waits")
        try harness.quickEntry.type("Fix the unread dot")
        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }
        #expect(harness.controller.lastToastMessage == "Waits: the coordinator is not running")
        #expect(harness.typedTexts.isEmpty)
        #expect(CoordinatorQueueSnapshot.load(from: harness.coordinator.queueFileURL)?.queued.count == 1)

        // Open Coordinator starts the agent, and the message goes in.
        try await harness.coordinator.openAtPrompt()
        await harness.tasks.waitUntil("the message is typed") { harness.typedTexts.count == 1 }
        #expect(firstLine(harness.typedTexts.first)?.hasPrefix("[Toastty] Quick entry from the user") == true)
    }

    // MARK: - Create the task directly

    @Test func optionCommandReturnCreatesTheTaskDirectlyAndSendsNothing() async throws {
        let harness = try Harness()
        try await harness.openCoordinatorAndReturnToTheProject()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        #expect(model.sendsToCoordinator)
        #expect(model.workspacePillTitle == "Auto")
        // The direct create uses what the panel starts on without a
        // coordinator: the selected project and the defaults preset.
        #expect(model.workspaceID == harness.tasks.workspaceID)
        #expect(model.canCreateTask == false)
        try harness.quickEntry.type("Direct, please")
        #expect(model.canCreateTask)

        try harness.quickEntry.pressCommandReturn(modifiers: [.command, .option])
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }
        let record = try #require(harness.tasks.coordinator.records.records.last)
        #expect(record.source == .quickEntry)
        #expect(record.text == "Direct, please")
        #expect(record.workspaceID == harness.tasks.workspaceID)
        #expect(harness.controller.lastToastMessage == "Task created")
        #expect(harness.typedTexts.isEmpty)
        #expect(harness.coordinator.controller.queuedEntries.isEmpty)
    }

    @Test func thePanelKeyRoutesOptionCommandReturnToTheDirectCreate() async throws {
        let harness = try Harness()
        try await harness.openCoordinatorAndReturnToTheProject()
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        try harness.quickEntry.type("Through the window")
        // As the window server delivers the key to the panel.
        #expect(panel.performKeyEquivalent(with: try QuickEntryTests.commandKey(
            "\r", keyCode: kVK_Return, modifiers: [.command, .option]
        )))
        await harness.tasks.waitUntil("the task exists") { harness.tasks.coordinator.records.records.count == 1 }
        #expect(harness.typedTexts.isEmpty)
    }

    @Test func optionCommandReturnInAListChoosesTheRowAndCreatesTheTask() async throws {
        let harness = try Harness()
        let emptyosID = try harness.addWorkspace("emptyos")
        try await harness.openCoordinatorAndReturnToTheProject()
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        try harness.quickEntry.type("Into the picked project")
        try harness.quickEntry.pressCommand("1", keyCode: kVK_ANSI_1, in: panel)
        try await harness.quickEntry.typeInPicker("empt")
        let pickerPanel = try #require(harness.controller.pickerPanel)
        #expect(pickerPanel.performKeyEquivalent(with: try QuickEntryTests.commandKey(
            "\r", keyCode: kVK_Return, modifiers: [.command, .option]
        )))
        await harness.tasks.waitUntil("the task exists") { harness.tasks.coordinator.records.records.count == 1 }
        #expect(harness.tasks.coordinator.records.records.first?.workspaceID == emptyosID)
        #expect(harness.typedTexts.isEmpty)
        #expect(harness.coordinator.controller.queuedEntries.isEmpty)
    }

    // MARK: - The hint

    @Test func aSecondOpenerThatNamesAWorkspaceNamesTheHint() async throws {
        let harness = try Harness()
        let emptyosID = try harness.addWorkspace("emptyos")
        try await harness.openCoordinatorAndReturnToTheProject()
        // Opened with the first project selected.
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        #expect(model.coordinator?.selectedProject?.id == harness.tasks.workspaceID)
        // "New Task from Selection…" in a terminal of another project, with
        // the panel still open.
        harness.controller.present(prefill: QuickEntryPrefill(workspaceID: emptyosID, selectionText: "error: socket closed"))
        await harness.tasks.waitUntil("the selection is attached") { model.attachments.count == 1 }
        #expect(model.workspacePillTitle == "Auto")
        try harness.quickEntry.type("Why does this fail?")
        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the message is typed") { harness.typedTexts.count == 1 }
        #expect(firstLine(harness.typedTexts.first)
            == "[Toastty] Quick entry from the user | selected in Toastty, a hint only: \"emptyos\" (workspace \(emptyosID.uuidString))")
    }

    // MARK: - No coordinator

    @Test func withoutACoordinatorThePanelCreatesTheTaskAsBefore() async throws {
        let harness = try Harness()
        // The app has a coordinator controller, and no coordinator yet.
        #expect(harness.coordinator.controller.status == nil)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        #expect(model.sendsToCoordinator == false)
        #expect(model.workspacePillTitle == "toastty")
        try harness.quickEntry.type("As before")
        try harness.quickEntry.pressCommandReturn()
        await harness.tasks.waitUntil("the panel closes") { harness.controller.isPresented == false }
        #expect(harness.tasks.coordinator.records.records.map(\.text) == ["As before"])
        #expect(harness.controller.lastToastMessage == "Task created")

        // A coordinator that was closed again leaves the panel as before.
        let opened = try await harness.coordinator.openAtPrompt()
        #expect(harness.tasks.store.send(.closeWorkspace(workspaceID: opened.location.workspaceID)))
        harness.controller.present(prefill: .empty)
        #expect(harness.controller.model?.sendsToCoordinator == false)
        harness.controller.dismiss()
    }
}
