import CoreState
import Foundation
import Testing

struct TaskWebhookEventDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let task = UUID()

    private func state(_ group: String, _ attention: String? = nil, merged: Bool = false, title: String = "Fix it") -> TaskWebhookTaskState {
        TaskWebhookTaskState(key: .init(group: group, attention: attention, merged: merged), title: title, projectRoot: "/repo")
    }

    private func primed(_ initial: TaskWebhookTaskState) -> TaskWebhookEventDetector {
        var detector = TaskWebhookEventDetector()
        _ = detector.observe([task: initial], now: t0)
        return detector
    }

    @Test func firstObservationOnlyRecords() {
        var detector = TaskWebhookEventDetector()
        #expect(detector.observe([task: state("needsYou", "awaitingReply")], now: t0).isEmpty)
        #expect(detector.isPrimed)
    }

    @Test func agentStageCountsOnlyAfterItHoldsForTheSettleWindow() {
        var detector = primed(state("running"))
        let waiting = state("needsYou", "awaitingReply")
        #expect(detector.observe([task: waiting], now: t0.addingTimeInterval(1)).isEmpty)
        #expect(detector.observe([task: waiting], now: t0.addingTimeInterval(3)).isEmpty)
        let changes = detector.observe([task: waiting], now: t0.addingTimeInterval(4))
        #expect(changes.map(\.events) == [[.needsYou]])
        #expect(changes.first?.state.key.attention == "awaitingReply")
        // It fires once.
        #expect(detector.observe([task: waiting], now: t0.addingTimeInterval(10)).isEmpty)
    }

    @Test func aStatusThatFlickersBackSendsNothing() {
        var detector = primed(state("needsYou", "agentFinished"))
        #expect(detector.observe([task: state("running")], now: t0.addingTimeInterval(1)).isEmpty)
        #expect(detector.observe([task: state("needsYou", "agentFinished")], now: t0.addingTimeInterval(2)).isEmpty)
        #expect(detector.observe([task: state("needsYou", "agentFinished")], now: t0.addingTimeInterval(9)).isEmpty)
    }

    @Test func aNewReasonInsideNeedsYouFiresAgain() {
        var detector = primed(state("needsYou", "agentFinished"))
        _ = detector.observe([task: state("needsYou", "awaitingReply")], now: t0.addingTimeInterval(1))
        let changes = detector.observe([task: state("needsYou", "awaitingReply")], now: t0.addingTimeInterval(5))
        #expect(changes.map(\.events) == [[.needsYou]])
    }

    @Test func runningAndIdleAreReportedForWebhooksThatOptIn() {
        var detector = primed(state("needsYou", "agentFinished"))
        _ = detector.observe([task: state("running")], now: t0.addingTimeInterval(1))
        #expect(detector.observe([task: state("running")], now: t0.addingTimeInterval(5)).map(\.events) == [[.running]])
        _ = detector.observe([task: state("idle")], now: t0.addingTimeInterval(6))
        #expect(detector.observe([task: state("idle")], now: t0.addingTimeInterval(10)).map(\.events) == [[.idle]])
    }

    @Test func recordStagesAndMergesCountAtOnce() {
        var detector = primed(state("needsYou", "review"))
        let merged = detector.observe([task: state("toShip", merged: true)], now: t0.addingTimeInterval(1))
        #expect(merged.map(\.events) == [[.merged, .done]])
        // To ship then Done is still done: the change counts, with no
        // second event.
        let shipped = detector.observe([task: state("done", merged: true)], now: t0.addingTimeInterval(2))
        #expect(shipped.map(\.events) == [[]])
        #expect(shipped.first?.state.key.group == "done")
        #expect(detector.observe([task: state("archived", merged: true)], now: t0.addingTimeInterval(3)).map(\.events) == [[.archived]])
    }

    @Test func aDeletedTaskReportsItsLastState() {
        var detector = primed(state("needsYou", "review", title: "Ship webhooks"))
        let changes = detector.observe([:], now: t0.addingTimeInterval(1))
        #expect(changes.map(\.events) == [[.deleted]])
        #expect(changes.first?.state.title == "Ship webhooks")
    }

    @Test func aNewTaskThatNeedsTheUserFiresAtOnce() {
        var detector = primed(state("running"))
        let other = UUID()
        let changes = detector.observe([task: state("running"), other: state("needsYou", "pickWorkspace")], now: t0.addingTimeInterval(1))
        #expect(changes.map(\.taskID) == [other])
        #expect(changes.map(\.events) == [[.needsYou]])
    }

    @Test func aSavedBaselineSurvivesARelaunch() throws {
        var detector = primed(state("needsYou", "review"))
        let data = try JSONEncoder().encode(detector)
        var restored = try JSONDecoder().decode(TaskWebhookEventDetector.self, from: data)
        // Still waiting: nothing new.
        #expect(restored.observe([task: state("needsYou", "review")], now: t0.addingTimeInterval(60)).isEmpty)
        // Merged while Toastty was quit: fires once.
        #expect(restored.observe([task: state("done", merged: true)], now: t0.addingTimeInterval(61)).map(\.events) == [[.merged, .done]])
        detector.reset()
        #expect(detector.observe([task: state("done", merged: true)], now: t0).isEmpty)
    }
}

