import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Failure modes: an alert for a stage that flips back quickly; an alert
/// for tasks that already waited when sampling started (relaunch); a merge
/// that stopped reported as a plain review; alerts for Needs you reasons the
/// session's own alerts cover; two alerts for one finished turn; a held
/// session alert that never goes out; and a relay without task alerts that
/// leaves the phone silent.
struct TaskAlertDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let task = UUID()

    private func sample(_ stage: TaskStage, merging: Bool = false) -> [UUID: TaskAlertDetector.Observation] {
        [task: .init(stage: stage, isMerging: merging)]
    }

    /// Feeds `steps` one second apart after priming with `initial`, and
    /// returns every trigger.
    private func run(from initial: TaskStage, initialMerging: Bool = false,
                     _ steps: [(TaskStage, Bool)]) -> [RemotePushTaskAlertReason] {
        var detector = TaskAlertDetector()
        #expect(detector.observe(sample(initial, merging: initialMerging), now: t0).isEmpty)
        var reasons: [RemotePushTaskAlertReason] = []
        for (index, step) in steps.enumerated() {
            let at = t0.addingTimeInterval(TimeInterval(index + 1))
            reasons += detector.observe(sample(step.0, merging: step.1), now: at).map(\.reason)
        }
        return reasons
    }

    private func held(_ stage: TaskStage, merging: Bool = false, seconds: Int = 4) -> [(TaskStage, Bool)] {
        Array(repeating: (stage, merging), count: seconds)
    }

    @Test func tasksThatAlreadyWaitedWhenSamplingStartedSendNothing() {
        var detector = TaskAlertDetector()
        #expect(detector.observe(sample(.needsYou(.awaitingReply)), now: t0).isEmpty)
        #expect(detector.observe(sample(.needsYou(.awaitingReply)), now: t0.addingTimeInterval(10)).isEmpty)
    }

    @Test func aQuestionCountsOnlyAfterItHoldsForTheSettleWindow() {
        var detector = TaskAlertDetector()
        _ = detector.observe(sample(.running), now: t0)
        #expect(detector.observe(sample(.needsYou(.awaitingReply)), now: t0.addingTimeInterval(1)).isEmpty)
        #expect(detector.observe(sample(.needsYou(.awaitingReply)), now: t0.addingTimeInterval(3.9)).isEmpty)
        let fired = detector.observe(sample(.needsYou(.awaitingReply)), now: t0.addingTimeInterval(4))
        #expect(fired == [.init(taskID: task, reason: .question)])
        #expect(detector.observe(sample(.needsYou(.awaitingReply)), now: t0.addingTimeInterval(9)).isEmpty)
    }

    @Test func aStageThatFlipsBackQuicklySendsNothing() {
        #expect(run(from: .running, [(.needsYou(.review), false), (.needsYou(.review), false)] + held(.running)).isEmpty)
    }

    @Test func eachReasonWithAnAlertFiresOnce() {
        #expect(run(from: .running, held(.needsYou(.review))) == [.review])
        #expect(run(from: .running, held(.needsYou(.readyForReview))) == [.review])
        #expect(run(from: .starting, held(.needsYou(.setupFailed(reason: "create_hook exited 1")))) == [.setupFailed])
        #expect(run(from: .starting, held(.needsYou(.moveFailed(reason: "dirty tree")))) == [.moveFailed])
        #expect(run(from: .done, held(.needsYou(.cleanupStopped(reason: "worktree busy")))) == [.cleanupStopped])
        // A pull request answer that arrives after the turn ends turns an
        // unread finish into a review.
        #expect(run(from: .running, held(.needsYou(.agentFinished)) + held(.needsYou(.review))) == [.review])
    }

    @Test func reasonsTheSessionAlertsCoverOrTheUserJustCausedSendNothing() {
        for stage in [
            TaskStage.needsYou(.agentFinished), .needsYou(.agentNeedsInput), .needsYou(.agentError),
            .needsYou(.taskSpaceClosed), .needsYou(.pickWorkspace(reason: "no match")), .idle, .done, .toShip,
        ] {
            #expect(run(from: .running, held(stage)).isEmpty, "\(stage)")
        }
    }

    @Test func aMergeThatStopsIsReportedAsStoppedNotAsAReview() {
        #expect(run(from: .needsYou(.review), held(.running, merging: true) + held(.needsYou(.review))) == [.mergeStopped])
        #expect(run(from: .running, initialMerging: true, held(.needsYou(.agentFinished))) == [.mergeStopped])
        #expect(run(from: .running, initialMerging: true, held(.needsYou(.agentError))) == [.mergeStopped])
        // The merge skill asked a question: the question is what the user acts on.
        #expect(run(from: .running, initialMerging: true, held(.needsYou(.awaitingReply))) == [.question])
        // A merge that finished sends nothing; a stopped cleanup after it does.
        #expect(run(from: .running, initialMerging: true, held(.done)).isEmpty)
        #expect(run(from: .running, initialMerging: true, held(.needsYou(.cleanupStopped(reason: "busy")))) == [.cleanupStopped])
        // An approval during the check is not a stop.
        #expect(run(from: .running, initialMerging: true, held(.needsYou(.agentNeedsInput))).isEmpty)
    }

    /// A merge that fails at once, such as Toastty's own merge refused by
    /// GitHub, ends before its merging stage settles.
    @Test func aMergeThatEndsBeforeItSettlesStillCounts() {
        let short: [(TaskStage, Bool)] = [(.running, true), (.running, true)]
        #expect(run(from: .needsYou(.review), short + held(.needsYou(.review))) == [.mergeStopped])
        #expect(run(from: .needsYou(.review), short + held(.needsYou(.agentError))) == [.mergeStopped])
        #expect(run(from: .needsYou(.review), short + held(.done)).isEmpty)
        // Once the outcome settled, the next review is a plain review again.
        let again = held(.running) + held(.needsYou(.review))
        #expect(run(from: .needsYou(.review), short + held(.needsYou(.review)) + again) == [.mergeStopped, .review])
    }

    @Test func aNewTaskThatFailedFiresAtOnceAndADeletedTaskIsForgotten() {
        var detector = TaskAlertDetector()
        _ = detector.observe([:], now: t0)
        let fired = detector.observe(sample(.needsYou(.setupFailed(reason: "x"))), now: t0.addingTimeInterval(1))
        #expect(fired.map(\.reason) == [.setupFailed])
        #expect(detector.observe([:], now: t0.addingTimeInterval(2)).isEmpty)
        #expect(detector.observe(sample(.running), now: t0.addingTimeInterval(3)).isEmpty)
    }
}

