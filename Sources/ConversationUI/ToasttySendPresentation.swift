import Foundation
import RemoteProtocol

/// What the host has said so far about a message sent from this device.
public enum ToasttyPendingSendResponse: Equatable, Sendable {
    case awaitingResponse
    case accepted
    case duplicate
    /// Held on the Mac for the next open prompt.
    case queued(position: Int)
}

public struct ToasttySendPresentationItem: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case optimistic(response: ToasttyPendingSendResponse)
        case receipt(ToasttySendReceiptPresentation)
        /// Held on the Mac for the next prompt, as the host currently lists it.
        case queued(ToasttyQueuedSendPresentation)
    }

    public var id: String { clientRequestID }

    public let clientRequestID: String
    public let text: String
    public let content: Content

    public init(clientRequestID: String, text: String, content: Content) {
        self.clientRequestID = clientRequestID
        self.text = text
        self.content = content
    }

    public var isQueued: Bool {
        if case .queued = content { return true }
        return false
    }
}

public struct ToasttyQueuedSendPresentation: Equatable, Sendable {
    /// 1-based delivery order.
    public let position: Int
    public let attachmentCount: Int
    /// The queue holds after a stop until the user resumes it.
    public let isPaused: Bool
    /// "Steer now" is offered on the row.
    public let canSteer: Bool

    public init(position: Int, attachmentCount: Int, isPaused: Bool, canSteer: Bool) {
        self.position = position
        self.attachmentCount = attachmentCount
        self.isPaused = isPaused
        self.canSteer = canSteer
    }
}

/// What the user asked for on a queued message in the transcript.
public enum ToasttyQueuedMessageAction: Equatable, Sendable {
    case edit(clientRequestID: String, text: String)
    case steer(clientRequestID: String, text: String)
    case remove(clientRequestID: String)
    case resume
}

public struct ToasttySendReceiptPresentation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case rejected(RemoteMessageRejectionReason)
        case uncertain
        case operationFailed
        case deliveryUnconfirmed
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var title: String {
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
        case .rejected(.invalidAttachments):
            "An attachment could not be accepted"
        case .rejected(.attachmentStorageUnavailable):
            "The Mac could not save the attachments"
        case .rejected(.emptyText):
            "The message was empty"
        case .rejected(.queueFull):
            "The Mac's queue for this session is full"
        case .rejected(.notWorking):
            "The agent finished before this message was queued"
        case .rejected(.turnMismatch):
            "The agent moved to another turn before this message was sent"
        case .rejected(.steerUnavailable):
            "Someone is typing on the Mac, so this message could not steer the turn"
        case .uncertain:
            "Delivery could not be confirmed"
        case .operationFailed:
            "Toastty could not complete the send"
        case .deliveryUnconfirmed:
            "The Mac accepted this send, but it did not appear in the session transcript"
        }
    }

    public var detail: String {
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
        case .rejected(.invalidAttachments), .rejected(.attachmentStorageUnavailable):
            "The attachments were not delivered. Review the draft and check Toastty on your Mac before sending again."
        case .rejected(.emptyText):
            "Enter a message before sending."
        case .rejected(.queueFull):
            "Wait for a queued message to send, or remove one. Your draft is still here."
        case .rejected(.notWorking), .rejected(.turnMismatch):
            "Review the current prompt before sending again. Toastty did not retry."
        case .rejected(.steerUnavailable):
            "Queue it for the next prompt instead, or wait for the Mac. Toastty did not retry."
        case .uncertain:
            "Check the transcript or the Mac before sending anything else. Toastty will not retry this message."
        case .operationFailed:
            "Check the transcript on the Mac. The attempted message is shown below; Toastty did not retry it."
        case .deliveryUnconfirmed:
            "Check the session on the Mac before sending again. Toastty will not retry this message."
        }
    }
}
