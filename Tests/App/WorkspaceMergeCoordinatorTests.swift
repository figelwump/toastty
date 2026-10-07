import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// Answers `gh` and the pull request script from scripted results and records
/// each call. `onScript` runs on the main actor before the script's result
/// returns, as the real script closes the workspace through the socket.
private final class FakeMergeRunner: WorkspaceMergeCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var pullRequestStates: [String] = []
    private var calls: [[String]] = []
    /// The script's report for each action: merge, clean-up, or close.
    var scriptResults: [String: WorkspaceMergeCommandResult] = [:]
    var onScript: [String: @MainActor () -> Void] = [:]

    /// Each `gh pr view` call takes the next state; the last one repeats.
    /// `nil` makes the call fail.
    func setPullRequestStates(_ states: [String?]) {
        lock.withLock { pullRequestStates = states.map { $0 ?? "" } }
    }

    var recordedCalls: [[String]] { lock.withLock { calls } }
    /// The script calls, without `python3` and the script path.
    var scriptCalls: [[String]] { recordedCalls.filter { $0.first == "python3" }.map { Array($0.dropFirst(2)) } }
    var checkCalls: [[String]] { recordedCalls.filter { $0.first == "gh" } }

    func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
        lock.withLock { calls.append(arguments) }
        if arguments.first == "gh" {
            let state: String = lock.withLock {
                pullRequestStates.count > 1 ? pullRequestStates.removeFirst() : pullRequestStates.first ?? ""
            }
            guard state.isEmpty == false else {
                return WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "gh: could not resolve host", failure: nil)
            }
            return WorkspaceMergeCommandResult(exitCode: 0, stdout: #"{"state":"\#(state)"}"#, stderr: "", failure: nil)
        }
        let action = arguments[2]
        if let hook = onScript[action] {
            await MainActor.run { hook() }
        }
        return scriptResults[action] ?? Self.report(status: "failed", detail: "no scripted result for \(action)")
    }

    static func report(status: String, detail: String) -> WorkspaceMergeCommandResult {
        let data = try! JSONSerialization.data(withJSONObject: ["status": status, "detail": detail])
        return WorkspaceMergeCommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "", failure: nil)
    }
}

@MainActor
private final class MergeFixture {
    static let pullRequest = WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/59")!

    let store: AppStore
    let sessionRuntimeStore = SessionRuntimeStore()
    let runner = FakeMergeRunner()
    let userDefaults: UserDefaults
    let taskWorkspaceID: UUID
    var notifications: [(title: String, body: String)] = []
    var failureAlerts: [(title: String, message: String)] = []
    private(set) var coordinator: WorkspaceMergeCoordinator!

    init() throws {
        userDefaults = UserDefaults(suiteName: "WorkspaceMergeCoordinatorTests.\(UUID().uuidString)")!
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
            annotation: try #require(WorkspaceAnnotation.validated(text: "PR #59", url: Self.pullRequest.url))
        ))
        makeCoordinator()
    }

    func makeCoordinator() {
        coordinator = WorkspaceMergeCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: runner,
            // Any existing file stands in for the bundled script.
            scriptPath: #filePath,
            userDefaults: userDefaults,
            pollInterval: .milliseconds(10),
            notify: { [unowned self] title, body in notifications.append((title, body)) },
            presentFailure: { [unowned self] title, message in failureAlerts.append((title, message)) }
        )
    }

    var request: WorkspaceMergeRequest? {
        sessionRuntimeStore.workspaceMergeRequests[taskWorkspaceID]
    }

    var isDone: Bool {
        store.state.workspacesByID[taskWorkspaceID]?.doneAt != nil
    }

    var savedRequests: Data? {
        userDefaults.data(forKey: "toastty.workspaceMergeRequests")
    }

    @discardableResult
    func merge(thenCleanUp: Bool) -> Task<Void, Never>? {
        coordinator.merge(
            workspaceID: taskWorkspaceID,
            pullRequest: Self.pullRequest,
            repoPath: "/work/fix-question",
            thenCleanUp: thenCleanUp
        )
    }

    /// A Merge and Clean whose merge was queued, now waiting for it.
    func mergeAndWait(pullRequestStates: [String?]) async {
        runner.setPullRequestStates(pullRequestStates)
        runner.scriptResults["merge"] = FakeMergeRunner.report(status: "queued", detail: "turned on auto-merge for PR #59")
        await merge(thenCleanUp: true)?.value
    }

    @discardableResult
    func close() -> Task<Void, Never>? {
        coordinator.closeWithoutMerging(
            workspaceID: taskWorkspaceID,
            pullRequest: Self.pullRequest,
            repoPath: "/work/fix-question"
        )
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

    func arguments(_ action: String) -> [String] {
        [action, "--pr", "59", "--pr-url", Self.pullRequest.url,
         "--workspace", taskWorkspaceID.uuidString, "--repo", "/work/fix-question"]
    }
}

