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

        init() throws {
            let fixture = try TaskCoordinatorTests.Fixture()
            fixture.config = TasksConfig(defaults: .init(agent: "claude"))
            let stagingRoot = fixture.root.appendingPathComponent("quick-entry-staging", isDirectory: true)
            self.fixture = fixture
            self.stagingRoot = stagingRoot
            controller = QuickEntryController(
                store: fixture.store,
                agentCatalogProvider: TestAgentCatalogProvider(),
                create: { request in
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

        var stagedDirectories: [URL] {
            (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
        }
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

    @Test func reloadReadsTheShortcutAndKeepsTheDefaultWhenTheFileIsBroken() throws {
        let harness = try Harness()
        let fixture = harness.fixture
        fixture.config.quickEntry = .init(shortcut: try QuickEntryShortcut.parse("ctrl+opt+space"))
        #expect(harness.controller.reloadShortcut() == nil)
        #expect(harness.controller.shortcut?.symbolLabel == "⌃⌥Space")

        fixture.config.quickEntry = .init(shortcut: nil)
        #expect(harness.controller.reloadShortcut() == nil)
        #expect(harness.controller.shortcut == nil)

        fixture.configError = TasksConfigParseError(line: 2, message: "[quick_entry] the shortcut \"t\" needs Command")
        let message = try #require(harness.controller.reloadShortcut())
        #expect(message.contains("⌥⇧T until the file is fixed"))
        #expect(harness.controller.shortcut == .default)
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
