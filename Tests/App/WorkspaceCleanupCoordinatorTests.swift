import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Answers `gh` and the cleanup script from scripted results and records
/// each call. `onCleanup` runs on the main actor before the script's result
/// returns, as the real script closes the workspace through the socket.
private final class FakeCleanupRunner: WorkspaceCleanupCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var pullRequestStates: [String] = []
    private var calls: [[String]] = []
    var cleanupResult = WorkspaceCleanupCommandResult(exitCode: 0, stdout: "", stderr: "", failure: nil)
    var onCleanup: (@MainActor () -> Void)?

    /// Each `gh pr view` call takes the next state; the last one repeats.
    /// `nil` makes the call fail.
    func setPullRequestStates(_ states: [String?]) {
        lock.withLock { pullRequestStates = states.map { $0 ?? "" } }
    }

    var recordedCalls: [[String]] { lock.withLock { calls } }
    var cleanupCalls: [[String]] { recordedCalls.filter { $0.first == "python3" } }
    var checkCount: Int { recordedCalls.filter { $0.first == "gh" }.count }

    func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceCleanupCommandResult {
        lock.withLock { calls.append(arguments) }
        if arguments.first == "gh" {
            let state: String = lock.withLock {
                pullRequestStates.count > 1 ? pullRequestStates.removeFirst() : pullRequestStates.first ?? ""
            }
            guard state.isEmpty == false else {
                return WorkspaceCleanupCommandResult(exitCode: 1, stdout: "", stderr: "gh: could not resolve host", failure: nil)
            }
            return WorkspaceCleanupCommandResult(exitCode: 0, stdout: #"{"state":"\#(state)"}"#, stderr: "", failure: nil)
        }
        if let onCleanup {
            await MainActor.run { onCleanup() }
        }
        return cleanupResult
    }

    static func report(pr: Int, status: String?, cleanup: String?, reason: String = "") -> WorkspaceCleanupCommandResult {
        var row: [String: Any] = ["pr": pr, "verdict": status == nil ? "blocked" : "cleanup", "reason": reason]
        row["cleanup_status"] = status ?? NSNull()
        row["cleanup"] = cleanup ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: ["repository": "example/toastty", "prs": [row]])
        return WorkspaceCleanupCommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "", failure: nil)
    }
}

@MainActor
private final class CleanupFixture {
    let store: AppStore
    let sessionRuntimeStore = SessionRuntimeStore()
    let runner = FakeCleanupRunner()
    let userDefaults: UserDefaults
    let taskWorkspaceID: UUID
    var notifications: [(title: String, body: String)] = []
    private(set) var coordinator: WorkspaceCleanupCoordinator!
    let scriptPath: String

    init(userDefaults: UserDefaults? = nil) throws {
        self.userDefaults = userDefaults ?? UserDefaults(suiteName: "WorkspaceCleanupCoordinatorTests.\(UUID().uuidString)")!
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        sessionRuntimeStore.bind(store: store)
        let existingWorkspaceIDs = Set(store.state.workspacesByID.keys)
        store.send(.createWorkspace(windowID: selection.windowID, title: "fix-question-lifetime", activate: false))
        taskWorkspaceID = try #require(Set(store.state.workspacesByID.keys).subtracting(existingWorkspaceIDs).first)
        store.send(.setWorkspaceParent(
            workspaceID: taskWorkspaceID,
            parentWorkspaceID: selection.workspaceID,
            spawningSessionID: nil
        ))
        store.send(.setWorkspaceAnnotation(
            workspaceID: taskWorkspaceID,
            key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(
                text: "PR #59",
                url: "https://github.com/example/toastty/pull/59"
            ))
        ))
        // Any existing file stands in for the bundled script.
        scriptPath = #filePath
        makeCoordinator()
    }

    func makeCoordinator() {
        coordinator = WorkspaceCleanupCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: runner,
            scriptPath: scriptPath,
            userDefaults: userDefaults,
            pollInterval: .milliseconds(10),
            notify: { [unowned self] title, body in notifications.append((title, body)) }
        )
    }

    var request: WorkspaceCleanupRequest? {
        sessionRuntimeStore.workspaceCleanupRequests[taskWorkspaceID]
    }

    func requestCleanup() {
        coordinator.requestCleanup(workspaceID: taskWorkspaceID, pullRequestNumber: 59, repoPath: "/work/fix-question")
    }

    func markDone(_ isDone: Bool = true) {
        store.send(.setWorkspaceDone(workspaceID: taskWorkspaceID, doneAt: isDone ? Date() : nil))
    }

    func closeTaskWorkspace() {
        store.send(.closeWorkspace(workspaceID: taskWorkspaceID))
    }

    /// Waits for the coordinator's background checks to reach `condition`.
    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where condition() == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@MainActor
