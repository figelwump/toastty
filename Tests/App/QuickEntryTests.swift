import AppKit
import Carbon.HIToolbox
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Drives the quick entry panel the way a user does: type into its text
/// view, attach, press ⌘↩ or Esc. Tasks are created by the real coordinator
/// over the real store, with a fake terminal in place of Ghostty.
@MainActor
struct QuickEntryTests {
    @MainActor
    final class Harness {
        let fixture: TaskCoordinatorTests.Fixture
        let stagingRoot: URL
        let controller: QuickEntryController

        init(
            create: (@MainActor (TaskCreateRequest) async throws -> TaskRecord)? = nil,
            recordsPresetUsage: Bool = false
        ) throws {
            let fixture = try TaskCoordinatorTests.Fixture()
            fixture.config = TasksConfig(defaults: .init(agent: "claude"))
            let stagingRoot = fixture.root.appendingPathComponent("quick-entry-staging", isDirectory: true)
            self.fixture = fixture
            self.stagingRoot = stagingRoot
            controller = QuickEntryController(
                store: fixture.store,
                agentProfiles: { [unowned fixture] in fixture.launcher.launchProfileSummaries() },
                presetUsage: recordsPresetUsage
                    ? QuickEntryPresetUsage(runtimePaths: .resolve(homeDirectoryPath: fixture.root.path, environment: [:]))
                    : nil,
                create: create ?? { request in
                    try await fixture.coordinator.create(request, caller: .quickEntry)
                },
                configLoader: { [unowned fixture] in
                    if let configError = fixture.configError { throw configError }
                    return fixture.config
                },
                stagingRootURL: stagingRoot,
                registersGlobalHotKey: false,
                toastDuration: .milliseconds(50)
            )
        }

        func textView() throws -> QuickEntryNSTextView {
            let contentView = try #require(controller.panel?.contentView)
            return try #require(Self.firstTextView(in: contentView))
        }

        private static func firstTextView(in view: NSView) -> QuickEntryNSTextView? {
            if let textView = view as? QuickEntryNSTextView { return textView }
            for subview in view.subviews {
                if let found = firstTextView(in: subview) { return found }
            }
            return nil
        }

        func type(_ text: String) throws {
            let textView = try textView()
            textView.insertText(text, replacementRange: textView.selectedRange())
        }

