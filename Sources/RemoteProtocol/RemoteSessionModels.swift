import Foundation

/// Shared wire hygiene for short user-visible preview strings. The wire
/// models remain responsible for their own length and optionality semantics;
/// this helper only centralizes grapheme-safe bounding and scalar filtering.
private enum RemoteWirePreviewText {
    static func sanitized(_ value: String, maximumGraphemeCount: Int) -> String {
        String(
            value.filter { character in
                character.unicodeScalars.allSatisfy(isAllowedScalar)
            }
                .prefix(maximumGraphemeCount)
        )
    }

    /// Reject C0/C1 controls plus formatting scalars that can make a short
    /// preview visually misleading. ZWJ, ZWNJ, and variation selectors remain
    /// allowed because they are valid parts of user-visible text and emoji.
    private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F,
             0x007F...0x009F,
             0x00AD,
             0x200B,
             0x200E...0x200F,
             0x202A...0x202E,
             0x2060,
             0x2066...0x2069,
             0xFEFF:
            false
        default:
            true
        }
    }
}

/// Small, explicitly bounded reason text for a needs-attention card. Full
/// provider prompts remain available only in the conversation projection.
public struct RemotePendingInteractionPreview: Codable, Equatable, Sendable {
    public static let maximumPromptLength = 240

    public var prompt: String

    public init(prompt: String) {
        self.prompt = RemoteWirePreviewText.sanitized(
            prompt,
            maximumGraphemeCount: Self.maximumPromptLength
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let prompt = try container.decode(String.self, forKey: .prompt)
        guard prompt == RemoteWirePreviewText.sanitized(
            prompt,
            maximumGraphemeCount: Self.maximumPromptLength
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .prompt,
                in: container,
                debugDescription: "Pending-interaction preview exceeds its wire bound"
            )
        }
        self.prompt = prompt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
    }
}

/// Where a conversation lives inside Toastty's organization, for the phone's
/// workspace/panel navigation. Optional because a conversation can outlive its
/// panel (for example after a workspace layout change while offline).
public struct RemoteConversationPlacement: Codable, Equatable, Sendable {
    public var workspaceID: UUID?
    public var workspaceTitle: String?
    public var panelID: UUID?

    public init(workspaceID: UUID? = nil, workspaceTitle: String? = nil, panelID: UUID? = nil) {
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.panelID = panelID
    }
}

/// Toastty's exact desktop presentation state for a session row. This is
/// intentionally independent of `RemoteSessionState`, which describes the
/// provider lifecycle and remote-input contract rather than the state shown in
/// Toastty's workspace UI.
public enum RemoteSessionPresentationStatus: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case working
    case needsApproval = "needs_approval"
    case ready
    case error
}

/// The latest model and reasoning values reported by the conversation's
/// provider. These are display metadata, never defaults or input authority.
public struct RemoteSessionExecutionProfile: Codable, Equatable, Sendable {
    public let modelIdentifier: String?
    public let reasoningEffort: String?

    public init(modelIdentifier: String? = nil, reasoningEffort: String? = nil) {
        self.modelIdentifier = Self.normalizedValue(modelIdentifier, limit: 200)
        self.reasoningEffort = Self.normalizedValue(reasoningEffort, limit: 80)
    }

    public var isEmpty: Bool { modelIdentifier == nil && reasoningEffort == nil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modelIdentifier: try container.decodeIfPresent(String.self, forKey: .modelIdentifier),
            reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        )
    }

    private static func normalizedValue(_ value: String?, limit: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value == RemoteWirePreviewText.sanitized(value, maximumGraphemeCount: limit) else {
            return nil
        }
        // Reject invalid or overlong identifiers rather than showing a
        // shortened string that could name a different provider model.
        return value
    }
}

/// One conversation row in the session list.
public struct RemoteConversationSummary: Codable, Equatable, Sendable {
    public static let maximumStatusDetailLength = 240

