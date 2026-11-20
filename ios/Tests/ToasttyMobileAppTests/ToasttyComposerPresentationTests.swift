@testable import ConversationUI
import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyComposerPresentationTests: XCTestCase {
    func testConnectionGraceHidesReconnectCopyWithoutUnlockingSendOrOtherGates() {
        let checking = ToasttyComposerPresentation.make(
            agentDisplayName: "Codex",
            authority: authority(failure: .coordinatorNotLive),
            suppressesConnectionNotice: true
        )
        XCTAssertTrue(checking.suppressesConnectionNotice)
        XCTAssertEqual(checking.placeholder, "Message Codex…")
        XCTAssertFalse(checking.canSubmit(draft: "saved draft"))
        XCTAssertFalse(checking.canSubmit(draft: "", attachments: [
            RemoteMessageAttachment(filename: "note.txt", data: Data("saved attachment".utf8)),
        ]))
        XCTAssertFalse(checking.canInterrupt)

        let failures: [ConversationSendGateFailure] = [.deviceSendScopeDenied, .inputUnavailable, .transcriptNotCaughtUp]
        for failure in failures {
            let blocked = ToasttyComposerPresentation.make(
                agentDisplayName: "Codex", authority: authority(failure: failure),
                suppressesConnectionNotice: true
            )
            XCTAssertFalse(blocked.suppressesConnectionNotice, "Grace must only hide reconnect copy")
            XCTAssertFalse(blocked.canSubmit(draft: "saved draft"))
        }
        let unavailableInputs: [CompatibleInputAvailability] = [
            .localDraft(epoch: stamp.inputEpoch),
            .unavailable(reason: .known(.working)),
            .unavailable(reason: .known(.sessionWritesDisabled)),
        ]
        for availability in unavailableInputs {
            let verifying = ToasttyComposerPresentation.make(
                agentDisplayName: "Codex",
                authority: authority(availability: availability, failure: .coordinatorNotLive),
                suppressesConnectionNotice: true
            )
            XCTAssertTrue(verifying.suppressesConnectionNotice)
            XCTAssertFalse(verifying.canSubmit(draft: "saved draft"))
            XCTAssertFalse(verifying.canInterrupt)
            XCTAssertFalse(verifying.canReleaseLocalDraft)
        }
    }

    func testComposerEnablesOnlyForDomainAuthorizedStampedOpenPrompt() {
        XCTAssertEqual(presentation(enabledAuthority).gate, .enabled(.prompt))

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
            (.emptyText, .enabled(.prompt)),
            (.messageTooLarge, .enabled(.prompt)),
            (.requestEncodingFailed, .enabled(.prompt)),
            (.cancelled, .enabled(.prompt)),
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

    func testComposerPlaceholderExplainsEachBlockedStateAndInvitesInputOnlyWhenEnabled() {
        XCTAssertEqual(presentation(enabledAuthority).placeholder, "Message Codex…")
        let cases: [(ToasttyComposerDisabledReason, String)] = [
            (.deviceScope, "Read-only on this iPhone"),
            (.sessionWrites, "Remote input is off"),
            (.localDraft, "Draft in progress on Mac"),
            (.pendingInteraction, "Pending request — input paused"),
            (.connection(.reconnecting), "Reconnecting to Mac…"),
            (.connection(.catchingUp), "Syncing with Mac…"),
            (.prompt(.starting), "Session starting…"),
            (.prompt(.working), "Agent working…"),
            (.prompt(.offline), "Session offline"),
            (.prompt(.closed), "Input unavailable"),
            (.prompt(.unsupported), "Read-only in this app version"),
            (.prompt(.sending), "Sending message…"),
        ]
        for (reason, expected) in cases {
            let subject = ToasttyComposerPresentation(
                agentDisplayName: "Codex",
                gate: .disabled(reason)
            )
            XCTAssertEqual(subject.placeholder, expected, "\(reason)")
        }
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

        XCTAssertEqual(cancelled.gate, .enabled(.prompt))
        XCTAssertTrue(cancelled.inlineFeedback?.contains("draft is still here") == true)
        XCTAssertEqual(empty.gate, .enabled(.prompt))
        XCTAssertTrue(empty.inlineFeedback?.contains("draft was not changed") == true)
        let oversized = presentation(authority(failure: .messageTooLarge))
        XCTAssertEqual(oversized.gate, .enabled(.prompt))
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
        // The sending bubble carries the caption its transcript row will
        // show, so the bubble keeps its height when the row replaces it.
        XCTAssertEqual(items.map(\.sentCaption), ["sent remotely", "sent remotely", "sent remotely"])
        let other = ToasttySendPresentationAdapter.makeItems(from: .init(records: [
            record("queued", text: "later", .pending(.queued(position: 1))),
            SendReconciliationRecord(
                clientRequestID: "steered", text: "OK", projectionRunID: nil,
                deliveryState: .pending(.accepted), deliveryMode: .steer
            ),
        ]))
        XCTAssertEqual(other.map(\.sentCaption), ["from queue", "steered"])
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

// MARK: - Queue, steer, and stop

extension ToasttyComposerPresentationTests {
    private var turnEpoch: RemoteInputEpoch {
        RemoteInputEpoch(bindingID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!, counter: 9)
    }

    private func workingStamp(_ mode: RemoteMessageDeliveryMode = .queue) -> ConversationComposerStamp {
        ConversationComposerStamp(
            connectionGeneration: 4, streamSnapshotOrdinal: 8,
            projectionRunID: RemoteProjectionRunID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
            projectionGeneration: 2, latestSequence: 10, inputEpoch: turnEpoch, deliveryMode: mode
        )
    }

    private func control(canSteer: Bool, canInterrupt: Bool = true, turnRunning: Bool = true) -> RemoteConversationInputControl {
        RemoteConversationInputControl(
            turnEpoch: turnRunning ? turnEpoch : nil, canQueue: true, canSteer: canSteer, canInterrupt: canInterrupt
        )
    }

    func testWorkingTurnOpensTheComposerWithStopAndSteersByDefault() {
        let steerable = ConversationComposerAuthority(
            stamp: workingStamp(), inputAvailability: .unavailable(reason: .known(.working)),
            inputControl: control(canSteer: true)
        )
        let steerablePresentation = presentation(steerable)
        XCTAssertEqual(steerablePresentation.gate, .enabled(.working(canSteer: true)))
        XCTAssertTrue(steerablePresentation.gate.isWorking)
        XCTAssertTrue(steerablePresentation.canInterrupt)
        XCTAssertTrue(steerable.canSteer)
        XCTAssertTrue(steerablePresentation.canSubmit(draft: "queue me"))
        // Steer is the default while the host allows it; Queue is the
        // user's explicit choice.
        XCTAssertEqual(steerablePresentation.gate.sendMode?.deliveryMode(queueSelected: false), .steer)
        XCTAssertEqual(steerablePresentation.gate.sendMode?.deliveryMode(queueSelected: true), .queue)
        // A Queue choice belongs to the running turn; a closed gate names none.
        XCTAssertEqual(steerablePresentation.runningTurnEpoch, turnEpoch)

        let localDraftOnMac = ConversationComposerAuthority(
            stamp: workingStamp(), inputAvailability: .unavailable(reason: .known(.working)),
            inputControl: control(canSteer: false)
        )
        XCTAssertEqual(presentation(localDraftOnMac).gate, .enabled(.working(canSteer: false)))
        XCTAssertFalse(localDraftOnMac.canSteer)
        // When the host closes steer, even mid-draft, Send falls back to Queue.
        XCTAssertEqual(presentation(localDraftOnMac).gate.sendMode?.deliveryMode(queueSelected: false), .queue)
        XCTAssertEqual(ToasttyComposerSendMode.prompt.deliveryMode(queueSelected: true), .prompt)

        // An older host sends no controls: the composer stays locked as before.
        let legacy = ConversationComposerAuthority(
            inputAvailability: .unavailable(reason: .known(.working)), gateFailure: .inputUnavailable
        )
        XCTAssertEqual(presentation(legacy).gate, .disabled(.prompt(.working)))
        XCTAssertNil(presentation(legacy).runningTurnEpoch)
        XCTAssertFalse(presentation(legacy).canInterrupt)
    }

    func testStopStaysAvailableWhileASendIsReservedButNotWhenTheTurnEnded() {
        let reserved = ConversationComposerAuthority(
            stamp: nil, inputAvailability: .unavailable(reason: .known(.working)),
            gateFailure: .sendAlreadyReserved, inputControl: control(canSteer: true)
        )
        XCTAssertTrue(reserved.canInterrupt)
        let ended = ConversationComposerAuthority(
            stamp: nil, inputAvailability: .unavailable(reason: .known(.interrupted)),
            gateFailure: .inputUnavailable, inputControl: control(canSteer: false, canInterrupt: false, turnRunning: false)
        )
        XCTAssertFalse(ended.canInterrupt)
        let offline = ConversationComposerAuthority(
            inputAvailability: .unavailable(reason: .known(.working)),
            gateFailure: .coordinatorNotLive, inputControl: control(canSteer: true)
        )
        XCTAssertFalse(offline.canInterrupt)
    }

    func testReleaseIsOfferedOnlyForAMacDraftOnALiveSendCapableConnection() {
        let draftEpoch = RemoteInputEpoch(bindingID: UUID(), counter: 9)
        let locked = ConversationComposerAuthority(
            inputAvailability: .localDraft(epoch: draftEpoch), gateFailure: .inputUnavailable
        )
        XCTAssertEqual(locked.releasableLocalDraftEpoch, draftEpoch)
        let offered = ToasttyComposerPresentation.make(
            agentDisplayName: "Claude", authority: locked,
            releasableLocalDraftEpoch: draftEpoch, localDraftReleaseRefusal: .macTypedAgain
        )
        XCTAssertEqual(offered.gate, .disabled(.localDraft))
        XCTAssertEqual(offered.releasableLocalDraftEpoch, draftEpoch)
        XCTAssertEqual(offered.localDraftReleaseRefusal, .macTypedAgain)

        // A reconnecting, stale, or read-only composer cannot release.
        let blocked: [ConversationSendGateFailure] = [.coordinatorNotLive, .deviceSendScopeDenied, .staleComposerAuthority]
        for failure in blocked {
            let authority = ConversationComposerAuthority(
                inputAvailability: .localDraft(epoch: draftEpoch), gateFailure: failure
            )
            XCTAssertNil(authority.releasableLocalDraftEpoch, "\(failure)")
        }

        // Once the Mac draft no longer holds the prompt, Release and its
        // refusal disappear even if the caller still passes them.
        let reopened = ToasttyComposerPresentation.make(
            agentDisplayName: "Claude",
            authority: ConversationComposerAuthority(stamp: stamp, inputAvailability: .openPrompt(epoch: stamp.inputEpoch)),
            releasableLocalDraftEpoch: draftEpoch, localDraftReleaseRefusal: .macTypedAgain
        )
        XCTAssertFalse(reopened.canReleaseLocalDraft)
        XCTAssertNil(reopened.localDraftReleaseRefusal)
    }

    func testStampChangesModeOnlyForAWorkingTurn() {
        XCTAssertEqual(workingStamp().withDeliveryMode(.steer).deliveryMode, .steer)
        XCTAssertEqual(workingStamp(.steer).withDeliveryMode(.queue).deliveryMode, .queue)
        XCTAssertEqual(workingStamp().withDeliveryMode(.prompt).deliveryMode, .queue)
        XCTAssertEqual(stamp.withDeliveryMode(.steer).deliveryMode, .prompt)
    }

    func testQueuedMessagesRenderFromTheHostListAndHideTheirOwnPendingRecord() {
        let state = SendReconciliationState(records: [
            record("queued-1", text: "first", .pending(.queued(position: 1))),
            record("steered", text: "now", .pending(.accepted)),
            record("dispatched", text: "typed", .pending(.queued(position: 1))),
        ])
        let control = RemoteConversationInputControl(
            turnEpoch: turnEpoch, canQueue: true, canSteer: true, canInterrupt: true,
            queuedMessages: [
                RemoteQueuedMessage(clientRequestID: "queued-1", text: "first", enqueuedAt: Date()),
                RemoteQueuedMessage(clientRequestID: "other-phone", text: "second", attachmentCount: 2, enqueuedAt: Date()),
            ],
            isQueuePaused: true
        )

        let items = ToasttySendPresentationAdapter.makeItems(from: state, inputControl: control)

        XCTAssertEqual(items.map(\.id), ["steered", "dispatched", "queued-1", "other-phone"])
        XCTAssertEqual(items[0].content, .optimistic(response: .accepted))
        // Left the Mac's queue: it is being typed, so it shows as sending.
        XCTAssertEqual(items[1].content, .optimistic(response: .queued(position: 1)))
        XCTAssertEqual(items[2].content, .queued(.init(position: 1, attachmentCount: 0, isPaused: true, canSteer: true)))
        // Attachments cannot be typed into a running turn, so the row offers no Steer.
        XCTAssertEqual(items[3].content, .queued(.init(position: 2, attachmentCount: 2, isPaused: true, canSteer: false)))
        XCTAssertEqual(items[3].text, "second")
    }

    /// The coordinator's chat lists both of its queues in the order the
    /// messages go once nothing is held: the conversation's, then the
    /// coordinator's held messages, then its waiting ones. The one Resume
    /// sits on the first held row, here the coordinator's, and counts every
    /// held message. A coordinator row offers Remove, never Edit or Steer.
    /// A queued message's own pending record does not show twice.
    func testTheCoordinatorsTwoQueuesListAsOneWithOneResume() {
        let state = SendReconciliationState(records: [
            record("chat-1", text: "first", .pending(.queued(position: 1))),
        ])
        let control = RemoteConversationInputControl(
            turnEpoch: turnEpoch, canQueue: true, canSteer: true, canInterrupt: true,
            queuedMessages: [RemoteQueuedMessage(clientRequestID: "chat-1", text: "first", enqueuedAt: Date())]
        )
        let queue = RemoteCoordinatorQueue(
            revision: "r", conversationID: RemoteConversationID(rawValue: UUID()), heldSetToken: "stop",
            entries: [
                RemoteCoordinatorQueueEntry(id: "held-1", text: "Held one", fileNames: ["a.txt", "b.png"], isHeld: true),
                RemoteCoordinatorQueueEntry(id: "held-2", text: "Yes.", quote: "Merge it?", quoteTime: "9:41", isHeld: true),
                RemoteCoordinatorQueueEntry(id: "waiting-1", text: "Later"),
            ]
        )

        let items = ToasttySendPresentationAdapter.makeItems(
            from: state, inputControl: control, readsCoordinatorMessages: true,
            coordinatorQueue: .init(queue: queue, mayChange: true)
        )

        XCTAssertEqual(items.map(\.id), ["chat-1", "held-1", "held-2", "waiting-1"])
        let queued = items.compactMap { item -> ToasttyQueuedSendPresentation? in
            guard case .queued(let queued) = item.content else { return nil }
            return queued
        }
        XCTAssertEqual(queued.map(\.position), [1, 2, 3, 4])
        XCTAssertEqual(queued.map(\.isPaused), [false, true, true, false])
        XCTAssertEqual(queued.map(\.resumeTitle), [nil, "Resume all 2", nil, nil])
        XCTAssertEqual(queued.map(\.canEdit), [true, false, false, false])
        XCTAssertEqual(queued.map(\.canSteer), [true, false, false, false])
        XCTAssertEqual(queued.map(\.canChange), [true, true, true, true])
        XCTAssertEqual(queued[1].attachmentCount, 2)
        XCTAssertEqual(items[2].quote, ToasttyMessageQuote(text: "Merge it?", timeText: "9:41"))

        // A Stop reaches the session list before the phone reads its token:
        // no row offers Resume until then.
        var beforeTheRead = queue
        beforeTheRead.heldSetToken = nil
        var heldControl = control
        heldControl.isQueuePaused = true
        let early = ToasttySendPresentationAdapter.makeItems(
            from: state, inputControl: heldControl, readsCoordinatorMessages: true,
            coordinatorQueue: .init(queue: beforeTheRead, mayChange: true)
        )
        XCTAssertTrue(early.allSatisfy { item in
            guard case .queued(let queued) = item.content else { return true }
            return queued.resumeTitle == nil
        })

        // Without the coordinator's queue, each paused row keeps Send next.
        var paused = control
        paused.isQueuePaused = true
        let single = ToasttySendPresentationAdapter.makeItems(from: state, inputControl: paused)
        guard case .queued(let alone) = single.first?.content else { return XCTFail("The message waits") }
        XCTAssertEqual(alone.resumeTitle, "Send next")
        XCTAssertTrue(alone.canEdit)
    }

    /// A row of the coordinator's own queue warns when Toastty on the Mac
    /// quit while it typed the message, and says when the Mac could not
    /// remove it. An entry from a Mac that sets no mark has neither.
    func testACoordinatorRowWarnsAboutInterruptedTypingAndAFailedRemove() {
        let queue = RemoteCoordinatorQueue(
            revision: "r", conversationID: RemoteConversationID(rawValue: UUID()), heldSetToken: "relaunch",
            entries: [
                RemoteCoordinatorQueueEntry(id: "interrupted", text: "Create the task", isHeld: true, typingWasInterrupted: true),
                RemoteCoordinatorQueueEntry(id: "held", text: "Held", isHeld: true),
                RemoteCoordinatorQueueEntry(id: "kept", text: "Later"),
            ]
        )

        let items = ToasttySendPresentationAdapter.makeItems(
            from: SendReconciliationState(), readsCoordinatorMessages: true,
            coordinatorQueue: .init(queue: queue, mayChange: true, removeFailures: ["kept", "gone"])
        )

        let queued = items.compactMap { item -> ToasttyQueuedSendPresentation? in
            guard case .queued(let queued) = item.content else { return nil }
            return queued
        }
        XCTAssertEqual(items.map(\.id), ["interrupted", "held", "kept"])
        XCTAssertEqual(queued.map(\.warning), [ToasttySendPresentationAdapter.typingInterruptedWarning, nil, nil])
        XCTAssertEqual(queued.map(\.actionFailure), [nil, nil, ToasttySendPresentationAdapter.removeFailedNotice])
        XCTAssertTrue(ToasttySendPresentationAdapter.typingInterruptedWarning.contains("If the message is there, choose Remove"))
        XCTAssertTrue(ToasttySendPresentationAdapter.typingInterruptedWarning.contains("If it is not, choose Resume to send it"))
        // The interrupted row keeps the one Resume and its Remove.
        XCTAssertEqual(queued.map(\.resumeTitle), ["Resume all 2", nil, nil])
        XCTAssertTrue(queued.allSatisfy(\.canChange))

        // A phone that cannot change the queue has neither: the warning
        // points to the Mac's chat.
        let readOnly = ToasttySendPresentationAdapter.makeItems(
            from: SendReconciliationState(), readsCoordinatorMessages: true,
            coordinatorQueue: .init(queue: queue, mayChange: false)
        ).compactMap { item -> ToasttyQueuedSendPresentation? in
            guard case .queued(let queued) = item.content else { return nil }
            return queued
        }
        XCTAssertEqual(readOnly.first?.warning, ToasttySendPresentationAdapter.typingInterruptedWarningForTheMac)
        XCTAssertTrue(ToasttySendPresentationAdapter.typingInterruptedWarningForTheMac.contains(
            "in the Mac's chat, choose Remove if the message is there, or Send next if it is not"
        ))
        XCTAssertTrue(readOnly.allSatisfy { $0.canChange == false && $0.resumeTitle == nil })
    }

    /// A digest or a message from `coordinator send` that waits in the
    /// coordinator's queue shows as its row will: the digest's line and the
    /// sender's card, not Toastty's raw text. A digest that the Mac
    /// shortened lost lines, so its line gives no count. The user's own
    /// message stays a bubble.
    func testAWaitingDigestOrSendersMessageShowsAsItsRowWill() throws {
        let digest = [
            "\(CoordinatorMessageHeader.digestPrefix): this message is from Toastty, not from the user.",
            "- [Fix the unread dot](toastty://task/1): needsYou (review) at 2026-11-19T22:01:04Z",
            "- [Ship the release](toastty://task/2): running at 2026-11-19T22:01:09Z",
        ].joined(separator: "\n")
        let queue = RemoteCoordinatorQueue(
            revision: "r", conversationID: RemoteConversationID(rawValue: UUID()), heldSetToken: nil,
            entries: [
                RemoteCoordinatorQueueEntry(id: "digest", text: digest),
                RemoteCoordinatorQueueEntry(id: "shortened", text: digest, isTextShortened: true),
                RemoteCoordinatorQueueEntry(id: "sender", text: "Checks passed.", sender: "task Fix the unread dot"),
                RemoteCoordinatorQueueEntry(id: "own", text: "Later"),
            ]
        )

        let items = ToasttySendPresentationAdapter.makeItems(
            from: SendReconciliationState(), readsCoordinatorMessages: true,
            coordinatorQueue: .init(queue: queue, mayChange: true)
        )

        XCTAssertEqual(items.map(\.id), ["digest", "shortened", "sender", "own"])
        let line = try XCTUnwrap(items[0].hostMessage)
        XCTAssertTrue(line.isLine)
        XCTAssertEqual(line.summary, "Toastty · 2 updates · waiting")
        XCTAssertEqual(line.title, "Toastty · 2 updates")
        XCTAssertEqual(items[1].hostMessage?.summary, "Toastty · waiting")
        let card = try XCTUnwrap(items[2].hostMessage)
        XCTAssertEqual(card.style, .sender(name: "task Fix the unread dot", timeText: "waiting"))
        XCTAssertEqual(card.text, "Checks passed.")
        XCTAssertNil(items[3].hostMessage)
        // Remove still acts on the queue's entry.
        XCTAssertTrue(items.allSatisfy { item in
            guard case .queued(let queued) = item.content else { return false }
            return queued.canChange && queued.canEdit == false
        })
    }

    func testQueueRejectionReceiptsExplainTheQueue() {
        for reason in [RemoteMessageRejectionReason.queueFull, .notWorking, .turnMismatch, .steerUnavailable] {
            let receipt = ToasttySendReceiptPresentation(kind: .rejected(reason))
            XCTAssertFalse(receipt.title.isEmpty)
            XCTAssertFalse(receipt.detail.isEmpty)
        }
        XCTAssertTrue(ToasttySendReceiptPresentation(kind: .rejected(.queueFull)).title.contains("queue"))
        XCTAssertTrue(ToasttySendReceiptPresentation(kind: .rejected(.steerUnavailable)).title.contains("typing on the Mac"))
    }

    func testRestoringAQueuedMessageKeepsAnExistingDraftAhead() {
        var state = ToasttyComposerDraftState()
        let conversationID = UUID()
        state.restoreDraft("queued text", for: conversationID)
        XCTAssertEqual(state.replacements[conversationID]?.text, "queued text")
        state.updateDraft("typed", for: conversationID)
        state.restoreDraft("queued text", for: conversationID)
        XCTAssertEqual(state.replacements[conversationID]?.text, "typed\n\nqueued text")
    }
}