        func pressCommandReturn() throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: UInt16(kVK_Return)
            ))
            try textView().keyDown(with: event)
        }

        /// The open picker's search field editor, once the field has
        /// focus in the picker's window.
        func pickerEditor() async throws -> NSTextView {
            let pickerPanel = try #require(controller.pickerPanel)
            await fixture.waitUntil("the picker's search has focus") {
                (pickerPanel.firstResponder as? NSTextView)?.delegate is NSTextField
            }
            return try #require(pickerPanel.firstResponder as? NSTextView)
        }

        func typeInPicker(_ text: String) async throws {
            let editor = try await pickerEditor()
            editor.insertText(text, replacementRange: editor.selectedRange())
        }

        func pickerCommand(_ selector: Selector) async throws {
            try await pickerEditor().doCommand(by: selector)
        }

        /// A key typed into the open picker, as the window server delivers it.
        func typeKeyInPicker(_ characters: String, keyCode: Int) throws {
            let pickerPanel = try #require(controller.pickerPanel)
            pickerPanel.sendEvent(try QuickEntryTests.commandKey(characters, keyCode: keyCode, modifiers: []))
        }

        func pressCommand(_ characters: String, keyCode: Int, in window: NSWindow?) throws {
            let window = try #require(window)
            #expect(window.performKeyEquivalent(with: try QuickEntryTests.commandKey(characters, keyCode: keyCode)))
        }

        var stagedDirectories: [URL] {
            (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
        }
    }

    /// A create held open by the test.
    @MainActor
    final class PendingCreate {
        var continuation: CheckedContinuation<TaskRecord, any Error>?
    }

    static func pngData() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    static func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("toastty-quick-entry-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    @Test func commandReturnCreatesTheTaskWithItsFilesAndClosesThePanel() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: QuickEntryPrefill(workspaceID: fixture.workspaceID))
        let model = try #require(harness.controller.model)
        #expect(harness.controller.isPresented)
        #expect(harness.controller.panel?.styleMask.contains(.nonactivatingPanel) == true)

        try harness.type("Unread dot stays on\nafter reading on the phone.")
        #expect(model.text == "Unread dot stays on\nafter reading on the phone.")

        // A file from Finder and an image pasted with ⌘V.
        let screenshot = fixture.root.appendingPathComponent("Screenshot 4.11.52 PM.png")
        try Self.pngData().write(to: screenshot)
        model.attachFiles([screenshot])
        let pasteboard = Self.pasteboard()
        pasteboard.setData(try Self.pngData(), forType: .png)
        #expect(model.pasteAttachments(from: pasteboard))
        await fixture.waitUntil("both files are staged") { model.attachments.count == 2 }
        #expect(harness.stagedDirectories.count == 1)

        try harness.pressCommandReturn()
        await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }

        let record = try #require(fixture.coordinator.records.records.last)
        #expect(record.source == .quickEntry)
        #expect(record.text == "Unread dot stays on\nafter reading on the phone.")
        #expect(record.title == "Unread dot stays on")
        #expect(record.workspaceID == fixture.workspaceID)
        #expect(Set(record.attachments.map(\.displayName)) == ["Screenshot 4.11.52 PM.png", "Pasted image.png"])
        // Toastty's own copies, outside the staging folder, which is gone.
        for attachment in record.attachments {
            #expect(attachment.path.hasPrefix(fixture.attachmentsDirectory.path))
            #expect(FileManager.default.fileExists(atPath: attachment.path))
        }
        #expect(harness.stagedDirectories.isEmpty)
        await fixture.waitForSetup(record.id)
        #expect(fixture.record(record.id)?.setup == .started)
    }

    @Test func autoWorkspaceWithTriageOffSavesTheTaskForTheUserToPlace() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        #expect(model.workspaceID == nil)
        try harness.type("Place me later")

        try harness.pressCommandReturn()
        await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }

        let record = try #require(fixture.coordinator.records.records.first)
        #expect(record.source == .quickEntry)
        #expect(record.workspaceID == nil)
        guard case .needsWorkspace = record.setup else {
            Issue.record("Expected the task to wait for a workspace, got \(record.setup)")
            return
        }
    }

    @Test func aFailedCreateKeepsThePanelAndTheTextUntilItSucceeds() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        fixture.configError = TaskError("tasks.toml line 3: [defaults] agent is empty")
        harness.controller.present(prefill: QuickEntryPrefill(workspaceID: fixture.workspaceID))
        let model = try #require(harness.controller.model)
        try harness.type("Keep this text")

        try harness.pressCommandReturn()
        await fixture.waitUntil("the error shows") { model.errorMessage != nil }
        #expect(model.errorMessage?.contains("[defaults] agent is empty") == true)
        #expect(harness.controller.isPresented)
        #expect(model.text == "Keep this text")
        #expect(fixture.coordinator.records.records.isEmpty)

        fixture.configError = nil
        try harness.pressCommandReturn()
        await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }
        #expect(fixture.coordinator.records.records.map(\.text) == ["Keep this text"])
    }

    @Test func escapeClosesWithoutCreatingAndRemovesStagedFiles() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        try harness.type("Never mind")
        model.attachText("notes", named: "notes.txt")
        #expect(harness.stagedDirectories.count == 1)

        try harness.textView().cancelOperation(nil)

        #expect(harness.controller.isPresented == false)
        #expect(harness.stagedDirectories.isEmpty)
        #expect(fixture.coordinator.records.records.isEmpty)
    }

    @Test func newTaskFromSelectionAttachesTheTextAndPicksTheTerminalsWorkspace() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        let panelID = try #require(fixture.store.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)

        harness.controller.presentFromSelection("error: socket closed (POSIX 53)", panelID: panelID)

        let model = try #require(harness.controller.model)
        #expect(model.workspaceID == fixture.workspaceID)
        #expect(model.workspaceTitle == "toastty")
        let attachment = try #require(model.attachments.first)
        #expect(attachment.displayName == "selection.txt")
        #expect(try String(contentsOf: attachment.url, encoding: .utf8) == "error: socket closed (POSIX 53)")
        // The task text stays empty for the user to write.
        #expect(model.text.isEmpty)
        #expect(model.canSubmit == false)
        harness.controller.dismiss()
    }

    @Test func theShortcutAgainBringsTheOpenPanelBackWithItsDraft() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let panel = harness.controller.panel
        try harness.type("Draft")

        harness.controller.handleHotKey()

        #expect(harness.controller.panel === panel)
        #expect(harness.controller.model?.text == "Draft")
        harness.controller.dismiss()
    }

    @Test func pastedTextPastesAndDroppedLinksJoinTheText() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)

        // Copying an image in a browser also copies text; that pastes as text.
        let mixed = Self.pasteboard()
        mixed.setString("alt text", forType: .string)
        mixed.setData(try Self.pngData(), forType: .png)
        #expect(model.pasteAttachments(from: mixed) == false)

        let link = Self.pasteboard()
        link.writeObjects([NSURL(string: "https://github.com/figelwump/toastty/pull/166")!])
        #expect(model.handleDrop(from: link))
        await harness.fixture.waitUntil("the link joins the text") { model.text.isEmpty == false }
        #expect(model.text == "https://github.com/figelwump/toastty/pull/166")
        #expect(model.attachments.isEmpty)
        harness.controller.dismiss()
    }

    @Test func refusesAttachmentsPastTheTaskLimit() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        for index in 0..<TaskRecord.maximumAttachmentCount {
            model.attachText("\(index)", named: "note.txt")
        }
        #expect(model.attachments.count == TaskRecord.maximumAttachmentCount)
        // Same names are kept apart.
        #expect(Set(model.attachments.map(\.displayName)).count == TaskRecord.maximumAttachmentCount)
        #expect(model.canAttachMore == false)

        model.attachText("one more", named: "note.txt")
        #expect(model.attachments.count == TaskRecord.maximumAttachmentCount)
        #expect(model.errorMessage == "Attach at most \(TaskRecord.maximumAttachmentCount) files.")
        harness.controller.dismiss()
    }

    static func commandKey(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode)
        ))
    }

    @Test func commandShortcutsStayInsideThePanel() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        try harness.type("Draft")
        let before = fixture.store.state

        // ⌘T would open a tab in the Toastty window behind the panel.
        #expect(panel.performKeyEquivalent(with: try Self.commandKey("t", keyCode: kVK_ANSI_T)))
        #expect(fixture.store.state == before)
        #expect(harness.controller.isPresented)

        // ⌘W closes the panel, not the focused terminal behind it.
        #expect(panel.performKeyEquivalent(with: try Self.commandKey("w", keyCode: kVK_ANSI_W)))
        #expect(harness.controller.isPresented == false)
        #expect(fixture.store.state == before)
        #expect(fixture.coordinator.records.records.isEmpty)
    }

    @Test func commandShortcutRouting() {
        let cases: [(String, Int, NSEvent.ModifierFlags, QuickEntryPanel.CommandAction)] = [
            ("1", kVK_ANSI_1, .command, .picker(.workspace)),
            ("2", kVK_ANSI_2, .command, .picker(.agent)),
            ("\u{F702}", kVK_LeftArrow, .command, .textNavigation),
            ("\u{7F}", kVK_Delete, .command, .textNavigation),
            ("3", kVK_ANSI_3, .command, .ignore),
            ("w", kVK_ANSI_W, .command, .close),
            (".", kVK_ANSI_Period, .command, .close),
            ("\r", kVK_Return, .command, .submit),
            ("q", kVK_ANSI_Q, .command, .application),
            ("v", kVK_ANSI_V, .command, .edit(#selector(NSText.paste(_:)))),
            ("z", kVK_ANSI_Z, [.command, .shift], .edit(Selector(("redo:")))),
            ("n", kVK_ANSI_N, .command, .ignore),
            ("d", kVK_ANSI_D, .command, .ignore),
        ]
        for (key, keyCode, modifiers, action) in cases {
            #expect(QuickEntryPanel.commandAction(key: key, keyCode: UInt16(keyCode), modifiers: modifiers) == action, "\(modifiers) \(key)")
        }
    }

    @Test func commandDeleteAndArrowsEditTheText() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        let textView = try harness.textView()
        await harness.fixture.waitUntil("the text has focus") { panel.firstResponder === textView }
        try harness.type("First line\nsecond line")
        // ⌘⌫ deletes to the start of the line, in the text, not in a menu.
        try harness.pressCommand("\u{7F}", keyCode: kVK_Delete, in: panel)
        #expect(harness.controller.model?.text == "First line\n")
        harness.controller.dismiss()
    }

    // MARK: - Pickers

    @Test func commandOneOpensTheWorkspacePickerAndReturnPicksAndRefocusesTheText() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        let model = try #require(harness.controller.model)
        try harness.type("Fix the sidebar")
        #expect(model.workspaceTitle == "Auto")

        try harness.pressCommand("1", keyCode: kVK_ANSI_1, in: panel)
        let pickerPanel = try #require(harness.controller.pickerPanel)
        #expect(pickerPanel.isVisible)
        #expect(pickerPanel.parent === panel)
        #expect(pickerPanel.styleMask.contains(.nonactivatingPanel))
        #expect(model.openPicker == .workspace)
        // It hangs from the Workspace pill.
        let pill = try #require(model.pillFrames[.workspace])
        #expect(abs(pickerPanel.frame.minX - (panel.frame.minX + pill.minX)) < 1)

        try await harness.typeInPicker("toas")
        #expect(harness.controller.picker?.highlightedRow?.title == "toastty")
        try await harness.pickerCommand(#selector(NSResponder.insertNewline(_:)))

        #expect(harness.controller.pickerPanel == nil)
        #expect(pickerPanel.isVisible == false)
        #expect(model.openPicker == nil)
        #expect(model.workspaceID == fixture.workspaceID)
        #expect(model.workspaceTitle == "toastty")
        await fixture.waitUntil("the panel is key with the text focused") {
            panel.isKeyWindow && panel.firstResponder === (try? harness.textView())
        }
        #expect(model.text == "Fix the sidebar")
        harness.controller.dismiss()
    }

    /// Wires the pill's button to its picker. A real click also has to get
    /// past the panel's background drag; the live check covers that.
    @Test func aClickOnAPillOpensItsPicker() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        let model = try #require(harness.controller.model)
        await harness.fixture.waitUntil("the pills are laid out") { model.pillFrames[.agent] != nil }
        let pill = try #require(model.pillFrames[.agent])
        let location = NSPoint(x: pill.midX, y: panel.frame.height - pill.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 7, clickCount: 1, pressure: 1
            )))
        }
        await harness.fixture.waitUntil("the click opens the Agent picker") { harness.controller.picker?.kind == .agent }
        harness.controller.dismiss()
    }

    @Test func escapeAndCommandWCloseOnlyThePicker() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let panel = try #require(harness.controller.panel)
        let model = try #require(harness.controller.model)

        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: panel)
        try await harness.typeInPicker("codex")
        try await harness.pickerCommand(#selector(NSResponder.cancelOperation(_:)))
        #expect(harness.controller.pickerPanel == nil)
        #expect(harness.controller.isPresented)
        #expect(model.preset == nil, "Esc keeps the pill as it was")

        try harness.pressCommand("1", keyCode: kVK_ANSI_1, in: panel)
        try harness.pressCommand("w", keyCode: kVK_ANSI_W, in: harness.controller.pickerPanel)
        #expect(harness.controller.pickerPanel == nil)
        #expect(harness.controller.isPresented)

        // ⌘1 toggles, and ⌘2 switches from one picker to the other.
        try harness.pressCommand("1", keyCode: kVK_ANSI_1, in: panel)
        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: harness.controller.pickerPanel)
        #expect(harness.controller.picker?.kind == .agent)
        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: harness.controller.pickerPanel)
        #expect(harness.controller.pickerPanel == nil)
        #expect(harness.controller.isPresented)
        harness.controller.dismiss()
    }

    @Test func commandTwoPinsTheDefaultsPresetWithAnEffortAndTheAgentStartsWithIt() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        fixture.config = TasksConfig(defaults: .init(agent: "claude", model: "claude-opus-5-5", effort: "high"))
        harness.controller.present(prefill: QuickEntryPrefill(workspaceID: fixture.workspaceID))
        let panel = try #require(harness.controller.panel)
        let model = try #require(harness.controller.model)
        try harness.type("Composer keeps a blank line")

        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: panel)
        let picker = try #require(harness.controller.picker)
        #expect(picker.rows.first?.title == "Claude Code · claude-opus-5-5")
        #expect(picker.highlightedRow?.id == picker.rows.first?.id)
        try await harness.pickerCommand(#selector(NSResponder.moveRight(_:)))
        #expect(picker.rows.first?.detail == "xhigh")
        try await harness.pickerCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(model.preset == QuickEntryPreset(agent: "claude", model: "claude-opus-5-5", effort: "xhigh"))
        #expect(model.agentTitle == "claude-opus-5-5 · xhigh")

        try harness.pressCommandReturn()
        await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }
        let record = try #require(fixture.coordinator.records.records.last)
        #expect(record.pinned.agent == "claude")
        #expect(record.pinned.model == "claude-opus-5-5")
        #expect(record.pinned.effort == "xhigh")
        await fixture.waitForSetup(record.id)
        let panelID = try #require(fixture.record(record.id)?.operation.taskSpace?.panelID)
        let sent = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(sent.contains("--model claude-opus-5-5"))
        #expect(sent.contains("--effort xhigh"))
    }

    @Test func theColumnsPickAnAgentModelAndEffortSeparately() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: QuickEntryPrefill(workspaceID: fixture.workspaceID))
        let panel = try #require(harness.controller.panel)
        let model = try #require(harness.controller.model)
        try harness.type("Release notes")

        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: panel)
        try await harness.typeInPicker("gp")
        try harness.pressCommand("\u{F703}", keyCode: kVK_RightArrow, in: harness.controller.pickerPanel)
        let picker = try #require(harness.controller.picker)
        #expect(picker.columns?.focused == .agent)
        // Cleared at once, before SwiftUI updates the field: the next key
        // can come first.
        #expect(try await harness.pickerEditor().string.isEmpty)
        try await harness.typeInPicker("codex")
        try await harness.pickerCommand(#selector(NSResponder.insertTab(_:)))
        try await harness.typeInPicker("gpt-6.1-sol")
        try await harness.pickerCommand(#selector(NSResponder.insertTab(_:)))
        try await harness.typeInPicker("hi")
        #expect(picker.columns?.preset == QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol", effort: "high"))
        try await harness.pickerCommand(#selector(NSResponder.insertNewline(_:)))
        #expect(harness.controller.pickerPanel == nil)
        #expect(model.agentTitle == "gpt-6.1-sol · high")

        try harness.pressCommandReturn()
        await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }
        let record = try #require(fixture.coordinator.records.records.last)
        #expect(record.pinned.agent == "codex")
        #expect(record.pinned.model == "gpt-6.1-sol")
        #expect(record.pinned.effort == "high")
        await fixture.waitForSetup(record.id)
        let panelID = try #require(fixture.record(record.id)?.operation.taskSpace?.panelID)
        let sent = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(sent.contains("gpt-6.1-sol"))
        #expect(sent.contains("model_reasoning_effort"))
    }

    @Test func aPresetChosenTwiceIsListedFirstAndItsNumberPicksIt() async throws {
        let harness = try Harness(recordsPresetUsage: true)
        let fixture = harness.fixture
        fixture.config = TasksConfig(defaults: .init(agent: "claude", model: "claude-opus-5-5", effort: "high"))
        let sol = QuickEntryPreset(agent: "codex", model: "gpt-6.1-sol", effort: "high")

        func create(_ text: String, choosing: Bool) async throws {
            harness.controller.present(prefill: QuickEntryPrefill(workspaceID: fixture.workspaceID))
            let panel = try #require(harness.controller.panel)
            try harness.type(text)
            if choosing {
                // The three columns, each part chosen separately.
                try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: panel)
                try harness.pressCommand("\u{F703}", keyCode: kVK_RightArrow, in: harness.controller.pickerPanel)
                try await harness.typeInPicker("codex")
                try await harness.pickerCommand(#selector(NSResponder.insertTab(_:)))
                try await harness.typeInPicker("gpt-6.1-sol")
                try await harness.pickerCommand(#selector(NSResponder.insertTab(_:)))
                try await harness.typeInPicker("high")
                try await harness.pickerCommand(#selector(NSResponder.insertNewline(_:)))
                #expect(harness.controller.model?.preset == sol)
            }
            try harness.pressCommandReturn()
            await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }
        }

        // Until a preset has two uses, Frequent is the [defaults] preset.
        try await create("First", choosing: true)
        try await create("Auto does not count", choosing: false)
        harness.controller.present(prefill: .empty)
        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: harness.controller.panel)
        #expect(harness.controller.picker?.rows.first?.title == "Claude Code · claude-opus-5-5")
        harness.controller.dismiss()

        try await create("Second", choosing: true)
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: harness.controller.panel)
        let picker = try #require(harness.controller.picker)
        #expect(picker.rows.filter { $0.section == "Frequent" }.map(\.title) == ["Codex · gpt-6.1-sol"])
        #expect(picker.rows.first?.number == 1)

        // With text in the search, a digit is typed.
        try await harness.typeInPicker("c")
        try harness.typeKeyInPicker("1", keyCode: kVK_ANSI_1)
        #expect(harness.controller.pickerPanel != nil)
        #expect(try await harness.pickerEditor().string == "c1")
        #expect(harness.controller.picker?.query == "c1")
        try await harness.pickerEditor().string = ""
        harness.controller.picker?.query = ""
        // Shift+1 is a character, not the shortcut.
        let shifted = try QuickEntryTests.commandKey("!", keyCode: kVK_ANSI_1, modifiers: .shift)
        harness.controller.pickerPanel?.sendEvent(shifted)
        #expect(harness.controller.pickerPanel != nil)
        try await harness.pickerEditor().string = ""
        harness.controller.picker?.query = ""
        try harness.typeKeyInPicker("1", keyCode: kVK_ANSI_1)
        #expect(harness.controller.pickerPanel == nil)
        #expect(model.preset == sol)

        // In the columns, digits filter.
        try harness.pressCommand("2", keyCode: kVK_ANSI_2, in: harness.controller.panel)
        try harness.pressCommand("\u{F703}", keyCode: kVK_RightArrow, in: harness.controller.pickerPanel)
        try harness.typeKeyInPicker("1", keyCode: kVK_ANSI_1)
        #expect(harness.controller.picker?.columns != nil)
        #expect(harness.controller.picker?.query == "1")
        harness.controller.dismiss()

        let saved = try String(contentsOf: fixture.root.appendingPathComponent(".toastty/task-preset-usage.json"), encoding: .utf8)
        #expect(saved.contains("gpt-6.1-sol"))
        #expect(saved.contains("\"count\" : 2"))
    }

    @Test func aPromisedFileHoldsItsSlotAndBlocksCreateUntilItArrives() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        harness.controller.present(prefill: QuickEntryPrefill(workspaceID: fixture.workspaceID))
        let model = try #require(harness.controller.model)
        try harness.type("With a screenshot")

        let promise = try #require(model.beginPromisedAttachment())
        #expect(model.canSubmit == false)
        try harness.pressCommandReturn()
        #expect(harness.controller.isPresented)
        #expect(fixture.coordinator.records.records.isEmpty)

        try FileManager.default.createDirectory(at: promise.directoryURL, withIntermediateDirectories: true)
        let delivered = promise.directoryURL.appendingPathComponent("Screenshot.png")
        try Self.pngData().write(to: delivered)
        model.finishPromisedAttachment(.success(delivered))
        #expect(model.attachments.map(\.displayName) == ["Screenshot.png"])
        #expect(model.canSubmit)

        try harness.pressCommandReturn()
        await fixture.waitUntil("the panel closes") { harness.controller.isPresented == false }
        #expect(fixture.coordinator.records.records.first?.attachments.map(\.displayName) == ["Screenshot.png"])
    }

    @Test func promisesCountAgainstTheAttachmentLimit() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        for index in 0..<(TaskRecord.maximumAttachmentCount - 1) {
            model.attachText("\(index)", named: "note.txt")
        }
        #expect(model.beginPromisedAttachment() != nil)
        #expect(model.beginPromisedAttachment() == nil)
        #expect(model.errorMessage == "Attach at most \(TaskRecord.maximumAttachmentCount) files.")
        harness.controller.dismiss()
    }

    @Test func aCopyThatFinishesAfterEscIsThrownAwayWithTheStagingFolder() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        model.attachText("kept until the copy ends", named: "notes.txt")
        let promise = try #require(model.beginPromisedAttachment())
        try FileManager.default.createDirectory(at: promise.directoryURL, withIntermediateDirectories: true)

        try harness.textView().cancelOperation(nil)
        #expect(harness.controller.isPresented == false)
        // A copy is still writing, so the folder stays until it ends.
        #expect(harness.stagedDirectories.count == 1)

        let late = promise.directoryURL.appendingPathComponent("late.png")
        try Self.pngData().write(to: late)
        model.finishPromisedAttachment(.success(late))
        #expect(model.attachments.map(\.displayName) == ["notes.txt"])
        #expect(harness.stagedDirectories.isEmpty)
        #expect(harness.fixture.coordinator.records.records.isEmpty)
    }

    @Test func theDraftIsLockedWhileTheTaskIsBeingCreated() async throws {
        let pending = PendingCreate()
        let harness = try Harness(create: { _ in
            try await withCheckedThrowingContinuation { pending.continuation = $0 }
        })
        harness.controller.present(prefill: .empty)
        let model = try #require(harness.controller.model)
        try harness.type("Locked while saving")
        model.attachText("first", named: "a.txt")
        let attachment = try #require(model.attachments.first)

        try harness.pressCommandReturn()
        await harness.fixture.waitUntil("the create starts") { pending.continuation != nil }
        #expect(model.isSubmitting)
        // The text view follows the model on SwiftUI's next update.
        await harness.fixture.waitUntil("the editor locks") { (try? harness.textView().isEditable) == false }
        model.attachText("second", named: "b.txt")
        model.removeAttachment(id: attachment.id)
        try harness.textView().cancelOperation(nil)
        #expect(model.attachments.map(\.displayName) == ["a.txt"])
        #expect(FileManager.default.fileExists(atPath: attachment.url.path(percentEncoded: false)))
        #expect(harness.controller.isPresented)

        pending.continuation?.resume(throwing: TaskError("Toastty could not save the task."))
        await harness.fixture.waitUntil("the create ends") { model.isSubmitting == false }
        #expect(model.isEditable)
        await harness.fixture.waitUntil("the editor unlocks") { (try? harness.textView().isEditable) == true }
        #expect(model.errorMessage == "Toastty could not save the task.")
        harness.controller.dismiss()
    }

    @Test func quittingWithThePanelOpenRemovesTheStagedFiles() async throws {
        let harness = try Harness()
        harness.controller.present(prefill: .empty)
        harness.controller.model?.attachText("draft", named: "notes.txt")
        #expect(harness.stagedDirectories.count == 1)

        harness.controller.handleTermination()
        #expect(harness.stagedDirectories.isEmpty)
        harness.controller.dismiss()
    }

    @Test func aBrokenFileAtLaunchUsesTheDefaultShortcut() throws {
        let harness = try Harness()
        harness.fixture.configError = TasksConfigParseError(line: 2, message: "[quick_entry] the shortcut \"t\" needs Command")
        let message = try #require(harness.controller.reloadShortcut())
        #expect(message.contains("⌥⇧T until the file is fixed"))
        #expect(harness.controller.shortcut == .default)
    }

    @Test func aBrokenFileOnReloadKeepsTheShortcutInUse() throws {
        let harness = try Harness()
        let fixture = harness.fixture
        fixture.config.quickEntry = .init(shortcut: try QuickEntryShortcut.parse("ctrl+opt+space"))
        #expect(harness.controller.reloadShortcut() == nil)
        #expect(harness.controller.shortcut?.symbolLabel == "⌃⌥Space")

        fixture.config.quickEntry = .init(shortcut: nil)
        #expect(harness.controller.reloadShortcut() == nil)
        #expect(harness.controller.shortcut == nil)

        // A typo elsewhere in the file must not turn the shortcut back on.
        fixture.configError = TasksConfigParseError(line: 9, message: "[defaults] agent is empty")
        let message = try #require(harness.controller.reloadShortcut())
        #expect(message.contains("stays off until the file is fixed"))
        #expect(harness.controller.shortcut == nil)
    }
}

