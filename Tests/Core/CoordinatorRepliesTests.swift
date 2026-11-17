import CoreState
import CryptoKit
import Foundation
import RemoteProtocol
import Testing

/// The coordinator's replies to messages from outside a task: which replies
/// Toastty takes, what a cursor returns after replies expire or a relaunch,
/// how long a message's ID is kept, and what a webhook event carries.
struct CoordinatorRepliesTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func store(messages: [UUID], from: String? = "Grok Bot") -> CoordinatorReplies {
        var replies = CoordinatorReplies()
        for id in messages { replies.recordMessage(id: id, from: from, at: t0, typed: true) }
        return replies
    }

    private func refused(_ mention: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected a refusal containing \(mention)", sourceLocation: sourceLocation)
        } catch let error as CoordinatorReplyError {
            #expect(error.message.contains(mention), "\(error.message)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func aReplyNamesItsMessageAndSenderAndARefusalChangesNothing() throws {
        let message = UUID()
        var replies = store(messages: [message])
        let first = try replies.addReply(messageID: message, text: "  I asked Vishal.\n", at: t0)
        #expect(first.messageID == message)
        #expect(first.from == "Grok Bot")
        #expect(first.text == "I asked Vishal.")
        // A message can have several replies, such as the user's answer.
        let second = try replies.addReply(messageID: message, text: "Vishal said yes.", at: t0.addingTimeInterval(60))
        #expect(second.sequence == first.sequence + 1)

        let before = replies
        refused("No message has ID") { _ = try replies.addReply(messageID: UUID(), text: "Hi", at: t0) }
        refused("empty") { _ = try replies.addReply(messageID: message, text: " \n ", at: t0) }
        refused("16 KB") {
            _ = try replies.addReply(messageID: message, text: String(repeating: "é", count: CoordinatorReplies.maximumTextBytes / 2 + 1), at: t0)
        }
        #expect(replies == before)
        // Exactly the limit is taken.
        _ = try replies.addReply(messageID: message, text: String(repeating: "a", count: CoordinatorReplies.maximumTextBytes), at: t0)
    }

    @Test func aCursorReturnsOnlyNewerRepliesAlsoAfterARelaunchAndAfterEveryReplyExpired() throws {
        let grok = UUID()
        let other = UUID()
        var replies = store(messages: [grok, other])
        _ = try replies.addReply(messageID: grok, text: "one", at: t0)
        let start = try replies.page(since: nil, messageID: nil)
        #expect(start.replies.map(\.text) == ["one"])
        #expect(start.truncated == false)
        _ = try replies.addReply(messageID: other, text: "two", at: t0)
        _ = try replies.addReply(messageID: grok, text: "three", at: t0)

        let next = try replies.page(since: start.cursor, messageID: nil)
        #expect(next.replies.map(\.text) == ["two", "three"])
        #expect(next.truncated == false)
        #expect(try replies.page(since: start.cursor, messageID: grok).replies.map(\.text) == ["three"])
        #expect(try replies.page(since: next.cursor, messageID: nil).replies.isEmpty)

        // A relaunch reads the store back from its file.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        replies = try decoder.decode(CoordinatorReplies.self, from: encoder.encode(replies))
        #expect(try replies.page(since: next.cursor, messageID: nil).replies.isEmpty)

        // Every reply expires. A reader that saw them all missed nothing,
        // and the next reply comes after its cursor.
        let pruned = replies.prune(now: t0.addingTimeInterval(8 * day), waitingMessageIDs: [])
        #expect(pruned)
        let empty = try replies.page(since: next.cursor, messageID: nil)
        #expect(empty.replies.isEmpty)
        #expect(empty.truncated == false)
        replies.recordMessage(id: grok, from: "Grok Bot", at: t0.addingTimeInterval(8 * day), typed: true)
        _ = try replies.addReply(messageID: grok, text: "four", at: t0.addingTimeInterval(8 * day))
        let later = try replies.page(since: next.cursor, messageID: nil)
        #expect(later.replies.map(\.text) == ["four"])
        #expect(later.truncated == false)

        // A reader that had not seen "two" and "three" is told they are gone.
        let behind = try replies.page(since: start.cursor, messageID: nil)
        #expect(behind.replies.map(\.text) == ["four"])
        #expect(behind.truncated)

        // A cursor from another store, as after the file was removed, gets
        // every kept reply. Text that is not a cursor is refused.
        let fresh = CoordinatorReplies()
        let elsewhere = try replies.page(since: try fresh.page(since: nil, messageID: nil).cursor, messageID: nil)
        #expect(elsewhere.replies.map(\.text) == ["four"])
        #expect(elsewhere.truncated)
        for bad in ["", "7", "not-a-cursor", "\(UUID().uuidString):-1", "\(UUID().uuidString):x"] {
            refused("cursor") { _ = try replies.page(since: bad, messageID: nil) }
        }
    }

    @Test func aMessageIDIsKeptWhileItWaitsAndForSevenDaysAfterItIsTyped() throws {
        let waiting = UUID()
        let typedLate = UUID()
        let typedEarly = UUID()
        let dropped = UUID()
        var replies = CoordinatorReplies()
        for id in [waiting, typedLate, typedEarly, dropped] {
            replies.recordMessage(id: id, from: nil, at: t0, typed: false)
        }
        // One message is typed at once, one after it waited 6 days. One
        // left the queue untyped, as when the user removed it.
        let typedAtOnce = replies.markTyped(id: typedEarly, at: t0)
        let typedAfterAWait = replies.markTyped(id: typedLate, at: t0.addingTimeInterval(6 * day))
        let typedAgain = replies.markTyped(id: typedLate, at: t0.addingTimeInterval(7 * day))
        #expect(typedAtOnce)
        #expect(typedAfterAWait)
        #expect(typedAgain == false)

        replies.prune(now: t0.addingTimeInterval(8 * day), waitingMessageIDs: [waiting])
        #expect(replies.message(id: waiting) != nil)
        #expect(replies.message(id: typedLate) != nil)
        #expect(replies.message(id: typedEarly) == nil)
        #expect(replies.message(id: dropped) == nil)
        _ = try replies.addReply(messageID: typedLate, text: "Answered late.", at: t0.addingTimeInterval(8 * day))
        refused("older than 7 days") { _ = try replies.addReply(messageID: typedEarly, text: "Too late.", at: t0.addingTimeInterval(8 * day)) }
    }

    @Test func theWebhookEventNamesTheReplyAndNeverCarriesItsText() throws {
        let message = UUID()
        var replies = store(messages: [message])
        let reply = try replies.addReply(messageID: message, text: "The bera symlinks point at the old volume.", at: t0)
        let eventID = UUID()
        let body = try CoordinatorReplyWebhookPayload(eventID: eventID, occurredAt: t0, webhook: "grok", reply: reply).encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["type"] as? String == "coordinator.reply")
        #expect(json["version"] as? Int == 1)
        #expect(json["eventID"] as? String == eventID.uuidString)
        #expect(json["webhook"] as? String == "grok")
        #expect(json["task"] == nil)
        let object = try #require(json["reply"] as? [String: Any])
        #expect(Set(object.keys) == ["id", "messageID", "from"])
        #expect(object["id"] as? String == reply.id.uuidString)
        #expect(object["messageID"] as? String == message.uuidString)
        #expect(object["from"] as? String == "Grok Bot")
        #expect(String(decoding: body, as: UTF8.self).contains("bera") == false)

        // A sender that gave no name: the key stays, as null.
        var unnamed = store(messages: [message], from: nil)
        let anonymous = try unnamed.addReply(messageID: message, text: "Done.", at: t0)
        let anonymousJSON = try #require(try JSONSerialization.jsonObject(
            with: CoordinatorReplyWebhookPayload(eventID: UUID(), occurredAt: t0, webhook: "grok", reply: anonymous).encoded()
        ) as? [String: Any])
        #expect((anonymousJSON["reply"] as? [String: Any])?["from"] is NSNull)
    }

    // MARK: - The webhook's opt-in

    @Test func aWebhookSavedBeforeRepliesKeepsItsApprovalAndOptsInOnlyWhenAsked() throws {
        let webhook = TaskWebhook(
            name: "grok", url: "https://hooks.example.com/w", auth: .bearer,
            requestedAt: t0, requestedBy: .init()
        )
        // The digest of a webhook without replies is the one the user
        // approved before Toastty had them.
        struct EarlierApproved: Encodable {
            var version = 1
            var url: String
            var events: [String]
            var roots: [String]
            var externalRefPrefix: String?
            var auth: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let earlier = try encoder.encode(EarlierApproved(
            url: webhook.url, events: webhook.events.map(\.rawValue).sorted(), roots: [], auth: "bearer"
        ))
        let earlierDigest = SHA256.hash(data: earlier).map { String(format: "%02x", $0) }.joined()
        #expect(webhook.settingsDigest == earlierDigest)

        var withReplies = webhook
        withReplies.coordinatorReplies = true
        #expect(withReplies.settingsDigest != webhook.settingsDigest)
        #expect(withReplies.eventNames == ["needs_you", "merged", "done", "archived", "deleted", "coordinator_reply"])
        #expect(withReplies.eventTitles.last == "Coordinator replies")

        // A webhook saved before has no key for it, and reads as without.
        let fileEncoder = JSONEncoder()
        fileEncoder.dateEncodingStrategy = .iso8601
        var saved = try #require(try JSONSerialization.jsonObject(with: fileEncoder.encode(withReplies)) as? [String: Any])
        #expect(saved["coordinatorReplies"] as? Bool == true)
        saved["coordinatorReplies"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let earlierFile = try decoder.decode(TaskWebhook.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(earlierFile == webhook)
        #expect(try decoder.decode(TaskWebhook.self, from: fileEncoder.encode(withReplies)) == withReplies)
    }
}
