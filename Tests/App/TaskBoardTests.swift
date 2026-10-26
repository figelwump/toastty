import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The task board through the real store, reducer and task coordinator,
/// with a fake `gh` in place of GitHub.
@MainActor
struct TaskBoardTests {
    /// Answers `gh pr view <url> --json …` from `answers`, optionally
    /// holding each answer until the test releases it.
    final class FakeGitHub: WorkspaceMergeCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var answersByURL: [String: String] = [:]
        private var recorded: [[String]] = []
        private var held: [CheckedContinuation<Void, Never>] = []
        var holdsAnswers = false
        /// Fails requests for `readinessViewFields`, like a token that
        /// cannot read checks.
        var rejectsReadinessFields = false

        /// `checks` is the `statusCheckRollup` array as JSON.
        func answer(
            _ url: String,
            state: String,
            isDraft: Bool = false,
            mergeCommit: String? = nil,
            mergeStateStatus: String? = nil,
            reviewDecision: String = "",
            checks: String = "[]"
        ) {
            let commit = mergeCommit.map { #"{"oid":"\#($0)"}"# } ?? "null"
            let mergeability = mergeStateStatus.map {
                #","mergeStateStatus":"\#($0)","reviewDecision":"\#(reviewDecision)","statusCheckRollup":\#(checks)"#
            } ?? ""
            lock.withLock {
                answersByURL[url] = #"{"state":"\#(state)","isDraft":\#(isDraft),"headRefOid":"head1","mergeCommit":\#(commit)\#(mergeability)}"#
            }
        }

        var calls: [[String]] { lock.withLock { recorded } }

        func release() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { held = [] }
                return held
            }
            waiting.forEach { $0.resume() }
        }

        func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
            let (url, holds) = lock.withLock { () -> (String, Bool) in
                recorded.append(arguments)
                return (arguments.count > 3 ? arguments[3] : "", holdsAnswers)
            }
            if holds {
                await withCheckedContinuation { continuation in
                    lock.withLock { held.append(continuation) }
                }
            }
            if lock.withLock({ rejectsReadinessFields }), arguments.last == PullRequestStateCache.readinessViewFields {
                return WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "checks: forbidden", failure: nil)
            }
            guard let stdout = lock.withLock({ answersByURL[url] }) else {
                return WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "gh: not found", failure: nil)
            }
            return WorkspaceMergeCommandResult(exitCode: 0, stdout: stdout, stderr: "", failure: nil)
        }
    }

    private let pullRequestURL = "https://github.com/example/toastty/pull/124"

    private func makeBoard(_ fixture: TaskCoordinatorTests.Fixture, gitHub: FakeGitHub) -> TaskBoardStore {
        TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: gitHub),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
    }

    /// A task space made the way an agent's `workspace.create` makes one,
    /// with no task record.
    private func makeUntrackedTaskSpace(_ fixture: TaskCoordinatorTests.Fixture, title: String) throws -> UUID {
        let windowID = try #require(fixture.store.state.windows.first?.id)
        let before = Set(fixture.store.state.workspacesByID.keys)
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: title, activate: false))
        let created = try #require(Set(fixture.store.state.workspacesByID.keys).subtracting(before).first)
        _ = fixture.store.send(.setWorkspaceParent(workspaceID: created, parentWorkspaceID: fixture.workspaceID, spawningSessionID: nil))
        return created
    }

    private func startTask(_ fixture: TaskCoordinatorTests.Fixture, text: String) async throws -> TaskRecord {
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: text,
            workspaceID: fixture.workspaceID,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            prompt: "Fix it."
        ))
        await fixture.waitForSetup(created.id)
        return try #require(fixture.record(created.id))
    }

    @Test func theBoardListsTasksAndUntrackedTaskSpacesWithTheirStages() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = FakeGitHub()
        let board = makeBoard(fixture, gitHub: gitHub)
        let untracked = try makeUntrackedTaskSpace(fixture, title: "qa-mobile-navigation")
        let task = try await startTask(fixture, text: "The unread dot stays on")

        var items = board.items()
        let watched = try #require(items.first { $0.id == .taskSpace(untracked) })
        #expect(watched.record == nil)
        #expect(watched.projectTitle == "toastty")
        #expect(watched.stage == .running)
        let tracked = try #require(items.first { $0.id == .task(task.id) })
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        #expect(tracked.taskSpaceWorkspaceID == taskSpace)
        #expect(tracked.stage.group == .running)
        // A task space with a record is listed once, as its task.
        #expect(items.contains { $0.id == .taskSpace(taskSpace) } == false)

        // Without an answer from GitHub, a linked pull request and an idle
        // task space wait for review.
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: untracked,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        items = board.items()
        #expect(items.first { $0.id == .taskSpace(untracked) }?.stage == .needsYou(.review))

        // Its done mark finishes it; the mark clears when work starts again.
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: untracked, doneAt: Date()))
        #expect(board.items().first { $0.id == .taskSpace(untracked) }?.stage == .done)

        let windowID = try #require(fixture.store.state.windows.first?.id)
        #expect(Set(board.items(windowID: windowID).map(\.id)) == Set(board.items().map(\.id)))
    }

    @Test func aMergeSeenOnGitHubStaysOnTheTaskAfterItsTaskSpaceCloses() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = FakeGitHub()
        let board = makeBoard(fixture, gitHub: gitHub)
        let task = try await startTask(fixture, text: "The unread dot stays on")
        let taskSpace = try #require(task.taskSpaceWorkspaceID)

        // The task keeps its task space's pull request link.
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL + "/files")
        ))
        #expect(fixture.record(task.id)?.pullRequestURL == pullRequestURL)

        gitHub.answer(pullRequestURL, state: "OPEN")
        board.refreshOpenPullRequests()
        await waitUntil { board.items().first { $0.id == .task(task.id) }?.pullRequestState?.state == .open }
        #expect(board.items().first { $0.id == .task(task.id) }?.stage.group != .done)

        gitHub.answer(pullRequestURL, state: "MERGED", mergeCommit: "abc123")
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        await board.pullRequests?.refresh(link).value
        let merged = try #require(fixture.record(task.id))
        #expect(merged.mergedAt != nil)
        #expect(merged.mergeCommit == "abc123")
        #expect(board.items().first { $0.id == .task(task.id) }?.stage == .done)

        // With release tags, a merge waits to ship.
        fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*")])
        board.reloadConfig()
        #expect(board.items().first { $0.id == .task(task.id) }?.stage == .toShip)

        // The record carries it once the task space is gone.
        _ = fixture.store.send(.closeWorkspace(workspaceID: taskSpace))
        let closed = try #require(board.items().first { $0.id == .task(task.id) })
        #expect(closed.taskSpaceWorkspaceID == nil)
        #expect(closed.stage == .toShip)
        #expect(gitHub.calls.allSatisfy { $0.suffix(2) == ["--json", PullRequestStateCache.readinessViewFields] })
    }

    @Test func theRecordKeepsTheDoneMarkAndTheRightPullRequestsMerge() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = FakeGitHub()
        let board = makeBoard(fixture, gitHub: gitHub)
        let task = try await startTask(fixture, text: "The unread dot stays on")
        let taskSpace = try #require(task.taskSpaceWorkspaceID)

        // The task space's done mark counts while it is open, and stays on
        // the record after it closes.
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: taskSpace, doneAt: Date()))
        #expect(fixture.record(task.id)?.doneAt != nil)
        #expect(board.items().first { $0.id == .task(task.id) }?.stage == .done)
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: taskSpace, doneAt: nil))
        #expect(fixture.record(task.id)?.doneAt == nil)

        // A merge GitHub reported is recorded as soon as the task has the link.
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        gitHub.answer(pullRequestURL, state: "MERGED", mergeCommit: "abc123")
        await board.pullRequests?.refresh(link).value
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        #expect(fixture.record(task.id)?.mergeCommit == "abc123")

        // A new pull request drops the old one's merge.
        let replacement = "https://github.com/example/toastty/pull/131"
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #131", url: replacement)
        ))
        let replaced = try #require(fixture.record(task.id))
        #expect(replaced.pullRequestURL == replacement)
        #expect(replaced.mergedAt == nil)
        #expect(replaced.mergeCommit == nil)

        // A closed pull request is checked again, since it can reopen.
        gitHub.answer(replacement, state: "CLOSED")
        let replacementLink = try #require(WorkspacePullRequestLink(annotationURL: replacement))
        await board.pullRequests?.refresh(replacementLink).value
        let callsBefore = gitHub.calls.count
        board.refreshOpenPullRequests()
        await waitUntil { gitHub.calls.count > callsBefore }
    }

    @Test func adoptingATaskSpaceRecordsAMergeSeenBefore() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = FakeGitHub()
        let board = makeBoard(fixture, gitHub: gitHub)
        let untracked = try makeUntrackedTaskSpace(fixture, title: "qa-private-app-verification")
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: untracked,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        gitHub.answer(pullRequestURL, state: "MERGED", mergeCommit: "abc123")
        await board.pullRequests?.refresh(try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))).value

        let adopted = try fixture.coordinator.adopt(workspaceID: untracked)
        #expect(fixture.record(adopted.id)?.mergeCommit == "abc123")
        _ = fixture.store.send(.closeWorkspace(workspaceID: untracked))
        #expect(board.items().first { $0.id == .task(adopted.id) }?.stage == .done)
    }

    @Test func pullRequestRequestsAreMergedAndOlderAnswersDropped() async throws {
        let gitHub = FakeGitHub()
        var clock = Date(timeIntervalSince1970: 5)
        let cache = PullRequestStateCache(runner: gitHub, now: { clock })
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        gitHub.answer(pullRequestURL, state: "OPEN")
        gitHub.holdsAnswers = true

        let first = cache.refresh(link)
        let second = cache.refresh(link)
        await waitUntil { gitHub.calls.count == 1 }
        // A newer answer arrives from elsewhere while the request runs.
        cache.store(TaskPullRequestState(state: .merged, mergeCommit: "abc123"), for: link, observedAt: Date(timeIntervalSince1970: 10))
        gitHub.release()
        await first.value
        await second.value
        #expect(gitHub.calls.count == 1)
        #expect(cache.state(for: link)?.state == .merged)

        // A failed request keeps the last good answer.
        gitHub.holdsAnswers = false
        clock = Date(timeIntervalSince1970: 20)
        let other = try #require(WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/125"))
        await cache.refresh(other).value
        #expect(cache.state(for: other) == nil)
        #expect(cache.entries[other.url]?.lastError == "gh: not found")
        await cache.refresh(link).value
        #expect(cache.state(for: link)?.state == .open)
    }

    @Test func mergeabilityComesFromGitHubAndSurvivesAnUnknownAnswer() async throws {
        let gitHub = FakeGitHub()
        var clock = Date(timeIntervalSince1970: 5)
        let cache = PullRequestStateCache(runner: gitHub, now: { clock })
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        func answer(_ mergeStateStatus: String, state: String = "OPEN", review: String = "", checks: String = "[]") async {
            clock = clock.addingTimeInterval(1)
            gitHub.answer(pullRequestURL, state: state, mergeStateStatus: mergeStateStatus, reviewDecision: review, checks: checks)
            await cache.refresh(link).value
        }
        let passed = #"{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}"#
        let running = #"{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}"#
        let failedStatus = #"{"__typename":"StatusContext","state":"FAILURE"}"#

        // With no earlier answer, a merge state GitHub has not worked out
        // reads as ready.
        await answer("UNKNOWN", checks: "[\(running)]")
        #expect(gitHub.calls.last?.last == PullRequestStateCache.readinessViewFields)
        #expect(cache.state(for: link)?.mergeBlocker == nil)

        await answer("BLOCKED", checks: "[\(passed),\(running)]")
        #expect(cache.state(for: link)?.mergeBlocker == .checksRunning)
        await answer("BLOCKED", review: "REVIEW_REQUIRED", checks: "[\(passed)]")
        #expect(cache.state(for: link)?.mergeBlocker == .reviewRequired)
        await answer("BLOCKED", checks: "[\(failedStatus),\(running)]")
        #expect(cache.state(for: link)?.mergeBlocker == .checksFailing)
        // A finished check that did not pass, such as a stale one, fails.
        await answer("BLOCKED", checks: #"[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"STALE"}]"#)
        #expect(cache.state(for: link)?.mergeBlocker == .checksFailing)

        // An unknown answer keeps the last known one instead of flickering
        // back to Merge.
        await answer("UNKNOWN", checks: "[\(running)]")
        #expect(cache.state(for: link)?.mergeBlocker == .checksFailing)

        await answer("CLEAN", review: "APPROVED", checks: "[\(passed)]")
        #expect(cache.state(for: link)?.mergeBlocker == nil)
        // A value this build does not know reads as unknown, so it keeps
        // the last known state.
        await answer("SOMETHING_NEW")
        #expect(cache.state(for: link)?.mergeability?.mergeState == .clean)
        await answer("DIRTY")
        #expect(cache.state(for: link)?.mergeBlocker == .conflicts)
        // A token that cannot read checks still learns of the merge.
        gitHub.rejectsReadinessFields = true
        let callsBefore = gitHub.calls.count
        await answer("UNKNOWN", state: "MERGED")
        #expect(gitHub.calls.count == callsBefore + 2)
        #expect(gitHub.calls.last?.last == PullRequestStateCache.viewFields)
        #expect(cache.state(for: link)?.state == .merged)
        #expect(cache.state(for: link)?.mergeBlocker == nil)
    }

    @Test func anUnreadFinishedTurnNeedsTheUserUnlessTheAgentWaitsOnAnotherTask() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        let task = try await startTask(fixture, text: "The unread dot stays on")
        let other = try await startTask(fixture, text: "Define the API")
        let session = try #require(task.operation.agentLaunch?.sessionID)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let panel = try #require(task.operation.taskSpace?.panelID)
        func item() throws -> TaskBoardItem { try #require(board.items().first { $0.id == .task(task.id) }) }

        // Started but no turn finished yet: still running.
        #expect(try item().stage == .running)

        fixture.sessionRuntimeStore.updateStatus(sessionID: session, status: SessionStatus(kind: .working, summary: "Working"), at: Date())
        #expect(try item().stage == .running)
        #expect(try item().agent == .working)

        // The turn ends with an unread answer: the next step is the user's.
        let endedAt = Date().addingTimeInterval(1)
        fixture.sessionRuntimeStore.updateStatus(sessionID: session, status: SessionStatus(kind: .ready, summary: "Ready"), at: endedAt)
        _ = fixture.store.send(.recordDesktopNotification(workspaceID: taskSpace, panelID: panel, sessionID: session))
        var finished = try item()
        #expect(finished.stage == .needsYou(.agentFinished))
        #expect(finished.stage.group == .needsYou)
        #expect(finished.hasUnreadTurn)
        #expect(TaskBoardPresentation.statusLine(finished) == "Codex finished · waiting for you")

        // Once the user reads it, the idle agent is running again.
        _ = fixture.store.send(.markPanelNotificationsRead(workspaceID: taskSpace, panelID: panel))
        let read = try item()
        #expect(read.stage == .running)
        #expect(read.agent == .idle)
        #expect(read.hasUnreadTurn == false)
        #expect(TaskBoardPresentation.statusLine(read) == "Codex · idle")
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: session, status: SessionStatus(kind: .idle, summary: "Waiting"), at: endedAt.addingTimeInterval(1)
        )
        #expect(try item().stage == .running)

        // After a relaunch the restored session starts idle under a new
        // session ID: it does not need the user.
        let windowID = try #require(fixture.store.state.windows.first?.id)
        fixture.sessionRuntimeStore.stopSession(sessionID: session, at: endedAt.addingTimeInterval(2))
        fixture.sessionRuntimeStore.startSession(
            sessionID: "restored-\(session)", agent: .codex, panelID: panel, windowID: windowID, workspaceID: taskSpace,
            codexStatusTrackingSource: .externallyReported, cwd: nil, repoRoot: nil, launchReason: .restore, at: endedAt.addingTimeInterval(3)
        )
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: "restored-\(session)", status: SessionStatus(kind: .idle, summary: "Waiting"), at: endedAt.addingTimeInterval(3)
        )
        #expect(try item().stage == .running)

        // An agent that ended its turn to wait on another task is running,
        // even with the turn unread.
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: "restored-\(session)", status: SessionStatus(kind: .ready, summary: "Ready"), at: endedAt.addingTimeInterval(4)
        )
        _ = fixture.store.send(.recordDesktopNotification(workspaceID: taskSpace, panelID: panel, sessionID: "restored-\(session)"))
        #expect(try item().stage == .needsYou(.agentFinished))
        _ = try fixture.coordinator.addWatch(targetTaskID: other.id, condition: .idle, notifyTaskID: task.id)
        let waiting = try item()
        #expect(waiting.stage == .running)
        #expect(TaskBoardPresentation.statusLine(waiting) == "Codex · waiting for \(other.title)")
    }

    @Test func childrenListUnderTheTaskThatStartedThem() {
        func item(_ title: String, taskID: UUID, parent: UUID? = nil, stage: TaskStage) -> TaskBoardItem {
            let record = TaskRecord(
                id: taskID, createdAt: Date(), text: title, title: title, slug: title,
                source: .cli, setup: .started, parentTaskID: parent
            )
            return TaskBoardItem(
                id: .task(taskID), record: record, title: title, taskSpaceWorkspaceID: UUID(), projectWorkspaceID: nil,
                projectTitle: "toastty", stage: stage, agent: .working, pullRequest: nil, pullRequestState: nil,
                branch: nil, parentTaskID: parent, activityAt: Date()
            )
        }
        let parentID = UUID()
        let parent = item("task-inbox", taskID: parentID, stage: .running)
        let firstChild = item("hotkey-capture", taskID: UUID(), parent: parentID, stage: .running)
        let secondChild = item("ios-outbox", taskID: UUID(), parent: parentID, stage: .running)
        let mergedChild = item("store-sidebar", taskID: UUID(), parent: parentID, stage: .toShip)
        let other = item("pricing-page", taskID: UUID(), stage: .running)

        let sections = SidebarStatusSections.make([firstChild, other, parent, secondChild, mergedChild])
        #expect(sections.running.map(\.item.title) == ["pricing-page", "task-inbox", "hotkey-capture", "ios-outbox"])
        #expect(sections.running.map(\.isLinkedChild) == [false, false, true, true])
        #expect(sections.toShip.map(\.count) == [1])
        let progress = TaskBoard.childProgress(of: parentID, items: [parent, firstChild, secondChild, mergedChild, other])
        #expect(progress?.merged == 1)
        #expect(progress?.total == 3)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
