import Foundation

/// Discriminator for `ConversationEventPayload`, stable on the wire.
///
/// The host decodes its own events strictly. Remote clients must instead treat
/// unknown kinds as ignorable (skip the event, keep the sequence) so new
/// optional kinds never break older clients; the web client does this in JS,
/// and a future native client needs a tolerant envelope decode path.
public enum ConversationEventKind: String, Codable, Equatable, Sendable {
    case userMessage = "user_message"
    case assistantMessage = "assistant_message"
    case toolStarted = "tool_started"
    case toolFinished = "tool_finished"
    case statusChanged = "status_changed"
    case interactionPresented = "interaction_presented"
    case interactionResolved = "interaction_resolved"
    case subagentSummary = "subagent_summary"
    case sessionBindingChanged = "session_binding_changed"
    case sendDeliveryUnconfirmed = "send_delivery_unconfirmed"

    /// Whether events of this kind are derived purely from provider files.
    ///
    /// Rebuilding a projection from unchanged provider files reproduces
    /// provider-derived events exactly (same eventID, same payload, same
    /// relative order). Runtime-derived kinds (`statusChanged`,
    /// `sessionBindingChanged`, and `sendDeliveryUnconfirmed`) describe live
    /// host state — bindings, epochs, availability, and delivery receipts —
    /// and are legitimately different across rebuilds; they are excluded from
    /// the rebuild-determinism contract.
    public var isProviderDerived: Bool {
        switch self {
        case .statusChanged, .sessionBindingChanged, .sendDeliveryUnconfirmed:
            return false
        case .userMessage, .assistantMessage, .toolStarted, .toolFinished,
             .interactionPresented, .interactionResolved, .subagentSummary:
            return true
        }
    }
}

/// Where a normalized user message originated, when the host can tell.
public enum ConversationMessageOrigin: String, Codable, Equatable, Sendable {
    case local
    case remote
    case unknown
}

public struct ConversationUserMessagePayload: Codable, Equatable, Sendable {
    public var text: String
    public var origin: ConversationMessageOrigin
    /// Echo of the `clientRequestID` from the remote send this message
    /// confirms, when the host correlated the two. Lets the sending device
    /// distinguish its own confirmed send from another device's identical text.
    public var clientRequestID: String?

    public init(
        text: String,
        origin: ConversationMessageOrigin = .unknown,
        clientRequestID: String? = nil
    ) {
        self.text = text
        self.origin = origin
        self.clientRequestID = clientRequestID
    }
}

/// Whether an assistant message is intermediate narration or the final answer
/// for its turn, when the provider distinguishes the two.
public enum ConversationAssistantMessagePhase: String, Codable, Equatable, Sendable {
    case commentary
    case final
    case unknown
}

public struct ConversationAssistantMessagePayload: Codable, Equatable, Sendable {
    public var text: String
    public var phase: ConversationAssistantMessagePhase

    public init(text: String, phase: ConversationAssistantMessagePhase = .unknown) {
        self.text = text
        self.phase = phase
    }
}

public struct ConversationToolStartedPayload: Codable, Equatable, Sendable {
    /// Provider call identifier used to correlate the matching `toolFinished`.
    public var callID: String
    public var toolName: String
    /// Short human-readable summary (for example the command line). Detailed
    /// tool payloads are intentionally out of the fidelity contract.
    public var detail: String?

    public init(callID: String, toolName: String, detail: String? = nil) {
        self.callID = callID
        self.toolName = toolName
        self.detail = detail
    }
}

public enum ConversationToolOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case unknown
}

public struct ConversationToolFinishedPayload: Codable, Equatable, Sendable {
    public var callID: String
    /// Providers omit the tool name on outputs; correlate via `callID`.
    public var toolName: String?
    public var outcome: ConversationToolOutcome
    public var detail: String?

    public init(
        callID: String,
        toolName: String? = nil,
        outcome: ConversationToolOutcome = .unknown,
        detail: String? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.outcome = outcome
        self.detail = detail
    }
}

