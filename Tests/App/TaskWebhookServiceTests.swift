import CoreState
import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import ToasttyApp

/// Task webhooks from registration to delivery: the approval gate, real
/// HTTP to a loopback receiver, retries, and relaunch.
@MainActor
struct TaskWebhookServiceTests {
    private let task = UUID()
    private let secret = "s3cret-key-0123456789"

    /// The task states a test changes between passes.
    private final class States {
        var value: [UUID: TaskWebhookTaskState]
        init(_ value: [UUID: TaskWebhookTaskState]) { self.value = value }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// A transport whose answers the test scripts, for retry timing.
    private final class FakeTransport: TaskWebhookTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [TaskWebhookSendResult] = []
        private(set) var requests: [URLRequest] = []

        func answer(_ results: TaskWebhookSendResult...) { lock.withLock { answers += results } }
        var count: Int { lock.withLock { requests.count } }
        func body(_ index: Int) -> [String: Any] {
            lock.withLock {
                (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
            }
        }

        func send(_ request: URLRequest) async -> TaskWebhookSendResult {
            lock.withLock {
                requests.append(request)
                return answers.isEmpty ? TaskWebhookSendResult(statusCode: 200) : answers.removeFirst()
            }
        }
    }

    /// A transport that holds each request until the test answers it.
    private final class GatedTransport: TaskWebhookTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CheckedContinuation<TaskWebhookSendResult, Never>] = []
        private var bodies: [Data] = []

        var waiting: Int { lock.withLock { pending.count } }
        func body(_ index: Int) -> [String: Any] {
            lock.withLock { (try? JSONSerialization.jsonObject(with: bodies[index])) as? [String: Any] ?? [:] }
        }
        func release(_ result: TaskWebhookSendResult) {
            let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            continuation?.resume(returning: result)
        }

