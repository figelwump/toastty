import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Wakes for the coordinator: task changes and its timer, from the event
/// service with a fake clock to the text typed at the coordinator's prompt.
/// The coordinator is the real controller over the real store, session
/// store and agent launcher, with a fake terminal.
@MainActor
struct CoordinatorWakeTests {
    typealias Fixture = CoordinatorControllerTests.Fixture

    private let task = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let other = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    /// The task states a test changes between passes.
    private final class States {
        var value: [UUID: TaskWebhookTaskState]
        init(_ value: [UUID: TaskWebhookTaskState]) { self.value = value }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private final class RecordingTransport: TaskWebhookTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        var types: [String] {
            lock.withLock {
                bodies.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["type"] as? String }
            }
        }
        func send(_ request: URLRequest) async -> TaskWebhookSendResult {
            lock.withLock { bodies.append(request.httpBody ?? Data()) }
            return TaskWebhookSendResult(statusCode: 200)
        }
    }

    private struct Files {
        let directory = FileManager.default.temporaryDirectory.appending(path: "toastty-wakes-\(UUID().uuidString)")
        var webhooks: URL { directory.appending(path: "task-webhooks.json") }
        var outbox: URL { directory.appending(path: "task-webhook-outbox.json") }
    }

    /// The event service as a new app launch would make it, over `files`,
    /// with the fixture's coordinator.
    private func makeService(
        _ fixture: Fixture,
        files: Files = Files(),
        clock: Clock,
        settleInterval: TimeInterval = 0,
        transport: any TaskWebhookTransport = RecordingTransport(),
        secrets: InMemoryTaskWebhookSecretStore = InMemoryTaskWebhookSecretStore(),
        states: @escaping @MainActor () -> [UUID: TaskWebhookTaskState]
    ) -> TaskWebhookService {
        let service = TaskWebhookService(
            webhooksFileURL: files.webhooks,
            outboxFileURL: files.outbox,
            secrets: secrets,
            transport: transport,
            now: { clock.now },
            timing: .init(passInterval: .seconds(3600), startupDelay: 0, settleInterval: settleInterval),
            userAgent: "Toastty/test"
        )
        service.taskStates = states
        service.attach(coordinator: fixture.controller)
        return service
    }

    private func state(_ group: String, _ attention: String? = nil, merged: Bool = false, title: String = "Wake design") -> TaskWebhookTaskState {
        TaskWebhookTaskState(
            key: .init(group: group, attention: attention, merged: merged),
            title: title,
            projectRoot: "/repos/toastty",
            question: attention == "awaitingReply" ? "Approve the design?" : nil
        )
    }

    private func line(_ id: UUID, _ title: String, _ stage: String, at date: Date) -> String {
        "- [\(title)](toastty://task/\(id.uuidString)): \(stage) at \(date.formatted(.iso8601))"
    }

    private func digest(_ lines: String...) -> String {
        ([CoordinatorWakeState.digestHeader] + lines + [CoordinatorWakeState.digestFooter]).joined(separator: "\n")
    }

    /// The coordinator runs the turn that the last typed text started, and
    /// its prompt opens again.
    private func runTurn(_ fixture: Fixture) async throws {
        try fixture.setStatus(.working)
        try fixture.setStatus(.idle)
        await fixture.settle()
    }

    private func savedOutbox(_ files: Files) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: files.outbox)) as? [String: Any])
    }

    // MARK: - Task changes

    @Test func aStageChangeIsTypedAsOneDigestAtTheOpenPrompt() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("running")])
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock) { current.value }
        // The first pass only records where the tasks stand.
        service.pass()
        #expect(fixture.typedTexts.isEmpty)

        clock.advance(30)
        current.value[task] = state("needsYou", "awaitingReply")
        service.pass()
        #expect(fixture.typedTexts == [digest(line(task, "Wake design", "needsYou (awaitingReply)", at: clock.now))])
        #expect(fixture.typed.first?.panelID == fixture.store.state.coordinator?.panelID)
        // Typed by Toastty, not by the user, and never the task's own text.
        let panelID = try #require(fixture.store.state.coordinator?.panelID)
        #expect(fixture.sessions.lastUserInputAt(panelID: panelID) == nil)
        #expect(fixture.typedTexts[0].contains("Approve the design") == false)
        // Told once: nothing waits, and later passes type nothing.
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 0)
        #expect(service.coordinatorWakeStatus?.lastWakeAt == clock.now)
        #expect(fixture.controller.queuedCount == 0)
        clock.advance(5)
        service.pass()
        try await runTurn(fixture)
        service.pass()
        #expect(fixture.typedTexts.count == 1)
    }

    @Test func severalChangesGoInOneDigestAndABusyCoordinatorGetsItAfterItsTurn() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("running"), other: state("running", title: "Other task")])
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock) { current.value }
        service.pass()
        try fixture.setStatus(.working)

        // Three changes of two tasks while the coordinator works.
        clock.advance(10)
        current.value[task] = state("needsYou", "review")
        service.pass()
        let otherChangedAt = clock.now.addingTimeInterval(10)
        clock.advance(10)
        current.value[other] = state("idle", title: "Other task")
        service.pass()
        clock.advance(10)
        current.value[task] = state("toShip", merged: true)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 2)
        // The digest is not in the coordinator's own queue, where it could
        // not grow and a quit would lose it.
        #expect(fixture.controller.queuedCount == 0)

        // An approval prompt is not an open prompt, and a turn that just
        // ended holds the prompt for its settle time.
        try fixture.setStatus(.needsApproval)
        service.pass()
        try fixture.setStatus(.idle)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        await fixture.settle()
        service.pass()
        #expect(fixture.typedTexts == [digest(
            line(other, "Other task", "idle", at: otherChangedAt),
            line(task, "Wake design", "toShip, merged", at: clock.now)
        )])

        // A change after that starts a new digest, which waits for the turn
        // that the first one started.
        clock.advance(10)
        current.value[other] = state("needsYou", "agentFinished", title: "Other task")
        service.pass()
        await fixture.settle()
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        try await runTurn(fixture)
        service.pass()
        #expect(fixture.typedTexts.count == 2)
        #expect(fixture.typedTexts[1] == digest(line(other, "Other task", "needsYou (agentFinished)", at: clock.now)))
    }

    @Test func aStageThatFlickersForUnderThreeSecondsWakesNothing() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("needsYou", "agentFinished")])
        try await fixture.openAtPrompt()
        let files = Files()
        let service = makeService(fixture, files: files, clock: clock, settleInterval: 3) { current.value }
        service.pass()

        // Running for two seconds between two tool calls, then back.
        clock.advance(1)
        current.value[task] = state("running")
        service.pass()
        clock.advance(2)
        current.value[task] = state("needsYou", "agentFinished")
        service.pass()
        clock.advance(10)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 0)

        // A stage that holds counts once the three seconds passed.
        current.value[task] = state("running")
        service.pass()
        clock.advance(2.5)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        clock.advance(1)
        service.pass()
        #expect(fixture.typedTexts == [digest(line(task, "Wake design", "running", at: clock.now))])
    }

    @Test func theUsersDraftAndWaitingMessagesGoBeforeTheDigest() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("running")])
        try await fixture.openAtPrompt()
        let panelID = try #require(fixture.store.state.coordinator?.panelID)
        let service = makeService(fixture, clock: clock) { current.value }
        service.pass()

        // The user has typed in the coordinator's terminal: nothing is typed
        // over the draft.
        fixture.terminals.handleLocalInput(for: panelID, kind: .key)
        current.value[task] = state("needsYou", "review")
        service.pass()
        await fixture.settle()
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 1)

        // They send it, and a message is sent to the coordinator during that
        // turn. The message goes first; the digest takes the prompt after.
        try fixture.setStatus(.working)
        #expect(try fixture.controller.send("from quick entry") == .queued(position: 1, hold: .busy))
        service.pass()
        try fixture.setStatus(.idle)
        await fixture.waitUntil("the waiting message is typed") { fixture.typedTexts == ["from quick entry"] }
        await fixture.settle()
        service.pass()
        #expect(fixture.typedTexts == ["from quick entry"])
        try await runTurn(fixture)
        service.pass()
        #expect(fixture.typedTexts.count == 2)
        #expect(fixture.typedTexts[1].hasPrefix(CoordinatorWakeState.digestPrefix))
        #expect(fixture.typedTexts[1].contains("needsYou (review)"))
    }

    @Test func anUnconfirmedReturnCountsAsTypedAndARestartKeepsWhatWaits() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("running")])
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock) { current.value }
        service.pass()

        // The text went in but the terminal did not confirm Return. Typing
        // it again would put it in the composer twice.
        fixture.nextSubmitIsUnconfirmed = true
        current.value[task] = state("idle")
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 0)
        await fixture.settle()
        service.pass()
        #expect(fixture.typedTexts.count == 1)

        // A change waits while no agent's prompt is open; a fresh agent
        // session in the same workspace gets it.
        try fixture.setStatus(.working)
        current.value[task] = state("needsYou", "agentError")
        service.pass()
        let restarted = try await fixture.controller.restart()
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        try fixture.reportAgentStarted()
        service.pass()
        #expect(fixture.typedTexts.count == 2)
        #expect(fixture.typed.last?.panelID == restarted.location.panelID)
        #expect(fixture.typedTexts[1].contains("needsYou (agentError)"))
    }

    // MARK: - Relaunch

    @Test func aQuitWithADigestWaitingTypesItOnceAfterTheRelaunch() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let files = Files()
        let current = States([task: state("running"), other: state("needsYou", "review", title: "Other task")])
        try await fixture.openAtPrompt()
        let first = makeService(fixture, files: files, clock: clock) { current.value }
        first.pass()
        try fixture.setStatus(.working)
        clock.advance(20)
        let changedAt = clock.now
        current.value[task] = state("needsYou", "awaitingReply")
        first.pass()
        #expect(fixture.typedTexts.isEmpty)
        // The change is on disk with the baseline before anything is typed.
        let saved = try #require(try savedOutbox(files)["coordinator"] as? [String: Any])
        #expect((saved["changes"] as? [[String: Any]])?.count == 1)
        first.stop()

        // Toastty relaunches. The other task's pull request merged meanwhile.
        clock.advance(600)
        current.value[other] = state("done", merged: true, title: "Other task")
        let second = makeService(fixture, files: files, clock: clock) { current.value }
        #expect(second.coordinatorWakeStatus?.pendingTaskCount == 1)
        try fixture.setStatus(.idle)
        await fixture.settle()
        second.pass()
        #expect(fixture.typedTexts == [digest(
            line(task, "Wake design", "needsYou (awaitingReply)", at: changedAt),
            line(other, "Other task", "done, merged", at: clock.now)
        )])
        try await runTurn(fixture)
        second.pass()
        second.stop()

        // A second relaunch repeats nothing.
        clock.advance(60)
        let third = makeService(fixture, files: files, clock: clock) { current.value }
        third.pass()
        await fixture.settle()
        third.pass()
        #expect(fixture.typedTexts.count == 1)
        #expect(third.coordinatorWakeStatus?.pendingTaskCount == 0)
    }

    // MARK: - Timer

    @Test func theCoordinatorSetsReadsAndClearsItsNextCheckAndARelaunchKeepsIt() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let files = Files()
        let current = States([:])
        try await fixture.openAtPrompt()
        let first = makeService(fixture, files: files, clock: clock) { current.value }
        first.pass()
        // No time set and no open task: no timer.
        #expect(first.coordinatorWakeStatus?.nextWake == nil)

        let set = try first.setCoordinatorWake(.after(1200))
        #expect(set.nextWake == .init(at: clock.now.addingTimeInterval(1200), isRequested: true))
        #expect(first.coordinatorWakeStatus == set)
        // A new time replaces it, and clearing removes it.
        let moved = clock.now.addingTimeInterval(7200)
        #expect(try first.setCoordinatorWake(.at(moved)).nextWake == .init(at: moved, isRequested: true))
        #expect(try first.setCoordinatorWake(.clear).nextWake == nil)
        for refused in [TaskWebhookService.CoordinatorWakeRequest.after(59), .at(clock.now.addingTimeInterval(-10)), .after(0)] {
            #expect(throws: CoordinatorError("The next check must be at least 1 minute from now.")) {
                try first.setCoordinatorWake(refused)
            }
        }
        #expect(first.coordinatorWakeStatus?.nextWake == nil)

        let dueAt = clock.now.addingTimeInterval(1200)
        try first.setCoordinatorWake(.after(1200))
        first.stop()
        clock.advance(600)
        let second = makeService(fixture, files: files, clock: clock) { current.value }
        #expect(second.coordinatorWakeStatus?.nextWake == .init(at: dueAt, isRequested: true))

        // It fires at its time, as a digest with one line.
        clock.advance(599)
        second.pass()
        #expect(fixture.typedTexts.isEmpty)
        clock.advance(1)
        second.pass()
        #expect(fixture.typedTexts == [digest(
            "- Scheduled check: the time you set, \(dueAt.formatted(.iso8601)), has come."
        )])
        // Once: the wake removed the time, and no task is open.
        #expect(second.coordinatorWakeStatus?.nextWake == nil)
        try await runTurn(fixture)
        clock.advance(86_400)
        second.pass()
        #expect(fixture.typedTexts.count == 1)
    }

    @Test func aTimerThatCameDueWhileToasttyWasQuitFiresOnceAfterTheRelaunch() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let files = Files()
        let current = States([:])
        try await fixture.openAtPrompt()
        let first = makeService(fixture, files: files, clock: clock) { current.value }
        first.pass()
        let dueAt = clock.now.addingTimeInterval(1200)
        try first.setCoordinatorWake(.after(1200))
        first.stop()

        clock.advance(5 * 3600)
        let second = makeService(fixture, files: files, clock: clock) { current.value }
        second.pass()
        #expect(fixture.typedTexts == [digest(
            "- Scheduled check: the time you set, \(dueAt.formatted(.iso8601)), has come."
        )])
        try await runTurn(fixture)
        second.pass()
        second.stop()
        let third = makeService(fixture, files: files, clock: clock) { current.value }
        third.pass()
        #expect(fixture.typedTexts.count == 1)
    }

    @Test func withNoTimeSetTheCoordinatorWakesHourlyOnlyWhileATaskIsOpen() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("idle")])
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock) { current.value }
        let startedAt = clock.now
        service.pass()
        #expect(service.coordinatorWakeStatus?.nextWake == .init(at: startedAt.addingTimeInterval(3600), isRequested: false))

        clock.advance(3599)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        clock.advance(1)
        service.pass()
        let defaultCheck = digest("- Scheduled check: 1 hour has passed since the last wake, and you set no time.")
        #expect(fixture.typedTexts == [defaultCheck])
        // The next one is an hour after this wake.
        #expect(service.coordinatorWakeStatus?.nextWake == .init(at: clock.now.addingTimeInterval(3600), isRequested: false))
        try await runTurn(fixture)
        clock.advance(3600)
        service.pass()
        #expect(fixture.typedTexts == [defaultCheck, defaultCheck])
        try await runTurn(fixture)

        // The last open task finishes. That change wakes the coordinator;
        // after it there is no timer.
        clock.advance(60)
        current.value[task] = state("done")
        service.pass()
        #expect(fixture.typedTexts.count == 3)
        #expect(fixture.typedTexts[2] == digest(line(task, "Wake design", "done", at: clock.now)))
        try await runTurn(fixture)
        #expect(service.coordinatorWakeStatus?.nextWake == nil)
        clock.advance(10 * 3600)
        service.pass()
        #expect(fixture.typedTexts.count == 3)
    }

    @Test func anyTypedWakeRemovesTheTimeTheCoordinatorSetAndADueTimerJoinsTheDigest() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("running")])
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock) { current.value }
        service.pass()
        try service.setCoordinatorWake(.after(1200))

        // A task change is typed five minutes later: the time is gone, and
        // the default counts from this wake.
        clock.advance(300)
        current.value[task] = state("needsYou", "review")
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        #expect(fixture.typedTexts[0].contains("Scheduled check") == false)
        #expect(service.coordinatorWakeStatus?.nextWake == .init(at: clock.now.addingTimeInterval(3600), isRequested: false))

        // In the turn that the wake started, the coordinator sets its next
        // check. It comes due while the coordinator works on something else,
        // and a task changes too: one digest carries both.
        try fixture.setStatus(.working)
        let dueAt = clock.now.addingTimeInterval(600)
        try service.setCoordinatorWake(.after(600))
        clock.advance(700)
        current.value[task] = state("idle")
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        try fixture.setStatus(.idle)
        await fixture.settle()
        service.pass()
        #expect(fixture.typedTexts.count == 2)
        #expect(fixture.typedTexts[1] == digest(
            line(task, "Wake design", "idle", at: clock.now),
            "- Scheduled check: the time you set, \(dueAt.formatted(.iso8601)), has come."
        ))
    }

    // MARK: - No coordinator

    @Test func withNoCoordinatorNothingIsQueuedAndNothingRuns() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let files = Files()
        let current = States([task: state("running")])
        let service = makeService(fixture, files: files, clock: clock) { current.value }
        service.start()
        defer { service.stop() }
        #expect(service.isPolling == false)
        current.value[task] = state("needsYou", "review")
        service.pass()
        #expect(service.coordinatorWakeStatus == nil)
        #expect(service.coordinatorWake == nil)
        #expect(FileManager.default.fileExists(atPath: files.outbox.path) == false)
        #expect(throws: CoordinatorError("There is no coordinator. Open it first.")) {
            try service.setCoordinatorWake(.after(1200))
        }

        // Opening the coordinator starts the passes. It starts from now: the
        // change made before it existed is not told.
        try await fixture.openAtPrompt()
        #expect(service.isPolling)
        service.pass()
        clock.advance(5)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        current.value[task] = state("idle")
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        try await runTurn(fixture)

        // Closing its workspace stops them and drops what waited, with the
        // timer.
        try fixture.setStatus(.working)
        try service.setCoordinatorWake(.after(1200))
        current.value[task] = state("needsYou", "review")
        service.pass()
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 1)
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: workspaceID)))
        #expect(service.isPolling == false)
        #expect(service.coordinatorWake == nil)
        #expect(try savedOutbox(files)["coordinator"] == nil)

        // A coordinator opened later has nothing waiting and no timer.
        try await fixture.openAtPrompt()
        #expect(service.isPolling)
        service.pass()
        clock.advance(7200)
        current.value[task] = state("done")
        service.pass()
        #expect(fixture.typedTexts.count == 2)
        #expect(fixture.typedTexts[1] == digest(line(task, "Wake design", "done", at: clock.now)))
    }

    // MARK: - With webhooks

    @Test func aWebhookAndTheCoordinatorGetTheSameChangeAndAnApprovalKeepsTheCoordinatorsBaseline() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let transport = RecordingTransport()
        let current = States([task: state("running")])
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock, transport: transport) { current.value }
        service.pass()
        #expect(service.isPolling == false)
        service.start()
        defer { service.stop() }
        #expect(service.isPolling)

        // A change the coordinator has not been told yet, then a webhook is
        // approved. The approval must not make the service forget where the
        // tasks stood.
        clock.advance(10)
        current.value[task] = state("needsYou", "review")
        var settings = TaskWebhookService.Settings()
        settings.url = "https://hooks.example.com/w"
        settings.auth = .hmac
        let webhook = try service.add(name: "bot", settings: settings, secret: "s3cret-key-0123456789", requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        #expect(fixture.typedTexts[0].contains("needsYou (review)"))
        try await runTurn(fixture)

        // The webhook gets its default events; the coordinator also gets
        // running and idle.
        clock.advance(10)
        current.value[task] = state("running")
        service.pass()
        #expect(fixture.typedTexts.count == 2)
        #expect(fixture.typedTexts[1].contains("): running at "))
        try await runTurn(fixture)
        clock.advance(10)
        current.value[task] = state("done", merged: true)
        service.pass()
        #expect(fixture.typedTexts.count == 3)
        #expect(fixture.typedTexts[2].contains("): done, merged at "))
        await fixture.waitUntil("the webhook gets its events") { Set(transport.types).isSuperset(of: ["task.merged", "task.done"]) }
        #expect(transport.types.contains("task.running") == false)

        // Closing the coordinator leaves the webhook's passes running.
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: workspaceID)))
        #expect(service.isPolling)
        #expect(service.coordinatorWake == nil)
    }

    @Test func aCoordinatorOpenedWhileAWebhookListensIsNotToldEarlierChanges() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let transport = RecordingTransport()
        let current = States([task: state("needsYou", "review")])
        let service = makeService(fixture, clock: clock, transport: transport) { current.value }
        var settings = TaskWebhookService.Settings()
        settings.url = "https://hooks.example.com/w"
        settings.auth = .hmac
        let webhook = try service.add(name: "bot", settings: settings, secret: "s3cret-key-0123456789", requester: .init())
        try service.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        service.pass()

        // A merge that the service has not looked at yet, as in the first
        // seconds after a relaunch. Then the coordinator is opened.
        clock.advance(600)
        current.value[task] = state("toShip", merged: true)
        try await fixture.openAtPrompt()
        service.pass()
        // The webhook catches up. The coordinator did not exist then.
        await fixture.waitUntil("the webhook gets the merge") { Set(transport.types) == ["task.merged", "task.done"] }
        await fixture.waitUntil("the outbox is empty") { service.entries.isEmpty }
        #expect(fixture.typedTexts.isEmpty)
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 0)

        // From here on it is told, also a change with no webhook event: a
        // release moves the task from To ship to Done.
        clock.advance(60)
        current.value[task] = state("done", merged: true)
        service.pass()
        #expect(fixture.typedTexts == [digest(line(task, "Wake design", "done, merged", at: clock.now))])
        #expect(service.entries.isEmpty)
        #expect(transport.types.count == 2)
    }

    // MARK: - App control

    @Test func theNextCheckIsSetReadAndClearedThroughAppControl() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let current = States([task: state("idle")])
        let service = makeService(fixture, clock: clock) { current.value }
        fixture.tasks.coordinator.webhooks = service
        let executor = TaskAppControlTests().makeExecutor(fixture.tasks, coordinator: fixture.tasks.coordinator)
        let context = AutomationRequestContext(callerSessionID: nil, commandName: "app_control.run_action")
        func iso(_ date: Date) -> AutomationJSONValue { .string(ISO8601DateFormatter().string(from: date)) }
        func wake(_ args: [String: AutomationJSONValue]) throws -> AutomationJSONValue? {
            try executor.runAction(id: "coordinator.wake", args: args, context: context).result?["wake"]
        }
        func refused(_ mention: String, _ args: [String: AutomationJSONValue], sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                _ = try wake(args)
                Issue.record("expected invalidPayload containing \(mention)", sourceLocation: sourceLocation)
            } catch AutomationSocketError.invalidPayload(let actual) {
                #expect(actual.contains(mention), "\(actual)", sourceLocation: sourceLocation)
            } catch {
                Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
            }
        }
        #expect(executor.listActionDescriptors().map(\.id).contains("coordinator.wake"))

        // Without a coordinator there is no timer to set or read.
        refused("no coordinator", ["inSeconds": .int(1200)])
        #expect(try executor.runQuery(id: "coordinator.get", args: [:]) == ["exists": .bool(false), "queuedCount": .int(0)])

        try await fixture.openAtPrompt()
        let startedAt = clock.now
        service.pass()
        // No time set, one open task: the default, an hour after the start.
        #expect(try executor.runQuery(id: "coordinator.get", args: [:])["wake"] == .object([
            "pendingTaskCount": .int(0),
            "nextWakeAt": iso(startedAt.addingTimeInterval(3600)),
            "nextWakeSource": .string("default"),
            "lastWakeAt": iso(startedAt),
        ]))

        clock.advance(100)
        #expect(try wake(["inSeconds": .int(1200)]) == .object([
            "pendingTaskCount": .int(0),
            "nextWakeAt": iso(clock.now.addingTimeInterval(1200)),
            "nextWakeSource": .string("coordinator"),
            "lastWakeAt": iso(startedAt),
        ]))
        // `action run coordinator.wake inSeconds=600` sends text.
        guard case .object(let asText)? = try wake(["inSeconds": .string("600")]) else {
            Issue.record("no wake in the answer")
            return
        }
        #expect(asText["nextWakeAt"] == iso(clock.now.addingTimeInterval(600)))
        guard case .object(let atTime)? = try wake(["at": .string("2027-01-15T12:00:00Z")]) else {
            Issue.record("no wake in the answer")
            return
        }
        #expect(atTime["nextWakeAt"] == .string("2027-01-15T12:00:00Z"))
        #expect(atTime["nextWakeSource"] == .string("coordinator"))
        guard case .object(let cleared)? = try wake(["clear": .bool(true)]) else {
            Issue.record("no wake in the answer")
            return
        }
        #expect(cleared["nextWakeSource"] == .string("default"))
        #expect(cleared["nextWakeAt"] == iso(startedAt.addingTimeInterval(3600)))

        refused("exactly one", [:])
        refused("exactly one", ["clear": .bool(false)])
        refused("exactly one", ["inSeconds": .int(600), "clear": .bool(true)])
        refused("exactly one", ["inSeconds": .int(600), "at": .string("2027-01-15T12:00:00Z")])
        refused("whole number", ["inSeconds": .string("soon")])
        refused("whole number", ["inSeconds": .double(90.5)])
        refused("ISO 8601", ["at": .string("tomorrow")])
        refused("at least 1 minute", ["inSeconds": .int(30)])
        refused("at least 1 minute", ["at": .string("2020-01-01T00:00:00Z")])
        // A refused request changes nothing.
        #expect(service.coordinatorWakeStatus?.nextWake?.isRequested == false)

        // A change that waits shows in the status.
        try fixture.setStatus(.working)
        current.value[task] = state("needsYou", "review")
        service.pass()
        guard case .object(let waiting)? = try executor.runQuery(id: "coordinator.get", args: [:])["wake"] else {
            Issue.record("no wake in the status")
            return
        }
        #expect(waiting["pendingTaskCount"] == .int(1))
    }

    // MARK: - Real tasks

    @Test func aRealTasksStageReachesTheCoordinatorAndItsOwnTurnsWakeNothing() async throws {
        let fixture = try Fixture()
        let clock = Clock()
        let board = TaskBoardStore(
            coordinator: fixture.tasks.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessions,
            pullRequests: PullRequestStateCache(runner: TaskAppControlTests.OfflineGitHub()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        fixture.tasks.coordinator.board = board
        fixture.sessions.taskCoordinator = fixture.tasks.coordinator
        let executor = TaskAppControlTests().makeExecutor(fixture.tasks, coordinator: fixture.tasks.coordinator)
        try await fixture.openAtPrompt()
        let service = makeService(fixture, clock: clock) { TaskWebhookService.taskStates(board.items()) }
        service.pass()

        // The coordinator's own turns change no task.
        try await runTurn(fixture)
        clock.advance(5)
        service.pass()
        #expect(fixture.typedTexts.isEmpty)
        #expect(service.coordinatorWakeStatus?.pendingTaskCount == 0)

        // A task is created and its agent starts.
        let created = try await fixture.tasks.coordinator.create(TaskCreateRequest(
            text: "Fix the unread dot", workspaceID: fixture.tasks.workspaceID, agent: "codex"
        ))
        await fixture.tasks.waitForSetup(created.id)
        func listedStage() throws -> String {
            let listed = try executor.runQuery(id: "task.list", args: [:])
            guard case .array(let tasks)? = listed["tasks"], case .object(let task)? = tasks.first,
                  case .object(let stage)? = task["stage"], case .string(let group)? = stage["group"] else {
                Issue.record("task.list has no stage: \(listed)")
                return ""
            }
            guard case .string(let attention)? = stage["attention"] else { return group }
            return "\(group) (\(attention))"
        }
        clock.advance(5)
        service.pass()
        #expect(fixture.typedTexts.count == 1)
        // The digest uses the words task list reports.
        #expect(fixture.typedTexts[0] == digest(line(created.id, "Fix the unread dot", try listedStage(), at: clock.now)))
        try await runTurn(fixture)

        // The task's agent runs a turn and ends it.
        let taskSession = try #require(fixture.tasks.record(created.id)?.operation.agentLaunch?.sessionID)
        fixture.sessions.updateStatus(sessionID: taskSession, status: SessionStatus(kind: .working, summary: "Working"), at: Date())
        clock.advance(5)
        service.pass()
        try await runTurn(fixture)
        let typedBefore = fixture.typedTexts.count
        fixture.sessions.updateStatus(sessionID: taskSession, status: SessionStatus(kind: .idle, summary: "Done"), at: Date())
        clock.advance(5)
        service.pass()
        #expect(fixture.typedTexts.count == typedBefore + 1)
        let stage = try listedStage()
        #expect(stage != "running")
        #expect(fixture.typedTexts.last == digest(line(created.id, "Fix the unread dot", stage, at: clock.now)))
    }
}
