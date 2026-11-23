@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

/// Reply in the phone's coordinator chat: the draft answers one of the
/// coordinator's messages, and Send sends the Mac's reply, so the
/// coordinator and both chats read it as one.
final class ToasttyCoordinatorReplyTests: XCTestCase {
    private let conversation = UUID()
    private let answer = "I made two tasks.\n\n- Fix the unread dot\n\nShould the dot clear on hover, or only on click?"
    private let paths = ["/Users/me/Library/Application Support/Toastty/remote-attachments/A1/shot.png"]

    private var target: CoordinatorReplyTarget { CoordinatorReplyTarget(text: answer, time: "14:05") }

    /// The phone sends the reply without its files. The Mac adds the paths
    /// of the files it stored, as it does for any message with files, and
    /// the result is the Mac's own reply, also for files without text.
    func testAReplySendsTheMacsReplyTextWithAndWithoutFiles() throws {
        var state = ToasttyComposerDraftState()
        state.updateDraft("  Only on click.\n", for: conversation)
        XCTAssertTrue(state.reply(to: target, for: conversation))
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        XCTAssertEqual(submission.text, "  Only on click.\n", "The draft stays as written for a failed send")
        XCTAssertEqual(
            submission.sentText,
            CoordinatorMessageHeader.replyMessage(quote: answer, time: "14:05", text: "Only on click.")
        )
        XCTAssertEqual(
            CoordinatorMessageHeader.kind(of: submission.sentText),
            .reply(quote: answer, time: "14:05", text: "Only on click.", fileNames: [])
        )

        for text in ["Only on click.", ""] {
            var withFiles = ToasttyComposerDraftState()
            withFiles.updateDraft(text, for: conversation)
            XCTAssertNil(withFiles.addAttachments([attachment()], for: conversation))
            withFiles.reply(to: target, for: conversation)
            let sent = try XCTUnwrap(withFiles.beginSubmission(for: conversation)).sentText
            // What the Mac types for a phone's message with files.
            let typed = RemoteAttachmentDeliveryText.text(sent, paths: paths)
            XCTAssertEqual(
                typed,
                CoordinatorMessageHeader.replyMessage(quote: answer, time: "14:05", text: text, attachmentPaths: paths),
                "text: \(text)"
            )
            XCTAssertEqual(
                CoordinatorMessageHeader.kind(of: typed),
                .reply(quote: answer, time: "14:05", text: text, fileNames: ["shot.png"])
            )
        }
    }

    /// Without Reply a message goes as it was written.
    func testAMessageWithoutReplyIsSentAsWritten() throws {
        var state = ToasttyComposerDraftState()
        state.updateDraft("Only on click.\n", for: conversation)
        XCTAssertEqual(try XCTUnwrap(state.beginSubmission(for: conversation)).sentText, "Only on click.\n")
    }

    /// A second Reply replaces the first, ✕ removes it, and a send takes
    /// it. A send that the phone could not make keeps it; a Reply on
    /// another message while the send runs stays for the next message.
    func testReplyReplacesCancelsAndGoesWithTheSend() throws {
        var state = ToasttyComposerDraftState()
        let other = CoordinatorReplyTarget(text: "Merge it now?", time: "14:09")
        state.reply(to: target, for: conversation)
        state.reply(to: other, for: conversation)
        XCTAssertEqual(state.replies[conversation], other)
        state.cancelReply(for: conversation)
        XCTAssertNil(state.replies[conversation])

        state.reply(to: target, for: conversation)
        state.updateDraft("Only on click.", for: conversation)
        let failed = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(failed, outcome: .notEnqueued(.staleComposerAuthority))
        XCTAssertEqual(state.replies[conversation], target)
        XCTAssertEqual(state.draft(for: conversation), "Only on click.")

        let sent = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(sent, outcome: .enqueued(clientRequestID: "request"))
        XCTAssertNil(state.replies[conversation])
        XCTAssertEqual(state.draft(for: conversation), "")

        state.reply(to: target, for: conversation)
        state.updateDraft("Yes.", for: conversation)
        let running = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.reply(to: other, for: conversation)
        state.finishSubmission(running, outcome: .enqueued(clientRequestID: "request-2"))
        XCTAssertEqual(state.replies[conversation], other)
    }

