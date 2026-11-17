import CoreState
import Foundation

/// The coordinator's replies to messages from outside a task.
///
/// `coordinator send` from outside a task gives its message an ID, which
/// the first line of the typed message ends with. The coordinator answers
/// the sender with `coordinator reply <message-id>`, and the sender reads
/// the text with `coordinator replies`. Each approved webhook that opted in
/// gets a `coordinator.reply` event with the IDs and the sender's name, and
/// never the text. The events wait in the replies file with their reply, so
/// one write saves both, and go out through each webhook's queue in the
/// order they happened, with the task events.
///
/// A message's ID is kept while the message waits in the coordinator's
/// queue, and for `CoordinatorReplies.keepTime` after Toastty types it. A
/// reply is kept for the same time.
extension TaskWebhookService {
    /// Keeps the ID of a message that `coordinator send` brought.
    func recordCoordinatorMessage(id: UUID, from: String?, typed: Bool) {
        let at = now()
        coordinatorReplies.recordMessage(id: id, from: from, at: at, typed: typed)
        coordinatorReplies.prune(now: at, waitingMessageIDs: waitingCoordinatorMessageIDs)
        saveCoordinatorReplies()
    }

    /// Notes that Toastty typed a message, which starts the keep time of
    /// its ID. Called for every message Toastty types; one without an ID
    /// changes nothing.
    func coordinatorTypedMessage(id: String) {
        guard let id = UUID(uuidString: id), coordinatorReplies.markTyped(id: id, at: now()) else { return }
        saveCoordinatorReplies()
    }

    /// Keeps the coordinator's reply, queues its event for each approved
    /// webhook that opted in, and saves both in one write. Returns the
    /// reply and the number of events queued.
    func addCoordinatorReply(messageID: UUID, text: String) throws -> (reply: CoordinatorReplies.Reply, webhookEvents: Int) {
        let at = now()
        var replies = coordinatorReplies
        replies.prune(now: at, waitingMessageIDs: waitingCoordinatorMessageIDs)
        let reply = try replies.addReply(messageID: messageID, text: text, at: at)
        var queued = 0
        for webhook in webhooks where webhook.coordinatorReplies && isActive(webhook) {
            let eventID = UUID()
            let payload = CoordinatorReplyWebhookPayload(eventID: eventID, occurredAt: at, webhook: webhook.name, reply: reply)
            guard let body = try? payload.encoded() else { continue }
            replies.events.append(CoordinatorReplies.Event(
                eventID: eventID, webhookID: webhook.id, replyID: reply.id, createdAt: at, body: body
            ))
            queued += 1
        }
        coordinatorReplies = replies
        saveCoordinatorReplies()
        ToasttyLog.info("The coordinator replied to a message", category: .tasks, metadata: [
            "message_id": messageID.uuidString,
            "reply_id": reply.id.uuidString,
            "webhook_events": String(queued),
        ])
        deliverDue(at: at)
        return (reply, queued)
    }

    /// The kept replies after `cursor`, or all of them without one.
    func coordinatorReplyPage(since cursor: String?, messageID: UUID?) throws -> CoordinatorReplies.Page {
        if coordinatorReplies.prune(now: now(), waitingMessageIDs: waitingCoordinatorMessageIDs) {
            saveCoordinatorReplies()
        }
        return try coordinatorReplies.page(since: cursor, messageID: messageID)
    }

    /// The messages that wait in the coordinator's queue, typed or set
    /// aside by the user's Stop, whose IDs stay kept.
    private var waitingCoordinatorMessageIDs: Set<UUID> {
        guard let coordinator else { return [] }
        return Set((coordinator.queuedEntries + coordinator.pausedEntries).compactMap { UUID(uuidString: $0.id) })
    }
}
