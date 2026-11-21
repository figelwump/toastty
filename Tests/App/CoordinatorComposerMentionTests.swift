import AppKit
import ConversationUI
import CoreState
import SwiftUI
import XCTest
@testable import ToasttyApp

/// Mentioning a task in the coordinator's composer, through its real text
/// view: `@` opens the list, the keys choose, and the message holds the
/// task's link while the field shows a chip. Images of the open list are
/// kept on the test result, and written to `TOASTTY_COMPOSER_SNAPSHOT_DIR`
/// when it is set.
@MainActor
final class CoordinatorComposerMentionTests: XCTestCase {
    private static let dockID = UUID(uuidString: "9F1C2D3A-0B4E-4C5F-8A6B-7C8D9E0F1A2B")!
    private static let dotID = UUID(uuidString: "8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F")!
    private static let dockLink = "[Show the coordinator's chat in a dock](toastty://task/\(dockID.uuidString))"
    private static let dotLink = "[Fix the unread dot](toastty://task/\(dotID.uuidString))"

    private final class Draft: ObservableObject {
        @Published var text = ""
        var sends = 0
    }

    private struct Host: View {
        @ObservedObject var draft: Draft
        let attachments: DraftAttachments
        let candidates: [CoordinatorMentionCandidate]

        var body: some View {
            VStack {
                Spacer(minLength: 0)
                CoordinatorComposerView(
                    text: $draft.text,
                    attachments: attachments,
                    canStop: false,
                    focusRequestID: 0,
                    onSend: { draft.sends += 1 },
                    onStop: {},
                    dropTarget: AttachmentDropTarget(attachments: attachments),
                    mentionCandidates: candidates
                )
            }
            .padding(16)
            .background(ConversationDesignTokens.background)
        }
    }

    private static let candidates: [CoordinatorMentionCandidate] = [
        CoordinatorMentionCandidate(
            taskID: dotID, title: "Fix the unread dot", projectTitle: "toastty", pullRequestNumber: 312,
            group: .needsYou, markColor: ConversationChipColor(red: 0.56, green: 0.36, blue: 0.85), doneAt: nil
        ),
        CoordinatorMentionCandidate(
            taskID: dockID, title: "Show the coordinator's chat in a dock", projectTitle: "toastty",
            pullRequestNumber: 331, group: .working,
            markColor: ConversationChipColor(red: 0.18, green: 0.44, blue: 0.87), doneAt: nil
        ),
        CoordinatorMentionCandidate(
            taskID: UUID(), title: "Keep image thumbnails one size", projectTitle: "toastty", pullRequestNumber: 335,
            group: .toShip, markColor: ConversationChipColor(red: 0.18, green: 0.61, blue: 0.37), doneAt: nil
        ),
    ]

