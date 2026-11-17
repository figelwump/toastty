import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// The coordinator's replies to a caller outside Toastty, as Grok Bot uses
/// them: `coordinator.send` gives the message an ID, the coordinator's own
/// agent replies with `coordinator.reply`, the caller reads the text with
/// `coordinator.replies`, and a webhook that opted in gets a
/// `coordinator.reply` event without the text. The real controller, store
/// and event service, with a fake terminal, clock and HTTP transport.
@MainActor
struct CoordinatorRepliesAppControlTests {
    typealias Fixture = CoordinatorControllerTests.Fixture

    private let task = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Answers each request with `statusCode`, and keeps what was sent.
    private final class Transport: TaskWebhookTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(url: URL?, body: Data)] = []
        private var code = 200
        var statusCode: Int {
            get { lock.withLock { code } }
            set { lock.withLock { code = newValue } }
        }
        var requests: [(url: URL?, body: Data)] { lock.withLock { sent } }
        var types: [String] {
            requests.compactMap { ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any])?["type"] as? String }
        }
        func send(_ request: URLRequest) async -> TaskWebhookSendResult {
            lock.withLock {
                sent.append((request.url, request.httpBody ?? Data()))
                return TaskWebhookSendResult(statusCode: code)
            }
        }
    }

    private struct Files {
        let directory = FileManager.default.temporaryDirectory.appending(path: "toastty-replies-\(UUID().uuidString)")
        var webhooks: URL { directory.appending(path: "task-webhooks.json") }
        var outbox: URL { directory.appending(path: "task-webhook-outbox.json") }
        var replies: URL { directory.appending(path: "coordinator-replies.json") }
    }

    private final class States {
        var value: [UUID: TaskWebhookTaskState] = [:]
    }

    /// The event service as an app launch makes it, over `files`, with the
    /// fixture's coordinator, reached by the executor as in the app.
    private func makeService(
        _ fixture: Fixture,
        files: Files,
        clock: Clock,
        transport: Transport,
        secrets: InMemoryTaskWebhookSecretStore,
        states: States = States()
    ) -> TaskWebhookService {
        let service = TaskWebhookService(
            webhooksFileURL: files.webhooks,
            outboxFileURL: files.outbox,
            coordinatorRepliesFileURL: files.replies,
            secrets: secrets,
            transport: transport,
            now: { clock.now },
            timing: .init(passInterval: .seconds(3600), startupDelay: 0, settleInterval: 0),
            userAgent: "Toastty/test"
        )
        service.taskStates = { states.value }
        service.attach(coordinator: fixture.controller)
        fixture.tasks.coordinator.webhooks = service
        return service
    }

    private func executor(_ fixture: Fixture) -> AppControlExecutor {
        TaskAppControlTests().makeExecutor(fixture.tasks, coordinator: fixture.tasks.coordinator)
    }

    private func context(_ caller: String?) -> AutomationRequestContext {
        AutomationRequestContext(callerSessionID: caller, commandName: "app_control.run_action")
    }

    private func string(_ value: AutomationJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func refused(
        _ mention: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("expected invalidPayload containing \(mention)", sourceLocation: sourceLocation)
        } catch AutomationSocketError.invalidPayload(let actual) {
            #expect(actual.contains(mention), "\(actual)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    /// `coordinator.send` from Grok Bot, a caller in no Toastty session, at
    /// the coordinator's open prompt. Returns the message ID.
    private func sendFromGrokBot(_ text: String, _ executor: AppControlExecutor, _ fixture: Fixture) async throws -> String {
        try fixture.setStatus(.idle)
        await fixture.settle()
        let result = try executor.runAction(
            id: "coordinator.send", args: ["text": .string(text), "from": .string("Grok Bot")], context: context(nil)
        ).result
        #expect(result?["delivery"] == .string("sent"))
        try fixture.setStatus(.working)
        return try #require(string(result?["messageID"]))
    }

    private func replies(_ executor: AppControlExecutor, _ args: [String: AutomationJSONValue] = [:]) throws -> (texts: [String], from: [AutomationJSONValue], cursor: String, truncated: Bool) {
        let result = try executor.runQuery(id: "coordinator.replies", args: args)
        guard case .array(let items)? = result["replies"] else {
            Issue.record("no replies in the answer")
            return ([], [], "", false)
        }
        let objects = items.compactMap { item -> [String: AutomationJSONValue]? in
            guard case .object(let object) = item else { return nil }
            return object
        }
        return (
            objects.compactMap { string($0["text"]) },
            objects.map { $0["from"] ?? .null },
            string(result["cursor"]) ?? "",
            result["truncated"] == .bool(true)
        )
    }

    // MARK: - Send, reply, read

    @Test func anOutsideSendersMessageGetsAnIDThatOnlyTheCoordinatorRepliesTo() async throws {
        let fixture = try Fixture()
        let files = Files()
        let clock = Clock()
        let secrets = InMemoryTaskWebhookSecretStore()
        let service = makeService(fixture, files: files, clock: clock, transport: Transport(), secrets: secrets)
        let executor = executor(fixture)
        #expect(executor.listActionDescriptors().map(\.id).contains("coordinator.reply"))
        #expect(executor.listQueryDescriptors().map(\.id).contains("coordinator.replies"))
        try await fixture.openAtPrompt()
        let coordinatorSessionID = try fixture.session().sessionID

        let messageID = try await sendFromGrokBot("Where do the bera symlinks point?", executor, fixture)
        let typed = try #require(fixture.typedTexts.last)
        #expect(typed == "[Toastty] From \"Grok Bot\" (named by the caller): Toastty cannot tell who ran it. "
            + "Message ID \(messageID).\nWhere do the bera symlinks point?")
        #expect(CoordinatorMessageHeader.kind(of: typed) == .fromSender(sender: "\"Grok Bot\" (named by the caller)"))
        #expect(service.coordinatorReplies.message(id: try #require(UUID(uuidString: messageID)))?.typedAt == clock.now)

        // The coordinator's own message needs no answer: no ID.
        try fixture.setStatus(.idle)
        await fixture.settle()
        let own = try executor.runAction(id: "coordinator.send", args: ["text": .string("A note.")], context: context(coordinatorSessionID))
        #expect(own.result?["messageID"] == .null)
        #expect(fixture.typedTexts.last == "[Toastty] From the coordinator: not from the user.\nA note.")
        try fixture.setStatus(.working)

        // Only the coordinator's own agent replies.
        func reply(_ text: String, to id: String = messageID, as caller: String?) throws -> [String: AutomationJSONValue]? {
            try executor.runAction(
                id: "coordinator.reply", args: ["messageID": .string(id), "text": .string(text)], context: context(caller)
            ).result
        }
        refused("Only the coordinator's own agent") { _ = try reply("Forged.", as: nil) }
        refused("Only the coordinator's own agent") { _ = try reply("Forged.", as: "not-a-session") }
        refused("No message has ID") { _ = try reply("Hi", to: UUID().uuidString, as: coordinatorSessionID) }
        refused("messageID must be") { _ = try reply("Hi", to: "the bera one", as: coordinatorSessionID) }
        refused("empty") { _ = try reply("  ", as: coordinatorSessionID) }
        #expect(try replies(executor).texts.isEmpty)

        let first = try reply("I asked Vishal.", as: coordinatorSessionID)
        #expect(string(first?["messageID"]) == messageID)
        #expect(first?["webhookEvents"] == .int(0))
        let start = try replies(executor)
        #expect(start.texts == ["I asked Vishal."])
        #expect(start.from == [.string("Grok Bot")])
        #expect(start.truncated == false)

        // A later turn answers again, after the user decided.
        clock.advance(600)
        _ = try reply("Vishal said yes: they point at /Volumes/old.", as: coordinatorSessionID)
        #expect(try replies(executor, ["since": .string(start.cursor)]).texts == ["Vishal said yes: they point at /Volumes/old."])
        #expect(try replies(executor, ["messageID": .string(messageID)]).texts.count == 2)
        #expect(try replies(executor, ["messageID": .string(UUID().uuidString)]).texts.isEmpty)
        refused("cursor") { _ = try replies(executor, ["since": .string("yesterday")]) }

        // A relaunch keeps the message's ID and the replies. The task
        // coordinator holds the service weakly, as the app does.
        let cursor = try replies(executor).cursor
        try withExtendedLifetime(service) {
            let relaunched = makeService(fixture, files: files, clock: clock, transport: Transport(), secrets: secrets)
            _ = try reply("Fixed.", as: coordinatorSessionID)
            let afterRelaunch = try replies(executor, ["since": .string(cursor)])
            #expect(afterRelaunch.texts == ["Fixed."])
            #expect(afterRelaunch.truncated == false)
            #expect(relaunched.coordinatorReplies.replies.count == 3)
        }
    }

    @Test func aMessageThatWaitsIsMarkedTypedWhenToasttyTypesIt() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let service = makeService(fixture, files: Files(), clock: clock, transport: Transport(), secrets: InMemoryTaskWebhookSecretStore())
        let executor = executor(fixture)
        try await fixture.openAtPrompt()
        try fixture.setStatus(.working)

        let result = try executor.runAction(
            id: "coordinator.send", args: ["text": .string("Status?"), "from": .string("Grok Bot")], context: context(nil)
        ).result
        #expect(result?["delivery"] == .string("queued"))
        let messageID = try #require(string(result?["messageID"]).flatMap(UUID.init(uuidString:)))
        #expect(service.coordinatorReplies.message(id: messageID)?.typedAt == nil)

        clock.advance(120)
        try fixture.setStatus(.idle)
        await fixture.waitUntil("the message is typed") { fixture.typedTexts.last?.hasSuffix("\nStatus?") == true }
        #expect(fixture.typedTexts.last?.contains("Message ID \(messageID.uuidString).") == true)
        #expect(service.coordinatorReplies.message(id: messageID)?.typedAt == clock.now)
    }

    // MARK: - Webhook events

    @Test func aReplyEventGoesOnlyToApprovedWebhooksThatAskedForItAndCarriesNoText() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let transport = Transport()
        let service = makeService(fixture, files: Files(), clock: clock, transport: transport, secrets: InMemoryTaskWebhookSecretStore())
        let executor = executor(fixture)
        func add(_ name: String, events: String) throws -> [String: AutomationJSONValue] {
            try #require(try executor.runAction(id: "webhook.add", args: [
                "name": .string(name), "url": .string("https://\(name).example.com/hook"), "events": .string(events),
                "auth": .string("bearer"), "secret": .string("s3cret-key-0123456789"),
            ], context: context(nil)).result)
        }
        func approve(_ name: String) throws {
            let webhook = try #require(service.webhook(named: name))
            try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        }
        let grok = try add("grok", events: "needs_you,coordinator_reply")
        #expect(grok["events"] == .array([.string("needs_you"), .string("coordinator_reply")]))
        try approve("grok")
        _ = try add("tasks-only", events: "needs_you,merged")
        try approve("tasks-only")
        _ = try add("pending", events: "merged,coordinator_reply")
        refused("at least one task event") { _ = try add("replies-only", events: "coordinator_reply") }
        refused("coordinator_reply") { _ = try add("typo", events: "coordinator_replies") }

        let grokID = try #require(service.webhook(named: "grok")?.id)
        try await fixture.openAtPrompt()
        let messageID = try await sendFromGrokBot("Where do the bera symlinks point?", executor, fixture)
        let result = try executor.runAction(id: "coordinator.reply", args: [
            "messageID": .string(messageID), "text": .string("They point at /Volumes/old."),
        ], context: context(try fixture.session().sessionID)).result
        #expect(result?["webhookEvents"] == .int(1))
        let replyID = try #require(string(result?["replyID"]))

        await fixture.waitUntil("the reply event is sent") { transport.requests.isEmpty == false }
        await fixture.waitUntil("nothing waits") { service.queuedEventCount(webhookID: grokID) == 0 }
        #expect(transport.requests.map(\.url?.host) == ["grok.example.com"])
        let body = try #require(transport.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["type"] as? String == "coordinator.reply")
        #expect(json["webhook"] as? String == "grok")
        let reply = try #require(json["reply"] as? [String: Any])
        #expect(reply["id"] as? String == replyID)
        #expect(reply["messageID"] as? String == messageID)
        #expect(reply["from"] as? String == "Grok Bot")
        #expect(String(decoding: body, as: UTF8.self).contains("Volumes") == false)

        // Without coordinator_reply in a new list, the webhook stops getting
        // replies, and the change needs approval again.
        let changed = try #require(try executor.runAction(id: "webhook.set", args: [
            "name": .string("grok"), "events": .string("needs_you"),
        ], context: context(nil)).result)
        #expect(changed["events"] == .array([.string("needs_you")]))
        #expect(changed["status"] == .string("pendingApproval"))
    }

    /// A reply event that waits is saved with its reply, never in the task
    /// outbox, which a build that does not know it still reads. After a
    /// relaunch it goes out after the task event that came before it.
    @Test func aWaitingReplyEventIsSavedApartAndSentInOrderAfterARelaunch() async throws {
        let fixture = try Fixture()
        let files = Files()
        let clock = Clock()
        let secrets = InMemoryTaskWebhookSecretStore()
        let failing = Transport()
        failing.statusCode = 503
        let states = States()
        states.value = [task: TaskWebhookTaskState(key: .init(group: "running"), title: "Fix the symlinks", projectRoot: "/repos/bera")]
        let service = makeService(fixture, files: files, clock: clock, transport: failing, secrets: secrets, states: states)
        let executor = executor(fixture)
        var settings = TaskWebhookService.Settings()
        settings.url = "https://grok.example.com/hook"
        settings.auth = .bearer
        settings.events = [.needsYou]
        settings.coordinatorReplies = true
        let webhook = try service.add(name: "grok", settings: settings, secret: "s3cret-key-0123456789", requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        try await fixture.openAtPrompt()
        // A busy coordinator keeps the wake digest of the task change to
        // itself, so only Grok Bot's message is typed.
        try fixture.setStatus(.working)
        service.pass()

        // A task event, then a reply. Neither gets through.
        clock.advance(10)
        states.value[task]?.key = .init(group: "needsYou", attention: "awaitingReply")
        service.pass()
        await fixture.waitUntil("the task event is tried") { failing.requests.count == 1 }
        let messageID = try await sendFromGrokBot("Fixed yet?", executor, fixture)
        clock.advance(1)
        _ = try executor.runAction(id: "coordinator.reply", args: [
            "messageID": .string(messageID), "text": .string("Not yet."),
        ], context: context(try fixture.session().sessionID))
        await fixture.settle()
        // The reply waits behind the task event.
        #expect(failing.types == ["task.needs_you"])
        #expect(service.queuedEventCount(webhookID: webhook.id) == 2)

        let outbox = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.outbox)) as? [String: Any])
        let outboxEntries = try #require(outbox["entries"] as? [[String: Any]])
        #expect(outboxEntries.count == 1)
        #expect(outboxEntries.allSatisfy { $0["taskID"] as? String == task.uuidString })
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.replies)) as? [String: Any])
        #expect((saved["events"] as? [[String: Any]])?.count == 1)
        #expect((saved["replies"] as? [[String: Any]])?.count == 1)

        // Relaunch; the receiver is back.
        let working = Transport()
        let relaunched = makeService(fixture, files: files, clock: clock, transport: working, secrets: secrets, states: states)
        clock.advance(60)
        relaunched.pass()
        await fixture.waitUntil("both events are sent") { working.types.count == 2 }
        #expect(working.types == ["task.needs_you", "coordinator.reply"])
        await fixture.waitUntil("nothing waits") { relaunched.queuedEventCount(webhookID: webhook.id) == 0 }
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.replies)) as? [String: Any])
        #expect((after["events"] as? [[String: Any]])?.isEmpty == true)
    }
}