struct WorkspaceCleanupCoordinatorTests {
    @Test
    func cleanupWaitsForTheDoneMarkAndTheMergeThenRunsTheScriptOnThatWorkspace() async throws {
        let fixture = try CleanupFixture()
        fixture.runner.setPullRequestStates(["OPEN", "OPEN", "MERGED"])
        fixture.runner.cleanupResult = FakeCleanupRunner.report(
            pr: 59,
            status: "cleaned",
            cleanup: "closed fix-question-lifetime; removed worktree; deleted local branch; deleted remote branch"
        )
        fixture.runner.onCleanup = { fixture.closeTaskWorkspace() }

        fixture.requestCleanup()
        // The agent may stop to ask about a prerequisite; the request waits
        // for the done mark however many turns that takes.
        #expect(fixture.request?.phase == .awaitingDone)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.runner.checkCount == 0)

        fixture.markDone()
        try await fixture.waitUntil { fixture.request == nil }

        #expect(fixture.runner.checkCount == 3)
        let cleanup = try #require(fixture.runner.cleanupCalls.first)
        #expect(Array(cleanup.dropFirst(2)) == [
            "--json", "--cleanup-merged", "--pr", "59",
            "--workspace", fixture.taskWorkspaceID.uuidString, "--repo", "/work/fix-question",
        ])
        #expect(fixture.notifications.map(\.title) == ["Cleaned up PR #59"])
        #expect(fixture.notifications.first?.body.hasPrefix("fix-question-lifetime: closed") == true)
    }

    @Test
    func newWorkAfterTheDoneMarkDropsTheCleanup() async throws {
        let fixture = try CleanupFixture()
        fixture.runner.setPullRequestStates(["OPEN"])
        fixture.requestCleanup()
        fixture.markDone()
        try await fixture.waitUntil { fixture.runner.checkCount >= 1 }
        #expect(fixture.request?.phase == .awaitingMerge)

        fixture.markDone(false)

        #expect(fixture.request == nil)
        let checks = fixture.runner.checkCount
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.runner.checkCount <= checks + 1)
        #expect(fixture.runner.cleanupCalls.isEmpty)
    }

    @Test
    func closedPullRequestAndFailedChecksShowAsFailuresThatCanBeRetried() async throws {
        let fixture = try CleanupFixture()
        fixture.runner.setPullRequestStates(["CLOSED"])
        fixture.requestCleanup()
        fixture.markDone()
        try await fixture.waitUntil { fixture.request?.phase != .awaitingMerge }
        #expect(fixture.request?.phase == .failed(reason: "PR #59 was closed without merging."))

        fixture.runner.setPullRequestStates([nil])
        fixture.coordinator.retryCleanup(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.request?.phase == .awaitingMerge)
        try await fixture.waitUntil {
            if case .failed = fixture.request?.phase { return true }
            return false
        }
        #expect(fixture.request?.phase == .failed(
            reason: "Could not check PR #59 with gh: gh: could not resolve host"
        ))

        fixture.coordinator.cancelCleanup(workspaceID: fixture.taskWorkspaceID)
        #expect(fixture.request == nil)
        #expect(fixture.runner.cleanupCalls.isEmpty)
    }

    @Test
    func skippedCleanupKeepsTheWorkspaceAndShowsWhy() async throws {
        let fixture = try CleanupFixture()
        fixture.runner.setPullRequestStates(["MERGED"])
        fixture.runner.cleanupResult = FakeCleanupRunner.report(
            pr: 59,
            status: "skipped",
            cleanup: "skipped: worktree has uncommitted changes"
        )
        fixture.requestCleanup()
        fixture.markDone()

        try await fixture.waitUntil { fixture.runner.cleanupCalls.isEmpty == false && fixture.request?.phase != .cleaningUp }

        #expect(fixture.request?.phase == .failed(reason: "skipped: worktree has uncommitted changes"))
        #expect(fixture.store.state.workspacesByID[fixture.taskWorkspaceID] != nil)
        #expect(fixture.notifications.isEmpty)
    }

    @Test
    func newWorkDuringTheRunDropsTheRequestInsteadOfOfferingARetry() async throws {
        let fixture = try CleanupFixture()
        fixture.runner.setPullRequestStates(["MERGED"])
        fixture.runner.cleanupResult = FakeCleanupRunner.report(
            pr: 59,
            status: "skipped",
            cleanup: "skipped: fix-question-lifetime is no longer marked done"
        )
        fixture.runner.onCleanup = { fixture.markDone(false) }
        fixture.requestCleanup()
        fixture.markDone()

        try await fixture.waitUntil { fixture.runner.cleanupCalls.isEmpty == false && fixture.request?.phase != .cleaningUp }

        #expect(fixture.request == nil)
        #expect(fixture.notifications.isEmpty)
    }

    @Test
    func partialCleanupAfterTheWorkspaceClosedIsReportedInANotification() async throws {
        let fixture = try CleanupFixture()
        fixture.runner.setPullRequestStates(["MERGED"])
        fixture.runner.cleanupResult = FakeCleanupRunner.report(
            pr: 59,
            status: "partial",
            cleanup: "partial: closed fix-question-lifetime; git worktree remove failed: locked"
        )
        fixture.runner.onCleanup = { fixture.closeTaskWorkspace() }
        fixture.requestCleanup()
        fixture.markDone()

        try await fixture.waitUntil { fixture.notifications.isEmpty == false }

        #expect(fixture.request == nil)
        #expect(fixture.notifications.first?.title == "Cleanup of PR #59 did not finish")
        #expect(fixture.notifications.first?.body.contains("git worktree remove failed") == true)
    }

    @Test
    func pendingCleanupSurvivesARelaunch() async throws {
        let first = try CleanupFixture()
        first.runner.setPullRequestStates(["OPEN"])
        first.requestCleanup()
        first.markDone()
        try await first.waitUntil { first.runner.checkCount >= 1 }

        // A new coordinator over the same state and defaults stands in for
        // the next launch.
        first.sessionRuntimeStore.setWorkspaceCleanupRequests([:])
        first.makeCoordinator()

        #expect(first.request == WorkspaceCleanupRequest(
            pullRequestNumber: 59,
            repoPath: "/work/fix-question",
            phase: .awaitingMerge
        ))
    }

    @Test
    func cleanupOutcomeTreatsMissingAndBlockedRowsAsFailures() {
        let failedScript = WorkspaceCleanupCommandResult(exitCode: 1, stdout: "", stderr: "Traceback\nKeyError: 'x'", failure: nil)
        #expect(WorkspaceCleanupCoordinator.cleanupOutcome(from: failedScript, pullRequestNumber: 59)
            == .init(status: nil, detail: "The cleanup script failed: KeyError: 'x'"))

        let otherPR = FakeCleanupRunner.report(pr: 60, status: "cleaned", cleanup: "removed worktree")
        #expect(WorkspaceCleanupCoordinator.cleanupOutcome(from: otherPR, pullRequestNumber: 59).status == nil)

        let blocked = FakeCleanupRunner.report(pr: 59, status: nil, cleanup: nil, reason: "worktree is 1 commit(s) ahead of the PR head")
        #expect(WorkspaceCleanupCoordinator.cleanupOutcome(from: blocked, pullRequestNumber: 59)
            == .init(status: nil, detail: "worktree is 1 commit(s) ahead of the PR head"))
    }
}