@MainActor
struct RemoteTaskAlertsPlannerTests {
    private let clock = ManualClock()
    private let conversation = RemoteConversationID()

    private func planner(startupDelay: TimeInterval = 0) -> RemoteTaskAlerts {
        RemoteTaskAlerts(
            timing: .init(passInterval: nil, startupDelay: startupDelay, settleInterval: 3, sessionHold: 8),
            now: { [clock] in clock.now }
        )
    }

    private func item(_ record: TaskRecord, _ stage: TaskStage, pullRequest: Int? = nil) -> TaskBoardItem {
        TaskBoardItem(
            id: .task(record.id), record: record, title: record.title, taskSpaceWorkspaceID: UUID(), stage: stage,
            agent: .idle,
            pullRequest: pullRequest.flatMap { WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/\($0)") },
            activityAt: clock.now
        )
    }

    private func record(_ title: String, question: String? = nil) -> TaskRecord {
        var record = TaskRecord(createdAt: clock.now, text: title, title: title, slug: "slug", source: .cli, setup: .started)
        record.replyRequest = question.map { TaskReplyRequest(askedAt: clock.now, question: $0) }
        return record
    }

    private func turnAlert() -> RemotePushSessionNotification {
        RemotePushSessionNotification(eventID: UUID(), conversationID: conversation, sessionTitle: "Agent", status: .ready)
    }

    /// Runs passes one second apart for `seconds`, with the board `items`.
    private func passes(_ alerts: RemoteTaskAlerts, _ items: [TaskBoardItem], seconds: Int) -> [RemoteTaskAlerts.Delivery] {
        var deliveries: [RemoteTaskAlerts.Delivery] = []
        for _ in 0..<seconds {
            clock.advance(1)
            deliveries += alerts.pass(items: items) { _ in nil }
        }
        return deliveries
    }

    @Test func aTaskAlertReplacesTheHeldTurnAlertOfItsTask() throws {
        let alerts = planner()
        let asking = record("iOS task support", question: "Should the badge count tasks?")
        let other = record("Other task")
        #expect(alerts.pass(items: [item(asking, .running), item(other, .running)]) { _ in nil }.isEmpty)
        let ownTurn = turnAlert()
        let otherTurn = turnAlert()
        alerts.hold(ownTurn, taskID: asking.id)
        alerts.hold(otherTurn, taskID: other.id)
        let deliveries = passes(alerts, [item(asking, .needsYou(.awaitingReply)), item(other, .needsYou(.agentFinished))], seconds: 9)
        let taskAlerts = deliveries.compactMap { if case .task(let alert) = $0 { alert } else { nil } }
        let alert = try #require(taskAlerts.first)
        #expect(taskAlerts.count == 1)
        #expect(alert.replaced == [ownTurn])
        #expect(alert.notification.taskID == asking.id)
        #expect(alert.notification.reason == .question)
        #expect(alert.notification.taskTitle == "iOS task support")
        #expect(alert.notification.detail == "Should the badge count tasks?")
        // The tap opens the session whose turn the alert replaced.
        #expect(alert.notification.conversationID == conversation)
        // The other task needs nothing an alert reports, so its turn alert
        // goes out once the hold ends, and only once.
        #expect(deliveries.filter { $0 == .session(otherTurn) }.count == 1)
        #expect(deliveries.contains(.session(ownTurn)) == false)
        #expect(alerts.hasHeldAlerts == false)
    }

    @Test func aTaskAlertWithoutAHeldTurnNamesTheTaskSpaceSessionAndItsPullRequest() throws {
        let alerts = planner()
        let reviewed = record("Jump-to-next-active fix", question: "stale")
        #expect(alerts.pass(items: [item(reviewed, .running, pullRequest: 263)]) { _ in nil }.isEmpty)
        var found: [RemotePushTaskNotification] = []
        for _ in 0..<5 {
            clock.advance(1)
            for case .task(let alert) in alerts.pass(items: [item(reviewed, .needsYou(.review), pullRequest: 263)], conversationID: { _ in conversation }) {
                found.append(alert.notification)
            }
        }
        let notification = try #require(found.first)
        #expect(found.count == 1)
        #expect(notification.reason == .review)
        #expect(notification.pullRequestNumber == 263)
        // Only a question carries the record's question text.
        #expect(notification.detail == nil)
        #expect(notification.conversationID == conversation)
    }

    /// A finished turn asks GitHub about the pull request. A slow answer that
    /// turns the task into a review still replaces the turn's alert.
    @Test func aTurnAlertWaitsForAnOutstandingPullRequestAnswer() throws {
        let alerts = planner()
        let task = record("Jump-to-next-active fix")
        #expect(alerts.pass(items: [item(task, .running, pullRequest: 263)]) { _ in nil }.isEmpty)
        let turn = turnAlert()
        alerts.hold(turn, taskID: task.id)
        var deliveries: [RemoteTaskAlerts.Delivery] = []
        // The draft answer from before the turn: an unread finish for 20 s
        // while `gh` runs, then the answer says it is ready for review.
        for second in 1...30 {
            clock.advance(1)
            let stage: TaskStage = second <= 20 ? .needsYou(.agentFinished) : .needsYou(.review)
            deliveries += alerts.pass(
                items: [item(task, stage, pullRequest: 263)], isAwaitingPullRequest: { _ in second <= 20 }
            ) { _ in nil }
        }
        let taskAlerts = deliveries.compactMap { if case .task(let alert) = $0 { alert } else { nil } }
        #expect(taskAlerts.map(\.notification.reason) == [.review])
        #expect(taskAlerts.first?.replaced == [turn])
        #expect(deliveries.contains(.session(turn)) == false)

        // An answer that changes nothing releases the alert once it settles,
        // and a request that never ends releases it at the maximum hold.
        let quiet = planner()
        #expect(quiet.pass(items: [item(task, .running, pullRequest: 263)]) { _ in nil }.isEmpty)
        let other = turnAlert()
        quiet.hold(other, taskID: task.id)
        var released: [Int] = []
        for second in 1...80 {
            clock.advance(1)
            let out = quiet.pass(items: [item(task, .needsYou(.agentFinished), pullRequest: 263)],
                                 isAwaitingPullRequest: { _ in true }) { _ in nil }
            if out.contains(.session(other)) { released.append(second) }
        }
        #expect(released == [75])
    }

    @Test func aTaskAlertOpensTheTasksOwnAgentBeforeTheSessionItReplaced() throws {
        let alerts = planner()
        let asking = record("Task", question: "Q?")
        #expect(alerts.pass(items: [item(asking, .running)]) { _ in nil }.isEmpty)
        alerts.hold(turnAlert(), taskID: asking.id)
        let owner = RemoteConversationID()
        var found: [RemotePushTaskNotification] = []
        for _ in 0..<5 {
            clock.advance(1)
            for case .task(let alert) in alerts.pass(items: [item(asking, .needsYou(.awaitingReply))], conversationID: { _ in owner }) {
                found.append(alert.notification)
            }
        }
        #expect(found.map(\.conversationID) == [owner])
    }

    @Test func theStartupDelayHoldsAlertsBackButNotHeldTurnAlerts() {
        let alerts = planner(startupDelay: 10)
        let asking = record("Task", question: "Q?")
        #expect(alerts.pass(items: [item(asking, .running)]) { _ in nil }.isEmpty)
        let turn = turnAlert()
        alerts.hold(turn, taskID: asking.id)
        let deliveries = passes(alerts, [item(asking, .needsYou(.awaitingReply))], seconds: 9)
        // The first sample after the delay only records, so the question
        // that was already waiting sends no task alert.
        #expect(deliveries == [.session(turn)])
        #expect(passes(alerts, [item(asking, .needsYou(.awaitingReply))], seconds: 10).isEmpty)
    }

    @Test func resetDropsHeldAlertsAndStartsFromTheCurrentStages() {
        let alerts = planner()
        let asking = record("Task", question: "Q?")
        _ = alerts.pass(items: [item(asking, .running)]) { _ in nil }
        alerts.hold(turnAlert(), taskID: asking.id)
        alerts.reset()
        #expect(alerts.hasHeldAlerts == false)
        #expect(passes(alerts, [item(asking, .needsYou(.awaitingReply))], seconds: 9).isEmpty)
    }
}

/// Runs a real task, board and remote service with a relay that records
/// what it would send to Apple.
@MainActor
struct RemoteTaskAlertServiceTests {
    @Test func aTurnThatAsksTheUserSendsOneTaskAlertInsteadOfTheReadyAlert() async throws {
        let harness = try await Harness()
        defer { harness.removeRuntimeFiles() }
        harness.finishTurn(asking: "Should the badge count tasks or sessions?")
        await harness.passUntil { harness.relay.calls.count == 1 }
        let call = try #require(harness.relay.calls.first)
        guard case .task(let alert) = call.alert else {
            Issue.record("Expected a task alert, got \(call.alert)")
            return
        }
        #expect(alert.reason == .question)
        #expect(alert.taskID == harness.taskID)
        #expect(alert.detail == "Should the badge count tasks or sessions?")
        #expect(alert.conversationID == harness.conversationID)
        #expect(call.registrationID == harness.registrationID)
        // The held Ready alert never goes out.
        await harness.pass(seconds: 10)
        #expect(harness.relay.calls.count == 1)
    }