struct TaskWebhookSettingsTests {
    private func webhook(_ change: (inout TaskWebhook) -> Void = { _ in }) -> TaskWebhook {
        var webhook = TaskWebhook(
            name: "grok",
            url: "https://hooks.example.com/v1/routines/rt_8f2c91ab77/wake",
            auth: .bearer,
            requestedAt: Date(timeIntervalSince1970: 0),
            requestedBy: TaskWebhookRequester()
        )
        change(&webhook)
        return webhook
    }

    @Test func theApprovalDigestCoversWhereAndWhatButNotState() {
        let base = webhook().settingsDigest
        #expect(webhook { $0.url = "https://evil.example.com/x" }.settingsDigest != base)
        #expect(webhook { $0.events = [.needsYou] }.settingsDigest != base)
        #expect(webhook { $0.roots = ["/repo"] }.settingsDigest != base)
        #expect(webhook { $0.externalRefPrefix = "grok:" }.settingsDigest != base)
        #expect(webhook { $0.auth = .hmac }.settingsDigest != base)
        #expect(webhook { $0.status = .approved; $0.lastDelivery = TaskWebhookDelivery(at: Date(), statusCode: 200) }.settingsDigest == base)
        // Field boundaries hold whatever the values contain.
        #expect(webhook { $0.roots = ["/a\u{1F}/b"] }.settingsDigest != webhook { $0.roots = ["/a", "/b"] }.settingsDigest)
    }

    @Test func filtersMatchRootsAndExternalReferences() {
        let all = webhook()
        #expect(all.matches(projectRoot: nil, externalRefID: nil))
        let scoped = webhook { $0.roots = ["/repos/toastty"]; $0.externalRefPrefix = "grok:" }
        #expect(scoped.matches(projectRoot: "/repos/toastty", externalRefID: "grok:12"))
        #expect(scoped.matches(projectRoot: "/repos/toastty/sub", externalRefID: "grok:12"))
        #expect(scoped.matches(projectRoot: "/repos/toastty-other", externalRefID: "grok:12") == false)
        #expect(scoped.matches(projectRoot: "/repos/toastty", externalRefID: nil) == false)
        #expect(scoped.matches(projectRoot: "/repos/toastty", externalRefID: "linear:1") == false)
    }

    @Test func theDisplayURLKeepsTheHostAndHidesThePath() {
        #expect(webhook().displayURL == "https://hooks.example.com/…")
        #expect(TaskWebhookValidation.displayURL("https://h.example/abc123?token=x") == "https://h.example/…")
        #expect(TaskWebhookValidation.displayURL("http://127.0.0.1:8080") == "http://127.0.0.1:8080")
    }

