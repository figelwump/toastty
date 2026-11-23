import ConversationUI
import Foundation
import Observation
import RemoteProtocol
import ToasttyMobileDomain

enum ToasttyComposerDisabledReason: Equatable, Sendable {
    enum Connection: Equatable, Sendable {
        case reconnecting
        case catchingUp
    }

    enum Prompt: Equatable, Sendable {
        case starting
        case working
        case offline
        case closed
        case unsupported
        case sending
    }

    case deviceScope
    case sessionWrites
    case localDraft
    case pendingInteraction
    case connection(Connection)
    case prompt(Prompt)

    var message: String {
        switch self {
        case .deviceScope:
            "This iPhone has read-only access — enable Send for this device on the Mac"
        case .sessionWrites:
            "Remote input is off for this session — enable it on the Mac"
        case .localDraft:
            "Paused — a draft is in progress on the Mac"
        case .pendingInteraction:
            "Respond to the pending interaction on the Mac"
        case .connection(.reconnecting):
            "Reconnecting to your Mac — your draft is saved"
        case .connection(.catchingUp):
            "Catching up with your Mac — your draft is saved"
        case .prompt(.starting):
            "The session is starting — input opens when the agent is ready"
        case .prompt(.working):
            "The agent is working — input opens at the next prompt"
        case .prompt(.offline):
            "Session offline — resume from the Mac"
        case .prompt(.closed):
            "Input is not available at this prompt"
        case .prompt(.unsupported):
            "This conversation is read-only on this version of Toastty"
        case .prompt(.sending):
            "A message is already being sent at this prompt"
        }
    }

    var systemImage: String {
        switch self {
        case .deviceScope, .sessionWrites, .prompt(.unsupported):
            "lock.fill"
        case .localDraft:
            "pencil.line"
        case .pendingInteraction:
            "rectangle.and.hand.point.up.left"
        case .connection:
            "wifi.exclamationmark"
        case .prompt(.starting):
            "hourglass"
        case .prompt(.working):
            "ellipsis"
        case .prompt(.offline):
            "desktopcomputer.trianglebadge.exclamationmark"
        case .prompt(.closed):
            "lock"
        case .prompt(.sending):
            "paperplane"
        }
    }
}

/// Why a Release from this phone left the Mac draft lock in place.
enum ToasttyLocalDraftReleaseRefusal: Equatable, Sendable {
    /// Someone typed on the Mac after this phone showed the lock.
    case macTypedAgain
    /// The Mac could not be reached or did not accept the request.
    case failed

    var message: String {
        switch self {
        case .macTypedAgain:
            "Mac was typed on again — still paused"
        case .failed:
            "Could not release the draft — try again"
        }
    }
}

/// What Send does while input is allowed.
enum ToasttyComposerSendMode: Equatable, Sendable {
    /// The prompt is open: Send types the message now.
    case prompt
    /// The agent is working: Send steers into the running turn while the host
    /// allows it, and otherwise holds the message on the Mac for the next
    /// prompt.
    case working(canSteer: Bool)

    /// The mode Send uses. While the agent works, Steer is the default and
    /// Queue applies only when the user picked it or the host does not allow
    /// steer. When the host closes steer mid-draft, the chip, the Send label,
    /// and the send itself all follow this value, so they fall back together.
    func deliveryMode(queueSelected: Bool) -> RemoteMessageDeliveryMode {
        switch self {
        case .prompt:
            .prompt
        case .working(let canSteer):
            canSteer && !queueSelected ? .steer : .queue
        }
    }
}

enum ToasttyComposerGate: Equatable, Sendable {
    case enabled(ToasttyComposerSendMode)
    case disabled(ToasttyComposerDisabledReason)

    var allowsInput: Bool {
        if case .enabled = self { return true }
        return false
    }

    var sendMode: ToasttyComposerSendMode? {
        if case .enabled(let mode) = self { return mode }
        return nil
    }

    var isWorking: Bool {
        if case .enabled(.working) = self { return true }
        return false
    }
}

struct ToasttyComposerPresentation: Equatable, Sendable {
    let agentDisplayName: String
    let gate: ToasttyComposerGate
    let inlineFeedback: String?
    /// The running turn can be stopped from this device.
    let canInterrupt: Bool
    /// The shared presentation grace hides brief connection checks. The
    /// domain gate still blocks sends until the retained stream is verified.
    let suppressesConnectionNotice: Bool
    /// The Mac draft epoch a Release would name, while a Mac draft holds the
    /// prompt closed and this device may release it.
    let releasableLocalDraftEpoch: RemoteInputEpoch?
    let localDraftReleaseRefusal: ToasttyLocalDraftReleaseRefusal?
    /// The host's epoch for the running turn while Send queues or steers into
    /// it. A Queue choice belongs to this turn: a new turn has a new epoch.
    let runningTurnEpoch: RemoteInputEpoch?

    var canReleaseLocalDraft: Bool { releasableLocalDraftEpoch != nil }