@MainActor
struct QuickEntryHotKeyTests {
    @Test func everyKeyTheConfigAcceptsHasAKeyCode() throws {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789") + Array(QuickEntryShortcut.Key.punctuation)
        for character in characters {
            let shortcut = try QuickEntryShortcut.parse("ctrl+opt+\(character)")
            #expect(QuickEntryHotKey.characterKeyCodes[character] != nil, "\(character)")
            #expect(shortcut.key == .character(character))
        }
        #expect(QuickEntryHotKey.carbonKeyCode(for: .character("t")) == UInt32(kVK_ANSI_T))
        #expect(QuickEntryHotKey.carbonKeyCode(for: .function(20)) == UInt32(kVK_F20))
        #expect(QuickEntryHotKey.carbonModifiers(for: [.option, .shift]) == UInt32(optionKey | shiftKey))
    }

    @Test func registersReplacesAndTurnsOff() throws {
        let hotKey = QuickEntryHotKey {}
        // An unlikely combination, so it does not collide with the
        // machine's own shortcuts.
        let first = QuickEntryShortcut(modifiers: [.control, .option, .shift, .command], key: .function(19))
        #expect(hotKey.register(first) == .registered(first))

        let second = QuickEntryShortcut(modifiers: [.control, .option, .shift, .command], key: .function(18))
        #expect(hotKey.register(second) == .registered(second))
        // The earlier one is released, so registering it again works.
        let other = QuickEntryHotKey {}
        #expect(other.register(first) == .registered(first))
        other.unregister()

        #expect(hotKey.register(nil) == .off)
    }
}

