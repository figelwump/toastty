import Foundation

/// A remote free-form send request at an explicitly open root prompt.
public struct RemoteMessageSendRequest: Codable, Equatable, Sendable {
    public var conversationID: RemoteConversationID
    /// Client-generated idempotency key. A reconnect retry with the same key
    /// must never inject the message twice.
    public var clientRequestID: String
    /// The exact prompt epoch the client rendered its compose bar against. Only
    /// an exact match against the host's current `openPrompt` epoch is accepted.
    public var expectedInputEpoch: RemoteInputEpoch
    public var text: String
    public var attachments: [RemoteMessageAttachment]

    public var maximumEncodedBodyBytes: Int { attachments.isEmpty ? RemoteGatewayProtocol.maximumRequestBodyBytes : RemoteAttachmentPolicy.maximumEncodedBodyBytes }
    public var displayText: String {
        ([text].filter { !$0.isEmpty } + attachments.map { "[Attachment: \(RemoteAttachmentPolicy.displayFilename($0.filename))]" }).joined(separator: "\n")
    }

    public init(
        conversationID: RemoteConversationID,
        clientRequestID: String,
        expectedInputEpoch: RemoteInputEpoch,
        text: String,
        attachments: [RemoteMessageAttachment] = []
    ) {
        self.conversationID = conversationID
        self.clientRequestID = clientRequestID
        self.expectedInputEpoch = expectedInputEpoch
        self.text = text
        self.attachments = attachments
    }
    private enum CodingKeys: String, CodingKey {
        case conversationID, clientRequestID, expectedInputEpoch, text, attachments
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try values.decode(RemoteConversationID.self, forKey: .conversationID)
        clientRequestID = try values.decode(String.self, forKey: .clientRequestID)
        expectedInputEpoch = try values.decode(RemoteInputEpoch.self, forKey: .expectedInputEpoch)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decodeIfPresent([RemoteMessageAttachment].self, forKey: .attachments) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encode(clientRequestID, forKey: .clientRequestID)
        try values.encode(expectedInputEpoch, forKey: .expectedInputEpoch)
        try values.encode(text, forKey: .text)
        if !attachments.isEmpty { try values.encode(attachments, forKey: .attachments) }
    }

}

/// Why a remote send was refused. Each reason fails closed — the host never
/// delivers when it cannot prove the send is safe.
public enum RemoteMessageRejectionReason: String, Codable, Equatable, Sendable {
    /// The device's credential lacks send scope.
    case sendScopeDenied = "send_scope_denied"
    /// Remote writes are not enabled for this session on the Mac.
    case sessionWritesDisabled = "session_writes_disabled"
    /// No live managed runtime / terminal surface is bound to the conversation.
    case notBound = "not_bound"
    /// The bound terminal surface is not ready to accept input right now.
    case surfaceUnavailable = "surface_unavailable"
    /// The prompt is not authoritatively open (working, offline, unknown).
    case promptNotOpen = "prompt_not_open"
    /// The presented epoch does not match the current open-prompt epoch.
    case epochMismatch = "epoch_mismatch"
    /// Local input has touched the prompt since the client rendered it.
    case localDraftPresent = "local_draft_present"
    /// A modal interaction (permission/question) is blocking the prompt.
    case pendingInteraction = "pending_interaction"
    /// The message text was empty after trimming.
    case emptyText = "empty_text"
    case invalidAttachments = "invalid_attachments"
    case attachmentStorageUnavailable = "attachment_storage_unavailable"
}

/// The immediate response to a send request. Never a claim that the agent
/// processed the message — only that the host accepted it for delivery.
/// Confirmation comes later, when the normalized user message appears in the
/// event projection carrying the request's `clientRequestID`.
public enum RemoteMessageSendResult: Equatable, Sendable {
    /// Accepted for delivery under the given epoch.
    case accepted(epoch: RemoteInputEpoch)
    /// Rejected; the client must not retry without re-reading state.
    case rejected(reason: RemoteMessageRejectionReason)
    /// Text may have reached the terminal, but submission could not be
    /// confirmed. The host closes the epoch and suppresses retries because a
    /// second injection could append or submit the message twice.
    case uncertain
    /// This `clientRequestID` was already accepted; the earlier delivery
    /// stands. Idempotent retries land here rather than injecting twice.
    case duplicate

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

extension RemoteMessageSendResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case epoch
        case reason
    }

    private enum Status: String, Codable {
        case accepted
        case rejected
        case uncertain
        case duplicate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .accepted:
            self = .accepted(epoch: try container.decode(RemoteInputEpoch.self, forKey: .epoch))
        case .rejected:
            self = .rejected(reason: try container.decode(RemoteMessageRejectionReason.self, forKey: .reason))
        case .uncertain:
            self = .uncertain
        case .duplicate:
            self = .duplicate
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let epoch):
            try container.encode(Status.accepted, forKey: .status)
            try container.encode(epoch, forKey: .epoch)
        case .rejected(let reason):
            try container.encode(Status.rejected, forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .uncertain:
            try container.encode(Status.uncertain, forKey: .status)
        case .duplicate:
            try container.encode(Status.duplicate, forKey: .status)
        }
    }
}