    public var conversationID: RemoteConversationID
    public var provider: AgentKind
    public var title: String
    public var placement: RemoteConversationPlacement
    public var cwd: String?
    private var storedExecutionProfile: RemoteSessionExecutionProfile?
    public var executionProfile: RemoteSessionExecutionProfile? {
        get { storedExecutionProfile }
        set { storedExecutionProfile = newValue?.isEmpty == false ? newValue : nil }
    }
    public var state: RemoteSessionState
    /// Exact desktop status when the host can associate this conversation with
    /// a panel. Optional so older encoded snapshots and status-less panels keep
    /// their existing wire representation and clients can fall back to the
    /// provider lifecycle.
    public var presentationStatus: RemoteSessionPresentationStatus?
    /// The same user-visible status detail shown by Toastty's desktop session
    /// row, bounded for list snapshots. Optional for compatibility with older
    /// hosts and for statuses without meaningful detail.
    private var storedStatusDetail: String?
    public var statusDetail: String? {
        get { storedStatusDetail }
        set { storedStatusDetail = Self.normalizedStatusDetail(newValue) }
    }
    public var inputAvailability: RemoteInputAvailability
    public var pendingInteractionPreview: RemotePendingInteractionPreview?
    /// Generation of this conversation's sequence space within the current
    /// projection run. Bumped when this one conversation is rebuilt mid-run
    /// (for example after an unreconcilable provider file rewrite) so its
    /// cursors invalidate without disturbing other conversations.
    public var projectionGeneration: UInt64
    /// Highest event sequence currently in the projection for this
    /// conversation, so a client can tell whether it is caught up.
    public var latestSequence: UInt64
    public var updatedAt: Date

    public init(
        conversationID: RemoteConversationID,
        provider: AgentKind,
        title: String,
        placement: RemoteConversationPlacement = RemoteConversationPlacement(),
        cwd: String? = nil,
        executionProfile: RemoteSessionExecutionProfile? = nil,
        state: RemoteSessionState,
        presentationStatus: RemoteSessionPresentationStatus? = nil,
        statusDetail: String? = nil,
        inputAvailability: RemoteInputAvailability,
        pendingInteractionPreview: RemotePendingInteractionPreview? = nil,
        projectionGeneration: UInt64 = 0,
        latestSequence: UInt64,
        updatedAt: Date
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.title = title
        self.placement = placement
        self.cwd = cwd
        self.storedExecutionProfile = executionProfile?.isEmpty == false ? executionProfile : nil
        self.state = state
        self.presentationStatus = presentationStatus
        self.storedStatusDetail = Self.normalizedStatusDetail(statusDetail)
        self.inputAvailability = inputAvailability
        self.pendingInteractionPreview = pendingInteractionPreview
        self.projectionGeneration = projectionGeneration
        self.latestSequence = latestSequence
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            conversationID: try container.decode(RemoteConversationID.self, forKey: .conversationID),
            provider: try container.decode(AgentKind.self, forKey: .provider),
            title: try container.decode(String.self, forKey: .title),
            placement: try container.decode(RemoteConversationPlacement.self, forKey: .placement),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            executionProfile: try container.decodeIfPresent(RemoteSessionExecutionProfile.self, forKey: .executionProfile),
            state: try container.decode(RemoteSessionState.self, forKey: .state),
            presentationStatus: try container.decodeIfPresent(
                RemoteSessionPresentationStatus.self,
                forKey: .presentationStatus
            ),
            statusDetail: try container.decodeIfPresent(String.self, forKey: .statusDetail),
            inputAvailability: try container.decode(RemoteInputAvailability.self, forKey: .inputAvailability),
            pendingInteractionPreview: try container.decodeIfPresent(
                RemotePendingInteractionPreview.self,
                forKey: .pendingInteractionPreview
            ),
            projectionGeneration: try container.decode(UInt64.self, forKey: .projectionGeneration),
            latestSequence: try container.decode(UInt64.self, forKey: .latestSequence),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(provider, forKey: .provider)
        try container.encode(title, forKey: .title)
        try container.encode(placement, forKey: .placement)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(executionProfile, forKey: .executionProfile)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(presentationStatus, forKey: .presentationStatus)
        try container.encodeIfPresent(statusDetail, forKey: .statusDetail)
        try container.encode(inputAvailability, forKey: .inputAvailability)
        try container.encodeIfPresent(pendingInteractionPreview, forKey: .pendingInteractionPreview)
        try container.encode(projectionGeneration, forKey: .projectionGeneration)
        try container.encode(latestSequence, forKey: .latestSequence)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Normalizes status detail at the host/client boundary while keeping its
    /// JSON representation an ordinary optional string.
    public static func normalizedStatusDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = RemoteWirePreviewText.sanitized(
            trimmed,
            maximumGraphemeCount: maximumStatusDetailLength
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case provider
        case title
        case placement
        case cwd
        case executionProfile
        case state
        case presentationStatus
        case statusDetail
        case inputAvailability
        case pendingInteractionPreview
        case projectionGeneration
        case latestSequence
        case updatedAt
    }
}

/// Full point-in-time view of the session list. Snapshot and subscription share
/// one sequence space per conversation, anchored by `projectionRunID`.
public struct RemoteSessionListSnapshot: Codable, Equatable, Sendable {
    public var projectionRunID: RemoteProjectionRunID
    public var conversations: [RemoteConversationSummary]
    public var generatedAt: Date
    public var workspaces: [RemoteWorkspaceSummary]

