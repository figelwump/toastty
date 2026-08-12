import Foundation
import RemoteProtocol

/// Outcome of an event page request.
public enum ConversationEventPageOutcome: Equatable, Sendable {
    case page(ConversationEventPage)
    /// The cursor belongs to a discarded sequence space (Toastty relaunch, or
    /// an unreconcilable provider rewrite). The client must drop its rendered
    /// transcript and reload from a fresh snapshot.
    case resnapshotRequired
    case conversationNotFound
    /// The request boundary or mutually exclusive paging fields were invalid.
    /// This is terminal for the request and must not trigger a resnapshot loop.
    case invalidRequest
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

    /// Newest retained page when `cursor` is nil, or the ascending page ending
    /// immediately before the cursor's exclusive upper boundary.
    func conversationEvents(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome
}

public extension RemoteSessionFacade {
    func conversationEvents(
        for conversationID: RemoteConversationID,
        before cursor: ConversationEventBackwardCursor?,
        limit: Int
    ) -> ConversationEventPageOutcome {
        .invalidRequest
    }
}
