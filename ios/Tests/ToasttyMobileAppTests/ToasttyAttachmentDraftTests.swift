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

    private func reconciliation(_ delivery: SendDeliveryState) -> SendReconciliationState {
        .init(records: [.init(clientRequestID: "request", text: "", projectionRunID: nil, deliveryState: delivery)])
    }
}