    private var root: URL!
    private var window: NSWindow?
    private var draft: Draft!
    private var host: NSView!
    private var textView: CoordinatorComposerTextView!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-composer-mention-\(UUID().uuidString)", isDirectory: true)
        draft = Draft()
        let attachments = DraftAttachments(stagingDirectoryURL: root.appendingPathComponent("staging"))
        let hosting = NSHostingView(rootView: Host(draft: draft, attachments: attachments, candidates: Self.candidates))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        host = hosting
        pump()
        textView = try XCTUnwrap(Self.descendants(of: hosting, as: CoordinatorComposerTextView.self).first)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("toastty-mention-test-\(UUID().uuidString)"))
        textView.pasteboard = pasteboard
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.undoManager?.groupsByEvent = false
    }

    override func tearDown() async throws {
        pasteboard?.releaseGlobally()
        window?.orderOut(nil)
        window = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
    }

    private func type(_ text: String) {
        asEvent { textView.insertText(text, replacementRange: textView.selectedRange()) }
        pump(0.1)
    }

    /// In the app, each key event has its own undo group. A test that calls
    /// the text view directly makes the group here.
    private func asEvent(_ body: () -> Void) {
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.endUndoGrouping()
    }

    private func press(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        asEvent { textView.keyDown(with: event) }
        pump(0.1)
    }

    private func pressReturn() throws { try press(36, "\r") }
    private func pressDown() throws { try press(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.numericPad, .function]) }

    private var picker: CoordinatorMentionPicker { textView.mentionPicker! }

    // MARK: - Tests

    /// `@` opens the list; Down and Return choose the second task; the
    /// field shows a chip and the message holds the task's link and a
    /// space. Return did not send, and the next Return sends.
    func testTheKeysChooseATaskAndTheMessageHoldsItsLink() throws {
        type("is @")
        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.results.map(\.taskID), [Self.dotID, Self.dockID, Self.candidates[2].taskID])
        try keep("composer-mention-open")

        try pressDown()
        try pressReturn()
        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(draft.text, "is \(Self.dockLink) ")
        XCTAssertTrue(textView.containsMention)
        XCTAssertEqual(textView.string, "is \u{FFFC} ")
        XCTAssertEqual(draft.sends, 0, "Return chose the task; it did not send")

        type("blocked on @dot")
        XCTAssertEqual(picker.results.map(\.taskID), [Self.dotID])
        try press(48, "\t")
        type("?")
        XCTAssertEqual(draft.text, "is \(Self.dockLink) blocked on \(Self.dotLink) ?")
        try keep("composer-mention-chips")

        try pressReturn()
        XCTAssertEqual(draft.sends, 1)
    }

    /// Caps Lock does not take the list's keys away: Return still chooses.
    func testReturnChoosesWithCapsLockOn() throws {
        type("@dock")
        try press(36, "\r", modifiers: [.capsLock])
        XCTAssertEqual(draft.text, "\(Self.dockLink) ")
        XCTAssertEqual(draft.sends, 0)
        try press(36, "\r", modifiers: [.capsLock])
        XCTAssertEqual(draft.sends, 1, "Return sends with Caps Lock on")
    }

    /// `#` and a number find the task by its pull request.
    func testAPullRequestNumberFindsTheTask() throws {
        type("@#33")
        XCTAssertEqual(picker.results.map(\.taskID), [Self.dockID, Self.candidates[2].taskID])
        try keep("composer-mention-pull-request")
        try pressReturn()
        XCTAssertEqual(draft.text, "\(Self.dockLink) ")
    }

    /// Escape closes the list and keeps the text; Return then sends.
    func testEscapeClosesTheListAndReturnThenSends() throws {
        type("ask @dock")
        XCTAssertTrue(picker.isOpen)
        textView.cancelOperation(nil)
        pump(0.1)
        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(draft.text, "ask @dock")
        try pressReturn()
        XCTAssertEqual(draft.sends, 1)
    }

    /// One Backspace takes out a whole chip, and Undo puts back what was
    /// typed before the task was chosen.
    func testAChipDeletesAsOneAndUndoRestoresTheSearch() throws {
        type("@dock")
        try pressReturn()
        XCTAssertEqual(draft.text, "\(Self.dockLink) ")
        asEvent { textView.deleteBackward(nil) }
        asEvent { textView.deleteBackward(nil) }
        pump(0.1)
        XCTAssertEqual(draft.text, "")

        type("@dock")
        try pressReturn()
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        pump(0.1)
        XCTAssertEqual(draft.text, "@dock")
    }

    /// Copy gives the link, and a paste of a task's link shows its chip.
    func testCopyGivesTheLinkAndPasteShowsTheChip() throws {
        type("@dot")
        try pressReturn()
        textView.selectAll(nil)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "\(Self.dotLink) ")

        textView.string = ""
        draft.text = ""
        pump(0.1)
        pasteboard.clearContents()
        pasteboard.setString("see \(Self.dockLink) and [docs](https://example.com)", forType: .string)
        asEvent { textView.paste(nil) }
        pump(0.1)
        XCTAssertEqual(textView.string, "see \u{FFFC} and [docs](https://example.com)")
        XCTAssertEqual(draft.text, "see \(Self.dockLink) and [docs](https://example.com)")
    }

    /// A draft set by the host, as Edit on a waiting message sets it, shows
    /// a link to a known task as a chip and keeps any other link as text.
    func testADraftFromTheHostShowsKnownTasksAsChips() throws {
        let unknown = "[Gone](toastty://task/\(UUID().uuidString))"
        draft.text = "Edit: \(Self.dotLink) and \(unknown)"
        pump()
        XCTAssertEqual(textView.string, "Edit: \u{FFFC} and \(unknown)")
        XCTAssertEqual(textView.draft, draft.text)

        // A link written before the task was renamed keeps its text: the
        // field does not rewrite the draft, and typing goes on at the caret.
        let renamed = "[Old name of the dot](toastty://task/\(Self.dotID.uuidString))"
        draft.text = "Was \(renamed) fixed"
        pump()
        XCTAssertEqual(textView.string, "Was \u{FFFC} fixed")
        XCTAssertEqual(textView.draft, draft.text)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        type(" it")
        XCTAssertEqual(draft.text, "Was it \(renamed) fixed")
        // Sending clears it.
        draft.text = ""
        pump()
        XCTAssertEqual(textView.string, "")
        XCTAssertFalse(picker.isOpen)
    }

    /// ＋ › Mention a Task… types `@`, with a space after a word, and opens
    /// the list.
    func testMentionATaskFromThePlusMenuTypesAnAtSign() throws {
        type("hello")
        asEvent { picker.beginMention() }
        pump(0.1)
        XCTAssertEqual(draft.text, "hello @")
        XCTAssertTrue(picker.isOpen)
        try pressReturn()
        XCTAssertEqual(draft.text, "hello \(Self.dotLink) ")
        XCTAssertEqual(draft.sends, 0)

        asEvent { picker.beginMention() }
        pump(0.1)
        XCTAssertEqual(draft.text, "hello \(Self.dotLink) @", "After a space, no second space")
        XCTAssertTrue(picker.isOpen)
    }

    // MARK: - Helpers

    private func keep(_ name: String) throws {
        pump(0.3)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["TOASTTY_COMPOSER_SNAPSHOT_DIR"], directory.isEmpty == false {
            let folder = URL(filePath: directory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + descendants(of: subview, as: type)
        }
    }
}
