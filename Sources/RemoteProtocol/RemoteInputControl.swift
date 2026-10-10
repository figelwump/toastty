import Foundation

/// How the host delivers a remote message relative to the agent's turn.
///
/// `prompt` is the original contract: type into the open root prompt now.
/// `queue` and `steer` are only meaningful while the agent works, and only
/// on a host that advertises `RemoteGatewayCapability.conversationInputControl`.
public enum RemoteMessageDeliveryMode: String, Codable, Equatable, Sendable {
    /// Type into the open root prompt now. Absent on the wire means this.
    case prompt
    /// Hold the message on the Mac and type it as the next prompt once the
    /// running turn ends and the prompt opens. Toastty owns this queue; the
    /// agent never sees the text early.
    case queue
    /// Type into the running turn now. Codex injects it into the current
    /// turn; Claude Code holds it in its own queue until the turn ends.
    case steer
}

/// One message waiting on the Mac for the next open prompt.
public struct RemoteQueuedMessage: Codable, Equatable, Sendable {
    /// The send request's idempotency key. Removing or steering a queued
    /// message names it by this ID.
    public var clientRequestID: String
    /// The message text as the client sent it, so it can be edited again.
    public var text: String
    /// Attachments stay staged on the Mac and are not editable remotely.
    public var attachmentCount: Int
    public var enqueuedAt: Date

    public init(clientRequestID: String, text: String, attachmentCount: Int = 0, enqueuedAt: Date) {
        self.clientRequestID = clientRequestID
        self.text = text
        self.attachmentCount = attachmentCount
        self.enqueuedAt = enqueuedAt
    }

    private enum CodingKeys: String, CodingKey {
        case clientRequestID, text, attachmentCount, enqueuedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientRequestID = try container.decode(String.self, forKey: .clientRequestID)
        text = try container.decode(String.self, forKey: .text)
        attachmentCount = try container.decodeIfPresent(Int.self, forKey: .attachmentCount) ?? 0
        enqueuedAt = try container.decode(Date.self, forKey: .enqueuedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientRequestID, forKey: .clientRequestID)
        try container.encode(text, forKey: .text)
        if attachmentCount > 0 { try container.encode(attachmentCount, forKey: .attachmentCount) }
        try container.encode(enqueuedAt, forKey: .enqueuedAt)
    }
}

/// Live input controls for a conversation beyond the open-prompt gate: the
/// identity of the running turn, whether steer and stop are accepted right
/// now, and the Mac-side queue. Absent from older hosts.
public struct RemoteConversationInputControl: Codable, Equatable, Sendable {
    /// Bounded so every session-list broadcast stays small.
    public static let maximumQueuedMessages = 5

    /// Identity of the turn the agent is working on, or awaiting an
    /// interaction in. It is the prompt epoch that was consumed to start the
    /// turn; it changes when the turn ends and whenever the runtime rebinds,
    /// so a late steer or stop can never target a later turn. Nil while no
    /// turn is running.
    public var turnEpoch: RemoteInputEpoch?
    /// A queue send would be held right now: the runtime is bound and the
    /// Mac allows remote writes for this session.
    public var canQueue: Bool
    /// A steer send presenting `turnEpoch` would be delivered right now.
    /// False once local keyboard input touched the running turn.
    public var canSteer: Bool
    /// An interrupt presenting `turnEpoch` would be delivered right now.
    public var canInterrupt: Bool
    /// Messages waiting for the next open prompt, in delivery order.
    public var queuedMessages: [RemoteQueuedMessage]
    /// The queue holds after a stop until the client resumes it or empties
    /// it, so a queued message never starts a new turn right after the user
    /// stopped the previous one.
    public var isQueuePaused: Bool

    public init(
        turnEpoch: RemoteInputEpoch? = nil,
        canQueue: Bool = false,
        canSteer: Bool = false,
        canInterrupt: Bool = false,
        queuedMessages: [RemoteQueuedMessage] = [],
        isQueuePaused: Bool = false
    ) {
        self.turnEpoch = turnEpoch
        self.canQueue = canQueue
        self.canSteer = canSteer
        self.canInterrupt = canInterrupt
        self.queuedMessages = queuedMessages
        self.isQueuePaused = isQueuePaused
    }

    private enum CodingKeys: String, CodingKey {
        case turnEpoch, canQueue, canSteer, canInterrupt, queuedMessages, isQueuePaused
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnEpoch = try container.decodeIfPresent(RemoteInputEpoch.self, forKey: .turnEpoch)
        canQueue = try container.decodeIfPresent(Bool.self, forKey: .canQueue) ?? false
        canSteer = try container.decodeIfPresent(Bool.self, forKey: .canSteer) ?? false
        canInterrupt = try container.decodeIfPresent(Bool.self, forKey: .canInterrupt) ?? false
        queuedMessages = try container.decodeIfPresent([RemoteQueuedMessage].self, forKey: .queuedMessages) ?? []
        isQueuePaused = try container.decodeIfPresent(Bool.self, forKey: .isQueuePaused) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(turnEpoch, forKey: .turnEpoch)
        if canQueue { try container.encode(true, forKey: .canQueue) }
        if canSteer { try container.encode(true, forKey: .canSteer) }
        if canInterrupt { try container.encode(true, forKey: .canInterrupt) }
        if !queuedMessages.isEmpty { try container.encode(queuedMessages, forKey: .queuedMessages) }
        if isQueuePaused { try container.encode(true, forKey: .isQueuePaused) }
    }
}