@MainActor
struct WorkspaceMergeCoordinatorTests {
    @Test
    func mergeAndCleanMarksTheWorkspaceDoneThenCleansUpOnceThePullRequestMerges() async throws {
        let fixture = try MergeFixture()
        fixture.runner.setPullRequestStates(["OPEN", "OPEN", "MERGED"])
        fixture.runner.scriptResults = [
            "merge": FakeMergeRunner.report(status: "queued", detail: "turned on auto-merge for PR #59"),
            "clean-up": FakeMergeRunner.report(
                status: "cleaned",
                detail: "closed fix-question-lifetime; removed worktree; deleted local branch; deleted remote branch"
            ),
        ]
        var observedDuringMerge: (phase: WorkspaceMergeRequest.Phase?, saved: Data?, secondMerge: Task<Void, Never>?)?
        fixture.runner.onScript["merge"] = {
            observedDuringMerge = (fixture.request?.phase, fixture.savedRequests, fixture.merge(thenCleanUp: true))
        }
        fixture.runner.onScript["clean-up"] = { fixture.closeTaskWorkspace() }

        await fixture.merge(thenCleanUp: true)?.value

        // A merge in progress shows on the button, is not saved, and takes no
        // second click.
        #expect(observedDuringMerge?.phase == .merging(thenCleanUp: true))
        #expect(observedDuringMerge?.saved == nil)
        #expect(observedDuringMerge?.secondMerge == nil)
        #expect(fixture.isDone)
        #expect(fixture.runner.scriptCalls.first == fixture.arguments("merge"))

        try await fixture.waitUntil { fixture.request == nil }

        #expect(fixture.runner.checkCalls.count == 3)
        #expect(fixture.runner.checkCalls.first == ["gh", "pr", "view", MergeFixture.pullRequest.url, "--json", "state"])
        #expect(fixture.runner.scriptCalls.last == fixture.arguments("clean-up"))
        #expect(fixture.notifications.map(\.title) == ["Cleaned up PR #59"])
        #expect(fixture.notifications.first?.body.hasPrefix("fix-question-lifetime: closed") == true)
        #expect(fixture.failureAlerts.isEmpty)
    }

    @Test
    func mergeOnlyMarksTheWorkspaceDoneAndEnds() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["merge"] = FakeMergeRunner.report(status: "merged", detail: "merged PR #59")

        await fixture.merge(thenCleanUp: false)?.value