    init(
        agentDisplayName: String,
        gate: ToasttyComposerGate,
        inlineFeedback: String? = nil,
        canInterrupt: Bool = false,
        suppressesConnectionNotice: Bool = false,
        releasableLocalDraftEpoch: RemoteInputEpoch? = nil,
        localDraftReleaseRefusal: ToasttyLocalDraftReleaseRefusal? = nil,
        runningTurnEpoch: RemoteInputEpoch? = nil
    ) {
        self.agentDisplayName = agentDisplayName
        self.gate = gate
        self.inlineFeedback = inlineFeedback
        self.canInterrupt = canInterrupt
        self.suppressesConnectionNotice = suppressesConnectionNotice
            && gate == .disabled(.connection(.reconnecting))
        let releasable = gate == .disabled(.localDraft) ? releasableLocalDraftEpoch : nil
        self.releasableLocalDraftEpoch = releasable
        self.localDraftReleaseRefusal = releasable == nil ? nil : localDraftReleaseRefusal
        self.runningTurnEpoch = gate.isWorking ? runningTurnEpoch : nil
    }

    static func make(
        agentDisplayName: String,
        authority: ConversationComposerAuthority,
        suppressesConnectionNotice: Bool = false,
        releasableLocalDraftEpoch: RemoteInputEpoch? = nil,
        localDraftReleaseRefusal: ToasttyLocalDraftReleaseRefusal? = nil
    ) -> ToasttyComposerPresentation {
        return ToasttyComposerPresentation(
            agentDisplayName: agentDisplayName,
            gate: gate(for: authority),
            inlineFeedback: feedback(for: authority.gateFailure),
            canInterrupt: authority.canInterrupt,
            suppressesConnectionNotice: suppressesConnectionNotice,
            releasableLocalDraftEpoch: releasableLocalDraftEpoch,
            localDraftReleaseRefusal: localDraftReleaseRefusal,
            runningTurnEpoch: authority.inputControl?.turnEpoch
        )
    }

    static func makeLockedFallback(
        agentDisplayName: String,
        inputAvailability: MobileInputAvailability
    ) -> ToasttyComposerPresentation {
        let reason: ToasttyComposerDisabledReason = switch inputAvailability {
        case .localDraft:
            .localDraft
        case .pendingInteraction:
            .pendingInteraction
        case .unavailable(let reason) where reason == "starting":
            .prompt(.starting)
        case .unavailable(let reason) where reason == "working":
            .prompt(.working)
        case .unavailable(let reason) where reason == "offline" || reason == "ended":
            .prompt(.offline)
        case .openPrompt, .unavailable:
            .connection(.catchingUp)
        }
        return ToasttyComposerPresentation(
            agentDisplayName: agentDisplayName,
            gate: .disabled(reason)
        )
    }

    var placeholder: String {
        if suppressesConnectionNotice { return "Message \(agentDisplayName)…" }
        return switch gate {
        case .enabled:
            "Message \(agentDisplayName)…"
        case .disabled(.deviceScope):
            "Read-only on this iPhone"
        case .disabled(.sessionWrites):
            "Remote input is off"
        case .disabled(.localDraft):
            "Draft in progress on Mac"
        case .disabled(.pendingInteraction):
            "Pending request — input paused"
        case .disabled(.connection(.reconnecting)):
            "Reconnecting to Mac…"
        case .disabled(.connection(.catchingUp)):
            "Syncing with Mac…"
        case .disabled(.prompt(.starting)):
            "Session starting…"
        case .disabled(.prompt(.working)):
            "Agent working…"
        case .disabled(.prompt(.offline)):
            "Session offline"
        case .disabled(.prompt(.closed)):
            "Input unavailable"
        case .disabled(.prompt(.unsupported)):
            "Read-only in this app version"
        case .disabled(.prompt(.sending)):
            "Sending message…"
        }
    }

    /// The mode a send uses while the agent works: Steer unless the user
    /// picked Queue for the running turn (`queuedTurnEpoch`, from the
    /// draft), or the host does not allow steer. `.queue` when the agent
    /// does not work.
    func workingDeliveryMode(queuedTurnEpoch: RemoteInputEpoch?) -> RemoteMessageDeliveryMode {
        guard let sendMode = gate.sendMode, sendMode != .prompt else { return .queue }
        return sendMode.deliveryMode(queueSelected: queuedTurnEpoch != nil && queuedTurnEpoch == runningTurnEpoch)
    }

