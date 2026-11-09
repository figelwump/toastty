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
        .frame(width: Self.transcriptSize.width, height: Self.transcriptSize.height)
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: transcript)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.transcriptSize),
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

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        XCTAssertGreaterThan(
            Self.sampledColorCount(in: bitmap), 12,
            "The transcript must draw more than its background"
        )
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "conversation-ui-macos-fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
        try Self.writeEvidence(png, name: "conversation-ui-macos-fixture")
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