    @Test func urlsMustBeHTTPSExceptLoopback() throws {
        #expect(try TaskWebhookValidation.validateURL(" https://a.example/x ") == "https://a.example/x")
        #expect(try TaskWebhookValidation.validateURL("http://127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
        #expect(try TaskWebhookValidation.validateURL("http://localhost/x") == "http://localhost/x")
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateURL("http://a.example/x") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateURL("https://user:pw@a.example/x") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateURL("ftp://a.example/x") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateURL("a.example/x") }
    }

    @Test func authModesParseAndHeaderNamesAreChecked() throws {
        #expect(TaskWebhookAuth("bearer") == .bearer)
        #expect(TaskWebhookAuth("header:X-Sender-Key") == .header(name: "X-Sender-Key"))
        #expect(TaskWebhookAuth("hmac") == .hmac)
        #expect(TaskWebhookAuth("header:") == nil)
        #expect(TaskWebhookAuth("basic") == nil)
        try TaskWebhookValidation.validateAuth(.header(name: "X-Sender-Key"), url: "https://a.example")
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateAuth(.header(name: "Host"), url: "https://a.example") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateAuth(.header(name: "Toastty-Event-ID"), url: "https://a.example") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateAuth(.header(name: "X Bad"), url: "https://a.example") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateAuth(.none, url: "https://a.example") }
        try TaskWebhookValidation.validateAuth(.none, url: "http://127.0.0.1:9/x")
    }

    @Test func secretsAndNamesAreChecked() throws {
        try TaskWebhookValidation.validateSecret("0123456789abcdef")
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateSecret("short") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateSecret("0123456789abcdef with space") }
        try TaskWebhookValidation.validateName("grok-bot_2")
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateName("Grok") }
        #expect(throws: TaskWebhookValidationError.self) { try TaskWebhookValidation.validateName("-x") }
    }

    @Test func theSignatureMatchesAnHMACOfTimestampAndBody() {
        let header = TaskWebhookSignature.header(secret: "0123456789abcdef-secret", timestamp: 1_800_000_000, body: Data(#"{"a":1}"#.utf8))
        #expect(header == "t=1800000000,v1=a95fb1cc54a8da42527df108b59e48635de2e4b67017c98aa3ced6c359aba57a")
    }

    @Test func retriesBackOffAndRefusalsStop() {
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 204) == .delivered)
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: nil) == .retry)
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 503) == .retry)
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 429) == .retry)
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 401) == .disable(reason: "HTTP 401"))
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 410) == .disable(reason: "HTTP 410"))
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 400) == .drop)
        #expect(TaskWebhookRetryPolicy.outcome(statusCode: 302) == .drop)
        #expect([1, 2, 3, 6, 20].map(TaskWebhookRetryPolicy.delay(afterAttempts:)) == [5, 15, 45, 600, 600])
    }

    @Test func thePayloadKeepsNullKeysAndCarriesNoReplyText() throws {
        let state = TaskWebhookTaskState(
            key: .init(group: "needsYou", attention: "awaitingReply"),
            title: "Webhook design",
            question: "Approve the design?"
        )
        let payload = TaskWebhookPayload(
            eventID: UUID(), type: .needsYou, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            webhook: "grok", taskID: UUID(), state: state
        )
        let object = try JSONSerialization.jsonObject(with: try payload.encoded()) as? [String: Any]
        #expect(object?["type"] as? String == "task.needs_you")
        #expect(object?["occurredAt"] as? String == "2027-01-15T08:00:00Z")
        let task = object?["task"] as? [String: Any]
        #expect(task?["question"] as? String == "Approve the design?")
        #expect(task?.keys.contains("mergedAt") == true)
        #expect(task?["mergedAt"] is NSNull)
        #expect(Set(task?.keys ?? [:].keys) == ["id", "title", "projectRoot", "externalRef", "stage", "question", "pullRequestURL", "mergedAt"])
    }
}
