import Foundation

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

/// One conversation row in the session list.
public struct RemoteConversationSummary: Codable, Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var provider: AgentKind
    public var title: String
    public var placement: RemoteConversationPlacement
    public var cwd: String?
    public var state: RemoteSessionState
    public var inputAvailability: RemoteInputAvailability
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
        state: RemoteSessionState,
        inputAvailability: RemoteInputAvailability,
        projectionGeneration: UInt64 = 0,
        latestSequence: UInt64,
        updatedAt: Date
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.title = title
        self.placement = placement
        self.cwd = cwd
        self.state = state
        self.inputAvailability = inputAvailability
        self.projectionGeneration = projectionGeneration
        self.latestSequence = latestSequence
        self.updatedAt = updatedAt
    }
}

/// Full point-in-time view of the session list. Snapshot and subscription share
/// one sequence space per conversation, anchored by `projectionRunID`.
public struct RemoteSessionListSnapshot: Codable, Equatable, Sendable {
    public var projectionRunID: RemoteProjectionRunID
    public var conversations: [RemoteConversationSummary]
    public var generatedAt: Date

    public init(
        projectionRunID: RemoteProjectionRunID,
        conversations: [RemoteConversationSummary],
        generatedAt: Date
    ) {
        self.projectionRunID = projectionRunID
        self.conversations = conversations
        self.generatedAt = generatedAt
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

/// Outcome of an event page request.
public enum ConversationEventPageOutcome: Equatable, Sendable {
    case page(ConversationEventPage)
    /// The cursor belongs to a discarded sequence space (Toastty relaunch, or
    /// an unreconcilable provider rewrite). The client must drop its rendered
    /// transcript and reload from a fresh snapshot.
    case resnapshotRequired
    case conversationNotFound
}

/// Protocol-facing read surface over the rebuildable projection.
///
/// This is the only contract remote transports may depend on; they never see
/// provider JSONL, terminal frames, or UI state. Implementations are expected
/// to be main-actor bound host services; the Foundation-phase implementation is
/// a pure in-memory store driven by provider fixtures.
public protocol RemoteSessionFacade {
    /// Current session list, organized for workspace/panel navigation.
    func sessionList(at date: Date) -> RemoteSessionListSnapshot

    /// Detail snapshot for one conversation, or nil when unknown.
    func conversationSnapshot(for conversationID: RemoteConversationID, at date: Date) -> RemoteConversationSnapshot?

    /// Ordered events after a cursor. Passing a nil cursor pages from the
    /// beginning of the current projection run.
    func conversationEvents(
        for conversationID: RemoteConversationID,
        after cursor: ConversationEventCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome
}
