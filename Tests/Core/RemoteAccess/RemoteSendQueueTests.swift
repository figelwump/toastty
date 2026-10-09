import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct RemoteSendQueueTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "a1a1a1a1-0000-4000-8000-000000000001")!)
    static let bindingID = UUID(uuidString: "a1a1a1a1-0000-4000-8000-0000000000b1")!
    static let deviceID = UUID(uuidString: "a1a1a1a1-0000-4000-8000-0000000000d1")!
    static let enqueuedAt = Date(timeIntervalSince1970: 1_786_000_000)

    static func entry(
        _ id: String,
        text: String = "ship it",
        bindingID: UUID = bindingID,
        attachments: [RemoteMessageAttachment] = []
    ) -> RemoteSendQueue.Entry {
        RemoteSendQueue.Entry(
            request: RemoteMessageSendRequest(
                conversationID: conversationID,
                clientRequestID: id,
                expectedInputEpoch: RemoteInputEpoch(bindingID: bindingID, counter: 3),
                text: text,
                attachments: attachments,
                deliveryMode: .queue
            ),
            deviceID: deviceID,
            bindingID: bindingID,
            enqueuedAt: enqueuedAt
        )
    }

    @Test func entriesDeliverInOrderAndReportPositions() {
        var queue = RemoteSendQueue()
        #expect(queue.enqueue(Self.entry("one")) == .queued(position: 1))
        #expect(queue.enqueue(Self.entry("two")) == .queued(position: 2))
        #expect(queue.next(for: Self.conversationID)?.clientRequestID == "one")
        #expect(queue.removeFirst(for: Self.conversationID)?.clientRequestID == "one")
        #expect(queue.next(for: Self.conversationID)?.clientRequestID == "two")
        #expect(queue.inputControlQueue(for: Self.conversationID).queuedMessages.map(\.clientRequestID) == ["two"])
    }

    @Test func capacityIsBounded() {
        var queue = RemoteSendQueue()
        for index in 1...RemoteSendQueue.capacity {
            #expect(queue.enqueue(Self.entry("req-\(index)")) == .queued(position: index))
        }
        #expect(queue.enqueue(Self.entry("overflow")) == .full)
        #expect(queue.entries(for: Self.conversationID).count == RemoteSendQueue.capacity)
    }

    @Test func retryOfAWaitingOrRetiredRequestNeverQueuesTwice() {
        var queue = RemoteSendQueue()
        #expect(queue.enqueue(Self.entry("one")) == .queued(position: 1))
        #expect(queue.enqueue(Self.entry("one", text: "edited")) == .duplicate(position: 1))
        #expect(queue.entries(for: Self.conversationID).map(\.request.text) == ["ship it"])

        #expect(queue.remove(clientRequestID: "one", for: Self.conversationID) != nil)
        // The phone's reconnect retry after the removal must not resurrect it.
        #expect(queue.enqueue(Self.entry("one")) == .duplicate(position: nil))
        #expect(queue.entries(for: Self.conversationID).isEmpty)
    }

    @Test func pauseHoldsDeliveryUntilResumedAndOnlyWhileNonEmpty() {
        var queue = RemoteSendQueue()
        #expect(queue.pause(Self.conversationID) == false)
        #expect(queue.enqueue(Self.entry("one")) == .queued(position: 1))
        #expect(queue.pause(Self.conversationID) == true)
        #expect(queue.isPaused(for: Self.conversationID))
        #expect(queue.next(for: Self.conversationID) == nil)
        #expect(queue.inputControlQueue(for: Self.conversationID).isPaused)
        #expect(queue.resume(Self.conversationID) == true)
        #expect(queue.resume(Self.conversationID) == false)
        #expect(queue.next(for: Self.conversationID)?.clientRequestID == "one")

        // Emptying the queue also drops the pause, so the next queued message
        // is not held by a stop the user made earlier.
        #expect(queue.pause(Self.conversationID) == true)
        #expect(queue.remove(clientRequestID: "one", for: Self.conversationID) != nil)
        #expect(queue.isPaused(for: Self.conversationID) == false)
    }

    @Test func entriesFromAnotherBindingExpireTogether() {
        var queue = RemoteSendQueue()
        let otherBinding = UUID()
        #expect(queue.enqueue(Self.entry("old-1", bindingID: otherBinding)) == .queued(position: 1))
        #expect(queue.enqueue(Self.entry("current", bindingID: Self.bindingID)) == .queued(position: 2))
        #expect(queue.enqueue(Self.entry("old-2", bindingID: otherBinding)) == .queued(position: 3))

        let stale = queue.removeAll(for: Self.conversationID, notMatchingBindingID: Self.bindingID)
        #expect(stale.map(\.clientRequestID) == ["old-1", "old-2"])
        #expect(queue.entries(for: Self.conversationID).map(\.clientRequestID) == ["current"])
        #expect(queue.removeAll(for: Self.conversationID, notMatchingBindingID: Self.bindingID).isEmpty)
        #expect(queue.enqueue(Self.entry("old-1", bindingID: otherBinding)) == .duplicate(position: nil))
    }

    @Test func queuedMessageCarriesPlainTextAndAttachmentCount() throws {
        let attachment = RemoteMessageAttachment(filename: "shot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        var queue = RemoteSendQueue()
        _ = queue.enqueue(Self.entry("with-file", text: "Look at this", attachments: [attachment]))
        let message = try #require(queue.inputControlQueue(for: Self.conversationID).queuedMessages.first)
        #expect(message.text == "Look at this")
        #expect(message.attachmentCount == 1)
        #expect(message.enqueuedAt == Self.enqueuedAt)
    }

    @Test func removingAConversationForgetsRetiredIDs() {
        var queue = RemoteSendQueue()
        _ = queue.enqueue(Self.entry("one"))
        _ = queue.removeAll(for: Self.conversationID)
        #expect(queue.enqueue(Self.entry("one")) == .duplicate(position: nil))
        queue.removeConversation(Self.conversationID)
        #expect(queue.enqueue(Self.entry("one")) == .queued(position: 1))
        #expect(queue.conversationIDs == [Self.conversationID])
    }
}