/// Status carried inside the event stream so a subscriber can never observe a
/// status ahead of the transcript event that caused it.
///
/// Emission is coalesced: a `statusChanged` event is appended only when the
/// state or the availability *case* changes, or when a new `openPrompt` epoch
/// is established. Epoch churn while already in `localDraft` (every local
/// keystroke advances the counter) must not emit events — the live epoch is
/// only observable through snapshots, and remote sends are rejected in
/// `localDraft` regardless.
public struct ConversationStatusChangedPayload: Codable, Equatable, Sendable {
    public var state: RemoteSessionState
    public var inputAvailability: RemoteInputAvailability

    public init(state: RemoteSessionState, inputAvailability: RemoteInputAvailability) {
        self.state = state
        self.inputAvailability = inputAvailability
    }
}

public struct ConversationInteractionResolvedPayload: Codable, Equatable, Sendable {
    public var interactionID: RemotePendingInteraction.ID
    public var resolution: RemotePendingInteraction.State

    public init(interactionID: RemotePendingInteraction.ID, resolution: RemotePendingInteraction.State) {
        self.interactionID = interactionID
        self.resolution = resolution
    }
}

public enum ConversationSubagentPhase: String, Codable, Equatable, Sendable {
    case started
    case updated
    case finished
    case unknown
}

/// Summarized subagent activity. Full subagent transcripts are intentionally
/// out of the first fidelity contract.
public struct ConversationSubagentSummaryPayload: Codable, Equatable, Sendable {
    public var subagentID: String
    public var displayName: String
    public var phase: ConversationSubagentPhase
    public var detail: String?

    public init(
        subagentID: String,
        displayName: String,
        phase: ConversationSubagentPhase = .unknown,
        detail: String? = nil
    ) {
        self.subagentID = subagentID
        self.displayName = displayName
        self.phase = phase
        self.detail = detail
    }
}

public enum ConversationBindingChangeReason: String, Codable, Equatable, Sendable {
    /// A managed runtime started and bound to this conversation.
    case runtimeBound = "runtime_bound"
    /// A native resume bound a new runtime (and possibly a new provider
    /// session) to this existing conversation.
    case runtimeResumed = "runtime_resumed"
    /// The bound runtime ended; the conversation remains readable offline.
    case runtimeEnded = "runtime_ended"
    /// The projection was rebuilt from provider files (fresh run, fresh
    /// sequences).
    case projectionRebuilt = "projection_rebuilt"
}

public struct ConversationSessionBindingChangedPayload: Codable, Equatable, Sendable {
    public var reason: ConversationBindingChangeReason
    public var providerSessionID: String?
    public var providerSessionFilePath: String?

    public init(
        reason: ConversationBindingChangeReason,
        providerSessionID: String? = nil,
        providerSessionFilePath: String? = nil
    ) {
        self.reason = reason
        self.providerSessionID = providerSessionID
        self.providerSessionFilePath = providerSessionFilePath
    }
}

/// Host-side receipt emitted when an accepted remote send did not appear in
/// the provider transcript before the bounded confirmation deadline. This is
/// deliberately conservative: a later correlated user message can still prove
/// that the provider eventually consumed the send.
public struct ConversationSendDeliveryUnconfirmedPayload: Codable, Equatable, Sendable {
    public var clientRequestID: String

    public init(clientRequestID: String) {
        self.clientRequestID = clientRequestID
    }
}

/// Typed payload for one conversation event. The wire discriminator is
/// `ConversationEventKind`.
public enum ConversationEventPayload: Codable, Equatable, Sendable {
    case userMessage(ConversationUserMessagePayload)
    case assistantMessage(ConversationAssistantMessagePayload)
    case toolStarted(ConversationToolStartedPayload)
    case toolFinished(ConversationToolFinishedPayload)
    case statusChanged(ConversationStatusChangedPayload)
    case interactionPresented(RemotePendingInteraction)
    case interactionResolved(ConversationInteractionResolvedPayload)
    case subagentSummary(ConversationSubagentSummaryPayload)
    case sessionBindingChanged(ConversationSessionBindingChangedPayload)
    case sendDeliveryUnconfirmed(ConversationSendDeliveryUnconfirmedPayload)

