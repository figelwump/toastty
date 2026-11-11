import AppKit
@testable import ConversationUI
import RemoteProtocol
import SwiftUI
import XCTest

/// Hosts the conversation transcript that the iPhone app also uses in an
/// AppKit window, and keeps the image on the test result for visual review.
@MainActor
final class ConversationUIRenderTests: XCTestCase {
    private static let transcriptSize = CGSize(width: 560, height: 1_700)

    func testFixtureConversationRendersWithSharedViews() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let transcript = ToasttyTranscriptView(
            state: Self.fixtureState,
            isSubmitting: false,
            interactionAnswerStates: [Self.question.id: Self.questionAnswerState],
            readAcknowledgementEpoch: .working,
            workingIndicator: ToasttyTranscriptWorkingIndicator(turnElapsed: .init(
                secondsAtReceipt: 75,
                receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime
            )),
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false
        )
        let (hostingView, window) = Self.host(transcript, size: Self.transcriptSize)
        defer { window.close() }

        // The AppKit text views carry the selectable message text.
        let textViews = Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self)
        func textView(containing fragment: String) throws -> ToasttyTranscriptTextView {
            try XCTUnwrap(
                textViews.first { $0.string.contains(fragment) },
                "No rendered text view contains \"\(fragment)\""
            )
        }
        let userMessage = try textView(containing: "Share the conversation renderer")
        let paragraph = try textView(containing: "both Tuist graphs")
        let codeBlock = try textView(containing: "tuist generate --no-open")
        let tableCell = try textView(containing: "NSTextView")
        for view in [userMessage, paragraph, codeBlock, tableCell] {
            XCTAssertGreaterThan(view.frame.width, 0)
            XCTAssertGreaterThan(view.frame.height, 0)
            XCTAssertLessThanOrEqual(view.frame.width, Self.transcriptSize.width)
        }
        // A long paragraph wraps inside the transcript width; a short bubble
        // keeps its own width.
        let lineHeight = try XCTUnwrap(userMessage.layoutManager).defaultLineHeight(
            for: try XCTUnwrap(userMessage.font)
        )
        XCTAssertGreaterThan(paragraph.frame.height, lineHeight * 2)
        XCTAssertLessThan(userMessage.frame.width, paragraph.frame.width)

        let bitmap = try Self.snapshot(hostingView)
        XCTAssertGreaterThan(
            Self.sampledColorCount(in: bitmap), 12,
            "The transcript must draw more than its background"
        )
        try keep(bitmap, name: "conversation-ui-macos-fixture")
    }

    /// A message keeps its bubble size and place from sending to sent, so
    /// the bubble does not grow and shrink back, or move, when the message
    /// arrives. On the Mac the sent row has no caption; on the iPhone it
    /// says how it was sent. Where messages have a copy button, the sending
    /// bubble keeps the button's space. Earlier messages fill the view, so
    /// the transcript stays at its bottom edge, as in a real conversation.
    func testSendingBubbleKeepsTheSizeOfTheSentBubble() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let text = "Merge it."
        let earlier = (1...4).map { index in
            Self.row(UInt64(index), .assistantMessage(
                text: "Earlier answer \(index), long enough to take a few lines in the narrow test window.",
                phase: .final
            ))
        }
        let cases: [(name: String, caption: String?, origin: ConversationMessageOrigin, copyButton: Bool)] = [
            ("mac", nil, .local, false),
            ("iphone", "sent remotely", .remote, false),
            ("mac-copy-button", nil, .local, true),
        ]
        for (name, caption, origin, copyButton) in cases {
            let options = ToasttyTranscriptOptions(showsMessageCopyButton: copyButton)
            let sending = try bubbleHeight(of: text, named: "sending-bubble-\(name)", options: options, in: .init(
                rows: earlier,
                sendItems: [ToasttySendPresentationItem(
                    clientRequestID: "sending", text: text,
                    content: .optimistic(response: .accepted), sentCaption: caption
                )],
                phase: .live, revision: .initial, historyTruncated: false
            ))
            let sent = try bubbleHeight(of: text, named: "sent-bubble-\(name)", options: options, in: .init(
                rows: earlier + [Self.row(5, .userMessage(text: text, origin: origin))],
                sendItems: [], phase: .live, revision: .initial, historyTruncated: false
            ))
            XCTAssertEqual(sending.height, sent.height, "\(name): the sending bubble must match the sent bubble's height")
            XCTAssertEqual(sending.top, sent.top, "\(name): the bubble must not move when the message is sent")
        }
    }

    /// The height in points of the bubble that holds `text`, and its top
    /// edge, measured from the drawn pixels in a column inside the bubble's
    /// leading padding.
    @available(macOS 15.0, *)
    private func bubbleHeight(
        of text: String,
        named name: String,
        options: ToasttyTranscriptOptions,
        in state: ToasttyConversationPresentationState
    ) throws -> (height: CGFloat, top: CGFloat) {
        let size = CGSize(width: 480, height: 220)
        let transcript = ToasttyTranscriptView(
            state: state,
            isSubmitting: false,
            interactionAnswerStates: [:],
            readAcknowledgementEpoch: .working,
            workingIndicator: nil,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false,
            options: options
        )
        let (hostingView, window) = Self.host(transcript, size: size)
        defer { window.close() }
        let textView = try XCTUnwrap(
            Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self)
                .first { $0.string.contains(text) },
            "No rendered text view contains \"\(text)\""
        )
        let textRect = textView.convert(textView.bounds, to: hostingView)
        let bitmap = try Self.snapshot(hostingView)
        try keep(bitmap, name: name)

        let scale = CGFloat(bitmap.pixelsWide) / hostingView.bounds.width
        let x = Int((textRect.minX - 6) * scale)
        // The transcript's left edge is plain background on every row.
        func isBubble(_ y: Int) -> Bool {
            guard y >= 0, y < bitmap.pixelsHigh,
                  let pixel = bitmap.colorAt(x: x, y: y),
                  let background = bitmap.colorAt(x: 2, y: y) else { return false }
            return abs(pixel.redComponent - background.redComponent)
                + abs(pixel.greenComponent - background.greenComponent)
                + abs(pixel.blueComponent - background.blueComponent) > 0.03
        }
        var top = Int(textRect.midY * scale)
        XCTAssertTrue(isBubble(top), "\(name): the measured column must start inside the bubble")
        while isBubble(top - 1) { top -= 1 }
        var bottom = Int(textRect.midY * scale)
        while isBubble(bottom + 1) { bottom += 1 }
        return (CGFloat(bottom - top + 1) / scale, CGFloat(top) / scale)
    }

    private static func host<Content: View>(_ content: Content, size: CGSize) -> (NSHostingView<some View>, NSWindow) {
        let hostingView = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    private static func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func keep(_ bitmap: NSBitmapImageRep, name: String) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try Self.writeEvidence(png, name: name)
    }

    /// A response's paragraphs, list items and quote share one text view, so
    /// one drag selects across them and Copy gives plain text. The code block
    /// keeps its own view.
    func testDragSelectsAcrossTheTextBlocksOfOneResponse() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let transcript = ToasttyTranscriptView(
            state: Self.fixtureState,
            isSubmitting: false,
            readAcknowledgementEpoch: .working,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false
        )
        let (hostingView, window) = Self.host(transcript, size: Self.transcriptSize)
        defer { window.close() }

        let textViews = Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self)
        let response = try XCTUnwrap(textViews.first { $0.string.contains("both Tuist graphs") })
        for fragment in ["Plan", "Move the transcript", "Add an AppKit text view", "The composer stays"] {
            XCTAssertTrue(response.string.contains(fragment), "\(fragment) is not in the response's text view")
        }
        XCTAssertFalse(response.string.contains("tuist generate"), "The code block keeps its own view")

        // Press inside the first paragraph and release after the quote's last
        // word: AppKit's own drag tracking reads the queued events.
        let start = try Self.windowPoint(of: "renderer moves", in: response, edge: .leading)
        let end = try Self.windowPoint(of: "iPhone app.", in: response, edge: .trailing)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }
        let middle = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: middle), atStart: false)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: end), atStart: false)
        NSApp.postEvent(try mouse(.leftMouseUp, at: end), atStart: false)
        // The press goes to the text view itself: making the window key
        // would activate the test host and take focus from the user's app.
        XCTAssertTrue(window.contentView?.hitTest(start) === response, "The press must land on the response")
        response.mouseDown(with: try mouse(.leftMouseDown, at: start))

        // Copy's own path, on a private pasteboard so the test leaves the
        // user's clipboard alone.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("toastty-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(response.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), """
        renderer moves into a module that both Tuist graphs build, so the iPhone app and the Mac \
        draw a conversation with the same views. See the automation notes and ios/Project.swift.

        1. Move the transcript, turn, and tool views.
        2. Add an AppKit text view for selectable text.

        The composer stays in the iPhone app.
        """)

        try keep(try Self.snapshot(hostingView), name: "conversation-ui-macos-drag-selection")
    }

    private enum TextEdge { case leading, trailing }

    /// A point in window coordinates at one edge of the first match of `fragment`.
    private static func windowPoint(of fragment: String, in textView: NSTextView, edge: TextEdge) throws -> NSPoint {
        let range = (textView.string as NSString).range(of: fragment)
        XCTAssertNotEqual(range.location, NSNotFound, "No \"\(fragment)\" in the text view")
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let edgeGlyph = edge == .leading ? glyphs.location : NSMaxRange(glyphs) - 1
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: edgeGlyph, length: 1), in: container)
        rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let x = edge == .leading ? rect.minX + 1 : rect.maxX + 1
        return textView.convert(NSPoint(x: x, y: rect.midY), to: nil)
    }

    /// Writes the PNG when the runner sets `TOASTTY_CONVERSATION_EVIDENCE_DIR`
    /// (pass it as `TEST_RUNNER_…` to xcodebuild).
    private static func writeEvidence(_ png: Data, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TOASTTY_CONVERSATION_EVIDENCE_DIR"],
              directory.isEmpty == false else { return }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try png.write(to: directoryURL.appendingPathComponent("\(name).png"))
    }

    private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            ((subview as? T).map { [$0] } ?? []) + descendants(of: subview, as: type)
        }
    }

    private static func sampledColorCount(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                colors.insert(String(
                    format: "%.2f-%.2f-%.2f",
                    color.redComponent, color.greenComponent, color.blueComponent
                ))
            }
        }
        return colors.count
    }

    // MARK: - Fixture

    private static let projectionRunID = UUID()
    private static let conversationID = UUID()

    private static func row(_ sequence: UInt64, _ content: ToasttyTranscriptRow.Content) -> ToasttyTranscriptRow {
        ToasttyTranscriptRow(
            id: ToasttyTranscriptRowID(
                projectionRunID: projectionRunID,
                projectionGeneration: 1,
                conversationID: conversationID,
                sequence: sequence
            ),
            timestamp: Date(),
            provider: .claude,
            content: content
        )
    }

    private static let decisionQuestion = RemoteInteractionQuestion(
        id: "base",
        header: "Base branch",
        question: "Which branch does the pull request go into?",
        options: [
            .init(id: "coordinator", label: "feat/task-system-coordinator", detail: "The coordinator sequence"),
            .init(id: "main", label: "main"),
        ]
    )

    private static let question = RemotePendingInteraction(
        id: .init(rawValue: "fixture-question"),
        kind: .question,
        prompt: decisionQuestion.question,
        inputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
        presentedAt: Date(),
        questions: [decisionQuestion],
        responseID: "fixture-response"
    )

    private static let questionAnswerState: ToasttyInteractionAnswerState = {
        var state = ToasttyInteractionAnswerState(
            key: ToasttyInteractionAnswerKey(
                interactionID: question.id,
                responseID: "fixture-response",
                inputEpoch: question.inputEpoch
            ),
            questions: [decisionQuestion]
        )
        state.apply(.toggleOption(questionID: decisionQuestion.id, optionID: "coordinator"))
        return state
    }()

    private static let response = """
    ## Plan

    The renderer moves into a module that **both Tuist graphs** build, so the \
    iPhone app and the Mac draw a conversation with the same views. See \
    [the automation notes](https://example.com/automation) and `ios/Project.swift`.

    1. Move the transcript, turn, and tool views.
    2. Add an AppKit text view for *selectable* text.

    > The composer stays in the iPhone app.

    ```bash
    sv exec -- tuist generate --no-open
    ```

    | Piece | iPhone | Mac |
    | :--- | :---: | ---: |
    | Selectable text | UITextView | NSTextView |
    | Haptics | yes | no |
    """

    private static let fixtureState = ToasttyConversationPresentationState(
        rows: [
            row(1, .userMessage(text: "Share the conversation renderer with the Mac.", origin: .local)),
            row(2, .assistantMessage(text: "I will read the iPhone views first.", phase: .commentary)),
            row(3, .toolStarted(callID: "read", name: "Read", detail: "ios/Sources/ToasttyMobileApp/Conversation")),
            row(4, .toolFinished(callID: "read", name: "Read", outcome: .succeeded, detail: nil)),
            row(5, .toolFinished(callID: "build", name: "Bash", outcome: .failed, detail: "exit 65")),
            row(6, .assistantMessage(text: response, phase: .final)),
            row(7, .userMessage(text: "Open the pull request.", origin: .remote, deliveryMode: .queue)),
            row(8, .toolStarted(callID: "push", name: "Bash", detail: "git push")),
            row(9, .subagentSummary(name: "reviewer", phase: .started, detail: "Checks the diff")),
            row(10, .interaction(ToasttyInteractionPresentation(interaction: question))),
        ],
        sendItems: [
            ToasttySendPresentationItem(
                clientRequestID: "fixture-optimistic",
                text: "Use the draft state until checks pass.",
                content: .optimistic(response: .accepted)
            ),
            ToasttySendPresentationItem(
                clientRequestID: "fixture-queued",
                text: "Then report to the parent task.",
                content: .queued(ToasttyQueuedSendPresentation(
                    position: 1, attachmentCount: 1, isPaused: false, canSteer: true
                ))
            ),
            ToasttySendPresentationItem(
                clientRequestID: "fixture-receipt",
                text: "Merge it.",
                content: .receipt(ToasttySendReceiptPresentation(kind: .rejected(.promptNotOpen)))
            ),
        ],
        phase: .live,
        revision: .initial,
        historyTruncated: true,
        hasOlder: true
    )
}