    /// The relay deploy is separate. Until it is live, the relay refuses
    /// task alerts with HTTP 400, and the Mac sends the Ready alert it sent
    /// before, so the phone does not go silent.
    @Test func aRelayWithoutTaskAlertsGetsTheSessionAlertInstead() async throws {
        let harness = try await Harness()
        defer { harness.removeRuntimeFiles() }
        harness.relay.taskOutcome = .unsupportedAlert
        harness.finishTurn(asking: "Ship it?")
        await harness.passUntil { harness.relay.calls.count == 2 }
        let kinds = harness.relay.calls.map(\.alert.kind)
        #expect(kinds == ["task", "session"])
        guard case .session(let fallback) = harness.relay.calls.last?.alert else {
            Issue.record("Expected the session alert")
            return
        }
        #expect(fallback.status == .ready)
        #expect(fallback.conversationID == harness.conversationID)
        #expect(harness.relay.calls.allSatisfy { $0.registrationID == harness.registrationID })
        await harness.pass(seconds: 10)
        #expect(harness.relay.calls.count == 2)
    }

    @Test func aTurnThatNeedsNothingMoreSendsTheReadyAlertAfterTheHold() async throws {
        let harness = try await Harness()
        defer { harness.removeRuntimeFiles() }
        harness.finishTurn(asking: nil)
        await harness.pass(seconds: 7)
        #expect(harness.relay.calls.isEmpty)
        await harness.passUntil { harness.relay.calls.count == 1 }
        #expect(harness.relay.calls.map(\.alert.kind) == ["session"])
        await harness.pass(seconds: 10)
        #expect(harness.relay.calls.count == 1)
    }

