import CoreState
import Foundation
import Testing

/// When a task entered its stage, as `task get` reports it in
/// `stage.changedAt`.
struct TaskStageClockTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let running = TaskStageClock.Key(group: "running")
    private let idle = TaskStageClock.Key(group: "idle")
    private let finished = TaskStageClock.Key(group: "needsYou", attention: "agentFinished")
    private let waiting = TaskStageClock.Key(group: "needsYou", attention: "awaitingReply")
    private let done = TaskStageClock.Key(group: "done")

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aStageKeepsItsTimeWhileItIsSeenAgain() {
        var clock = TaskStageClock(key: running, since: t0)
        clock.observe(running, now: at(600))
        #expect(clock.since(running) == t0)
        #expect(clock.since(idle) == nil)
    }

    @Test func aNewStageReportsWhenItAppearedAlsoBeforeItSettles() {
        var clock = TaskStageClock(key: running, since: t0)
        clock.observe(finished, now: at(60))
        #expect(clock.since(finished) == at(60))
        clock.observe(finished, now: at(70))
        #expect(clock.since(finished) == at(60))
    }

    @Test func aFlickerShorterThanTheSettleWindowKeepsTheEarlierTime() {
        var clock = TaskStageClock(key: running, since: t0)
        clock.observe(finished, now: at(600))
        clock.observe(running, now: at(602))
        #expect(clock.since(running) == t0)
        // Several short stages in a row are still one flicker.
        clock.observe(finished, now: at(700))
        clock.observe(idle, now: at(702))
        clock.observe(running, now: at(704))
        #expect(clock.since(running) == t0)
    }

    @Test func aStageThatHeldAndThenReturnedStartsANewTime() {
        var clock = TaskStageClock(key: running, since: t0)
        clock.observe(finished, now: at(600))
        // Nothing was observed while the stage held; the return still counts.
        clock.observe(running, now: at(610))
        #expect(clock.since(running) == at(610))
        // The new stage can itself be a flicker of the one that held.
        clock.observe(finished, now: at(611))
        #expect(clock.since(finished) == at(600))
    }

    @Test func aNewReasonInsideNeedsYouIsANewStage() {
        var clock = TaskStageClock(key: finished, since: t0)
        clock.observe(waiting, now: at(30))
        #expect(clock.since(waiting) == at(30))
        // The reason held, so a return to the first one is a new stage too.
        clock.observe(finished, now: at(90))
        #expect(clock.since(finished) == at(90))
    }

    @Test func stagesTheRecordDecidesCountAtOnce() {
        var clock = TaskStageClock(key: running, since: t0)
        clock.observe(done, now: at(60))
        #expect(clock.since(done) == at(60))
        #expect(clock.since(running) == nil)
        // Done was not a flicker: running starts again a second later.
        clock.observe(running, now: at(61))
        #expect(clock.since(running) == at(61))
    }

    @Test func theSavedClockKeepsItsTimeAcrossARelaunch() throws {
        var clock = TaskStageClock(key: running, since: t0)
        clock.observe(TaskStageClock.Key(group: "needsYou", attention: "review"), now: at(60))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored = try decoder.decode(TaskStageClock.self, from: encoder.encode(clock))
        let review = TaskStageClock.Key(group: "needsYou", attention: "review")
        restored.observe(review, now: at(86_400), afterRelaunch: true)
        #expect(restored.since(review) == at(60))
    }

    @Test func aDifferentStageAfterARelaunchCountsAtOnce() {
        // Toastty quit while the task ran; the relaunch restores its agent idle.
        var clock = TaskStageClock(key: idle, since: t0)
        clock.observe(running, now: at(600))
        clock.observe(idle, now: at(5000), afterRelaunch: true)
        #expect(clock.since(idle) == at(5000))
        // A turn that starts a second later is a new stage, not the return
        // of the one the quit cut off.
        clock.observe(running, now: at(5001))
        #expect(clock.since(running) == at(5001))
    }

    @Test func theKeyNamesTheGroupAndTheAttentionButNotTheReason() {
        #expect(TaskStageClock.Key(.starting) == TaskStageClock.Key(.running))
        #expect(TaskStageClock.Key(.needsYou(.setupFailed(reason: "a"))) == TaskStageClock.Key(.needsYou(.setupFailed(reason: "b"))))
        #expect(TaskStageClock.Key(.needsYou(.review)) == TaskStageClock.Key(group: "needsYou", attention: "review"))
        #expect(TaskStageClock.Key(.toShip) == TaskStageClock.Key(group: "toShip"))
    }
}

/// When a session entered its state, as `task get` reports it in
/// `agentState.changedAt`.
struct SessionStateChangedAtTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func registry() -> SessionRegistry {
        var registry = SessionRegistry()
        registry.startSession(
            sessionID: "agent", agent: .claude, panelID: UUID(), windowID: UUID(), workspaceID: UUID(),
            cwd: "/repo", repoRoot: "/repo", at: start
        )
        return registry
    }

    private func report(_ registry: inout SessionRegistry, _ kind: SessionStatusKind, after seconds: TimeInterval, fromAgent: Bool = true) {
        registry.updateStatus(
            sessionID: "agent", status: SessionStatus(kind: kind, summary: "\(kind) \(seconds)"),
            fromAgent: fromAgent, at: start.addingTimeInterval(seconds)
        )
    }

    private func changedAt(_ registry: SessionRegistry) -> Date? {
        registry.sessionsByID["agent"]?.stateChangedAt
    }

    @Test func aReportThatRepeatsTheStateDoesNotMoveIt() {
        var registry = registry()
        // At rest since it started: the start time stands in.
        report(&registry, .idle, after: 5)
        #expect(changedAt(registry) == nil)

        report(&registry, .working, after: 10)
        report(&registry, .working, after: 200)
        report(&registry, .working, after: 400)
        #expect(changedAt(registry) == start.addingTimeInterval(10))
        // The status time moves with every report.
        #expect(registry.sessionsByID["agent"]?.statusUpdatedAt == start.addingTimeInterval(400))
    }

    @Test func eachChangeOfStateMovesIt() {
        var registry = registry()
        report(&registry, .working, after: 10)
        report(&registry, .needsApproval, after: 20)
        #expect(changedAt(registry) == start.addingTimeInterval(20))
        report(&registry, .working, after: 30)
        #expect(changedAt(registry) == start.addingTimeInterval(30))
        report(&registry, .ready, after: 40)
        #expect(changedAt(registry) == start.addingTimeInterval(40))
        // Reading the finished turn collapses ready to idle: still at rest.
        report(&registry, .idle, after: 90, fromAgent: false)
        #expect(changedAt(registry) == start.addingTimeInterval(40))
        report(&registry, .error, after: 100)
        #expect(changedAt(registry) == start.addingTimeInterval(100))
    }
}