/// Where the panel opens with a laptop and an external display: the laptop
/// is the primary screen at the origin, the external one sits to its right.
struct QuickEntryPlacementTests {
    let laptop = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let laptopVisible = NSRect(x: 0, y: 0, width: 1512, height: 944)
    let external = NSRect(x: 1512, y: -200, width: 2560, height: 1440)
    let externalVisible = NSRect(x: 1512, y: -200, width: 2560, height: 1415)
    let size = NSSize(width: 600, height: 210)

    @Test func opensOnTheScreenOfTheFocusedWindowNotThePointer() {
        let editorOnExternal = NSRect(x: 1700, y: 100, width: 1600, height: 900)
        let pointerOnLaptop = NSPoint(x: 300, y: 300)

        let index = QuickEntryPlacement.screenIndex(
            focusedWindowFrame: editorOnExternal,
            pointer: pointerOnLaptop,
            screenFrames: [laptop, external]
        )

        #expect(index == 1)
    }

    @Test func aWindowAcrossTwoScreensCountsForTheOneHoldingMoreOfIt() {
        let straddling = NSRect(x: 1300, y: 100, width: 1000, height: 600)

        #expect(QuickEntryPlacement.screenIndex(
            focusedWindowFrame: straddling,
            pointer: .zero,
            screenFrames: [laptop, external]
        ) == 1)
    }

    @Test func withoutAFocusedWindowTheScreenWithThePointerWins() {
        #expect(QuickEntryPlacement.screenIndex(
            focusedWindowFrame: nil,
            pointer: NSPoint(x: 2000, y: 400),
            screenFrames: [laptop, external]
        ) == 1)
        #expect(QuickEntryPlacement.screenIndex(
            focusedWindowFrame: NSRect(x: 9000, y: 9000, width: 100, height: 100),
            pointer: NSPoint(x: 300, y: 300),
            screenFrames: [laptop, external]
        ) == 0)
    }

    @Test func aRememberedSpotOnAnotherScreenIsIgnored() {
        let leftOnLaptop = QuickEntryPlacement.Remembered(topLeft: NSPoint(x: 100, y: 800), screenFrame: laptop)

        let frame = QuickEntryPlacement.frame(
            size: size,
            screenFrame: external,
            visibleFrame: externalVisible,
            remembered: leftOnLaptop
        )

        #expect(frame == QuickEntryPanel.defaultFrame(size: size, visibleFrame: externalVisible))
        #expect(externalVisible.contains(frame))
    }

    @Test func aRememberedSpotOnTheSameScreenIsReusedAndKeptOnScreen() {
        let moved = QuickEntryPlacement.Remembered(topLeft: NSPoint(x: 1900, y: 1000), screenFrame: external)
        let frame = QuickEntryPlacement.frame(
            size: size,
            screenFrame: external,
            visibleFrame: externalVisible,
            remembered: moved
        )
        #expect(frame.origin == NSPoint(x: 1900, y: 790))

        // A spot partly off the visible area, as after the Dock grew.
        let offEdge = QuickEntryPlacement.Remembered(topLeft: NSPoint(x: 1300, y: 1000), screenFrame: laptop)
        let clamped = QuickEntryPlacement.frame(
            size: size,
            screenFrame: laptop,
            visibleFrame: laptopVisible,
            remembered: offEdge
        )
        #expect(laptopVisible.contains(clamped))
        #expect(clamped.maxY == laptopVisible.maxY)
    }

    @Test func theFrontWindowSkipsInvisibleOtherLayerAndOtherAppWindows() {
        func window(pid: pid_t, layer: Int, alpha: Double, _ bounds: CGRect) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer,
                kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: bounds.dictionaryRepresentation,
            ]
        }
        let visible = CGRect(x: -3000, y: 300, width: 1400, height: 900)
        let windows = [
            window(pid: 7, layer: 25, alpha: 1, CGRect(x: 1200, y: 0, width: 30, height: 24)),
            window(pid: 9, layer: 0, alpha: 1, CGRect(x: 100, y: 100, width: 800, height: 600)),
            window(pid: 7, layer: 0, alpha: 0, CGRect(x: 100, y: 100, width: 800, height: 600)),
            window(pid: 7, layer: 0, alpha: 1, visible),
        ]

        #expect(QuickEntryPlacement.frontWindowBounds(of: 7, in: windows) == visible)
        #expect(QuickEntryPlacement.frontWindowBounds(of: 8, in: windows) == nil)
    }

    @Test func windowServerBoundsFlipToAppKitCoordinates() {
        // 100 pt below the top of a 982 pt primary screen, 500 pt tall.
        let bounds = CGRect(x: 1700, y: 100, width: 800, height: 500)

        #expect(QuickEntryPlacement.cocoaFrame(fromWindowServerBounds: bounds, primaryScreenHeight: 982)
            == NSRect(x: 1700, y: 382, width: 800, height: 500))
    }
}