    func canSubmit(draft: String, attachments: [RemoteMessageAttachment] = []) -> Bool {
        gate.allowsInput
            && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || attachments.isEmpty == false)
    }

    private static func gate(for authority: ConversationComposerAuthority) -> ToasttyComposerGate {
        if let failure = authority.gateFailure {
            switch failure {
            case .deviceSendScopeDenied:
                return .disabled(.deviceScope)
            case .coordinatorNotLive:
                return .disabled(.connection(.reconnecting))
            case .staleComposerAuthority, .conversationNotLive, .transcriptNotCaughtUp:
                return .disabled(.connection(.catchingUp))
            case .inputUnavailable:
                let availabilityGate = gate(for: authority.inputAvailability)
                return availabilityGate.allowsInput
                    ? .disabled(.prompt(.closed))
                    : availabilityGate
            case .sendAlreadyReserved, .tooManyUnresolvedSends:
                return .disabled(.prompt(.sending))
            case .conversationNotOpen, .conversationMissing:
                return .disabled(.prompt(.offline))
            case .emptyText, .messageTooLarge, .requestEncodingFailed, .cancelled, .attachmentsUnsupported, .invalidAttachments:
                return gate(for: authority.inputAvailability)
            }
        }
        guard authority.canSend, let stamp = authority.stamp else {
            return .disabled(.connection(.catchingUp))
        }
        switch stamp.deliveryMode {
        case .prompt:
            return gate(for: authority.inputAvailability)
        case .queue, .steer:
            return .enabled(.working(canSteer: authority.canSteer))
        }
    }

    private static func feedback(
        for failure: ConversationSendGateFailure?
    ) -> String? {
        switch failure {
        case .attachmentsUnsupported:
            "Update Toastty on your Mac to send attachments. Your draft is still here."
        case .invalidAttachments:
            "An attachment could not be sent. Check its type and size. Your draft is still here."
        case .emptyText:
            "Enter a message before sending. Your draft was not changed."
        case .messageTooLarge:
            "This message is too large to send. Shorten it and try again. Your draft is still here."
        case .requestEncodingFailed:
            "Toastty could not prepare this message. Your draft is still here."
        case .cancelled:
            "Send was cancelled before dispatch. Your draft is still here."
        case .coordinatorNotLive, .deviceSendScopeDenied, .conversationNotOpen,
             .conversationMissing, .staleComposerAuthority, .conversationNotLive,
             .transcriptNotCaughtUp, .inputUnavailable, .sendAlreadyReserved,
             .tooManyUnresolvedSends, nil:
            nil
        }
    }

    private static func gate(for availability: CompatibleInputAvailability?) -> ToasttyComposerGate {
        switch availability {
        case .openPrompt:
            .enabled(.prompt)
        case .localDraft:
            .disabled(.localDraft)
        case .pendingInteraction:
            .disabled(.pendingInteraction)
        case .unavailable(let reason):
            switch reason {
            case .known(.sessionWritesDisabled):
                .disabled(.sessionWrites)
            case .known(.starting):
                .disabled(.prompt(.starting))
            case .known(.working):
                .disabled(.prompt(.working))
            case .known(.offline), .known(.ended):
                .disabled(.prompt(.offline))
            case .known(.interrupted), .known(.error), .known(.surfaceUnavailable),
                 .known(.unknownProviderState):
                .disabled(.prompt(.closed))
            case .unsupported:
                .disabled(.prompt(.unsupported))
            }
        case .unsupported:
            .disabled(.prompt(.unsupported))
        case nil:
            .disabled(.connection(.catchingUp))
        }
    }
}

