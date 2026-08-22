import Foundation
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

enum ToasttyComposerGate: Equatable, Sendable {
    case enabled
    case disabled(ToasttyComposerDisabledReason)

    var allowsInput: Bool {
        if case .enabled = self { return true }
        return false
    }
}

struct ToasttyComposerPresentation: Equatable, Sendable {
    let agentDisplayName: String
    let gate: ToasttyComposerGate
    let inlineFeedback: String?

    init(
        agentDisplayName: String,
        gate: ToasttyComposerGate,
        inlineFeedback: String? = nil
    ) {
        self.agentDisplayName = agentDisplayName
        self.gate = gate
        self.inlineFeedback = inlineFeedback
    }

    static func make(
        agentDisplayName: String,
        authority: ConversationComposerAuthority
    ) -> ToasttyComposerPresentation {
        return ToasttyComposerPresentation(
            agentDisplayName: agentDisplayName,
            gate: gate(for: authority),
            inlineFeedback: feedback(for: authority.gateFailure)
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
        "Message \(agentDisplayName)…"
    }

    func canSubmit(draft: String) -> Bool {
        gate.allowsInput
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
            case .emptyText, .cancelled:
                return gate(for: authority.inputAvailability)
            }
        }
        guard authority.canSend else { return .disabled(.connection(.catchingUp)) }
        return gate(for: authority.inputAvailability)
    }

    private static func feedback(
        for failure: ConversationSendGateFailure?
    ) -> String? {
        switch failure {
        case .emptyText:
            "Enter a message before sending. Your draft was not changed."
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
            .enabled
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
    let text: String
}

struct ToasttyComposerDraftState: Equatable, Sendable {
    private(set) var drafts: [UUID: String] = [:]
    private(set) var submissions: [UUID: ToasttyComposerSubmission] = [:]

    func draft(for conversationID: UUID) -> String {
        drafts[conversationID, default: ""]
    }

    func isSubmitting(_ conversationID: UUID) -> Bool {
        submissions[conversationID] != nil
    }

    mutating func updateDraft(_ text: String, for conversationID: UUID) {
        if text.isEmpty {
            drafts.removeValue(forKey: conversationID)
        } else {
            drafts[conversationID] = text
        }
    }

    mutating func beginSubmission(
        for conversationID: UUID,
        submissionID: UUID = UUID()
    ) -> ToasttyComposerSubmission? {
        guard submissions[conversationID] == nil else { return nil }
        let text = draft(for: conversationID)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let submission = ToasttyComposerSubmission(
            id: submissionID,
            conversationID: conversationID,
            text: text
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
        guard case .enqueued = outcome,
              draft(for: submission.conversationID) == submission.text else {
            return
        }
        drafts.removeValue(forKey: submission.conversationID)
    }

    mutating func retainConversations(_ conversationIDs: Set<UUID>) {
        drafts = drafts.filter { conversationIDs.contains($0.key) }
        submissions = submissions.filter { conversationIDs.contains($0.key) }
    }

    mutating func reset() {
        drafts.removeAll(keepingCapacity: false)
        submissions.removeAll(keepingCapacity: false)
    }
}

struct ToasttySendPresentationItem: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case optimistic(response: PendingSendResponse)
        case receipt(ToasttySendReceiptPresentation)
    }

    var id: String { clientRequestID }

    let clientRequestID: String
    let text: String
    let content: Content
}

struct ToasttySendReceiptPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case rejected(RemoteMessageRejectionReason)
        case uncertain
        case operationFailed
        case deliveryUnconfirmed
    }

    let kind: Kind

    var title: String {
        switch kind {
        case .rejected(.sendScopeDenied):
            "This iPhone cannot send messages"
        case .rejected(.sessionWritesDisabled):
            "Remote input is off for this session"
        case .rejected(.epochMismatch):
            "The prompt changed before this message was sent"
        case .rejected(.localDraftPresent):
            "A draft started on the Mac before this message was sent"
        case .rejected(.pendingInteraction):
            "A pending interaction blocked this message"
        case .rejected(.notBound):
            "The session is no longer connected"
        case .rejected(.surfaceUnavailable):
            "The Mac could not accept this message"
        case .rejected(.promptNotOpen):
            "The prompt closed before this message was sent"
        case .rejected(.emptyText):
            "The message was empty"
        case .uncertain:
            "Delivery could not be confirmed"
        case .operationFailed:
            "Toastty could not complete the send"
        case .deliveryUnconfirmed:
            "The Mac accepted this send, but it did not appear in the session transcript"
        }
    }

    var detail: String {
        switch kind {
        case .rejected(.sendScopeDenied):
            "Enable Send for this device on the Mac. The attempted message is shown below; Toastty did not retry it."
        case .rejected(.sessionWritesDisabled):
            "Enable remote input for this session on the Mac. The attempted message is shown below; Toastty did not retry it."
        case .rejected(.epochMismatch):
            "Review the current prompt before sending again. Toastty did not retry."
        case .rejected(.localDraftPresent):
            "Continue on the Mac or wait for a new prompt. Toastty did not retry."
        case .rejected(.pendingInteraction):
            "Respond to the interaction on the Mac. Toastty did not retry."
        case .rejected(.notBound), .rejected(.surfaceUnavailable), .rejected(.promptNotOpen):
            "Check the session on the Mac. The attempted message is shown below; Toastty did not retry it."
        case .rejected(.emptyText):
            "Enter a message before sending."
        case .uncertain:
            "Check the transcript or the Mac before sending anything else. Toastty will not retry this message."
        case .operationFailed:
            "Check the transcript on the Mac. The attempted message is shown below; Toastty did not retry it."
        case .deliveryUnconfirmed:
            "Check the session on the Mac before sending again. Toastty will not retry this message."
        }
    }
}

enum ToasttySendPresentationAdapter {
    static func makeItems(
        from state: SendReconciliationState
    ) -> [ToasttySendPresentationItem] {
        state.records.compactMap { record in
            let content: ToasttySendPresentationItem.Content
            switch record.deliveryState {
            case .pending(let response):
                content = .optimistic(response: response)
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
                content: content
            )
        }
    }
}