        func send(_ request: URLRequest) async -> TaskWebhookSendResult {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    bodies.append(request.httpBody ?? Data())
                    pending.append(continuation)
                }
            }
        }
    }

    /// Reads fail while locked, as a locked Keychain does.
    private final class LockableSecretStore: TaskWebhookSecretStoring, @unchecked Sendable {
        let inner: InMemoryTaskWebhookSecretStore
        var isLocked = true
        init(_ inner: InMemoryTaskWebhookSecretStore) { self.inner = inner }
        func item(for webhookID: UUID) throws -> TaskWebhookKeychainItem? {
            if isLocked { throw TaskWebhookSecretStoreError(status: errSecInteractionNotAllowed) }
            return try inner.item(for: webhookID)
        }
        func setItem(_ item: TaskWebhookKeychainItem, for webhookID: UUID) throws { try inner.setItem(item, for: webhookID) }
        func removeItem(for webhookID: UUID) throws { try inner.removeItem(for: webhookID) }
    }

    private struct Files {
        let directory = FileManager.default.temporaryDirectory.appending(path: "toastty-webhooks-\(UUID().uuidString)")
        var webhooks: URL { directory.appending(path: "task-webhooks.json") }
        var outbox: URL { directory.appending(path: "task-webhook-outbox.json") }
    }

    private func makeService(
        files: Files = Files(),
        secrets: InMemoryTaskWebhookSecretStore = InMemoryTaskWebhookSecretStore(),
        transport: any TaskWebhookTransport,
        clock: Clock,
        states: @escaping @MainActor () -> [UUID: TaskWebhookTaskState]
    ) -> TaskWebhookService {
        let service = TaskWebhookService(
            webhooksFileURL: files.webhooks,
            outboxFileURL: files.outbox,
            secrets: secrets,
            transport: transport,
            now: { clock.now },
            timing: .init(passInterval: .seconds(3600), startupDelay: 0, settleInterval: 0),
            userAgent: "Toastty/test"
        )
        service.taskStates = states
        return service
    }

    private func state(_ group: String, _ attention: String? = nil, merged: Bool = false) -> TaskWebhookTaskState {
        TaskWebhookTaskState(
            key: .init(group: group, attention: attention, merged: merged),
            title: "Webhook design",
            projectRoot: "/repos/toastty",
            externalRef: TaskExternalRef(id: "grok:7"),
            question: attention == "awaitingReply" ? "Approve the design?" : nil
        )
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting until \(what)")
    }

    private func settings(_ url: String, auth: TaskWebhookAuth = .hmac) -> TaskWebhookService.Settings {
        var settings = TaskWebhookService.Settings()
        settings.url = url
        settings.auth = auth
        return settings
    }

    // MARK: - Approval gate

    @Test func aPendingWebhookSendsNothingUntilApproved() async throws {
        let clock = Clock()
        let transport = FakeTransport()
        let current = States([task: state("running")])
        let secrets = InMemoryTaskWebhookSecretStore()
        let service = makeService(secrets: secrets, transport: transport, clock: clock) { current.value }
        let webhook = try service.add(name: "grok", settings: settings("https://hooks.example.com/w"), secret: secret, requester: .init())
        #expect(webhook.status == .pendingApproval)
        #expect(try secrets.item(for: webhook.id)?.approvedDigest == nil)

        current.value[task] = state("needsYou", "awaitingReply")
        service.pass()
        await #expect(throws: TaskWebhookValidationError.self) { _ = try await service.sendTest(name: "grok") }
        #expect(transport.count == 0)

        // Approval starts from now: the change made while it waited is not
        // replayed.
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        #expect(try secrets.item(for: webhook.id)?.approvedDigest == webhook.settingsDigest)
        service.pass()
        #expect(transport.count == 0)
        current.value[task] = state("needsYou", "review")
        service.pass()
        await waitUntil("one event is sent") { transport.count == 1 }
        #expect(transport.body(0)["type"] as? String == "task.needs_you")
    }

    @Test func changingWhereEventsGoNeedsApprovalAgainButANewSecretDoesNot() async throws {
        let clock = Clock()
        let secrets = InMemoryTaskWebhookSecretStore()
        let service = makeService(secrets: secrets, transport: FakeTransport(), clock: clock) { [:] }
        let added = try service.add(name: "grok", settings: settings("https://hooks.example.com/w", auth: .bearer), secret: secret, requester: .init())
        try service.approve(id: added.id, shownDigest: added.settingsDigest)

        let rotated = try service.update(name: "grok", settings: .init(), secret: "another-secret-0123456789", requester: .init())
        #expect(rotated.status == .approved)
        #expect(service.isActive(rotated))
        #expect(try secrets.item(for: added.id)?.secret == "another-secret-0123456789")

        var moved = TaskWebhookService.Settings()
        moved.url = "https://elsewhere.example.com/w"
        let changed = try service.update(name: "grok", settings: moved, secret: nil, requester: .init(agentSessionID: "agent-1"))
        #expect(changed.status == .pendingApproval)
        #expect(changed.requestedBy.isAgentSession)
        #expect(service.isActive(changed) == false)

        try service.deny(id: added.id)
        #expect(service.webhooks.isEmpty)
        #expect(try secrets.item(for: added.id) == nil)
    }

    @Test func aHandEditOfTheFileReturnsTheWebhookToPending() throws {
        let clock = Clock()
        let files = Files()
        let secrets = InMemoryTaskWebhookSecretStore()
        let first = makeService(files: files, secrets: secrets, transport: FakeTransport(), clock: clock) { [:] }
        let webhook = try first.add(name: "grok", settings: settings("https://hooks.example.com/w"), secret: secret, requester: .init())
        try first.approve(id: webhook.id, shownDigest: webhook.settingsDigest)

        let text = try String(contentsOf: files.webhooks, encoding: .utf8)
        try text.replacingOccurrences(of: "hooks.example.com", with: "evil.example.com").write(to: files.webhooks, atomically: true, encoding: .utf8)
        let relaunched = makeService(files: files, secrets: secrets, transport: FakeTransport(), clock: clock) { [:] }
        #expect(relaunched.webhooks.first?.status == .pendingApproval)
        #expect(relaunched.webhooks.first.map(relaunched.isActive) == false)

        // Approving the edited settings, as the sheet shows them, holds
        // across a relaunch.
        let edited = try #require(relaunched.webhooks.first)
        #expect(throws: TaskWebhookValidationError.self) { try relaunched.approve(id: edited.id, shownDigest: webhook.settingsDigest) }
        try relaunched.approve(id: edited.id, shownDigest: edited.settingsDigest)
        let again = makeService(files: files, secrets: secrets, transport: FakeTransport(), clock: clock) { [:] }
        #expect(again.webhooks.first.map(again.isActive) == true)
    }

    @Test func registrationChecksItsInputs() throws {
        let service = makeService(transport: FakeTransport(), clock: Clock()) { [:] }
        #expect(throws: TaskWebhookValidationError.self) {
            _ = try service.add(name: "grok", settings: settings("http://hooks.example.com/w"), secret: secret, requester: .init())
        }
        #expect(throws: TaskWebhookValidationError.self) {
            _ = try service.add(name: "grok", settings: settings("https://hooks.example.com/w", auth: .bearer), secret: nil, requester: .init())
        }
        _ = try service.add(name: "local", settings: settings("http://127.0.0.1:9/w", auth: .none), secret: nil, requester: .init())
        #expect(throws: TaskWebhookValidationError.self) {
            _ = try service.add(name: "local", settings: settings("http://127.0.0.1:9/w", auth: .none), secret: nil, requester: .init())
        }
        for index in 0..<4 {
            _ = try service.add(name: "w\(index)", settings: settings("https://h\(index).example.com"), secret: secret, requester: .init())
        }
        #expect(throws: TaskWebhookValidationError.self) {
            _ = try service.add(name: "w9", settings: settings("https://h9.example.com"), secret: secret, requester: .init())
        }
    }

    // MARK: - Delivery

    @Test func eventsGoOnlyToWebhooksWhoseFiltersMatch() async throws {
        let clock = Clock()
        let transport = FakeTransport()
        let current = States([task: state("running")])
        let service = makeService(transport: transport, clock: clock) { current.value }
        var narrow = settings("https://narrow.example.com/w")
        narrow.roots = ["/repos/other"]
        let other = try service.add(name: "narrow", settings: narrow, secret: secret, requester: .init())
        var everything = settings("https://all.example.com/w")
        everything.events = TaskWebhookEventType.allCases
        let all = try service.add(name: "all", settings: everything, secret: secret, requester: .init())
        try service.approve(id: other.id, shownDigest: other.settingsDigest)
        try service.approve(id: all.id, shownDigest: all.settingsDigest)
        service.pass()

        current.value[task] = state("idle")
        service.pass()
        await waitUntil("the idle event is sent") { transport.count == 1 }
        #expect(transport.requests.first?.url?.host == "all.example.com")
        #expect(transport.body(0)["type"] as? String == "task.idle")
    }

    @Test func failedSendsRetryWithBackoffAndANewerStageReplacesAnOldOne() async throws {
        let clock = Clock()
        let transport = FakeTransport()
        transport.answer(TaskWebhookSendResult(statusCode: nil, errorClass: "offline"))
        let current = States([task: state("running")])
        let service = makeService(transport: transport, clock: clock) { current.value }
        let webhook = try service.add(name: "grok", settings: settings("https://hooks.example.com/w"), secret: secret, requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        service.pass()

        current.value[task] = state("needsYou", "agentFinished")
        service.pass()
        await waitUntil("the first attempt fails") { transport.count == 1 && service.entries.first?.attempts == 1 }
        let firstEventID = try #require(service.entries.first?.eventID)

        // Too early for a retry.
        clock.advance(2)
        service.pass()
        #expect(transport.count == 1)

        // A newer stage for the same task replaces the waiting one.
        current.value[task] = state("needsYou", "awaitingReply")
        service.pass()
        #expect(service.entries.count == 1)
        #expect(service.entries.first?.eventID != firstEventID)
        await waitUntil("the newer event is sent") { transport.count == 2 && service.entries.isEmpty }
        #expect((transport.body(1)["task"] as? [String: Any])?["question"] as? String == "Approve the design?")

        // A merge is a milestone: a later stage does not replace it.
        transport.answer(TaskWebhookSendResult(statusCode: 503))
        current.value[task] = state("done", merged: true)
        service.pass()
        await waitUntil("the merge send fails") { transport.count == 3 && service.entries.first?.attempts == 1 }
        current.value[task] = state("archived", merged: true)
        service.pass()
        #expect(Set(service.entries.map(\.type)).isSuperset(of: [.merged, .archived]))
        clock.advance(6)
        service.pass()
        await waitUntil("every event is delivered") { service.entries.isEmpty }
    }

    @Test func aRefusedWebhookStopsUntilItGetsANewSecret() async throws {
        let clock = Clock()
        let transport = FakeTransport()
        transport.answer(TaskWebhookSendResult(statusCode: 401))
        let current = States([task: state("running")])
        let service = makeService(transport: transport, clock: clock) { current.value }
        let webhook = try service.add(name: "grok", settings: settings("https://hooks.example.com/w", auth: .bearer), secret: secret, requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        service.pass()
        current.value[task] = state("needsYou", "review")
        service.pass()
        await waitUntil("the webhook stops") { service.webhook(named: "grok")?.status == .disabled }
        #expect(service.webhook(named: "grok")?.disabledReason == "HTTP 401")
        #expect(service.entries.isEmpty)

        let resumed = try service.update(name: "grok", settings: .init(), secret: "fresh-secret-0123456789", requester: .init())
        #expect(resumed.status == .approved)
        #expect(service.isActive(resumed))
    }

    @Test func aRelaunchSendsWaitingEventsAndDoesNotRepeatOldOnes() async throws {
        let clock = Clock()
        let files = Files()
        let secrets = InMemoryTaskWebhookSecretStore()
        let offline = FakeTransport()
        offline.answer(TaskWebhookSendResult(statusCode: nil, errorClass: "offline"))
        let current = States([task: state("running")])
        let first = makeService(files: files, secrets: secrets, transport: offline, clock: clock) { current.value }
        let webhook = try first.add(name: "grok", settings: settings("https://hooks.example.com/w"), secret: secret, requester: .init())
        try first.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        first.pass()
        current.value[task] = state("needsYou", "review")
        first.pass()
        await waitUntil("the send fails") { first.entries.first?.attempts == 1 }
        let eventID = try #require(first.entries.first?.eventID)
        first.stop()

        // Toastty relaunches. The task still waits for review, and its PR
        // merges a moment later.
        let online = FakeTransport()
        let second = makeService(files: files, secrets: secrets, transport: online, clock: clock) { current.value }
        clock.advance(60)
        second.pass()
        await waitUntil("the saved event is sent") { online.count == 1 }
        #expect(online.requests.first?.value(forHTTPHeaderField: "Toastty-Event-ID") == eventID.uuidString.lowercased())
        current.value[task] = state("toShip", merged: true)
        second.pass()
        await waitUntil("the merge is sent") { online.count == 3 }
        #expect(Set((1...2).compactMap { online.body($0)["type"] as? String }) == ["task.merged", "task.done"])
    }

    // MARK: - Review fixes

    @Test func aHandEditCannotApproveAnInsecureAddressOrSendOldEvents() async throws {
        let clock = Clock()
        let files = Files()
        let secrets = InMemoryTaskWebhookSecretStore()
        let offline = FakeTransport()
        offline.answer(TaskWebhookSendResult(statusCode: nil, errorClass: "offline"))
        let current = States([task: state("running")])
        let first = makeService(files: files, secrets: secrets, transport: offline, clock: clock) { current.value }
        let webhook = try first.add(name: "grok", settings: settings("https://hooks.example.com/w", auth: .bearer), secret: secret, requester: .init())
        try first.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        first.pass()
        current.value[task] = state("needsYou", "review")
        first.pass()
        await waitUntil("an event waits") { first.entries.first?.attempts == 1 }

        let text = try String(contentsOf: files.webhooks, encoding: .utf8)
        try text.replacingOccurrences(of: "https:\\/\\/hooks.example.com", with: "http:\\/\\/evil.example.com")
            .write(to: files.webhooks, atomically: true, encoding: .utf8)
        let relaunched = makeService(files: files, secrets: secrets, transport: FakeTransport(), clock: clock) { current.value }
        let edited = try #require(relaunched.webhooks.first)
        #expect(edited.url == "http://evil.example.com/w")
        #expect(edited.status == .pendingApproval)
        #expect(relaunched.entries.isEmpty)
        #expect(throws: TaskWebhookValidationError.self) { try relaunched.approve(id: edited.id, shownDigest: edited.settingsDigest) }
    }

    @Test func anUnreadableKeychainKeepsTheApprovalUntilItCanBeRead() throws {
        let clock = Clock()
        let files = Files()
        let secrets = InMemoryTaskWebhookSecretStore()
        let first = makeService(files: files, secrets: secrets, transport: FakeTransport(), clock: clock) { [:] }
        let webhook = try first.add(name: "grok", settings: settings("https://hooks.example.com/w"), secret: secret, requester: .init())
        try first.approve(id: webhook.id, shownDigest: webhook.settingsDigest)

        let locked = LockableSecretStore(secrets)
        let relaunched = TaskWebhookService(
            webhooksFileURL: files.webhooks, outboxFileURL: files.outbox, secrets: locked, transport: FakeTransport(),
            now: { clock.now }, timing: .init(passInterval: .seconds(3600), startupDelay: 0, settleInterval: 0)
        )
        #expect(relaunched.webhooks.first?.status == .approved)
        #expect(relaunched.webhooks.first.map(relaunched.isActive) == false)
        locked.isLocked = false
        relaunched.pass()
        #expect(relaunched.webhooks.first.map(relaunched.isActive) == true)
    }

    @Test func aRefusalOfAnOlderSecretDoesNotStopTheWebhook() async throws {
        let clock = Clock()
        let transport = GatedTransport()
        let current = States([task: state("running")])
        let service = makeService(transport: transport, clock: clock) { current.value }
        let webhook = try service.add(name: "grok", settings: settings("https://hooks.example.com/w", auth: .bearer), secret: secret, requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        service.pass()
        current.value[task] = state("needsYou", "review")
        service.pass()
        await waitUntil("a send is out") { transport.waiting == 1 }

        _ = try service.update(name: "grok", settings: .init(), secret: "rotated-secret-0123456789", requester: .init())
        transport.release(TaskWebhookSendResult(statusCode: 401))
        await waitUntil("the send finishes") { service.entries.first?.attempts == 1 }
        #expect(service.webhook(named: "grok")?.status == .approved)
    }

    @Test func aFailedStageEventThatANewerOneReplacedIsDropped() async throws {
        let clock = Clock()
        let transport = GatedTransport()
        let current = States([task: state("running")])
        let service = makeService(transport: transport, clock: clock) { current.value }
        let webhook = try service.add(name: "grok", settings: settings("https://hooks.example.com/w"), secret: secret, requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        service.pass()
        current.value[task] = state("needsYou", "agentFinished")
        service.pass()
        await waitUntil("the first stage is out") { transport.waiting == 1 }
        clock.advance(1)
        current.value[task] = state("needsYou", "awaitingReply")
        service.pass()
        #expect(service.entries.count == 2)

        transport.release(TaskWebhookSendResult(statusCode: 503))
        await waitUntil("the newer stage is out") { transport.waiting == 1 && service.entries.count == 1 }
        #expect((transport.body(1)["task"] as? [String: Any])?["question"] as? String == "Approve the design?")
        transport.release(TaskWebhookSendResult(statusCode: 200))
        await waitUntil("nothing waits") { service.entries.isEmpty }
    }

    // MARK: - Real HTTP

    @Test func aLoopbackReceiverGetsSignedAndKeyedRequests() async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let clock = Clock()
        clock.now = Date()
        let current = States([task: state("running")])
        let service = makeService(transport: TaskWebhookClient(), clock: clock) { current.value }
        var signed = settings("http://127.0.0.1:\(receiver.port)/signed")
        signed.events = [.needsYou]
        let hmac = try service.add(name: "signed", settings: signed, secret: secret, requester: .init())
        var keyed = settings("http://127.0.0.1:\(receiver.port)/keyed", auth: .header(name: "X-Sender-Key"))
        keyed.events = [.needsYou]
        let header = try service.add(name: "keyed", settings: keyed, secret: secret, requester: .init())
        try service.approve(id: hmac.id, shownDigest: hmac.settingsDigest)
        try service.approve(id: header.id, shownDigest: header.settingsDigest)
        service.pass()

        current.value[task] = state("needsYou", "awaitingReply")
        service.pass()
        await waitUntil("both receivers get the event") { receiver.requests.count == 2 && service.entries.isEmpty }

        let signedRequest = try #require(receiver.requests.first { $0.path == "/signed" })
        let timestamp = try #require(signedRequest.headers["toastty-timestamp"])
        let expected = TaskWebhookSignature.header(secret: secret, timestamp: Int(timestamp) ?? 0, body: signedRequest.body)
        #expect(signedRequest.headers["toastty-signature"] == expected)
        #expect(signedRequest.headers["authorization"] == nil)
        #expect(signedRequest.headers["content-type"] == "application/json")
        let payload = try #require(try JSONSerialization.jsonObject(with: signedRequest.body) as? [String: Any])
        #expect(signedRequest.headers["toastty-event-id"] == (payload["eventID"] as? String)?.lowercased())
        let taskPayload = try #require(payload["task"] as? [String: Any])
        #expect(taskPayload["title"] as? String == "Webhook design")
        #expect(taskPayload["question"] as? String == "Approve the design?")
        #expect((taskPayload["stage"] as? [String: Any])?["attention"] as? String == "awaitingReply")

        let keyedRequest = try #require(receiver.requests.first { $0.path == "/keyed" })
        #expect(keyedRequest.headers["x-sender-key"] == secret)
        #expect(keyedRequest.headers["toastty-signature"] == nil)

        let delivery = try await service.sendTest(name: "keyed")
        #expect(delivery.statusCode == 200)
        #expect(receiver.requests.count == 3)
    }

    // MARK: - Socket commands

    @Test func socketCommandsRegisterButCannotApproveOrRevealTheSecret() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let service = makeService(transport: FakeTransport(), clock: Clock()) { [:] }
        fixture.coordinator.webhooks = service
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        webPanelRuntimeRegistry.bind(store: fixture.store)
        let executor = AppControlExecutor(
            store: fixture.store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: fixture.store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: fixture.launcher,
            taskCoordinator: fixture.coordinator,
            reloadConfigurationAction: nil
        )
        let context = AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")

        #expect(AppControlActionID.allCases.filter { $0.rawValue.hasPrefix("webhook.") }.map(\.rawValue).sorted()
            == ["webhook.add", "webhook.remove", "webhook.set", "webhook.test"])
        let added = try await executor.runActionAsync(
            id: "webhook.add",
            args: [
                "name": .string("grok"),
                "url": .string("https://hooks.example.com/v1/routines/rt_8f2c91ab77/wake"),
                "auth": .string("bearer"),
                "secret": .string(secret),
                "events": .array([.string("needs_you,merged")]),
            ],
            context: context
        )
        #expect(added.result?["status"] == .string("pendingApproval"))
        #expect(added.result?["url"] == .string("https://hooks.example.com/…"))
        #expect(added.result?["events"] == .array([.string("needs_you"), .string("merged")]))
        let listed = try executor.runQuery(id: "webhook.list", args: [:])
        let encoded = String(decoding: try JSONEncoder().encode(listed), as: UTF8.self)
        #expect(encoded.contains(secret) == false)
        #expect(encoded.contains("rt_8f2c91ab77") == false)

        do {
            _ = try await executor.runActionAsync(id: "webhook.test", args: ["name": .string("grok")], context: context)
            Issue.record("a pending webhook was tested")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message.contains("waiting for approval"))
        }
        do {
            _ = try await executor.runActionAsync(id: "webhook.add", args: ["name": .string("x"), "url": .string("https://a.example"), "auth": .string("basic")], context: context)
            Issue.record("an unknown auth mode was accepted")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "auth must be bearer, header:<Name>, hmac or none")
        }

        // A workspace-scoped agent session may not manage webhooks.
        let created = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("scoped"), "workspace": .string(fixture.workspaceID.uuidString), "agent": .string("codex")],
            context: context
        )
        guard case .string(let rawID)? = created.result?["taskID"], let taskID = UUID(uuidString: rawID) else {
            Issue.record("no task")
            return
        }
        await fixture.waitForSetup(taskID)
        let sessionID = try #require(fixture.record(taskID)?.operation.agentLaunch?.sessionID)
        #expect(fixture.sessionRuntimeStore.setScope(sessionID: sessionID, workspaceIDs: []))
        do {
            _ = try executor.runQuery(
                id: "webhook.list", args: [:],
                context: AutomationRequestContext(callerSessionID: sessionID, commandName: "app_control.run_query")
            )
            Issue.record("a scoped session listed webhooks")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "A workspace-scoped session cannot manage task webhooks.")
        }

        let removed = try await executor.runActionAsync(id: "webhook.remove", args: ["name": .string("grok")], context: context)
        #expect(removed.result?["removed"] == .bool(true))
        #expect(service.webhooks.isEmpty)
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 that records each request and
/// answers 200.
private final class LoopbackReceiver: @unchecked Sendable {
    struct Request {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "toastty.tests.webhook-receiver")
    private let lock = NSLock()
    private var recorded: [Request] = []

    var requests: [Request] { lock.withLock { recorded } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> LoopbackReceiver {
        let receiver = try LoopbackReceiver()
        receiver.listener.newConnectionHandler = { [weak receiver] connection in receiver?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            receiver.listener.stateUpdateHandler = { state in
                // Runs on the receiver's serial queue.
                guard once.done == false else { return }
                switch state {
                case .ready: once.done = true; continuation.resume()
                case .failed(let error): once.done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            receiver.listener.start(queue: receiver.queue)
        }
        return receiver
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.recorded.append(request) }
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return Request(path: path, headers: headers, body: Data(body.prefix(length)))
    }
}
