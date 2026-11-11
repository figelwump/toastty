import AppKit
@testable import ConversationUI
import CoreState
import RemoteProtocol
import SwiftUI
@testable import ToasttyApp
import XCTest

/// The coordinator's chat as the Mac draws it: the shared transcript with a
/// folded digest, task chips and the Mac's width. The image stays on the
/// test result for visual review.
@MainActor
final class CoordinatorChatViewTests: XCTestCase {
    private static let windowSize = CGSize(width: 1_100, height: 640)
    private static let reviewTaskID = UUID(uuidString: "8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F")!
    private static let questionTaskID = UUID(uuidString: "41B7E9C0-1111-4222-8333-444455556666")!
    private static let missingTaskID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    func testTranscriptDrawsTaskChipsAFoldedDigestAndPlainTextForOtherToasttyLinks() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("The shared transcript uses scroll APIs from macOS 15.")
        }
        let chips = CoordinatorTaskChips(items: [
            Self.item(Self.reviewTaskID, title: "Restore split ratios", stage: .needsYou(.review), pullRequest: 283),
            Self.item(Self.questionTaskID, title: "Composer blank line", stage: .needsYou(.awaitingReply)),
        ])
        let transcript = ToasttyTranscriptView(
            state: Self.state,
            isSubmitting: false,
            readAcknowledgementEpoch: .working,
            jumpToLiveEdgeRequest: .constant(0),
            canAcknowledgeRead: false,
            options: CoordinatorChatView.transcriptOptions
        )
        .environment(\.conversationLinkPresenter, chips.presenter)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: transcript)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        defer { window.close() }
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hostingView.layoutSubtreeIfNeeded()

        let textViews = Self.descendants(of: hostingView, as: ToasttyTranscriptTextView.self)
        // Each paragraph of the answer is a text view of its own.
        func attributes(of fragment: String) throws -> [NSAttributedString.Key: Any] {
            for view in textViews {
                guard let storage = view.textStorage else { continue }
                let range = (storage.string as NSString).range(of: fragment)
                if range.location != NSNotFound {
                    return storage.attributes(at: range.location, effectiveRange: nil)
                }
            }
            XCTFail("No rendered text view shows \"\(fragment)\"")
            return [:]
        }
        _ = try attributes(of: "is ready")

        // A chip shows the task's title now, not the text the agent wrote,
        // with its pull request number. A click goes to the task's link.
        XCTAssertFalse(textViews.contains { $0.string.contains("an old title") })
        let reviewChip = try attributes(of: "Restore\u{00A0}split\u{00A0}ratios")
        XCTAssertNotNil(reviewChip[.toasttyChip])
        XCTAssertEqual(reviewChip[.link] as? URL, CoordinatorTaskLink.url(taskID: Self.reviewTaskID))
        XCTAssertNotNil(try attributes(of: "#283")[.toasttyChip])
        let questionChip = try attributes(of: "Composer\u{00A0}blank\u{00A0}line")
        XCTAssertNotNil(questionChip[.toasttyChip])
        XCTAssertEqual(questionChip[.link] as? URL, CoordinatorTaskLink.url(taskID: Self.questionTaskID))

        // A link to no task, and any other Toastty link, is plain text: the
        // words stay, and nothing can be clicked.
        for fragment in ["a task that is gone", "run this action", "a task link with more"] {
            let plain = try attributes(of: fragment)
            XCTAssertNil(plain[.link], "\"\(fragment)\" must not be a link")
            XCTAssertNil(plain[.toasttyChip], "\"\(fragment)\" must not be a chip")
        }
        // A web link stays a link.
        XCTAssertEqual(try attributes(of: "the docs")[.link] as? URL, URL(string: "https://example.com/docs"))

        // The digest is folded: its text is in no text view.
        XCTAssertFalse(textViews.contains { $0.string.contains(CoordinatorWakeState.digestPrefix) })

        // The column of messages keeps the Mac's reading width.
        for view in textViews {
            XCTAssertLessThanOrEqual(view.frame.width, CoordinatorChatView.maximumContentWidth)
        }

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "coordinator-chat-transcript"
        attachment.lifetime = .keepAlways
        add(attachment)
        try Self.writeEvidence(png, name: "coordinator-chat-transcript")
    }

    /// A chip in running text: it moves to the next line as one piece, also
    /// when its title has a hyphen. A chip wider than the line wraps, and each
    /// line gets its own outline around that line's part of the chip.
    func testTaskChipStaysOnOneLineAndOutlinesOnlyItsOwnTextWhenItWraps() throws {
        let taskID = Self.reviewTaskID
        let chips = CoordinatorTaskChips(items: [
            Self.item(taskID, title: "Toastty-coordinator SKILL.md lightweight routing",
                      stage: .running, pullRequest: 295),
        ])
        let markdown = """
        Whether that event can go, or is useful in other cases, is already a question in \
        [the routing task](toastty://task/\(taskID.uuidString)). Its agent is busy now, so I will \
        send it your question when it is idle.
        """
        let source = try AttributedString(markdown: markdown)
        func hosted(width: CGFloat) -> (NSHostingView<AnyView>, NSWindow) {
            let view = ToasttySelectableText(ConversationLinkDecoration.apply(source, presenter: chips.presenter))
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
            let hostingView = NSHostingView(rootView: AnyView(view))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 24, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hostingView
            hostingView.layoutSubtreeIfNeeded()
            return (hostingView, window)
        }

        let (probe, probeWindow) = hosted(width: 600)
        defer { probeWindow.close() }
        let storage = try XCTUnwrap(Self.descendants(of: probe, as: ToasttyTranscriptTextView.self).first?.textStorage)
        let rendered = NSAttributedString(attributedString: storage)
        var chipRange = NSRange()
        let chipStart = (rendered.string as NSString).range(of: "Toastty-coordinator").location
        XCTAssertNotEqual(chipStart, NSNotFound)
        XCTAssertNotNil(rendered.attribute(.toasttyChip, at: chipStart, longestEffectiveRange: &chipRange,
                                           in: NSRange(location: 0, length: rendered.length)))

        /// The chip's text on each line, laid out at `width`. A layout
        /// manager holds its storage weakly, so the caller keeps it.
        func layout(width: CGFloat, layoutManager: NSLayoutManager)
            -> (lines: [NSRange], chipWidth: CGFloat, storage: NSTextStorage) {
            let textStorage = NSTextStorage(attributedString: rendered)
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            textStorage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
            let glyphs = layoutManager.glyphRange(forCharacterRange: chipRange, actualCharacterRange: nil)
            var lines: [NSRange] = []
            var index = glyphs.location
            while index < NSMaxRange(glyphs) {
                var line = NSRange()
                _ = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &line)
                lines.append(NSIntersectionRange(line, glyphs))
                index = NSMaxRange(line)
            }
            let chipWidth = rendered.attributedSubstring(from: chipRange)
                .boundingRect(with: CGSize(width: 100_000, height: 1_000), options: [.usesLineFragmentOrigin]).width
            return (lines, chipWidth, textStorage)
        }

        var hyphenBreakWidth: CGFloat?
        var sawWrappedChip = false
        for width in stride(from: CGFloat(160), through: 900, by: 4) {
            let manager = ToasttyChipLayoutManager()
            let (lines, chipWidth, storage) = layout(width: width, layoutManager: manager)
            if chipWidth + 1 < width {
                XCTAssertEqual(lines.count, 1, "At width \(width) the chip must stay on one line")
            } else {
                sawWrappedChip = true
            }
            // Each outline covers that line's part of the chip, and nothing
            // past it.
            let outlines = manager.chipOutlineRects(forCharacterRange: chipRange)
            XCTAssertEqual(outlines.count, lines.count, "At width \(width)")
            for (outline, line) in zip(outlines, lines) {
                let text = manager.boundingRect(forGlyphRange: line, in: manager.textContainers[0])
                XCTAssertLessThanOrEqual(outline.maxX, text.maxX + 1, "At width \(width)")
                XCTAssertGreaterThanOrEqual(outline.minX, text.minX - 1, "At width \(width)")
            }
            // Where a plain layout manager breaks the chip after its hyphen.
            if hyphenBreakWidth == nil, chipWidth + 1 < width,
               layout(width: width, layoutManager: NSLayoutManager()).lines.count > 1 {
                hyphenBreakWidth = width
            }
            withExtendedLifetime(storage) {}
        }
        XCTAssertTrue(sawWrappedChip, "The sweep must include a line narrower than the chip")
        let breakWidth = try XCTUnwrap(hyphenBreakWidth, "The sweep must include the hyphen break")

        for (name, width) in [("task-chip-at-hyphen-break", breakWidth), ("task-chip-wider-than-line", 220)] {
            let (hostingView, window) = hosted(width: width)
            defer { window.close() }
            let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            try Self.writeEvidence(png, name: name)
        }
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

    // MARK: - Fixture

    private static func item(
        _ taskID: UUID,
        title: String,
        stage: TaskStage,
        pullRequest: Int? = nil
    ) -> TaskBoardItem {
        TaskBoardItem(
            id: .task(taskID),
            title: title,
            stage: stage,
            agent: .idle,
            pullRequest: pullRequest.flatMap {
                WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/\($0)")
            },
            activityAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// The rows the chat's own adapter makes from a conversation: a digest
    /// that Toastty typed, the coordinator's answer with task links, and a
    /// message from the user.
    private static var state: ToasttyConversationPresentationState {
        let runID = RemoteProjectionRunID(rawValue: UUID())
        let conversationID = RemoteConversationID(rawValue: UUID())
        let digest = """
        \(CoordinatorWakeState.digestHeader)
        - [Restore split ratios](toastty://task/\(reviewTaskID.uuidString)): needsYou (review) at 2026-11-09T18:02:11Z
        - [Composer blank line](toastty://task/\(questionTaskID.uuidString)): needsYou (awaitingReply) at 2026-11-09T18:03:40Z
        \(CoordinatorWakeState.digestFooter)
        """
        let answer = """
        [an old title](toastty://task/\(reviewTaskID.uuidString)) is ready. It checks four relaunch cases with video, and CI is green.

        [Composer blank line](toastty://task/\(questionTaskID.uuidString)) asks which base to use. I'd say *main*, because the PR it waited for merged an hour ago.

        Not chips: [a task that is gone](toastty://task/\(missingTaskID.uuidString)), [run this action](toastty://action/open-settings), [a task link with more](toastty://task/\(reviewTaskID.uuidString)/merge), and [the docs](https://example.com/docs).
        """
        var sequence: UInt64 = 0
        func event(_ payload: ConversationEventPayload) -> ConversationEvent {
            sequence += 1
            return ConversationEvent(
                conversationID: conversationID,
                sequence: sequence,
                eventID: "event-\(sequence)",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
                provider: .claude,
                payload: payload
            )
        }
        let events = [
            event(.userMessage(ConversationUserMessagePayload(text: digest, origin: .remote, clientRequestID: "digest-1"))),
            event(.assistantMessage(ConversationAssistantMessagePayload(text: answer, phase: .final))),
            event(.userMessage(ConversationUserMessagePayload(
                text: "main. and answer base questions yourself when the dependency merged",
                origin: .remote,
                clientRequestID: "composer-1"
            ))),
            event(.assistantMessage(ConversationAssistantMessagePayload(
                text: "Sent. Added to Unblocking: \"Answer base-branch questions when the dependency merged.\"",
                phase: .final
            ))),
        ]
        return ToasttyConversationPresentationState(
            rows: CoordinatorChatTranscript.rows(
                from: events,
                projectionRunID: runID,
                projectionGeneration: 1,
                isSentFromThisMac: { $0 == "composer-1" || $0 == "digest-1" },
                timeText: { _ in "14:05" }
            ),
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }
}
