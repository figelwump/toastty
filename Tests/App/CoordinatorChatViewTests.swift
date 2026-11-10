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