// MARK: - Queue updates

public enum RemoteConversationQueueAction: String, Codable, Equatable, Sendable {
    /// Drop one queued message, named by `clientRequestID`.
    case remove
    /// Let a paused queue deliver again at the next open prompt.
    case resume
}

public struct RemoteConversationQueueUpdateRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var conversationID: RemoteConversationID
    public var action: RemoteConversationQueueAction
    /// Required for `remove`; ignored for `resume`.
    public var clientRequestID: String?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        action: RemoteConversationQueueAction,
        clientRequestID: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.action = action
        self.clientRequestID = clientRequestID
    }
}

public enum RemoteConversationQueueUpdateResult: String, Codable, Equatable, Sendable {
    case updated
    /// The named message was already gone, or the queue was not paused. A
    /// retry after a lost response lands here.
    case unchanged
    case conversationNotFound = "conversation_not_found"
}

public struct RemoteConversationQueueUpdateResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteConversationQueueUpdateResult

    public init(result: RemoteConversationQueueUpdateResult) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.result = result
    }
}

// MARK: - Interrupt

/// Stops the running turn by sending the provider's interrupt key. The
/// request names the turn it saw so a late tap cannot stop a later turn.
public struct RemoteConversationInterruptRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var conversationID: RemoteConversationID
    public var expectedTurnEpoch: RemoteInputEpoch

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        expectedTurnEpoch: RemoteInputEpoch
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.expectedTurnEpoch = expectedTurnEpoch
    }
}

public enum RemoteConversationInterruptRejectionReason: String, Codable, Equatable, Sendable {
    case sendScopeDenied = "send_scope_denied"
    case sessionWritesDisabled = "session_writes_disabled"
    case notBound = "not_bound"
    case surfaceUnavailable = "surface_unavailable"
    /// No turn is running, so there is nothing to stop.
    case notWorking = "not_working"
    /// The running turn is not the one the client saw.
    case turnMismatch = "turn_mismatch"
    case unsupported
}

public enum RemoteConversationInterruptResult: Equatable, Sendable {
    /// The interrupt key reached the terminal. The provider reports the
    /// turn's end through the transcript as usual.
    case accepted
    case rejected(reason: RemoteConversationInterruptRejectionReason)
}

extension RemoteConversationInterruptResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case reason
    }

    private enum Status: String, Codable {
        case accepted
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .accepted:
            self = .accepted
        case .rejected:
            self = .rejected(reason: try container.decode(RemoteConversationInterruptRejectionReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted:
            try container.encode(Status.accepted, forKey: .status)
        case .rejected(let reason):
            try container.encode(Status.rejected, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct RemoteConversationInterruptResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteConversationInterruptResult

    public init(result: RemoteConversationInterruptResult) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.result = result
    }
}

// MARK: - Local draft release

/// Reopens a prompt that the Mac holds closed because local input touched it
/// (`RemoteInputAvailability.localDraft`). The user asserts the Mac composer
/// is empty; the host sends no keys to the terminal. The request names the
/// draft epoch the client saw, and every later Mac keystroke advances that
/// epoch, so a release decided before newer Mac typing is refused.
public struct RemoteConversationLocalDraftReleaseRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var conversationID: RemoteConversationID
    public var expectedDraftEpoch: RemoteInputEpoch

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        expectedDraftEpoch: RemoteInputEpoch
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.expectedDraftEpoch = expectedDraftEpoch
    }
}

public enum RemoteConversationLocalDraftReleaseRejectionReason: String, Codable, Equatable, Sendable {
    case sendScopeDenied = "send_scope_denied"
    case sessionWritesDisabled = "session_writes_disabled"
    case notBound = "not_bound"
    /// No Mac draft holds the prompt now: it already reopened, or the agent
    /// moved on (for example, the Mac user submitted the draft).
    case noLocalDraft = "no_local_draft"
    /// The Mac was typed on after the client saw the draft.
    case draftChanged = "draft_changed"
    case unsupported
}

public enum RemoteConversationLocalDraftReleaseResult: Equatable, Sendable {
    /// The prompt is open again. The fresh session list carries its epoch.
    case released
    case rejected(reason: RemoteConversationLocalDraftReleaseRejectionReason)
}

extension RemoteConversationLocalDraftReleaseResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case reason
    }

    private enum Status: String, Codable {
        case released
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .released:
            self = .released
        case .rejected:
            self = .rejected(reason: try container.decode(
                RemoteConversationLocalDraftReleaseRejectionReason.self,
                forKey: .reason
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .released:
            try container.encode(Status.released, forKey: .status)
        case .rejected(let reason):
            try container.encode(Status.rejected, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }
}

public struct RemoteConversationLocalDraftReleaseResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteConversationLocalDraftReleaseResult

    public init(result: RemoteConversationLocalDraftReleaseResult) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.result = result
    }
}