    @Test func aMacInUseSendsNoTaskAlert() async throws {
        let harness = try await Harness()
        defer { harness.removeRuntimeFiles() }
        harness.finishTurn(asking: "Ship it?")
        harness.macInUse = true
        await harness.pass(seconds: 12)
        #expect(harness.relay.calls.isEmpty)
    }

    /// The user came back to the Mac while the Ready alert was held.
    @Test func aMacInUseWhenTheHoldEndsSendsNoReadyAlert() async throws {
        let harness = try await Harness()
        defer { harness.removeRuntimeFiles() }
        harness.finishTurn(asking: nil)
        await harness.pass(seconds: 4)
        harness.macInUse = true
        await harness.pass(seconds: 10)
        #expect(harness.relay.calls.isEmpty)
    }
}

@MainActor
private final class Harness {
    let fixture: TaskCoordinatorTests.Fixture
    let board: TaskBoardStore
    let relay = TaskAlertRelaySpy()
    let clock = ManualClock()
    let service: RemoteAccessService
    let taskID: UUID
    let sessionID: String
    let registrationID = UUID()
    var macInUse = false
    private(set) var conversationID: RemoteConversationID?
    private let runtimeHome = "/tmp/toastty-remote-task-alerts-\(UUID().uuidString)"

    init() async throws {
        fixture = try TaskCoordinatorTests.Fixture()
        board = TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: NoPullRequests()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "iOS task support", workspaceID: fixture.workspaceID, agent: "codex", prompt: "Start."))
        await fixture.waitForSetup(created.id)
        taskID = created.id
        sessionID = try #require(fixture.record(created.id)?.operation.agentLaunch?.sessionID)

        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: "/tmp/toastty-remote-access-test-home",
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome]
        )
        let configuration = try #require(RemotePushConfiguration(relayURL: URL(string: "https://push.example.com")!))
        let devices = RemoteDeviceStore(fileURL: runtimePaths.remoteAccessDevicesFileURL)
        let offer = try devices.issueNativePairingOffer(gatewayURL: URL(string: "https://test.tailnet.ts.net")!, at: Date())
        guard case .paired(let device, _) = try devices.redeemNativePairingOffer(
            using: .qr(offerID: offer.id, secret: offer.qrPayload.secret),
            deviceName: "Test phone", tailscaleLogin: "owner@example.com", at: Date()
        ) else { throw CocoaError(.coderInvalidValue) }
        try devices.setPushRegistration(
            .init(registrationID: registrationID, sendToken: String(repeating: "A", count: 43), relayID: configuration.relayID),
            forDevice: device.id, configuration: configuration
        )

        let server = TaskAlertGatewayServerSpy()
        let clock = clock
        var harness: Harness?
        service = RemoteAccessService(
            store: fixture.store,
            annotationStyleStore: AnnotationStyleStore(runtimePaths: runtimePaths),
            taskBoard: board,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            terminalRuntimeRegistry: TerminalRuntimeRegistry(),
            runtimePaths: runtimePaths,
            port: 42_994,
            initiallyEnabled: false,
            pushConfiguration: configuration,
            pushRelay: relay,
            pushMacPresence: { RemotePushMacPresence(screenIsLocked: harness?.macInUse != true, idleSeconds: 0) },
            taskAlerts: RemoteTaskAlerts(
                timing: .init(passInterval: nil, startupDelay: 0, settleInterval: 3, sessionHold: 8),
                now: { clock.now }
            ),
            gatewayServerFactory: { _ in server }
        )
        harness = self
        service.setEnabled(true, persist: false)
        server.onListenerReady?(42_994)
        // The agent works on the task; the first sample only records.
        status(.working)
        service.runTaskAlertPass()
        await pass(seconds: 4)
    }

    func status(_ kind: SessionStatusKind) {
        clock.advance(0.1)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: sessionID, status: SessionStatus(kind: kind, summary: kind.rawValue), at: clock.now)
    }

    /// The agent ends its turn, after `task needs-reply` when it asks.
    func finishTurn(asking question: String?) {
        if let question {
            _ = try? fixture.coordinator.needsReply(taskID: taskID, question: question)
        }
        status(.ready)
        let panelID = fixture.record(taskID)?.operation.taskSpace?.panelID
        conversationID = fixture.store.state.workspacesByID.values.lazy
            .compactMap { workspace -> RemoteConversationID? in
                guard let panelID, case .terminal(let terminal) = workspace.allPanelsByID[panelID] else { return nil }
                return terminal.remoteConversationID
            }
            .first
    }

    func pass(seconds: Int) async {
        for _ in 0..<seconds {
            clock.advance(1)
            service.runTaskAlertPass()
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Passes one second at a time until `condition` holds, up to 20.
    func passUntil(_ condition: () -> Bool) async {
        for _ in 0..<20 where condition() == false {
            await pass(seconds: 1)
        }
        #expect(condition())
    }

    func removeRuntimeFiles() {
        service.setEnabled(false, persist: false)
        try? FileManager.default.removeItem(atPath: runtimeHome)
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@MainActor
private final class TaskAlertRelaySpy: RemotePushRelaying {
    enum Alert {
        case session(RemotePushSessionNotification)
        case task(RemotePushTaskNotification)

        var kind: String {
            switch self {
            case .session: "session"
            case .task: "task"
            }
        }
    }

    struct Call {
        var alert: Alert
        var registrationID: UUID
    }

    var calls: [Call] = []
    var taskOutcome: RemotePushSendOutcome = .accepted

    func send(_ notification: RemotePushSessionNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome {
        calls.append(Call(alert: .session(notification), registrationID: registration.registrationID))
        return .accepted
    }

    func send(_ notification: RemotePushTaskNotification, to registration: RemoteDevicePushRegistration) async -> RemotePushSendOutcome {
        calls.append(Call(alert: .task(notification), registrationID: registration.registrationID))
        return taskOutcome
    }

    func revoke(_ registration: RemoteDevicePushRegistration) async -> Bool { true }
}

/// Answers no pull request question, so the board keeps what it has.
private struct NoPullRequests: WorkspaceMergeCommandRunning {
    func run(arguments _: [String], directory _: String, timeout _: TimeInterval) async -> WorkspaceMergeCommandResult {
        WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "gh: not found", failure: nil)
    }
}

private final class TaskAlertGatewayServerSpy: RemoteAccessGatewayServing {
    var onWebSocketCountsChanged: ((RemoteAccessWebSocketCounts) -> Void)?
    var onDeviceRevoked: ((UUID) -> Void)?
    var onListenerReady: ((UInt16) -> Void)?
    var onListenerFailed: ((RemoteAccessListenerFailure) -> Void)?

    func start(port _: UInt16) throws {}
    func stop() {}
    func disconnectWebSockets(for _: UUID) {}
    func disconnectAllWebSockets() {}
    func broadcast(_: RemoteGatewayStreamMessage) {}
}
