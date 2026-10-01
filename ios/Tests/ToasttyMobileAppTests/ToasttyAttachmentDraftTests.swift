import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyAttachmentDraftTests: XCTestCase {
    private func attachment(bytes: Int = 4) -> RemoteMessageAttachment {
        .init(filename: "note.txt", data: Data(repeating: 65, count: bytes))
    }

    func testAttachmentOnlySubmissionAndLocalFailurePreserveConversationOwnership() throws {
        let conversation = UUID()
        let other = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        XCTAssertNil(state.addAttachments([file], for: conversation))
        XCTAssertTrue(state.attachments(for: other).isEmpty)
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        XCTAssertEqual(submission.attachments, [file])
        XCTAssertEqual(submission.text, "")
        state.removeAttachment(file.id, for: conversation)
        XCTAssertEqual(state.attachments(for: conversation), [file], "Removal is locked during submission")
        state.finishSubmission(submission, outcome: .notEnqueued(.staleComposerAuthority))
        XCTAssertEqual(state.attachments(for: conversation), [file])
        XCTAssertFalse(state.isSubmitting(conversation))
        XCTAssertTrue(ToasttyComposerPresentation(agentDisplayName: "Codex", gate: .enabled)
            .canSubmit(draft: "", attachments: [file]))
    }

    func testEnqueueClearsAttachmentsAndDefiniteRejectionRestoresOriginalDraft() throws {
        let conversation = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        state.updateDraft("Review this", for: conversation)
        XCTAssertNil(state.addAttachments([file], for: conversation))
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
        XCTAssertEqual(state.draft(for: conversation), "")
        state.reconcileAttachments(reconciliation(.rejected(reason: .epochMismatch)), for: conversation)
        XCTAssertEqual(state.attachments(for: conversation), [file])
        XCTAssertEqual(state.draft(for: conversation), "Review this")
        XCTAssertTrue(state.attachmentRecoveries.isEmpty)
    }

    func testRejectedRecoveryWaitsForNewerDraftToBeCleared() throws {
        let conversation = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        XCTAssertNil(state.addAttachments([file], for: conversation))
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        state.updateDraft("A newer message", for: conversation)
        state.reconcileAttachments(reconciliation(.rejected(reason: .epochMismatch)), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "A newer message")
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
        XCTAssertNotNil(state.attachmentRecoveries["request"])
        state.updateDraft("", for: conversation)
        state.reconcileAttachments(reconciliation(.rejected(reason: .epochMismatch)), for: conversation)
        XCTAssertEqual(state.attachments(for: conversation), [file])
    }

    func testDismissingRejectedReceiptDiscardsDeferredRecoveryWithoutChangingNewerDraft() throws {
        let conversation = UUID()
        var state = ToasttyComposerDraftState()
        XCTAssertNil(state.addAttachments([attachment()], for: conversation))
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        state.updateDraft("A newer message", for: conversation)
        state.reconcileAttachments(reconciliation(.rejected(reason: .epochMismatch)), for: conversation)
        XCTAssertNotNil(state.attachmentRecoveryMessages[conversation])

        state.discardAttachmentRecovery(clientRequestID: "request", for: conversation)

        XCTAssertTrue(state.attachmentRecoveries.isEmpty)
        XCTAssertNil(state.attachmentRecoveryMessages[conversation])
        XCTAssertEqual(state.draft(for: conversation), "A newer message")
        state.updateDraft("", for: conversation)
        state.reconcileAttachments(reconciliation(.rejected(reason: .epochMismatch)), for: conversation)
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
    }

    func testRejectedAttachmentsRestoreOnlyAfterCurrentSubmissionFinishes() throws {
        let conversation = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        state.updateDraft("Same text", for: conversation)
        XCTAssertNil(state.addAttachments([file], for: conversation))
        let original = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(original, outcome: .enqueued(clientRequestID: "request"))
        state.updateDraft("Same text", for: conversation)
        let current = try XCTUnwrap(state.beginSubmission(for: conversation))
        let rejected = reconciliation(.rejected(reason: .epochMismatch))

        state.reconcileAttachments(rejected, for: conversation)

        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
        XCTAssertNotNil(state.attachmentRecoveries["request"])
        XCTAssertTrue(state.isSubmitting(conversation))
        state.finishSubmission(current, outcome: .notEnqueued(.staleComposerAuthority))
        state.reconcileAttachments(rejected, for: conversation)
        XCTAssertEqual(state.attachments(for: conversation), [file])
        XCTAssertEqual(state.draft(for: conversation), "Same text")
    }

    func testAcceptedAndUncertainSendsNeverRestoreAttachments() throws {
        for delivery: SendDeliveryState in [.pending(.accepted), .pending(.duplicate), .confirmed(sequence: 1), .uncertain, .operationFailed, .deliveryUnconfirmed] {
            let conversation = UUID()
            var state = ToasttyComposerDraftState()
            XCTAssertNil(state.addAttachments([attachment()], for: conversation))
            let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
            state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
            state.reconcileAttachments(reconciliation(delivery), for: conversation)
            XCTAssertTrue(state.attachments(for: conversation).isEmpty)
            XCTAssertTrue(state.attachmentRecoveries.isEmpty)
        }
    }

    func testDraftBudgetCountsPendingRecoveryAndPrunesResetState() throws {
        var state = ToasttyComposerDraftState()
        let conversations = (0..<4).map { _ in UUID() }
        for (index, conversation) in conversations.enumerated() {
            XCTAssertNil(state.addAttachments([attachment(bytes: 4 * 1024 * 1024), attachment(bytes: 4 * 1024 * 1024)], for: conversation))
            let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
            state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request-\(index)"))
        }
        XCTAssertNotNil(state.addAttachments([attachment()], for: UUID()))
        state.retainConversations([conversations[0]])
        XCTAssertEqual(state.attachmentRecoveries.count, 1)
        XCTAssertNil(state.addAttachments([attachment()], for: conversations[0]))
        let generation = state.generation
        state.reset()
        XCTAssertNotEqual(state.generation, generation)
        XCTAssertTrue(state.attachmentDrafts.isEmpty)
        XCTAssertTrue(state.attachmentRecoveries.isEmpty)
    }

    func testNativeEditDuringRestorationDefersAttachmentsUntilDraftIsCleared() throws {
        let conversation = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        state.updateDraft("Review this", for: conversation)
        XCTAssertNil(state.addAttachments([file], for: conversation))
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        let clear = try XCTUnwrap(state.replacements[conversation])
        let rejected = reconciliation(.rejected(reason: .epochMismatch))
        state.reconcileAttachments(rejected, for: conversation)
        let restoration = try XCTUnwrap(state.replacements[conversation])
        XCTAssertGreaterThan(restoration.revision, clear.revision)
        XCTAssertEqual(restoration.expectedEditRevision, clear.expectedEditRevision)
        state.updateDraft("New typing", for: conversation)
        state.completeReplacement(.init(revision: restoration.revision, nativeText: "New typing", nativeEditRevision: 2, wasApplied: false), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "New typing")
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
        XCTAssertEqual(state.attachmentRecoveries["request"], submission)
        // An older completion must not undo the newer draft or recovery.
        state.completeReplacement(.init(revision: clear.revision, nativeText: "Review this", nativeEditRevision: 1, wasApplied: false), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "New typing")
        state.updateDraft("", for: conversation)
        state.reconcileAttachments(rejected, for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "Review this")
        XCTAssertEqual(state.attachments(for: conversation), [file])
    }

    func testResetAndPruningInvalidatePendingReplacementCompletions() throws {
        let conversation = UUID()
        var state = ToasttyComposerDraftState()
        state.updateDraft("sent", for: conversation)
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        let clear = try XCTUnwrap(state.replacements[conversation])
        state.retainConversations([])
        state.completeReplacement(.init(revision: clear.revision, nativeText: "obsolete", nativeEditRevision: 1, wasApplied: false), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "")
        state.updateDraft("another", for: conversation)
        let next = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(next, outcome: .enqueued(clientRequestID: "next"))
        XCTAssertGreaterThan(try XCTUnwrap(state.replacements[conversation]).revision, clear.revision)
        state.reset()
        state.completeReplacement(.init(revision: clear.revision, nativeText: "obsolete", nativeEditRevision: 1, wasApplied: false), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "")
    }

    func testRestorationCompletionDoesNotRecoverAttachmentsAlreadyBeingResent() throws {
        let conversation = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        state.updateDraft("original", for: conversation)
        XCTAssertNil(state.addAttachments([file], for: conversation))
        let original = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(original, outcome: .enqueued(clientRequestID: "request"))
        let rejected = reconciliation(.rejected(reason: .epochMismatch))
        state.reconcileAttachments(rejected, for: conversation)
        let replacement = try XCTUnwrap(state.replacements[conversation])
        state.updateDraft("newer", for: conversation)
        let resend = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.completeReplacement(.init(
            revision: replacement.revision, nativeText: "newer", nativeEditRevision: 2, wasApplied: false
        ), for: conversation)
        XCTAssertEqual(state.attachments(for: conversation), [file])
        XCTAssertNil(state.replacements[conversation])
        XCTAssertNil(state.attachmentRecoveries["request"])
        state.finishSubmission(resend, outcome: .enqueued(clientRequestID: "resend"))
        state.reconcileAttachments(rejected, for: conversation)
        XCTAssertTrue(state.attachments(for: conversation).isEmpty)
        XCTAssertNil(state.attachmentRecoveries["request"])
        XCTAssertEqual(state.attachmentRecoveries["resend"], resend)
    }

    func testDismissedPendingRestorationDoesNotAttachFilesToNewerText() throws {
        let conversation = UUID()
        let file = attachment()
        var state = ToasttyComposerDraftState()
        XCTAssertNil(state.addAttachments([file], for: conversation))
        let submission = try XCTUnwrap(state.beginSubmission(for: conversation))
        state.finishSubmission(submission, outcome: .enqueued(clientRequestID: "request"))
        state.reconcileAttachments(reconciliation(.rejected(reason: .epochMismatch)), for: conversation)
        let replacement = try XCTUnwrap(state.replacements[conversation])
        state.discardAttachmentRecovery(clientRequestID: "request", for: conversation)
        state.completeReplacement(.init(
            revision: replacement.revision, nativeText: "newer", nativeEditRevision: 1, wasApplied: false
        ), for: conversation)
        XCTAssertEqual(state.draft(for: conversation), "newer")
        XCTAssertNil(state.attachmentDrafts[conversation])
        XCTAssertTrue(state.attachmentRecoveries.isEmpty)
        XCTAssertNil(state.attachmentRecoveryMessages[conversation])
    }

    private func reconciliation(_ delivery: SendDeliveryState) -> SendReconciliationState {
        .init(records: [.init(clientRequestID: "request", text: "", projectionRunID: nil, deliveryState: delivery)])
    }
}