        #expect(fixture.isDone)
        #expect(fixture.request == nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.runner.checkCalls.isEmpty)
        #expect(fixture.runner.scriptCalls.count == 1)
        #expect(fixture.failureAlerts.isEmpty)
    }

    @Test
    func mergeDoesNotMarkAWorkspaceThatMovedToAnotherPullRequestDone() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["merge"] = FakeMergeRunner.report(status: "merged", detail: "merged PR #59")
        fixture.runner.onScript["merge"] = {
            fixture.store.send(.setWorkspaceAnnotation(
                workspaceID: fixture.taskWorkspaceID,
                key: "github-pr",
                annotation: WorkspaceAnnotation.validated(text: "PR #60", url: "https://github.com/example/toastty/pull/60")!
            ))
        }

        await fixture.merge(thenCleanUp: true)?.value

        #expect(fixture.isDone == false)
        #expect(fixture.request == nil)
        #expect(fixture.runner.checkCalls.isEmpty)
    }

    @Test
    func refusedOrFailedMergeShowsWhyAndLeavesTheWorkspaceOpen() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["merge"] = FakeMergeRunner.report(
            status: "refused",
            detail: "the worktree has uncommitted changes; the merge would not be the version in this workspace"
        )
        await fixture.merge(thenCleanUp: true)?.value

        #expect(fixture.request == nil)
        #expect(fixture.isDone == false)
        #expect(fixture.failureAlerts.map(\.title) == ["Unable to Merge PR #59"])
        #expect(fixture.failureAlerts.first?.message.hasPrefix("the worktree has uncommitted changes") == true)

        fixture.runner.scriptResults["merge"] = WorkspaceMergeCommandResult(
            exitCode: 1,
            stdout: "",
            stderr: "Traceback\nworkspace-pull-request: gh pr view failed: HTTP 401",
            failure: nil
        )
        await fixture.merge(thenCleanUp: false)?.value
        #expect(fixture.failureAlerts.last?.message == "The pull request script failed: workspace-pull-request: gh pr view failed: HTTP 401")
        #expect(fixture.isDone == false)
        #expect(fixture.runner.checkCalls.isEmpty)
    }

    @Test
    func newWorkAfterTheMergeDropsTheCleanup() async throws {
        let fixture = try MergeFixture()
        await fixture.mergeAndWait(pullRequestStates: ["OPEN"])
        try await fixture.waitUntil { fixture.runner.checkCalls.count >= 1 }
        #expect(fixture.request?.phase == .awaitingMerge)

        fixture.markDone(false)

        #expect(fixture.request == nil)
        let checks = fixture.runner.checkCalls.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.runner.checkCalls.count <= checks + 1)
        #expect(fixture.runner.scriptCalls.count == 1)
    }

    @Test
    func closedPullRequestAndFailedChecksShowAsFailuresThatCanBeRetried() async throws {
        let fixture = try MergeFixture()
        await fixture.mergeAndWait(pullRequestStates: ["CLOSED"])
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
        #expect(fixture.runner.scriptCalls.count == 1)
    }

    @Test
    func skippedCleanupKeepsTheWorkspaceAndShowsWhy() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["clean-up"] = FakeMergeRunner.report(
            status: "skipped",
            detail: "the worktree has uncommitted changes"
        )
        await fixture.mergeAndWait(pullRequestStates: ["MERGED"])

        try await fixture.waitUntil { fixture.runner.scriptCalls.count == 2 && fixture.request?.phase != .cleaningUp }

        #expect(fixture.request?.phase == .failed(reason: "the worktree has uncommitted changes"))
        #expect(fixture.store.state.workspacesByID[fixture.taskWorkspaceID] != nil)
        #expect(fixture.notifications.isEmpty)
    }

    @Test
    func newWorkDuringTheCleanupDropsTheRequestInsteadOfOfferingARetry() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["clean-up"] = FakeMergeRunner.report(
            status: "skipped",
            detail: "fix-question-lifetime is no longer marked done"
        )
        fixture.runner.onScript["clean-up"] = { fixture.markDone(false) }
        await fixture.mergeAndWait(pullRequestStates: ["MERGED"])

        try await fixture.waitUntil { fixture.runner.scriptCalls.count == 2 && fixture.request?.phase != .cleaningUp }

        #expect(fixture.request == nil)
        #expect(fixture.notifications.isEmpty)
    }

    @Test
    func partialCleanupAfterTheWorkspaceClosedIsReportedInANotification() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["clean-up"] = FakeMergeRunner.report(
            status: "partial",
            detail: "closed fix-question-lifetime; git worktree remove failed: locked"
        )
        fixture.runner.onScript["clean-up"] = { fixture.closeTaskWorkspace() }
        await fixture.mergeAndWait(pullRequestStates: ["MERGED"])

        try await fixture.waitUntil { fixture.notifications.isEmpty == false }

        #expect(fixture.request == nil)
        #expect(fixture.notifications.first?.title == "Cleanup of PR #59 did not finish")
        #expect(fixture.notifications.first?.body.contains("git worktree remove failed") == true)
    }

    @Test
    func pendingCleanupSurvivesARelaunch() async throws {
        let fixture = try MergeFixture()
        await fixture.mergeAndWait(pullRequestStates: ["OPEN"])
        try await fixture.waitUntil { fixture.runner.checkCalls.count >= 1 }

        // A new coordinator over the same state and defaults stands in for
        // the next launch.
        fixture.sessionRuntimeStore.setWorkspaceMergeRequests([:])
        fixture.makeCoordinator()

        #expect(fixture.request == WorkspaceMergeRequest(
            pullRequest: MergeFixture.pullRequest,
            repoPath: "/work/fix-question",
            phase: .awaitingMerge
        ))
    }

    @Test
    func closeWithoutMergingRunsTheScriptOnceAndReportsTheResult() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["close"] = FakeMergeRunner.report(
            status: "cleaned",
            detail: "closed PR #59; closed fix-question-lifetime; removed worktree; deleted local branch; kept the branch on GitHub"
        )
        var observedDuringRun: (phase: WorkspaceMergeRequest.Phase?, saved: Data?)?
        fixture.runner.onScript["close"] = {
            observedDuringRun = (fixture.request?.phase, fixture.savedRequests)
            fixture.closeTaskWorkspace()
        }

        let task = try #require(fixture.close())
        // A second request while the first runs does nothing.
        #expect(fixture.close() == nil)
        #expect(fixture.merge(thenCleanUp: false) == nil)
        await task.value

        #expect(observedDuringRun?.phase == .closing)
        // A close is never saved, so a relaunch does not repeat it.
        #expect(observedDuringRun?.saved == nil)
        #expect(fixture.request == nil)
        #expect(fixture.runner.scriptCalls == [fixture.arguments("close")])
        #expect(fixture.notifications.map(\.title) == ["Closed PR #59 without merging"])
        #expect(fixture.failureAlerts.isEmpty)
    }

    @Test
    func refusedCloseKeepsTheWorkspaceAndShowsWhy() async throws {
        let fixture = try MergeFixture()
        fixture.runner.scriptResults["close"] = FakeMergeRunner.report(
            status: "skipped",
            detail: "the worktree has uncommitted changes"
        )

        await fixture.close()?.value

        #expect(fixture.request == nil)
        #expect(fixture.store.state.workspacesByID[fixture.taskWorkspaceID] != nil)
        #expect(fixture.notifications.isEmpty)
        #expect(fixture.failureAlerts.map(\.title) == ["Unable to Close PR #59"])
        #expect(fixture.failureAlerts.first?.message == "the worktree has uncommitted changes")
    }

    @Test
    func scriptOutcomeTreatsAFailedRunOrAMissingReportAsAFailure() {
        let failedScript = WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "Traceback\nKeyError: 'x'", failure: nil)
        #expect(WorkspaceMergeCoordinator.scriptOutcome(from: failedScript)
            == .init(status: nil, detail: "The pull request script failed: KeyError: 'x'"))

        let noReport = WorkspaceMergeCommandResult(exitCode: 0, stdout: "", stderr: "", failure: nil)
        #expect(WorkspaceMergeCoordinator.scriptOutcome(from: noReport).status == nil)

        let report = FakeMergeRunner.report(status: "queued", detail: "turned on auto-merge for PR #59")
        #expect(WorkspaceMergeCoordinator.scriptOutcome(from: report)
            == .init(status: "queued", detail: "turned on auto-merge for PR #59"))
    }
}