    public init(projectionRunID: RemoteProjectionRunID, conversations: [RemoteConversationSummary],
                generatedAt: Date, workspaces: [RemoteWorkspaceSummary] = []) {
        self.projectionRunID = projectionRunID
        self.conversations = conversations
        self.generatedAt = generatedAt
        self.workspaces = workspaces
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectionRunID, forKey: .projectionRunID)
        try container.encode(conversations, forKey: .conversations)
        try container.encode(generatedAt, forKey: .generatedAt)
        if !workspaces.isEmpty { try container.encode(workspaces, forKey: .workspaces) }
    }
    private enum CodingKeys: String, CodingKey { case projectionRunID, conversations, generatedAt, workspaces }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectionRunID = try container.decode(RemoteProjectionRunID.self, forKey: .projectionRunID)
        conversations = try container.decode([RemoteConversationSummary].self, forKey: .conversations)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        workspaces = try container.decodeIfPresent([RemoteWorkspaceSummary].self, forKey: .workspaces) ?? []
    }
}

/// Detail snapshot for one conversation, including its pending interactions.
public struct RemoteConversationSnapshot: Codable, Equatable, Sendable {
    public var summary: RemoteConversationSummary
    public var pendingInteractions: [RemotePendingInteraction]

    public init(summary: RemoteConversationSummary, pendingInteractions: [RemotePendingInteraction]) {
        self.summary = summary
        self.pendingInteractions = pendingInteractions
    }
}

/// Client cursor into one conversation's event stream. A cursor is valid only
/// while both the projection run and that conversation's generation match; any
/// mismatch yields `resnapshotRequired`.
public struct ConversationEventCursor: Codable, Equatable, Sendable {
    public var projectionRunID: RemoteProjectionRunID
    public var projectionGeneration: UInt64
    public var afterSequence: UInt64

    public init(
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        afterSequence: UInt64
    ) {
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.afterSequence = afterSequence
    }
}

public struct ConversationEventPage: Codable, Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var projectionRunID: RemoteProjectionRunID
    public var projectionGeneration: UInt64
    public var events: [ConversationEvent]
    /// Highest sequence in the projection at page time; when the last returned
    /// event is below this, more pages are available.
    public var latestSequence: UInt64
    /// Oldest sequence retained by the bounded in-memory projection. Optional
    /// for wire compatibility with v0.5 clients.
    public var firstAvailableSequence: UInt64?
    /// True when earlier events have aged out of the projection cache.
    public var historyTruncated: Bool?

    public init(
        conversationID: RemoteConversationID,
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        events: [ConversationEvent],
        latestSequence: UInt64,
        firstAvailableSequence: UInt64? = nil,
        historyTruncated: Bool? = nil
    ) {
        self.conversationID = conversationID
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.events = events
        self.latestSequence = latestSequence
        self.firstAvailableSequence = firstAvailableSequence
        self.historyTruncated = historyTruncated
    }

    public var hasMore: Bool {
        guard let last = events.last else { return false }
        return last.sequence < latestSequence
    }

    /// The cursor a client should present for the page after this one.
    public var continuationCursor: ConversationEventCursor? {
        guard let last = events.last else { return nil }
        return ConversationEventCursor(
            projectionRunID: projectionRunID,
            projectionGeneration: projectionGeneration,
            afterSequence: last.sequence
        )
    }
}
