import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyComposerPresentationTests: XCTestCase {
    func testComposerEnablesOnlyForDomainAuthorizedStampedOpenPrompt() {
        XCTAssertEqual(presentation(enabledAuthority).gate, .enabled)

        XCTAssertEqual(
            presentation(authority(failure: .coordinatorNotLive)).gate,
            .disabled(.connection(.reconnecting))
        )
        XCTAssertEqual(
            presentation(authority(failure: .transcriptNotCaughtUp)).gate,
            .disabled(.connection(.catchingUp))
        )
        XCTAssertEqual(
            presentation(ConversationComposerAuthority()).gate,
            .disabled(.connection(.reconnecting))
        )
    }

    func testComposerGateKeepsDomainDeviceAndRawSessionAuthorityDistinct() {
        let deviceDenied = authority(
            availability: .unavailable(reason: .known(.sessionWritesDisabled)),
            failure: .deviceSendScopeDenied
        )
        XCTAssertEqual(
            presentation(deviceDenied).gate,
            .disabled(.deviceScope),
            "Domain gate precedence must win over the raw availability presentation"
        )
        XCTAssertTrue(presentation(deviceDenied).gateMessage.contains("device"))

        let sessionDisabled = authority(
            availability: .unavailable(reason: .known(.sessionWritesDisabled)),
            failure: .inputUnavailable
        )
        XCTAssertEqual(presentation(sessionDisabled).gate, .disabled(.sessionWrites))
        XCTAssertTrue(presentation(sessionDisabled).gateMessage.contains("session"))
    }

    func testEveryDomainGateFailureMapsToAStableLocalPresentation() {
        let cases: [(ConversationSendGateFailure, ToasttyComposerGate)] = [
            (.emptyText, .enabled),
            (.messageTooLarge, .enabled),
            (.requestEncodingFailed, .enabled),
            (.cancelled, .enabled),
            (.coordinatorNotLive, .disabled(.connection(.reconnecting))),
            (.deviceSendScopeDenied, .disabled(.deviceScope)),
            (.conversationNotOpen, .disabled(.prompt(.offline))),
            (.conversationMissing, .disabled(.prompt(.offline))),
            (.staleComposerAuthority, .disabled(.connection(.catchingUp))),
            (.conversationNotLive, .disabled(.connection(.catchingUp))),
            (.transcriptNotCaughtUp, .disabled(.connection(.catchingUp))),
            (.inputUnavailable, .disabled(.prompt(.closed))),
            (.sendAlreadyReserved, .disabled(.prompt(.sending))),
            (.tooManyUnresolvedSends, .disabled(.prompt(.sending))),
        ]

        for (failure, expectedGate) in cases {
            XCTAssertEqual(
                presentation(authority(failure: failure)).gate,
                expectedGate,
                "Unexpected composer presentation for \(failure)"
            )
        }
    }

    func testComposerMapsRawAvailabilityIntoTruthfulGroupedDisabledStates() {
        let epoch = stamp.inputEpoch
        let cases: [(CompatibleInputAvailability, ToasttyComposerDisabledReason)] = [
            (.localDraft(epoch: epoch), .localDraft),
            (.pendingInteraction(interactionIDs: []), .pendingInteraction),
            (.unavailable(reason: .known(.sessionWritesDisabled)), .sessionWrites),
            (.unavailable(reason: .known(.starting)), .prompt(.starting)),
            (.unavailable(reason: .known(.working)), .prompt(.working)),
            (.unavailable(reason: .known(.offline)), .prompt(.offline)),
            (.unavailable(reason: .known(.ended)), .prompt(.offline)),
            (.unavailable(reason: .known(.interrupted)), .prompt(.closed)),
            (.unavailable(reason: .known(.error)), .prompt(.closed)),
            (.unavailable(reason: .known(.surfaceUnavailable)), .prompt(.closed)),
            (.unavailable(reason: .known(.unknownProviderState)), .prompt(.closed)),
            (.unavailable(reason: .unsupported(rawValue: "future_reason")), .prompt(.unsupported)),
            (.unsupported(rawKind: "future_kind"), .prompt(.unsupported)),
        ]

        for (availability, expectedReason) in cases {
            XCTAssertEqual(
                presentation(authority(
                    availability: availability,
                    failure: .inputUnavailable
                )).gate,
                .disabled(expectedReason),
                "Unexpected presentation for \(availability)"
            )
        }
    }

    func testLockedFallbackKeepsStartingDistinctFromWorking() {
        let starting = ToasttyComposerPresentation.makeLockedFallback(
            agentDisplayName: "Codex",
            inputAvailability: .unavailable(reason: "starting")
        )
        let working = ToasttyComposerPresentation.makeLockedFallback(
            agentDisplayName: "Codex",
            inputAvailability: .unavailable(reason: "working")
        )

        XCTAssertEqual(starting.gate, .disabled(.prompt(.starting)))
        XCTAssertEqual(working.gate, .disabled(.prompt(.working)))
        XCTAssertTrue(starting.gateMessage.contains("starting"))
        XCTAssertTrue(working.gateMessage.contains("working"))
    }

    func testComposerPlaceholderDoesNotMislabelEveryDisabledStateAsALocalDraft() {
        let enabled = presentation(enabledAuthority)
        let localDraft = presentation(authority(
            availability: .localDraft(epoch: stamp.inputEpoch),
            failure: .inputUnavailable
        ))
        let catchingUp = presentation(authority(failure: .transcriptNotCaughtUp))

        XCTAssertEqual(enabled.placeholder, "Message Codex…")
        XCTAssertEqual(localDraft.placeholder, "Message Codex…")
        XCTAssertEqual(catchingUp.placeholder, "Message Codex…")
    }

    func testDraftValidationRejectsWhitespaceButDoesNotInventATextLimit() {
        let subject = presentation(enabledAuthority)

        XCTAssertFalse(subject.canSubmit(draft: ""))
        XCTAssertFalse(subject.canSubmit(draft: " \n\t "))
        XCTAssertTrue(subject.canSubmit(draft: " message "))
        XCTAssertTrue(
            subject.canSubmit(draft: String(repeating: "a", count: 70_000)),
            "The app must not guess a character cap from the host's encoded HTTP-body limit"
        )

        let disabled = authority(
            availability: .localDraft(epoch: stamp.inputEpoch),
            failure: .inputUnavailable
        )
        XCTAssertFalse(presentation(disabled).canSubmit(draft: "message"))
    }

    func testLocalPreDispatchFailureHasInlineDraftPreservationFeedback() {
        let cancelled = presentation(authority(failure: .cancelled))
        let empty = presentation(authority(failure: .emptyText))

        XCTAssertEqual(cancelled.gate, .enabled)
        XCTAssertTrue(cancelled.inlineFeedback?.contains("draft is still here") == true)
        XCTAssertEqual(empty.gate, .enabled)
        XCTAssertTrue(empty.inlineFeedback?.contains("draft was not changed") == true)
        let oversized = presentation(authority(failure: .messageTooLarge))
        XCTAssertEqual(oversized.gate, .enabled)
        XCTAssertTrue(oversized.inlineFeedback?.contains("Shorten it") == true)
    }

    func testDraftStateAllowsOnlyOneSubmissionPerConversation() throws {
        let conversationID = UUID()
        let otherConversationID = UUID()
        var subject = ToasttyComposerDraftState()
        subject.updateDraft("first message", for: conversationID)
        subject.updateDraft("other message", for: otherConversationID)

        let first = try XCTUnwrap(subject.beginSubmission(
            for: conversationID,
            submissionID: UUID()
        ))

        XCTAssertNil(subject.beginSubmission(for: conversationID))
        XCTAssertNotNil(subject.beginSubmission(for: otherConversationID))
        XCTAssertTrue(subject.isSubmitting(conversationID))
        XCTAssertEqual(first.text, "first message")
    }

    func testEnqueuedSubmissionClearsOnlyItsUnchangedCapturedDraft() throws {
        let unchangedConversationID = UUID()
        let editedConversationID = UUID()
        var subject = ToasttyComposerDraftState()
        subject.updateDraft("unchanged", for: unchangedConversationID)
        subject.updateDraft("captured", for: editedConversationID)
        let unchanged = try XCTUnwrap(subject.beginSubmission(for: unchangedConversationID))
        let edited = try XCTUnwrap(subject.beginSubmission(for: editedConversationID))

        subject.updateDraft("edited while sending", for: editedConversationID)
        subject.finishSubmission(
            unchanged,
            outcome: .enqueued(clientRequestID: "unchanged")
        )
        subject.finishSubmission(
            edited,
            outcome: .enqueued(clientRequestID: "edited")
        )

        XCTAssertEqual(subject.draft(for: unchangedConversationID), "")
        XCTAssertEqual(subject.draft(for: editedConversationID), "edited while sending")
        XCTAssertFalse(subject.isSubmitting(unchangedConversationID))
        XCTAssertFalse(subject.isSubmitting(editedConversationID))
    }

    func testLocalFailurePreservesDraftAndSessionResetInvalidatesStaleCompletion() throws {
        let conversationID = UUID()
        var subject = ToasttyComposerDraftState()
        subject.updateDraft("preserve on failure", for: conversationID)
        let failed = try XCTUnwrap(subject.beginSubmission(for: conversationID))
        subject.finishSubmission(failed, outcome: .notEnqueued(.staleComposerAuthority))
        XCTAssertEqual(subject.draft(for: conversationID), "preserve on failure")

        let stale = try XCTUnwrap(subject.beginSubmission(for: conversationID))
        subject.reset()
        subject.updateDraft("new paired session", for: conversationID)
        let current = try XCTUnwrap(subject.beginSubmission(for: conversationID))

        subject.finishSubmission(stale, outcome: .enqueued(clientRequestID: "stale"))

        XCTAssertEqual(subject.draft(for: conversationID), "new paired session")
        XCTAssertTrue(subject.isSubmitting(conversationID))
        subject.finishSubmission(current, outcome: .enqueued(clientRequestID: "current"))
        XCTAssertEqual(subject.draft(for: conversationID), "")
    }

    func testOversizedMessageKeepsFullDraftAndReleasesSubmissionForEditing() throws {
        let conversationID = UUID()
        let text = String(repeating: "🐈\n\"\\", count: 12_000)
        var subject = ToasttyComposerDraftState()
        subject.updateDraft(text, for: conversationID)
        let submission = try XCTUnwrap(subject.beginSubmission(for: conversationID))

        subject.finishSubmission(submission, outcome: .notEnqueued(.messageTooLarge))

        XCTAssertEqual(subject.draft(for: conversationID), text)
        XCTAssertFalse(subject.isSubmitting(conversationID))
        subject.updateDraft("Shortened message", for: conversationID)
        XCTAssertNotNil(subject.beginSubmission(for: conversationID))
    }

    func testDraftStatePrunesRemovedConversations() {
        let retainedID = UUID()
        let removedID = UUID()
        var subject = ToasttyComposerDraftState()
        subject.updateDraft("retained", for: retainedID)
        subject.updateDraft("removed", for: removedID)
        _ = subject.beginSubmission(for: removedID)

        subject.retainConversations([retainedID])

        XCTAssertEqual(subject.draft(for: retainedID), "retained")
        XCTAssertEqual(subject.draft(for: removedID), "")
        XCTAssertFalse(subject.isSubmitting(removedID))
    }

    func testEveryPendingResponseRemainsOneOptimisticBubbleKeyedOnlyByRequestID() throws {
        let state = SendReconciliationState(records: [
            record("awaiting", text: "same", .pending(.awaitingResponse)),
            record("accepted", text: "same", .pending(.accepted)),
            record("duplicate", text: "same", .pending(.duplicate)),
        ])

        let items = ToasttySendPresentationAdapter.makeItems(from: state)

        XCTAssertEqual(items.map(\.id), ["awaiting", "accepted", "duplicate"])
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
        XCTAssertEqual(items.map(\.text), ["same", "same", "same"])
        XCTAssertEqual(
            items.map(\.content),
            [
                .optimistic(response: .awaitingResponse),
                .optimistic(response: .accepted),
                .optimistic(response: .duplicate),
            ]
        )
    }

    func testExactConfirmationRemovesOptimisticPresentationSoCanonicalEchoStandsAlone() {
        let state = SendReconciliationState(records: [
            record("confirmed", text: "identical", .confirmed(sequence: 14)),
            record("other-phone", text: "identical", .pending(.accepted)),
        ])

        let items = ToasttySendPresentationAdapter.makeItems(from: state)

        XCTAssertEqual(items.map(\.id), ["other-phone"])
        XCTAssertEqual(items.first?.content, .optimistic(response: .accepted))
    }

    func testEveryRejectionHasAStandaloneDismissibleReasonAndNoOptimisticBubble() {
        let reasons: [RemoteMessageRejectionReason] = [
            .sendScopeDenied,
            .sessionWritesDisabled,
            .notBound,
            .surfaceUnavailable,
            .promptNotOpen,
            .epochMismatch,
            .localDraftPresent,
            .pendingInteraction,
            .emptyText,
        ]
        let state = SendReconciliationState(records: reasons.enumerated().map { index, reason in
            record("rejected-\(index)", text: "draft \(index)", .rejected(reason: reason))
        })

        let items = ToasttySendPresentationAdapter.makeItems(from: state)

        XCTAssertEqual(items.count, reasons.count)
        for (item, reason) in zip(items, reasons) {
            guard case .receipt(let receipt) = item.content else {
                return XCTFail("A rejection must not retain an optimistic bubble")
            }
            XCTAssertEqual(receipt.kind, .rejected(reason))
            XCTAssertFalse(receipt.title.isEmpty)
            XCTAssertTrue(receipt.detail.localizedCaseInsensitiveContains("retry")
                || receipt.detail.localizedCaseInsensitiveContains("draft")
                || reason == .emptyText)
        }
    }

    func testUncertainOperationFailureAndDeliveryUnconfirmedAreStandaloneReceiptsWithoutRetry() {
        let uncertain = ToasttySendPresentationAdapter.makeItems(from: .init(records: [
            record("uncertain", text: "maybe sent", .uncertain),
        ]))
        let unconfirmed = ToasttySendPresentationAdapter.makeItems(from: .init(records: [
            record("unconfirmed", text: "lost echo", .deliveryUnconfirmed),
        ]))
        let operationFailed = ToasttySendPresentationAdapter.makeItems(from: .init(records: [
            record("operation-failed", text: "unknown response", .operationFailed),
        ]))

        guard case .receipt(let uncertainReceipt) = uncertain.first?.content else {
            return XCTFail("Uncertain delivery needs a standalone receipt")
        }
        guard case .receipt(let unconfirmedReceipt) = unconfirmed.first?.content else {
            return XCTFail("Lost correlation needs a standalone receipt")
        }
        guard case .receipt(let operationFailedReceipt) = operationFailed.first?.content else {
            return XCTFail("An incompatible response needs a standalone receipt")
        }
        XCTAssertEqual(uncertainReceipt.kind, .uncertain)
        XCTAssertTrue(uncertainReceipt.detail.contains("will not retry"))
        XCTAssertEqual(unconfirmedReceipt.kind, .deliveryUnconfirmed)
        XCTAssertTrue(unconfirmedReceipt.title.contains("did not appear"))
        XCTAssertTrue(unconfirmedReceipt.detail.contains("before sending again"))
        XCTAssertTrue(unconfirmedReceipt.detail.contains("will not retry"))
        XCTAssertEqual(operationFailedReceipt.kind, .operationFailed)
        XCTAssertTrue(operationFailedReceipt.title.contains("could not complete"))
        XCTAssertTrue(operationFailedReceipt.detail.contains("did not retry"))
    }

    private var enabledAuthority: ConversationComposerAuthority {
        ConversationComposerAuthority(
            stamp: stamp,
            inputAvailability: .openPrompt(epoch: stamp.inputEpoch)
        )
    }

    private func presentation(
        _ authority: ConversationComposerAuthority
    ) -> ToasttyComposerPresentation {
        .make(agentDisplayName: "Codex", authority: authority)
    }

    private func authority(
        availability: CompatibleInputAvailability? = nil,
        failure: ConversationSendGateFailure
    ) -> ConversationComposerAuthority {
        ConversationComposerAuthority(
            stamp: stamp,
            inputAvailability: availability ?? .openPrompt(epoch: stamp.inputEpoch),
            gateFailure: failure
        )
    }

    private var stamp: ConversationComposerStamp {
        ConversationComposerStamp(
            connectionGeneration: 4,
            streamSnapshotOrdinal: 8,
            projectionRunID: RemoteProjectionRunID(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            projectionGeneration: 2,
            latestSequence: 10,
            inputEpoch: RemoteInputEpoch(
                bindingID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                counter: 3
            )
        )
    }

    private func record(
        _ id: String,
        text: String,
        _ state: SendDeliveryState
    ) -> SendReconciliationRecord {
        SendReconciliationRecord(
            clientRequestID: id,
            text: text,
            projectionRunID: nil,
            deliveryState: state
        )
    }
}

private extension ToasttyComposerPresentation {
    var gateMessage: String {
        guard case .disabled(let reason) = gate else { return "" }
        return reason.message
    }
}