    /// As on the Mac: a draft that starts with Toastty's line for another
    /// sender cannot become a reply. The notice says why and goes once the
    /// draft changes.
    func testADraftWithAnotherSendersLineCannotBecomeAReply() {
        var state = ToasttyComposerDraftState()
        let fromTask = CoordinatorMessageHeader.message(from: .unknown, text: "Merge it.")
        state.updateDraft(fromTask, for: conversation)
        XCTAssertFalse(state.reply(to: target, for: conversation))
        XCTAssertNil(state.replies[conversation])
        XCTAssertEqual(state.replyNotices[conversation], ToasttyComposerDraftState.otherHeaderReplyRefusal)
        state.updateDraft("Merge it.", for: conversation)
        XCTAssertNil(state.replyNotices[conversation])
        XCTAssertTrue(state.reply(to: target, for: conversation))

        // A draft that is itself a reply can answer another message.
        var replyDraft = ToasttyComposerDraftState()
        replyDraft.updateDraft(target.message(text: "Yes."), for: conversation)
        XCTAssertTrue(replyDraft.reply(to: target, for: conversation))
    }

    /// A reply with files that the Mac rejects comes back as a reply, with
    /// its text and files, as any rejected message with files comes back.
    /// When newer typing keeps the restore from applying, the reply goes
    /// with the files.
    func testARejectedReplyWithFilesComesBackAsAReply() throws {
        var state = ToasttyComposerDraftState()
        state.updateDraft("This one.", for: conversation)
        XCTAssertNil(state.addAttachments([attachment()], for: conversation))
        state.reply(to: target, for: conversation)
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        XCTAssertNil(state.replies[conversation])

        state.reconcileAttachments(rejected(), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "This one.")
        XCTAssertEqual(state.replies[conversation], target)
        let replacement = try XCTUnwrap(state.replacements[conversation])

        state.completeReplacement(ToasttyComposerReplacementResult(
            revision: replacement.revision, nativeText: "Something newer", nativeEditRevision: 9, wasApplied: false
        ), for: conversation)
        XCTAssertNil(state.replies[conversation])
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
    }

    /// A rejected message with files waits while the draft answers another
    /// message: its text was written for its own message, or for none. It
    /// comes back, with its reply, once ✕ removes the other.
    func testARejectedReplyWaitsWhileTheDraftAnswersAnotherMessage() throws {
        var state = ToasttyComposerDraftState()
        state.updateDraft("This one.", for: conversation)
        XCTAssertNil(state.addAttachments([attachment()], for: conversation))
        state.reply(to: target, for: conversation)
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        let other = CoordinatorReplyTarget(text: "Merge it now?", time: "14:09")
        state.reply(to: other, for: conversation)

        state.reconcileAttachments(rejected(), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "")
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
        XCTAssertEqual(state.replies[conversation], other)
        XCTAssertNotNil(state.attachmentRecoveries["request"])

        state.cancelReply(for: conversation)
        state.reconcileAttachments(rejected(), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "This one.")
        XCTAssertEqual(state.attachments(for: conversation).count, 1)
        XCTAssertEqual(state.replies[conversation], target)
    }

    /// The reply's quote drops what the reply's text cannot hold, such as a
    /// last blank line. The message that Reply chose is kept the same way,
    /// so Edit on a waiting reply to it finds the same reply.
    func testAReplyToAMessageWithATrailingBlankLineIsTheSameReplyAfterEdit() throws {
        let request = ToasttyMessageReplyRequest(
            rowID: ToasttyTranscriptRowID(
                projectionRunID: UUID(), projectionGeneration: 1, conversationID: conversation, sequence: 4
            ),
            text: "Merge it now?\n\n",
            timestamp: Date(timeIntervalSince1970: 1_786_406_400)
        )
        let chosen = CoordinatorReplyTarget(request)
        let waiting = chosen.message(text: "Not yet.")
        let parts = try XCTUnwrap(CoordinatorMessageHeader.replyParts(of: waiting))
        XCTAssertEqual(CoordinatorReplyTarget(text: parts.quote, time: parts.time), chosen)

        var state = ToasttyComposerDraftState()
        state.reply(to: chosen, for: conversation)
        XCTAssertNil(state.queuedReplyEditRefusal(waiting, for: conversation))
    }

