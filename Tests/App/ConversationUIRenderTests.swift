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
    /// bubble keeps the button's space. A reply's quote line is the same in
    /// both, also when the sent row's quote opens the message it quotes.
    /// Earlier messages fill the view, so
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
        let cases: [(name: String, caption: String?, origin: ConversationMessageOrigin, copyButton: Bool, replies: Bool)] = [
            ("mac", nil, .local, false, false),
            ("iphone", "sent remotely", .remote, false, false),
            ("mac-copy-button", nil, .local, true, false),
            ("mac-reply", nil, .local, true, true),
        ]
        for (name, caption, origin, copyButton, replies) in cases {
            let options = ToasttyTranscriptOptions(showsMessageCopyButton: copyButton)
            let quoted = "Earlier answer 4, long enough to take a few lines in the narrow test window."
            let sendingQuote = replies ? ToasttyMessageQuote(text: quoted, timeText: "14:05") : nil
            let sentQuote = replies ? ToasttyMessageQuote(text: quoted, timeText: "14:05", sourceRowID: earlier[3].id) : nil
            let sending = try bubbleHeight(of: text, named: "sending-bubble-\(name)", options: options, replies: replies, in: .init(
                rows: earlier,
                sendItems: [ToasttySendPresentationItem(
                    clientRequestID: "sending", text: text,
                    content: .optimistic(response: .accepted), sentCaption: caption, quote: sendingQuote
                )],
                phase: .live, revision: .initial, historyTruncated: false
            ))
            let sent = try bubbleHeight(of: text, named: "sent-bubble-\(name)", options: options, replies: replies, in: .init(
                rows: earlier + [Self.row(5, .userMessage(text: text, origin: origin, quote: sentQuote))],
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
        replies: Bool = false,
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
            options: options,
            replyToMessage: replies ? { @MainActor _ in } : nil
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

    /// A task the user mentioned shows in the user's own message as the
    /// chip the coordinator's text gets. The rest of the message, a web
    /// link and Markdown included, shows as typed; so does a link to a task
    /// the host does not know.
    func testAMentionedTaskShowsAsAChipInTheUsersMessage() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let known = "8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F"
        let unknown = "41B7E9C0-1111-4222-8333-444455556666"
        let chip = ConversationLinkChip(
            markColor: ConversationChipColor(red: 0.56, green: 0.36, blue: 0.85),
            title: "Fix the unread dot",
            detail: "#312"
        )
        let presenter = ConversationLinkPresenter(revision: 1) { url in
            guard url.scheme == "toastty" else { return nil }
            return url.absoluteString.hasSuffix(known) ? .chip(chip) : .plainText
        }
        let rows = [
            Self.row(1, .userMessage(
                text: "is [Fix the unread dot](toastty://task/\(known)) blocked on "
                    + "[Gone](toastty://task/\(unknown))? See [docs](https://example.com), *as typed*.",
                origin: .local
            )),
            Self.row(2, .assistantMessage(
                text: "Yes: [Fix the unread dot](toastty://task/\(known)) waits for your answer.",
                phase: .final
            )),
        ]
        let state = ToasttyConversationPresentationState(rows: rows, phase: .live, revision: .initial, historyTruncated: false)
        let transcript = ToasttyTranscriptView(
            state: state,
            isSubmitting: false,
            readAcknowledgementEpoch: nil,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false
        )
        .environment(\.conversationLinkPresenter, presenter)
        let (hostingView, window) = Self.host(transcript, size: CGSize(width: 560, height: 360))
        defer { window.close() }

        let textViews = Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self)
        let user = try XCTUnwrap(textViews.first { $0.string.hasPrefix("is ") })
        XCTAssertTrue(user.string.contains("Fix\u{00A0}the\u{00A0}unread\u{00A0}dot"), user.string)
        XCTAssertFalse(user.string.contains("toastty://task/\(known)"), user.string)
        XCTAssertTrue(
            user.string.contains("blocked on [Gone](toastty://task/\(unknown))? See [docs](https://example.com), *as typed*."),
            user.string
        )
        try keep(Self.snapshot(hostingView), name: "conversation-ui-macos-user-mention-chip")
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

    /// A wake turn the coordinator marked quiet folds whole under the
    /// host's line: its work and its answer show only when the line is open.
    /// The next wake, which is not quiet, shows its answer as usual.
    func testAQuietWakeFoldsItsWholeTurnUnderTheHostsLine() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let header = "[Toastty] Wake: this message is from Toastty, not from the user."
        let footer = "Read `toastty task list` for details."
        let quietDigest = [header, "- [Fix the login redirect](toastty://task/1): needsYou (agentFinished) at 2026-11-12T18:39:14Z", footer]
            .joined(separator: "\n")
        let nextDigest = [header, "- [Fix the unread dot](toastty://task/2): needsYou (review) at 2026-11-12T18:52:03Z", footer]
            .joined(separator: "\n")
        let rows = [
            Self.row(1, .hostMessage(.init(summary: "Toastty · 1 update · 10:39 AM", text: quietDigest, foldsTurn: true))),
            Self.row(2, .toolStarted(callID: "quiet-1", name: "Bash", detail: "toastty task list")),
            Self.row(3, .toolFinished(callID: "quiet-1", name: "Bash", outcome: .succeeded, detail: nil)),
            Self.row(4, .toolStarted(callID: "quiet-2", name: "Bash", detail: "toastty coordinator wake --clear --quiet")),
            Self.row(5, .toolFinished(callID: "quiet-2", name: "Bash", outcome: .succeeded, detail: nil)),
            Self.row(6, .assistantMessage(text: "Nothing needs you.", phase: .final)),
            Self.row(7, .hostMessage(.init(summary: "Toastty · 1 update · 10:52 AM", text: nextDigest))),
            Self.row(8, .toolStarted(callID: "next-1", name: "Bash", detail: "toastty task list")),
            Self.row(9, .toolFinished(callID: "next-1", name: "Bash", outcome: .succeeded, detail: nil)),
            Self.row(10, .assistantMessage(text: "Fix the unread dot is ready for your review.", phase: .final)),
        ]
        let state = ToasttyConversationPresentationState(rows: rows, phase: .live, revision: .initial, historyTruncated: false)
        let quietTurn = try XCTUnwrap(state.turns.first)
        XCTAssertTrue(quietTurn.foldsWholeTurn)
        XCTAssertEqual(quietTurn.toolCallCount, 2)
        XCTAssertTrue(quietTurn.workBlockIDs.contains { $0.rowID.sequence == 6 }, "The quiet turn's answer folds with its work")
        XCTAssertFalse(state.turns[1].foldsWholeTurn)
        XCTAssertFalse(state.turns[1].workBlockIDs.contains { $0.rowID.sequence == 10 }, "A normal turn's answer stays out of the fold")

        let size = CGSize(width: 560, height: 520)
        let transcript = ToasttyTranscriptView(
            state: state,
            isSubmitting: false,
            readAcknowledgementEpoch: .ready,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false
        )
        let (hostingView, window) = Self.host(transcript, size: size)
        defer { window.close() }
        // A click reaches SwiftUI only in a window that is on screen. Off the
        // visible screen, so the real pointer never moves over it.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func shownTexts() -> [String] {
            Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self).map(\.string)
        }
        XCTAssertFalse(shownTexts().contains { $0.contains("Nothing needs you.") }, "The quiet answer shows while folded")
        XCTAssertTrue(shownTexts().contains { $0.contains("ready for your review") }, "The next wake's answer is hidden")
        let folded = try Self.snapshot(hostingView)
        try keep(folded, name: "coordinator-quiet-wake-folded")

        // The quiet turn's line is the topmost thing drawn. A click on it
        // opens the digest, the work and the answer.
        let lineY = try XCTUnwrap(Self.firstDrawnRow(in: folded, scale: hostingView.window?.backingScaleFactor ?? 2),
                                  "Nothing is drawn")
        try click(CGPoint(x: size.width / 2, y: lineY + 6), in: hostingView, window: window, size: size)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, shownTexts().contains(where: { $0.contains("Nothing needs you.") }) == false {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Let the opening animation end before the image.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(shownTexts().contains { $0.contains("Nothing needs you.") }, "A click on the line does not open the quiet turn")
        XCTAssertTrue(shownTexts().contains { $0.contains("needsYou (agentFinished)") }, "The open line does not show the digest")
        XCTAssertTrue(shownTexts().contains { $0.contains("ready for your review") })
        try keep(try Self.snapshot(hostingView), name: "coordinator-quiet-wake-open")
    }

    /// In the coordinator's chat a wake turn is one line from its start to
    /// its end. The typed digest shows as its line before its row comes, not
    /// as Toastty's text. While the turn runs, that line is the only thing
    /// that shows that the agent works, and the work stays folded. When the
    /// turn ends only the answer is new. A click on the line opens the
    /// digest and the work, each tool call as one line.
    func testACoordinatorWakeTurnIsOneLineFromItsStartToItsEnd() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let header = "[Toastty] Wake: this message is from Toastty, not from the user."
        let digest = [header, "- [Fix the unread dot](toastty://task/1): readyForReview at 2026-11-19T22:01:04Z"]
            .joined(separator: "\n")
        let line = ToasttyHostMessagePresentation(
            summary: "Toastty · 1 update · 2:01 PM", title: "Toastty · 1 update", text: digest
        )
        let earlier = [
            Self.row(1, .assistantMessage(text: "**Tag pause:** the release task no longer needs the pause.", phase: .final)),
            Self.row(2, .hostMessage(.init(summary: "Toastty · 4 updates · 1:52 PM", title: "Toastty · 4 updates",
                                           text: header, foldsTurn: true))),
            Self.row(3, .toolStarted(callID: "quiet", name: "Bash", detail: "toastty task list")),
            Self.row(4, .toolFinished(callID: "quiet", name: "Bash", outcome: .succeeded, detail: nil)),
            Self.row(5, .assistantMessage(text: "Nothing needs you.", phase: .final)),
        ]
        let wake = [
            Self.row(6, .hostMessage(line)),
            Self.row(7, .assistantMessage(text: "Checking its pull request.", phase: .commentary)),
            Self.row(8, .toolStarted(callID: "checks", name: "Bash", detail: "gh pr checks 449")),
            Self.row(9, .toolFinished(callID: "checks", name: "Bash", outcome: .succeeded, detail: nil)),
        ]
        let answer = Self.row(10, .assistantMessage(text: "Fix the unread dot is ready for review.", phase: .final))
        let size = CGSize(width: 560, height: 460)

        func render(
            _ rows: [ToasttyTranscriptRow],
            sendItems: [ToasttySendPresentationItem] = [],
            working: Bool,
            options: ToasttyTranscriptOptions = Self.coordinatorOptions,
            name: String
        ) throws -> (texts: [String], spinners: Int) {
            let transcript = ToasttyTranscriptView(
                state: ToasttyConversationPresentationState(
                    rows: rows, sendItems: sendItems, phase: .live, revision: .initial, historyTruncated: false
                ),
                isSubmitting: false,
                readAcknowledgementEpoch: working ? .working : .ready,
                workingIndicator: working ? ToasttyTranscriptWorkingIndicator(turnElapsed: .init(
                    secondsAtReceipt: 16, receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime
                )) : nil,
                jumpToLiveEdgeRequest: .constant(0),
                canAcknowledgeRead: false,
                options: options
            )
            let (hostingView, window) = Self.host(transcript, size: size)
            defer { window.close() }
            try keep(Self.snapshot(hostingView), name: name)
            return (
                Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self).map(\.string),
                Self.descendants(of: hostingView, as: ToasttyLayerAnimationNSView.self).count
            )
        }

        // Toastty typed the digest; its row has not come yet.
        let typed = try render(earlier, sendItems: [ToasttySendPresentationItem(
            clientRequestID: "wake", text: digest, content: .optimistic(response: .accepted), hostMessage: line
        )], working: true, name: "coordinator-wake-typed")
        XCTAssertFalse(typed.texts.contains { $0.contains("[Toastty] Wake") }, "The typed digest shows raw")
        XCTAssertEqual(typed.spinners, 1)

        let running = try render(earlier + wake, working: true, name: "coordinator-wake-running")
        XCTAssertFalse(running.texts.contains { $0.contains("Checking its pull request") }, "Running work shows")
        XCTAssertFalse(running.texts.contains { $0.contains("[Toastty] Wake") })
        XCTAssertEqual(running.spinners, 1, "More than one thing says that the agent works")

        let answered = try render(earlier + wake + [answer], working: false, name: "coordinator-wake-answered")
        XCTAssertTrue(answered.texts.contains { $0.contains("ready for review") })
        XCTAssertFalse(answered.texts.contains { $0.contains("Checking its pull request") })
        XCTAssertEqual(answered.spinners, 0)

        // A digest and a message from `coordinator send` that wait show as
        // their line and card, with the queue's caption and Remove.
        let waitingQueue = { (position: Int) in
            ToasttySendPresentationItem.Content.queued(ToasttyQueuedSendPresentation(
                position: position, attachmentCount: 0, isPaused: false, canSteer: false, canEdit: false
            ))
        }
        let waiting = try render(earlier + wake + [answer], sendItems: [
            ToasttySendPresentationItem(
                clientRequestID: "wake-2", text: digest, content: waitingQueue(1),
                hostMessage: ToasttyHostMessagePresentation(
                    summary: "Toastty · 1 update · waiting", title: "Toastty · 1 update", text: digest
                )
            ),
            ToasttySendPresentationItem(
                clientRequestID: "from-task", text: "[Toastty] From task Fix the unread dot\nChecks passed.",
                content: waitingQueue(2),
                hostMessage: ToasttyHostMessagePresentation(
                    summary: "From task Fix the unread dot · waiting", text: "Checks passed.",
                    style: .sender(name: "task Fix the unread dot", timeText: "waiting")
                )
            ),
        ], working: true, name: "coordinator-waiting-messages")
        XCTAssertFalse(waiting.texts.contains { $0.contains("[Toastty]") }, "A waiting message shows raw")
        XCTAssertTrue(waiting.texts.contains { $0.contains("Checks passed.") })

        // A turn that the user started shows its line under the message
        // before any work comes.
        let asked = try render(
            [Self.row(11, .userMessage(text: "What blocks the release?", origin: .local))],
            working: true, name: "coordinator-user-turn-starting"
        )
        XCTAssertEqual(asked.spinners, 1)

        // A session's chat keeps its running work open, so the agent's
        // notes show as they come, and only the row at the end has a
        // spinner.
        let session = try render(
            [
                Self.row(12, .userMessage(text: "Fix the flaky upload test", origin: .local)),
                Self.row(13, .assistantMessage(text: "Checking its pull request.", phase: .commentary)),
                Self.row(14, .toolStarted(callID: "test", name: "Bash", detail: "swift test --filter Upload")),
            ],
            working: true, options: ToasttyTranscriptOptions(), name: "session-running-turn"
        )
        XCTAssertTrue(session.texts.contains { $0.contains("Checking its pull request") })
        XCTAssertEqual(session.spinners, 1, "The chip and the row both show a spinner")

        // A click on the line opens the digest and the work.
        let transcript = ToasttyTranscriptView(
            state: ToasttyConversationPresentationState(
                rows: wake + [answer], phase: .live, revision: .initial, historyTruncated: false
            ),
            isSubmitting: false,
            readAcknowledgementEpoch: .ready,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false,
            options: Self.coordinatorOptions
        )
        let (hostingView, window) = Self.host(transcript, size: size)
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func shownTexts() -> [String] {
            Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self).map(\.string)
        }
        let lineY = try XCTUnwrap(
            Self.firstDrawnRow(in: try Self.snapshot(hostingView), scale: window.backingScaleFactor), "Nothing is drawn"
        )
        try click(CGPoint(x: size.width / 2, y: lineY + 6), in: hostingView, window: window, size: size)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, shownTexts().contains(where: { $0.contains("Checking its pull request") }) == false {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(shownTexts().contains { $0.contains("Checking its pull request") }, "The line does not open the work")
        XCTAssertTrue(shownTexts().contains { $0.contains("[Toastty] Wake") }, "The open line does not show the digest")
        try keep(try Self.snapshot(hostingView), name: "coordinator-wake-open")
    }

    private static let coordinatorOptions = ToasttyTranscriptOptions(
        readOnlyInteractionMessage: "Answer in the terminal",
        showsMessageCopyButton: true,
        foldsRunningWork: true
    )

    private func click(_ point: CGPoint, in hostingView: NSView, window: NSWindow, size: CGSize) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: hostingView.convert(
                    CGPoint(x: point.x, y: hostingView.isFlipped ? point.y : size.height - point.y), to: nil
                ),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// The transcript opens at the line above the messages the reader has
    /// not seen, not at the latest response, and Jump to latest counts them.
    func testTheTranscriptOpensAtTheNewMessagesLine() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        var rows: [ToasttyTranscriptRow] = []
        for index in 1 ... 6 {
            rows.append(Self.row(UInt64(rows.count + 1), .userMessage(text: "Earlier question \(index)", origin: .local)))
            rows.append(Self.row(UInt64(rows.count + 1), .assistantMessage(
                text: "Earlier answer \(index). The coordinator checked the task and reported its state.",
                phase: .final
            )))
        }
        let digest = "[Toastty] Wake: this message is from Toastty, not from the user.\n"
            + "- [Fix the unread dot](toastty://task/2): needsYou (review) at 2026-11-14T18:52:03Z"
        let firstNew = Self.row(UInt64(rows.count + 1), .hostMessage(.init(summary: "Toastty · 1 update · 10:52 AM", text: digest)))
        rows.append(firstNew)
        rows.append(Self.row(UInt64(rows.count + 1), .assistantMessage(
            text: "Fix the unread dot is ready for your review.", phase: .final
        )))
        let longAnswer = (1 ... 24).map { "- Check \($0) of the release passed on the mini." }.joined(separator: "\n")
        rows.append(Self.row(UInt64(rows.count + 1), .assistantMessage(text: "The release checks:\n\n" + longAnswer, phase: .final)))
        let state = ToasttyConversationPresentationState(rows: rows, phase: .live, revision: .initial, historyTruncated: false)

        let size = CGSize(width: 560, height: 520)
        let transcript = ToasttyTranscriptView(
            state: state,
            isSubmitting: false,
            readAcknowledgementEpoch: .ready,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false,
            newMessages: ToasttyNewMessagesMarker(firstRowID: firstNew.id, count: 2)
        )
        let (hostingView, window) = Self.host(transcript, size: size)
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hostingView.layoutSubtreeIfNeeded()

        func top(of fragment: String) throws -> CGFloat {
            let view = try XCTUnwrap(
                Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self).first { $0.string.contains(fragment) },
                "No rendered text view contains \"\(fragment)\""
            )
            let frame = view.convert(view.bounds, to: hostingView)
            return hostingView.isFlipped ? frame.minY : size.height - frame.maxY
        }
        // The line is at the top, then the wake's line, then the first
        // unseen response; the messages before them are above the view.
        // Opened at the latest response instead, the first unseen response
        // would be at the top with the two lines above the view.
        let firstNewTop = try top(of: "ready for your review")
        XCTAssertGreaterThan(firstNewTop, 50, "The new messages' line or the wake's line is above the view")
        XCTAssertLessThan(firstNewTop, 140, "The transcript did not open at the new messages' line")
        XCTAssertLessThan(try top(of: "Earlier answer 6"), 0, "The read messages fill the view")
        try keep(try Self.snapshot(hostingView), name: "coordinator-new-messages-line")
    }

    /// The top of the first pixel row, in points, that differs from the
    /// top-left pixel's color.
    private static func firstDrawnRow(in bitmap: NSBitmapImageRep, scale: CGFloat) -> CGFloat? {
        guard let background = bitmap.colorAt(x: 0, y: 0) else { return nil }
        for y in 0 ..< bitmap.pixelsHigh {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let difference = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if difference > 0.08 { return CGFloat(y) / scale }
            }
        }
        return nil
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