    public var kind: ConversationEventKind {
        switch self {
        case .userMessage: return .userMessage
        case .assistantMessage: return .assistantMessage
        case .toolStarted: return .toolStarted
        case .toolFinished: return .toolFinished
        case .statusChanged: return .statusChanged
        case .interactionPresented: return .interactionPresented
        case .interactionResolved: return .interactionResolved
        case .subagentSummary: return .subagentSummary
        case .sessionBindingChanged: return .sessionBindingChanged
        case .sendDeliveryUnconfirmed: return .sendDeliveryUnconfirmed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ConversationEventKind.self, forKey: .kind) {
        case .userMessage:
            self = .userMessage(try container.decode(ConversationUserMessagePayload.self, forKey: .payload))
        case .assistantMessage:
            self = .assistantMessage(try container.decode(ConversationAssistantMessagePayload.self, forKey: .payload))
        case .toolStarted:
            self = .toolStarted(try container.decode(ConversationToolStartedPayload.self, forKey: .payload))
        case .toolFinished:
            self = .toolFinished(try container.decode(ConversationToolFinishedPayload.self, forKey: .payload))
        case .statusChanged:
            self = .statusChanged(try container.decode(ConversationStatusChangedPayload.self, forKey: .payload))
        case .interactionPresented:
            self = .interactionPresented(try container.decode(RemotePendingInteraction.self, forKey: .payload))
        case .interactionResolved:
            self = .interactionResolved(try container.decode(ConversationInteractionResolvedPayload.self, forKey: .payload))
        case .subagentSummary:
            self = .subagentSummary(try container.decode(ConversationSubagentSummaryPayload.self, forKey: .payload))
        case .sessionBindingChanged:
            self = .sessionBindingChanged(try container.decode(ConversationSessionBindingChangedPayload.self, forKey: .payload))
        case .sendDeliveryUnconfirmed:
            self = .sendDeliveryUnconfirmed(try container.decode(ConversationSendDeliveryUnconfirmedPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .userMessage(let value): try container.encode(value, forKey: .payload)
        case .assistantMessage(let value): try container.encode(value, forKey: .payload)
        case .toolStarted(let value): try container.encode(value, forKey: .payload)
        case .toolFinished(let value): try container.encode(value, forKey: .payload)
        case .statusChanged(let value): try container.encode(value, forKey: .payload)
        case .interactionPresented(let value): try container.encode(value, forKey: .payload)
        case .interactionResolved(let value): try container.encode(value, forKey: .payload)
        case .subagentSummary(let value): try container.encode(value, forKey: .payload)
        case .sessionBindingChanged(let value): try container.encode(value, forKey: .payload)
        case .sendDeliveryUnconfirmed(let value): try container.encode(value, forKey: .payload)
        }
    }
}

/// One ordered, immutable entry in a conversation's projected transcript.
///
/// Sequences are monotonic per conversation within one projection run; they are
/// not durable across Toastty relaunches.
///
/// `eventID` is deterministic for provider-derived kinds (see
/// `ConversationEventKind.isProviderDerived`): rebuilding the projection from
/// unchanged provider files reproduces identical events. The recipe, in
/// preference order: (1) the provider's native record identity (message ID,
/// call ID, approval ID) prefixed with the provider — e.g. `codex:msg_…`,
/// `codex:call_…`; (2) when the provider record has no identity, a stable
/// content fingerprint over (record kind, turn identity, role, normalized
/// content, occurrence index within the turn), prefixed `codex:fp:…`. Binding
/// the fingerprint to turn identity plus occurrence index is what lets the
/// projection deduplicate compaction-replayed records while preserving
/// genuinely repeated identical messages in different turns. Runtime-derived
/// kinds use a distinct `rt:` prefix and carry no determinism promise. Never a
/// random value.
public struct ConversationEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var conversationID: RemoteConversationID
    public var sequence: UInt64
    public var eventID: String
    public var schemaVersion: Int
    public var timestamp: Date
    public var provider: AgentKind
    /// Provider-native identity for this fact (message ID, call ID, native
    /// session ID) when one exists.
    public var providerIdentity: String?
    /// Provider turn identity (for example Codex `turn_id`) when one exists.
    /// Groups a turn's messages and tool activity and feeds fingerprinting.
    public var turnID: String?
    public var payload: ConversationEventPayload

    public var kind: ConversationEventKind {
        payload.kind
    }

    public init(
        conversationID: RemoteConversationID,
        sequence: UInt64,
        eventID: String,
        schemaVersion: Int = ConversationEvent.currentSchemaVersion,
        timestamp: Date,
        provider: AgentKind,
        providerIdentity: String? = nil,
        turnID: String? = nil,
        payload: ConversationEventPayload
    ) {
        self.conversationID = conversationID
        self.sequence = sequence
        self.eventID = eventID
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.provider = provider
        self.providerIdentity = providerIdentity
        self.turnID = turnID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case sequence
        case eventID
        case schemaVersion
        case timestamp
        case provider
        case providerIdentity
        case turnID
        case kind
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.conversationID = try container.decode(RemoteConversationID.self, forKey: .conversationID)
        self.sequence = try container.decode(UInt64.self, forKey: .sequence)
        self.eventID = try container.decode(String.self, forKey: .eventID)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.provider = try container.decode(AgentKind.self, forKey: .provider)
        self.providerIdentity = try container.decodeIfPresent(String.self, forKey: .providerIdentity)
        self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)

        switch try container.decode(ConversationEventKind.self, forKey: .kind) {
        case .userMessage:
            self.payload = .userMessage(try container.decode(ConversationUserMessagePayload.self, forKey: .payload))
        case .assistantMessage:
            self.payload = .assistantMessage(try container.decode(ConversationAssistantMessagePayload.self, forKey: .payload))
        case .toolStarted:
            self.payload = .toolStarted(try container.decode(ConversationToolStartedPayload.self, forKey: .payload))
        case .toolFinished:
            self.payload = .toolFinished(try container.decode(ConversationToolFinishedPayload.self, forKey: .payload))
        case .statusChanged:
            self.payload = .statusChanged(try container.decode(ConversationStatusChangedPayload.self, forKey: .payload))
        case .interactionPresented:
            self.payload = .interactionPresented(try container.decode(RemotePendingInteraction.self, forKey: .payload))
        case .interactionResolved:
            self.payload = .interactionResolved(try container.decode(ConversationInteractionResolvedPayload.self, forKey: .payload))
        case .subagentSummary:
            self.payload = .subagentSummary(try container.decode(ConversationSubagentSummaryPayload.self, forKey: .payload))
        case .sessionBindingChanged:
            self.payload = .sessionBindingChanged(try container.decode(ConversationSessionBindingChangedPayload.self, forKey: .payload))
        case .sendDeliveryUnconfirmed:
            self.payload = .sendDeliveryUnconfirmed(try container.decode(ConversationSendDeliveryUnconfirmedPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(providerIdentity, forKey: .providerIdentity)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(payload.kind, forKey: .kind)

        switch payload {
        case .userMessage(let value):
            try container.encode(value, forKey: .payload)
        case .assistantMessage(let value):
            try container.encode(value, forKey: .payload)
        case .toolStarted(let value):
            try container.encode(value, forKey: .payload)
        case .toolFinished(let value):
            try container.encode(value, forKey: .payload)
        case .statusChanged(let value):
            try container.encode(value, forKey: .payload)
        case .interactionPresented(let value):
            try container.encode(value, forKey: .payload)
        case .interactionResolved(let value):
            try container.encode(value, forKey: .payload)
        case .subagentSummary(let value):
            try container.encode(value, forKey: .payload)
        case .sessionBindingChanged(let value):
            try container.encode(value, forKey: .payload)
        case .sendDeliveryUnconfirmed(let value):
            try container.encode(value, forKey: .payload)
        }
    }
}
