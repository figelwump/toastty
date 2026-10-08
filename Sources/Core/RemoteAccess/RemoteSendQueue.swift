import Foundation
import RemoteProtocol

/// Messages a remote client asked the Mac to hold while the agent works.
///
/// Toastty owns this queue rather than relying on each provider's own
/// type-ahead queue: Claude and Codex queue differently, their queues live
/// inside the terminal where the host cannot read or edit them, and they are
/// lost when the agent restarts. Here each entry is delivered as an ordinary
/// prompt send through the same open-prompt gate as a live send, one entry per
/// open prompt, so the Mac user's own draft is never typed over.
///
/// Pure value type; the host serializes access on the main actor.
public struct RemoteSendQueue: Sendable {
    public struct Entry: Equatable, Sendable {
        public var request: RemoteMessageSendRequest
        /// The device that queued it. Re-checked at delivery so a device that
        /// lost send scope or was revoked in the meantime delivers nothing.
        public var deviceID: UUID
        /// The runtime binding the client queued against. An entry never
        /// outlives its binding: a resumed or relaunched runtime is a
        /// different conversation as far as queued text is concerned.
        public var bindingID: UUID
        /// Attachment-expanded text staged at enqueue time, when present.
        public var deliveredText: String?
        public var enqueuedAt: Date

        public init(
            request: RemoteMessageSendRequest,
            deviceID: UUID,
            bindingID: UUID,
            deliveredText: String? = nil,
            enqueuedAt: Date
        ) {
            self.request = request
            self.deviceID = deviceID
            self.bindingID = bindingID
            self.deliveredText = deliveredText
            self.enqueuedAt = enqueuedAt
        }

        public var clientRequestID: String { request.clientRequestID }

        public var queuedMessage: RemoteQueuedMessage {
            RemoteQueuedMessage(
                clientRequestID: request.clientRequestID,
                text: request.text,
                attachmentCount: request.attachments.count,
                enqueuedAt: enqueuedAt
            )
        }
    }

    public enum EnqueueOutcome: Equatable, Sendable {
        /// 1-based delivery position.
        case queued(position: Int)
        /// The same `clientRequestID` is already waiting, or already left the
        /// queue (delivered, removed, or expired); a reconnect retry must not
        /// queue it a second time.
        case duplicate(position: Int?)
        case full
    }

    public static let capacity = RemoteConversationInputControl.maximumQueuedMessages
    /// Bounded memory of request IDs that left the queue, per conversation.
    public static let retiredCapacityPerConversation = 64

    private var entriesByConversationID: [RemoteConversationID: [Entry]] = [:]
    private var pausedConversationIDs: Set<RemoteConversationID> = []
    private var retiredRequestIDsByConversationID: [RemoteConversationID: [String]] = [:]

    public init() {}

    public var conversationIDs: Set<RemoteConversationID> {
        Set(entriesByConversationID.keys)
    }

    public func entries(for conversationID: RemoteConversationID) -> [Entry] {
        entriesByConversationID[conversationID] ?? []
    }

    public func isPaused(for conversationID: RemoteConversationID) -> Bool {
        pausedConversationIDs.contains(conversationID)
    }

    /// The entry to deliver at the next open prompt, or nil while the queue
    /// is empty or paused.
    public func next(for conversationID: RemoteConversationID) -> Entry? {
        guard pausedConversationIDs.contains(conversationID) == false else { return nil }
        return entriesByConversationID[conversationID]?.first
    }

    public mutating func enqueue(_ entry: Entry) -> EnqueueOutcome {
        let conversationID = entry.request.conversationID
        var entries = entriesByConversationID[conversationID] ?? []
        if let index = entries.firstIndex(where: { $0.clientRequestID == entry.clientRequestID }) {
            return .duplicate(position: index + 1)
        }
        if retiredRequestIDsByConversationID[conversationID]?.contains(entry.clientRequestID) == true {
            return .duplicate(position: nil)
        }
        guard entries.count < Self.capacity else { return .full }
        entries.append(entry)
        entriesByConversationID[conversationID] = entries
        return .queued(position: entries.count)
    }

    @discardableResult
    public mutating func remove(
        clientRequestID: String,
        for conversationID: RemoteConversationID
    ) -> Entry? {
        guard var entries = entriesByConversationID[conversationID],
              let index = entries.firstIndex(where: { $0.clientRequestID == clientRequestID }) else {
            return nil
        }
        let removed = entries.remove(at: index)
        retire(removed.clientRequestID, for: conversationID)
        store(entries, for: conversationID)
        return removed
    }

    @discardableResult
    public mutating func removeFirst(for conversationID: RemoteConversationID) -> Entry? {
        guard var entries = entriesByConversationID[conversationID], entries.isEmpty == false else {
            return nil
        }
        let removed = entries.removeFirst()
        retire(removed.clientRequestID, for: conversationID)
        store(entries, for: conversationID)
        return removed
    }

    @discardableResult
    public mutating func removeAll(for conversationID: RemoteConversationID) -> [Entry] {
        pausedConversationIDs.remove(conversationID)
        let removed = entriesByConversationID.removeValue(forKey: conversationID) ?? []
        for entry in removed { retire(entry.clientRequestID, for: conversationID) }
        return removed
    }

    /// Drops every entry queued against a binding other than `bindingID`.
    @discardableResult
    public mutating func removeAll(
        for conversationID: RemoteConversationID,
        notMatchingBindingID bindingID: UUID
    ) -> [Entry] {
        guard let entries = entriesByConversationID[conversationID] else { return [] }
        let stale = entries.filter { $0.bindingID != bindingID }
        guard stale.isEmpty == false else { return [] }
        for entry in stale { retire(entry.clientRequestID, for: conversationID) }
        store(entries.filter { $0.bindingID == bindingID }, for: conversationID)
        return stale
    }

    /// Forgets a conversation entirely, including its retired IDs.
    public mutating func removeConversation(_ conversationID: RemoteConversationID) {
        entriesByConversationID.removeValue(forKey: conversationID)
        pausedConversationIDs.remove(conversationID)
        retiredRequestIDsByConversationID.removeValue(forKey: conversationID)
    }

    /// Holds delivery after the user stopped a turn. An empty queue is never
    /// paused: a message queued after the stop is meant to go next.
    @discardableResult
    public mutating func pause(_ conversationID: RemoteConversationID) -> Bool {
        guard entriesByConversationID[conversationID]?.isEmpty == false else { return false }
        return pausedConversationIDs.insert(conversationID).inserted
    }

    @discardableResult
    public mutating func resume(_ conversationID: RemoteConversationID) -> Bool {
        pausedConversationIDs.remove(conversationID) != nil
    }

    public func inputControlQueue(
        for conversationID: RemoteConversationID
    ) -> (queuedMessages: [RemoteQueuedMessage], isPaused: Bool) {
        (entries(for: conversationID).map(\.queuedMessage), isPaused(for: conversationID))
    }

    private mutating func retire(_ clientRequestID: String, for conversationID: RemoteConversationID) {
        var retired = retiredRequestIDsByConversationID[conversationID] ?? []
        retired.append(clientRequestID)
        if retired.count > Self.retiredCapacityPerConversation {
            retired.removeFirst(retired.count - Self.retiredCapacityPerConversation)
        }
        retiredRequestIDsByConversationID[conversationID] = retired
    }

    private mutating func store(_ entries: [Entry], for conversationID: RemoteConversationID) {
        if entries.isEmpty {
            entriesByConversationID.removeValue(forKey: conversationID)
            pausedConversationIDs.remove(conversationID)
        } else {
            entriesByConversationID[conversationID] = entries
        }
    }
}
