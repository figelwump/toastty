import CoreState
import Foundation
import RemoteProtocol

/// Lets code in the app read and send to the agent conversation in a terminal
/// panel, without a paired device and without a network hop.
///
/// The models are the ones a paired phone gets. The conversation is tracked
/// only while a subscription is held, so hold one for as long as the
/// conversation is shown or has messages waiting.
@MainActor
protocol LocalConversationAccess: AnyObject {
    /// Starts tracking the panel's conversation. The panel does not need an
    /// agent yet; the subscription reports the conversation when one starts.
    func subscribeToConversation(inPanel panelID: UUID) -> any LocalConversationSubscription
}

/// One in-app reader and sender of a panel's conversation.
@MainActor
protocol LocalConversationSubscription: AnyObject {
    var panelID: UUID { get }

    /// The panel's conversation, or `nil` while the panel has no tracked
    /// agent conversation.
    var conversationID: RemoteConversationID? { get }

    /// Yields after the conversation changed: new events, a different
    /// summary (state, input availability, queue), or a restarted event
    /// sequence. Changes are coalesced and a yield can be spurious, so read
    /// the snapshot and the pages again after each one. The stream ends when
    /// the subscription is cancelled. It has one consumer.
    var changes: AsyncStream<Void> { get }

    /// The conversation's summary and pending interactions.
    func snapshot(at date: Date) -> RemoteConversationSnapshot?

    func events(after cursor: ConversationEventCursor?, limit: Int) -> ConversationEventPageOutcome

    func events(before cursor: ConversationEventBackwardCursor?, limit: Int) -> ConversationEventPageOutcome

    /// Sends a message through the queue, steer and prompt-epoch rules of a
    /// phone send, with the Mac as the origin. `request` names the epoch the
    /// caller read from the snapshot and the delivery mode. Attachments are
    /// not supported.
    ///
    /// Pass `byUser: true` only when a person sent the message, for example
    /// from a chat composer. Other senders must not count as the user's
    /// input.
    func send(_ request: RemoteMessageSendRequest, byUser: Bool) -> RemoteMessageSendResult

    /// Stops the turn the request names by sending the agent's interrupt
    /// key, under the turn check of a phone's Stop. A person asked for it,
    /// so it counts as the user's input. Messages a phone queued for the
    /// conversation then wait until a device resumes them.
    func interrupt(_ request: RemoteConversationInterruptRequest) -> RemoteConversationInterruptResult

    /// Reopens a prompt that text typed in the terminal holds closed, after
    /// the user said that the agent's prompt holds none of their text. The
    /// request names the draft epoch from the snapshot, so a key typed in
    /// the terminal since then refuses the release. Nothing is typed.
    func releaseLocalDraft(
        _ request: RemoteConversationLocalDraftReleaseRequest
    ) -> RemoteConversationLocalDraftReleaseResult

    /// Ends the subscription. When no other subscription holds the panel,
    /// messages the Mac queued for it that still wait are dropped, and
    /// tracking of the panel stops unless Remote Access needs it.
    func cancel()
}