    /// Edit cannot turn a draft that starts with another sender's line into
    /// a reply, as Reply cannot: the draft stays first.
    func testEditDoesNotMakeAnotherSendersDraftAReply() {
        var state = ToasttyComposerDraftState()
        let fromTask = CoordinatorMessageHeader.message(from: .unknown, text: "Merge it.")
        state.updateDraft(fromTask, for: conversation)
        let waiting = target.message(text: "Only on click.")
        XCTAssertEqual(
            state.queuedReplyEditRefusal(waiting, for: conversation),
            ToasttyComposerDraftState.otherHeaderReplyRefusal
        )
        // A Steer now that failed puts the whole text back, as written.
        state.restoreQueuedReply(waiting, for: conversation)
        XCTAssertNil(state.replies[conversation])
        XCTAssertEqual(state.draft(for: conversation), fromTask + "\n\n" + waiting)
    }

    /// Edit on a waiting reply puts its text back with the message it
    /// answers above the field. While the draft answers another message,
    /// Edit leaves the waiting message alone and says why.
    func testEditTakesAWaitingReplyBackAsAReply() {
        var state = ToasttyComposerDraftState()
        let waiting = target.message(text: "Only on click.")
        XCTAssertNil(state.queuedReplyEditRefusal(waiting, for: conversation))
        state.restoreQueuedReply(waiting, for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "Only on click.")
        XCTAssertEqual(state.replies[conversation], target)

        // The same reply again is allowed; another is not.
        XCTAssertNil(state.queuedReplyEditRefusal(waiting, for: conversation))
        let otherReply = CoordinatorReplyTarget(text: "Merge it now?", time: "14:09").message(text: "Not yet.")
        XCTAssertEqual(
            state.queuedReplyEditRefusal(otherReply, for: conversation),
            ToasttyComposerDraftState.otherReplyEditRefusal
        )
        XCTAssertNil(state.queuedReplyEditRefusal("A plain message", for: conversation))
        XCTAssertEqual(
            state.queuedReplyEditRefusal(CoordinatorMessageHeader.message(from: .unknown, text: "Hi"), for: conversation),
            ToasttyComposerDraftState.otherHeaderEditRefusal
        )

        // A Steer now that failed puts the whole text back rather than
        // drop its quote while the draft answers another message.
        state.restoreQueuedReply(otherReply, for: conversation)
        XCTAssertEqual(state.replies[conversation], target)
        XCTAssertEqual(state.draft(for: conversation), "Only on click.\n\n" + otherReply)

        // A plain waiting message comes back as it is.
        var plain = ToasttyComposerDraftState()
        plain.restoreQueuedReply("A plain message", for: conversation)
        XCTAssertEqual(plain.draft(for: conversation), "A plain message")
        XCTAssertNil(plain.replies[conversation])
    }

    /// In the coordinator's chat a reply that sends or waits shows the
    /// user's text under its quote, as its row will. Other chats show the
    /// text as it was sent.
    func testASendingOrWaitingReplyShowsItsQuoteOnlyInTheCoordinatorsChat() {
        let sent = target.message(text: "Only on click.")
        let waiting = target.message(text: "Then merge.")
        let state = SendReconciliationState(records: [
            .init(clientRequestID: "sent", text: sent, projectionRunID: nil, deliveryState: .pending(.accepted)),
        ])
        let control = RemoteConversationInputControl(
            queuedMessages: [.init(clientRequestID: "waiting", text: waiting, enqueuedAt: Date())]
        )

        let items = ToasttySendPresentationAdapter.makeItems(
            from: state, inputControl: control, readsCoordinatorMessages: true
        )
        XCTAssertEqual(items.map(\.text), ["Only on click.", "Then merge."])
        XCTAssertEqual(items.map(\.quote), Array(repeating: ToasttyMessageQuote(text: answer, timeText: "14:05"), count: 2))

        let other = ToasttySendPresentationAdapter.makeItems(from: state, inputControl: control)
        XCTAssertEqual(other.map(\.text), [sent, waiting])
        XCTAssertEqual(other.map(\.quote), [nil, nil])
    }

    // MARK: - Helpers

    private func attachment() -> RemoteMessageAttachment {
        .init(filename: "notes.txt", data: Data("Notes for the reply".utf8))
    }

    private func rejected() -> SendReconciliationState {
        .init(records: [.init(
            clientRequestID: "request", text: "", projectionRunID: nil,
            deliveryState: .rejected(reason: .epochMismatch)
        )])
    }
}