struct ToasttyComposerSubmission: Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    /// The draft as the user wrote it.
    let text: String
    var attachments: [RemoteMessageAttachment] = []
    /// The coordinator's message that this one answers.
    var reply: CoordinatorReplyTarget?

    /// The text to send. A reply is written in the Mac's format without
    /// its files: the Mac adds the paths of the files it stores, as for any
    /// message, so the coordinator gets the Mac's own reply.
    var sentText: String {
        guard let reply else { return text }
        return reply.message(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A native edit is published as text; only an explicit request may replace the field.
struct ToasttyComposerReplacement: Equatable, Sendable {
    let revision: UInt64
    // External replacements do not advance the native edit revision, so a
    // coalesced clear and restore can apply unless the user edited in between.
    let expectedEditRevision: UInt64
    let text: String
}

struct ToasttyComposerReplacementResult {
    let revision: UInt64
    let nativeText: String
    let nativeEditRevision: UInt64
    let wasApplied: Bool
}

struct ToasttyComposerDraftState: Equatable, Sendable {
    static let maximumAttachmentDraftBytes = 32 * 1024 * 1024
    private(set) var generation = UUID()
    private(set) var attachmentRecoveries: [String: ToasttyComposerSubmission] = [:]
    private(set) var attachmentRecoveryMessages: [UUID: String] = [:]
    private(set) var attachmentDrafts: [UUID: [RemoteMessageAttachment]] = [:]
    private(set) var drafts: [UUID: String] = [:]
    /// Queue is a choice for one draft and one running turn.
    var queuedTurnEpochs: [UUID: RemoteInputEpoch] = [:]
    private(set) var submissions: [UUID: ToasttyComposerSubmission] = [:]
    private(set) var editRevisions: [UUID: UInt64] = [:]
    private(set) var replacements: [UUID: ToasttyComposerReplacement] = [:]
    /// The coordinator's message that each draft answers, from Reply.
    private(set) var replies: [UUID: CoordinatorReplyTarget] = [:]
    /// Why the last Reply or Edit could not make or keep a reply.
    private(set) var replyNotices: [UUID: String] = [:]
    private var replacementRevision: UInt64 = 0
    private struct RestoredRecovery: Equatable, Sendable {
        let requestID: String
        let submission: ToasttyComposerSubmission
        var wasDismissed = false
        /// The restore also put the submission's reply back.
        var restoredReply = false
    }
    private var restoredRecoveries: [UUID: RestoredRecovery] = [:]

    func draft(for conversationID: UUID) -> String {
        drafts[conversationID, default: ""]
    }

    func attachments(for conversationID: UUID) -> [RemoteMessageAttachment] {
        attachmentDrafts[conversationID, default: []]
    }

    mutating func addAttachments(_ additions: [RemoteMessageAttachment], for conversationID: UUID) -> String? {
        guard isSubmitting(conversationID) == false else { return "Wait for this message to finish sending." }
        let updated = attachments(for: conversationID) + additions
        if let error = RemoteAttachmentPolicy.validationError(for: updated) { return error }
        let retained = attachmentDrafts.values.flatMap { $0 }
            + attachmentRecoveries.values.flatMap(\.attachments)
        var sizesByID: [UUID: Int] = [:]
        for attachment in retained + additions { sizesByID[attachment.id] = attachment.data.count }
        let total = sizesByID.values.reduce(0, +)
        guard total <= Self.maximumAttachmentDraftBytes else {
            return "Attachment drafts are full. Remove or send attachments in another conversation first."
        }
        attachmentDrafts[conversationID] = updated
        return nil
    }

    mutating func removeAttachment(_ attachmentID: UUID, for conversationID: UUID) {
        guard isSubmitting(conversationID) == false else { return }
        removeAttachments(for: conversationID) { $0.id == attachmentID }
    }

    private mutating func removeAttachments(for conversationID: UUID, where matches: (RemoteMessageAttachment) -> Bool) {
        attachmentDrafts[conversationID]?.removeAll(where: matches)
        if attachmentDrafts[conversationID]?.isEmpty == true {
            attachmentDrafts.removeValue(forKey: conversationID)
            if drafts[conversationID] == nil { queuedTurnEpochs.removeValue(forKey: conversationID) }
        }
    }

    func isSubmitting(_ conversationID: UUID) -> Bool {
        submissions[conversationID] != nil
    }

    mutating func updateDraft(_ text: String, for conversationID: UUID, editRevision: UInt64? = nil) {
        if draft(for: conversationID) != text { replyNotices.removeValue(forKey: conversationID) }
        if let editRevision {
            editRevisions[conversationID] = editRevision
        } else if draft(for: conversationID) != text {
            editRevisions[conversationID, default: 0] += 1
        }
        storeDraft(text, for: conversationID)
    }

    private mutating func storeDraft(_ text: String, for conversationID: UUID) {
        if text.isEmpty {
            if drafts.removeValue(forKey: conversationID) != nil, attachments(for: conversationID).isEmpty {
                queuedTurnEpochs.removeValue(forKey: conversationID)
            }
        } else {
            drafts[conversationID] = text
        }
    }

    /// Puts a queued message back into the composer for editing. An existing
    /// draft is kept ahead of it rather than overwritten.
    mutating func restoreDraft(_ text: String, for conversationID: UUID) {
        guard isSubmitting(conversationID) == false else { return }
        let current = draft(for: conversationID)
        let combined = current.isEmpty ? text : current + "\n\n" + text
        replaceDraft(combined, for: conversationID)
    }

    // MARK: - Reply, in the coordinator's chat

    static let otherHeaderReplyRefusal =
        "Your message starts with Toastty's line for another sender, so it cannot be a reply. Send or clear it first."
    static let otherReplyEditRefusal =
        "This message is a reply, and the message you are writing replies to another message. Remove that reply first."
    static let otherHeaderEditRefusal =
        "This message starts with Toastty's line for another sender, and the message you are writing is a reply. "
            + "Remove the reply first."

    /// Reply on one of the coordinator's messages: the draft answers it. A
    /// second Reply replaces the first. A draft that starts with Toastty's
    /// line for another sender cannot become a reply, as on the Mac.
    @discardableResult
    mutating func reply(to target: CoordinatorReplyTarget, for conversationID: UUID) -> Bool {
        guard CoordinatorMessageHeader.hasOtherHeader(draft(for: conversationID)) == false else {
            replyNotices[conversationID] = Self.otherHeaderReplyRefusal
            return false
        }
        replies[conversationID] = target
        replyNotices.removeValue(forKey: conversationID)
        return true
    }

    mutating func cancelReply(for conversationID: UUID) {
        replies.removeValue(forKey: conversationID)
        replyNotices.removeValue(forKey: conversationID)
    }

    /// Why Edit cannot take this waiting message back into the draft, which
    /// answers at most one message. `text` is the message as sent.
    func queuedReplyEditRefusal(_ text: String, for conversationID: UUID) -> String? {
        let current = replies[conversationID]
        if let parts = CoordinatorMessageHeader.replyParts(of: text) {
            if let current, CoordinatorReplyTarget(text: parts.quote, time: parts.time) != current {
                return Self.otherReplyEditRefusal
            }
            // The draft stays first, so it would start the reply.
            return CoordinatorMessageHeader.hasOtherHeader(draft(for: conversationID))
                ? Self.otherHeaderReplyRefusal : nil
        }
        guard current != nil else { return nil }
        return CoordinatorMessageHeader.hasOtherHeader(text) ? Self.otherHeaderEditRefusal : nil
    }

    /// Edit on a waiting message in the coordinator's chat: a reply comes
    /// back as its text, with the message it answers above the field. The
    /// draft answers one message at most, and a draft that starts with
    /// another sender's line cannot become a reply: Edit checks both first
    /// with `queuedReplyEditRefusal`, and a Steer now that failed puts the
    /// whole text back, quote included.
    mutating func restoreQueuedReply(_ text: String, for conversationID: UUID) {
        guard isSubmitting(conversationID) == false else { return }
        guard let parts = CoordinatorMessageHeader.replyParts(of: text) else {
            restoreDraft(text, for: conversationID)
            return
        }
        let target = CoordinatorReplyTarget(text: parts.quote, time: parts.time)
        guard replies[conversationID] == nil || replies[conversationID] == target,
              CoordinatorMessageHeader.hasOtherHeader(draft(for: conversationID)) == false else {
            restoreDraft(text, for: conversationID)
            return
        }
        replies[conversationID] = target
        replyNotices.removeValue(forKey: conversationID)
        restoreDraft(parts.body, for: conversationID)
    }

    mutating func showReplyNotice(_ notice: String, for conversationID: UUID) {
        replyNotices[conversationID] = notice
    }

    private mutating func replaceDraft(_ text: String, for conversationID: UUID) {
        replacementRevision += 1
        replacements[conversationID] = ToasttyComposerReplacement(
            revision: replacementRevision, expectedEditRevision: editRevisions[conversationID, default: 0], text: text
        )
        restoredRecoveries.removeValue(forKey: conversationID)
        storeDraft(text, for: conversationID)
    }

    /// A native edit can arrive between issuing a replacement and rendering it.
    /// Keep that edit, and defer any attachment recovery associated with the request.
    mutating func completeReplacement(_ result: ToasttyComposerReplacementResult, for conversationID: UUID) {
        guard replacements[conversationID]?.revision == result.revision else { return }
        replacements.removeValue(forKey: conversationID)
        updateDraft(result.nativeText, for: conversationID, editRevision: result.nativeEditRevision)
        guard !result.wasApplied else {
            restoredRecoveries.removeValue(forKey: conversationID)
            return
        }
        if let recovery = restoredRecoveries.removeValue(forKey: conversationID) {
            // A subsequent send already owns these attachments. Do not create
            // a second recovery for the same files when this callback arrives.
            guard !isSubmitting(conversationID) else { return }
            if recovery.restoredReply, replies[conversationID] == recovery.submission.reply {
                replies.removeValue(forKey: conversationID)
            }
            let restoredIDs = Set(recovery.submission.attachments.map(\.id))
            removeAttachments(for: conversationID) { restoredIDs.contains($0.id) }
            guard !recovery.wasDismissed else { return }
            attachmentRecoveries[recovery.requestID] = recovery.submission
            attachmentRecoveryMessages[conversationID] = "A rejected attachment draft is saved. Clear this draft to restore it, or dismiss the rejected send to discard its attachments."
        }
    }

    mutating func beginSubmission(
        for conversationID: UUID,
        submissionID: UUID = UUID()
    ) -> ToasttyComposerSubmission? {
        guard submissions[conversationID] == nil else { return nil }
        let text = draft(for: conversationID)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || attachments(for: conversationID).isEmpty == false else {
            return nil
        }
        let submission = ToasttyComposerSubmission(
            id: submissionID,
            conversationID: conversationID,
            text: text,
            attachments: attachments(for: conversationID),
            reply: replies[conversationID]
        )
        submissions[conversationID] = submission
        return submission
    }

    mutating func finishSubmission(
        _ submission: ToasttyComposerSubmission,
        outcome: ConversationSendOutcome
    ) {
        guard submissions[submission.conversationID]?.id == submission.id else { return }
        submissions.removeValue(forKey: submission.conversationID)
        guard case .enqueued(let clientRequestID) = outcome else { return }
        if !submission.attachments.isEmpty {
            attachmentRecoveries[clientRequestID] = submission
        }
        attachmentRecoveryMessages.removeValue(forKey: submission.conversationID)
        if draft(for: submission.conversationID) == submission.text {
            replaceDraft("", for: submission.conversationID)
        }
        // A Reply on another message during the send stays for the next.
        if let reply = submission.reply, replies[submission.conversationID] == reply {
            replies.removeValue(forKey: submission.conversationID)
        }
        let submittedIDs = Set(submission.attachments.map(\.id))
        removeAttachments(for: submission.conversationID) { submittedIDs.contains($0.id) }
    }

    mutating func reconcileAttachments(_ state: SendReconciliationState, for conversationID: UUID) {
        for record in state.records {
            guard let submission = attachmentRecoveries[record.clientRequestID],
                  submission.conversationID == conversationID else { continue }
            switch record.deliveryState {
            case .pending(.awaitingResponse): continue
            case .rejected:
                let currentText = draft(for: conversationID)
                // The text answers the message it was written for, or none: it
                // waits while the draft answers another message.
                let currentReply = replies[conversationID]
                if !isSubmitting(conversationID), attachments(for: conversationID).isEmpty,
                   currentText.isEmpty || currentText == submission.text,
                   currentReply == nil || currentReply == submission.reply {
                    replaceDraft(submission.text, for: conversationID)
                    // A rejected reply comes back as a reply.
                    let restoresReply = submission.reply != nil && currentReply == nil
                    if restoresReply { replies[conversationID] = submission.reply }
                    restoredRecoveries[conversationID] = RestoredRecovery(
                        requestID: record.clientRequestID, submission: submission, restoredReply: restoresReply
                    )
                    attachmentDrafts[conversationID] = submission.attachments
                    attachmentRecoveries.removeValue(forKey: record.clientRequestID)
                    attachmentRecoveryMessages[conversationID] = "The Mac rejected the send. Your attachments are back in this draft."
                } else {
                    attachmentRecoveryMessages[conversationID] = isSubmitting(conversationID)
                        ? "A rejected attachment draft is saved until this send finishes. Dismiss the rejected send to discard its attachments."
                        : "A rejected attachment draft is saved. Clear this draft to restore it, or dismiss the rejected send to discard its attachments."
                }
            case .pending(.accepted), .pending(.duplicate), .pending(.queued), .confirmed, .uncertain,
                 .operationFailed, .deliveryUnconfirmed:
                attachmentRecoveries.removeValue(forKey: record.clientRequestID)
            }
        }
    }

    /// Dismissing a rejected receipt also releases its deferred recovery.
    /// Attachments already restored to the editable draft remain there.
    mutating func discardAttachmentRecovery(clientRequestID: String, for conversationID: UUID) {
        if restoredRecoveries[conversationID]?.requestID == clientRequestID {
            restoredRecoveries[conversationID]?.wasDismissed = true
        }
        if attachmentRecoveries[clientRequestID]?.conversationID == conversationID {
            attachmentRecoveries.removeValue(forKey: clientRequestID)
        }
        if !attachmentRecoveries.values.contains(where: { $0.conversationID == conversationID }) {
            attachmentRecoveryMessages.removeValue(forKey: conversationID)
        }
    }

    mutating func retainConversations(_ conversationIDs: Set<UUID>) {
        attachmentRecoveries = attachmentRecoveries.filter { conversationIDs.contains($0.value.conversationID) }
        attachmentRecoveryMessages = attachmentRecoveryMessages.filter { conversationIDs.contains($0.key) }
        attachmentDrafts = attachmentDrafts.filter { conversationIDs.contains($0.key) }
        drafts = drafts.filter { conversationIDs.contains($0.key) }
        queuedTurnEpochs = queuedTurnEpochs.filter { conversationIDs.contains($0.key) }
        submissions = submissions.filter { conversationIDs.contains($0.key) }
        editRevisions = editRevisions.filter { conversationIDs.contains($0.key) }
        replacements = replacements.filter { conversationIDs.contains($0.key) }
        restoredRecoveries = restoredRecoveries.filter { conversationIDs.contains($0.key) }
        replies = replies.filter { conversationIDs.contains($0.key) }
        replyNotices = replyNotices.filter { conversationIDs.contains($0.key) }
    }

    mutating func reset() {
        generation = UUID()
        attachmentRecoveries.removeAll(keepingCapacity: false)
        attachmentRecoveryMessages.removeAll(keepingCapacity: false)
        attachmentDrafts.removeAll(keepingCapacity: false)
        drafts.removeAll(keepingCapacity: false)
        queuedTurnEpochs.removeAll(keepingCapacity: false)
        submissions.removeAll(keepingCapacity: false)
        editRevisions.removeAll(keepingCapacity: false)
        replacements.removeAll(keepingCapacity: false)
        restoredRecoveries.removeAll(keepingCapacity: false)
        replies.removeAll(keepingCapacity: false)
        replyNotices.removeAll(keepingCapacity: false)
    }
}

/// Holds the composer drafts for the whole app, so that a keystroke updates
/// the composer and not the screens around it.
///
/// SwiftUI updates a view when a value that its body read changes. Only the
/// composer reads `state`, which changes on each keystroke. The root view
/// reads `generation` and the conversation screen reads `isSubmitting(_:)`;
/// these change only on a reset and on a send.
@MainActor @Observable
final class ToasttyComposerDraftStore {
    private(set) var state: ToasttyComposerDraftState
    private(set) var generation: UUID
    private var submittingConversations: Set<UUID>

    init(_ state: ToasttyComposerDraftState = ToasttyComposerDraftState()) {
        self.state = state
        generation = state.generation
        submittingConversations = Set(state.submissions.keys)
    }

    func isSubmitting(_ conversationID: UUID) -> Bool {
        submittingConversations.contains(conversationID)
    }

    @discardableResult
    func update<Result>(_ change: (inout ToasttyComposerDraftState) -> Result) -> Result {
        let result = change(&state)
        // Set these only when they change: each set updates their readers.
        if generation != state.generation { generation = state.generation }
        let submitting = Set(state.submissions.keys)
        if submittingConversations != submitting { submittingConversations = submitting }
        return result
    }
}

enum ToasttySendPresentationAdapter {
    /// The coordinator's own queue, from a Mac that shares it, and whether
    /// this phone may let its messages go and remove them.
    struct CoordinatorQueue: Equatable {
        var queue: RemoteCoordinatorQueue
        var mayChange: Bool
        /// The entries whose last Remove the Mac answered `failed`.
        var removeFailures: Set<String> = []
    }

    /// On a row whose typing a quit of Toastty on the Mac interrupted, as
    /// the Mac chat says it above its composer.
    static let typingInterruptedWarning = "Toastty on the Mac quit while it typed this message, so the coordinator "
        + "may have it already. Check the conversation. If the message is there, choose Remove. "
        + "If it is not, choose Resume to send it."
    /// The same, for a phone that cannot change the queue: the row has no
    /// Resume or Remove.
    static let typingInterruptedWarningForTheMac = "Toastty on the Mac quit while it typed this message, so the "
        + "coordinator may have it already. Check the conversation. Then, in the Mac's chat, "
        + "choose Remove if the message is there, or Send next if it is not."
    /// On a row that the Mac could not remove.
    static let removeFailedNotice = "The Mac could not remove this message. It still waits."

    /// Reconciliation records first, then the Mac's queue in delivery order.
    /// A queued record the host still lists renders from the host's list,
    /// so the two never show the same message twice. In the coordinator's
    /// chat (`readsCoordinatorMessages`) a reply shows as its row will.
    ///
    /// With the coordinator's own queue, the chat lists both of the
    /// coordinator's queues as one, in the order Toastty types them once
    /// nothing is held: the conversation's queue, which goes first at each
    /// open prompt, then the coordinator's held messages, then its waiting
    /// ones. One Resume, on the first held row, lets go all that a Stop
    /// holds. A message in the coordinator's queue has Remove, not Edit.
    static func makeItems(
        from state: SendReconciliationState,
        inputControl: RemoteConversationInputControl? = nil,
        readsCoordinatorMessages: Bool = false,
        coordinatorQueue: CoordinatorQueue? = nil
    ) -> [ToasttySendPresentationItem] {
        let items = recordAndQueueItems(from: state, inputControl: inputControl, coordinatorQueue: coordinatorQueue)
        let mapped = readsCoordinatorMessages ? items.map(coordinatorItem) : items
        guard let coordinatorQueue else { return mapped }
        let firstPosition = (inputControl?.queuedMessages.count ?? 0) + 1
        let resumeRowID = firstHeldRowID(inputControl: inputControl, coordinatorQueue: coordinatorQueue)
        let heldTitle = resumeTitle(inputControl: inputControl, coordinatorQueue: coordinatorQueue)
        let coordinatorItems = coordinatorQueue.queue.entries.enumerated().map { index, entry in
            ToasttySendPresentationItem(
                clientRequestID: entry.id,
                text: entry.sender.map { "From \($0):\n\(entry.text)" } ?? entry.text,
                content: .queued(ToasttyQueuedSendPresentation(
                    position: firstPosition + index,
                    attachmentCount: entry.fileNames.count,
                    isPaused: entry.isHeld,
                    canSteer: false,
                    canChange: coordinatorQueue.mayChange,
                    canEdit: false,
                    resume: entry.id == resumeRowID ? .titled(heldTitle) : .none,
                    warning: entry.typingWasInterrupted
                        ? (coordinatorQueue.mayChange ? typingInterruptedWarning : typingInterruptedWarningForTheMac)
                        : nil,
                    actionFailure: coordinatorQueue.removeFailures.contains(entry.id) ? removeFailedNotice : nil
                )),
                quote: entry.quote.map { ToasttyMessageQuote(text: $0, timeText: entry.quoteTime) },
                hostMessage: hostMessage(of: entry)
            )
        }
        return mapped + coordinatorItems
    }

    /// A digest or a message from `coordinator send` that waits in the
    /// coordinator's queue, as its row will show it: the digest's line, or
    /// the sender's card. The Mac sends a sender's message without
    /// Toastty's first line and names the sender apart; a digest comes as
    /// Toastty typed it.
    static func hostMessage(of entry: RemoteCoordinatorQueueEntry) -> ToasttyHostMessagePresentation? {
        let waiting = "waiting"
        if let sender = entry.sender {
            return ToasttyHostMessagePresentation(
                summary: "From \(sender) · \(waiting)",
                text: entry.text,
                style: .sender(name: sender, timeText: waiting)
            )
        }
        guard var digest = CoordinatorChatTranscript.hostMessage(entry.text, timeText: waiting),
              digest.isLine else { return nil }
        // A shortened digest lost some of its lines, so its count is not
        // the digest's.
        if entry.isTextShortened {
            digest.title = "Toastty"
            digest.summary = "Toastty · \(waiting)"
        }
        return digest
    }

    /// The row that offers the one Resume: the first held message of the
    /// list, while this phone may change the queue and has the token of the
    /// Stop that holds it. A Stop reaches the session list before this
    /// phone reads the queue it holds; until then no row offers Resume.
    private static func firstHeldRowID(
        inputControl: RemoteConversationInputControl?,
        coordinatorQueue: CoordinatorQueue
    ) -> String? {
        guard coordinatorQueue.mayChange, coordinatorQueue.queue.heldSetToken != nil else { return nil }
        if inputControl?.isQueuePaused == true, let first = inputControl?.queuedMessages.first {
            return first.clientRequestID
        }
        return coordinatorQueue.queue.entries.first(where: \.isHeld)?.id
    }

    private static func resumeTitle(
        inputControl: RemoteConversationInputControl?,
        coordinatorQueue: CoordinatorQueue
    ) -> String {
        let conversationHeld = inputControl?.isQueuePaused == true ? inputControl?.queuedMessages.count ?? 0 : 0
        let held = conversationHeld + coordinatorQueue.queue.heldEntries.count
        return held > 1 ? "Resume all \(held)" : "Resume"
    }

    /// A message for the coordinator as its row in the coordinator's chat
    /// will show it: a reply as the user's text under its quote, and
    /// answers to offers as one line for each. Edit and Steer now still act
    /// on the text as sent, which the Mac's queue holds.
    static func coordinatorItem(_ item: ToasttySendPresentationItem) -> ToasttySendPresentationItem {
        let quote = CoordinatorChatTranscript.quote(of: item.text)
        guard quote != nil || CoordinatorMessageHeader.offerAnswers(of: item.text) != nil else { return item }
        return ToasttySendPresentationItem(
            clientRequestID: item.clientRequestID,
            text: CoordinatorMessageHeader.displayText(of: item.text),
            content: item.content,
            sentCaption: item.sentCaption,
            quote: quote,
            attachments: item.attachments,
            hostMessage: item.hostMessage
        )
    }

    private static func recordAndQueueItems(
        from state: SendReconciliationState,
        inputControl: RemoteConversationInputControl?,
        coordinatorQueue: CoordinatorQueue? = nil
    ) -> [ToasttySendPresentationItem] {
        let queued = inputControl?.queuedMessages ?? []
        let queuedIDs = Set(queued.map(\.clientRequestID))
            .union(coordinatorQueue?.queue.entries.map(\.id) ?? [])
        var items = makeItems(from: state).filter { queuedIDs.contains($0.clientRequestID) == false }
        let resumeRowID = coordinatorQueue.flatMap { firstHeldRowID(inputControl: inputControl, coordinatorQueue: $0) }
        for (index, message) in queued.enumerated() {
            let resume: ToasttyQueuedSendPresentation.ResumeOffer = if let coordinatorQueue {
                // One Resume for both of the coordinator's queues.
                message.clientRequestID == resumeRowID
                    ? .titled(resumeTitle(inputControl: inputControl, coordinatorQueue: coordinatorQueue))
                    : .none
            } else {
                .onEachPausedRow
            }
            items.append(ToasttySendPresentationItem(
                clientRequestID: message.clientRequestID,
                text: message.text,
                content: .queued(ToasttyQueuedSendPresentation(
                    position: index + 1,
                    attachmentCount: message.attachmentCount,
                    isPaused: inputControl?.isQueuePaused == true,
                    // Attachments stay staged on the Mac; a steer resends only
                    // text, so it is not offered for those entries.
                    canSteer: inputControl?.canSteer == true && message.attachmentCount == 0,
                    resume: resume
                ))
            ))
        }
        return items
    }

    static func makeItems(
        from state: SendReconciliationState
    ) -> [ToasttySendPresentationItem] {
        state.records.compactMap { record in
            let content: ToasttySendPresentationItem.Content
            var sentCaption: String?
            switch record.deliveryState {
            case .pending(let response):
                content = .optimistic(response: ToasttyPendingSendResponse(response))
                // The row that replaces this bubble says how the message
                // arrived. The Mac can queue a message sent at the prompt.
                let deliveryMode: RemoteMessageDeliveryMode =
                    if case .queued = response { .queue } else { record.deliveryMode }
                sentCaption = ToasttyUserMessageCaption.text(origin: .remote, deliveryMode: deliveryMode)
            case .confirmed:
                return nil
            case .rejected(let reason):
                content = .receipt(.init(kind: .rejected(reason)))
            case .uncertain:
                content = .receipt(.init(kind: .uncertain))
            case .operationFailed:
                content = .receipt(.init(kind: .operationFailed))
            case .deliveryUnconfirmed:
                content = .receipt(.init(kind: .deliveryUnconfirmed))
            }
            return ToasttySendPresentationItem(
                clientRequestID: record.clientRequestID,
                text: record.text,
                content: content,
                sentCaption: sentCaption
            )
        }
    }
}

private extension ToasttyPendingSendResponse {
    init(_ response: PendingSendResponse) {
        self = switch response {
        case .awaitingResponse: .awaitingResponse
        case .accepted: .accepted
        case .duplicate: .duplicate
        case .queued(let position): .queued(position: position)
        }
    }
}
