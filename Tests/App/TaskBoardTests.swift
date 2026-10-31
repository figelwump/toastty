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
        #expect(watched.stage == .idle)
        let tracked = try #require(items.first { $0.id == .task(task.id) })
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        #expect(tracked.taskSpaceWorkspaceID == taskSpace)
        // The agent launched with its first prompt, so its turn has begun.
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

    @Test(arguments: [true, false])
    func jumpCyclesReviewTaskSpacesAlongsideWorkingAgents(hasWorkingAgent: Bool) async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let store = fixture.store
        let runtime = fixture.sessionRuntimeStore
        let windowID = try #require(store.state.windows.first?.id)
        let workingPanelID = try #require(store.selectedWorkspace?.focusedPanelID)
        if hasWorkingAgent {
            runtime.startSession(
                sessionID: "working", agent: .codex, panelID: workingPanelID,
                windowID: windowID, workspaceID: fixture.workspaceID,
                codexStatusTrackingSource: .externallyReported,
                cwd: fixture.projectRoot, repoRoot: fixture.projectRoot, at: Date()
            )
            runtime.updateStatus(sessionID: "working", status: SessionStatus(kind: .working, summary: "Working"), at: Date())
        }

        // A tracked task explicitly ready for review, with its answer read.
        let task = try await startTask(fixture, text: "Review the fix")
        let trackedPanelID = try #require(task.operation.taskSpace?.panelID)
        for kind in [SessionStatusKind.working, .idle] {
            runtime.updateStatus(
                sessionID: try #require(task.currentSessionID), status: SessionStatus(kind: kind, summary: "\(kind)"), at: Date()
            )
        }
        try fixture.coordinator.readyForReview(taskID: task.id)

        // An older task space with a linked PR and no live agent also needs review.
        let observedID = try makeUntrackedTaskSpace(fixture, title: "Review the linked PR")
        let observedPanelID = try #require(store.state.workspacesByID[observedID]?.focusedPanelID)
        _ = store.send(.setWorkspaceAnnotation(
            workspaceID: observedID, key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        #expect(board.items().first { $0.taskID == task.id }?.stage == .needsYou(.readyForReview))
        #expect(board.items().first { $0.id == .taskSpace(observedID) }?.stage == .needsYou(.review))

        #expect(store.selectedWorkspace?.focusedPanelID == workingPanelID)
        // Repeated jumps visit both review spaces and the working agent, then wrap.
        let expectedCycle = hasWorkingAgent
            ? [trackedPanelID, observedPanelID, workingPanelID, trackedPanelID]
            : [trackedPanelID, observedPanelID, trackedPanelID]
        for expectedPanelID in expectedCycle {
            #expect(store.nextUnreadOrActivePanelTargetFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            )?.panelID == expectedPanelID)
            #expect(store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.selectedWorkspace?.focusedPanelID == expectedPanelID)
        }

        // Resuming work removes the task from the review segment immediately.
        let sessionID = try #require(task.currentSessionID)
        runtime.updateStatus(sessionID: sessionID, status: SessionStatus(kind: .working, summary: "Working"), at: Date())
        #expect(board.items().first { $0.taskID == task.id }?.stage == .running)
        for expectedPanelID in [observedPanelID, hasWorkingAgent ? workingPanelID : trackedPanelID] {
            #expect(store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.selectedWorkspace?.focusedPanelID == expectedPanelID)
        }
        runtime.updateStatus(sessionID: sessionID, status: SessionStatus(kind: .idle, summary: "Idle"), at: Date())
        _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: try #require(task.taskSpaceWorkspaceID)))

        // A completed review leaves the cycle. Its workspace remains open.
        try fixture.coordinator.markDone(taskID: task.id)
        #expect(store.state.workspacesByID[try #require(task.taskSpaceWorkspaceID)] != nil)
        #expect(store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID, sessionRuntimeStore: runtime
        ))
        #expect(store.selectedWorkspace?.focusedPanelID == observedPanelID)
        _ = store.send(.setWorkspaceDone(workspaceID: observedID, doneAt: Date()))
        #expect(store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID, sessionRuntimeStore: runtime
        ) == hasWorkingAgent)
        #expect(store.selectedWorkspace?.focusedPanelID == (hasWorkingAgent ? workingPanelID : observedPanelID))
    }

    @Test func jumpKeepsReviewCycleStableWithLaterPaneAndPreservesUnreadAndApprovalPriority() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let store = fixture.store
        let runtime = fixture.sessionRuntimeStore
        let windowID = try #require(store.state.windows.first?.id)
        let workingPanelID = try #require(store.selectedWorkspace?.focusedPanelID)
        let laterSpaceID = try makeUntrackedTaskSpace(fixture, title: "Review with later pane")
        let reviewSpaceID = try makeUntrackedTaskSpace(fixture, title: "Another review")
        let reviewPanelID = try #require(store.state.workspacesByID[reviewSpaceID]?.focusedPanelID)
        for workspaceID in [laterSpaceID, reviewSpaceID] {
            _ = store.send(.setWorkspaceAnnotation(
                workspaceID: workspaceID, key: "github-pr",
                annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
            ))
        }
        let laterPanelID = UUID()
        _ = store.send(.createBackgroundTerminalTab(
            workspaceID: laterSpaceID, tabID: UUID(), panelID: laterPanelID, terminalCWD: fixture.projectRoot
        ))
        for (sessionID, workspaceID, panelID, kind) in [
            ("working", fixture.workspaceID, workingPanelID, SessionStatusKind.working),
            ("later", laterSpaceID, laterPanelID, SessionStatusKind.idle),
        ] {
            runtime.startSession(
                sessionID: sessionID, agent: .codex, panelID: panelID,
                windowID: windowID, workspaceID: workspaceID,
                codexStatusTrackingSource: .externallyReported,
                cwd: fixture.projectRoot, repoRoot: fixture.projectRoot, at: Date()
            )
            runtime.updateStatus(sessionID: sessionID, status: SessionStatus(kind: kind, summary: kind.rawValue), at: Date())
        }
        runtime.setLaterFlag(sessionID: "later", isFlagged: true)
        #expect(board.items().first { $0.id == .taskSpace(laterSpaceID) }?.stage == .needsYou(.review))
        // The review space with a later pane is already reachable. Changing
        // its selected tab through the jump must not reset the saved cycle.
        for expectedPanelID in [reviewPanelID, laterPanelID, workingPanelID, reviewPanelID] {
            #expect(store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.selectedWorkspace?.focusedPanelID == expectedPanelID)
        }

        runtime.updateStatus(sessionID: "working", status: SessionStatus(kind: .needsApproval, summary: "Approve"), at: Date())
        // Read the approval notice so the next cycle tests approval status,
        // independently of the unread notification created by that transition.
        _ = store.send(.markPanelNotificationsRead(workspaceID: fixture.workspaceID, panelID: workingPanelID))
        _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: laterSpaceID))
        _ = store.send(.recordDesktopNotification(workspaceID: reviewSpaceID, panelID: reviewPanelID))
        #expect(store.state.workspacesByID[reviewSpaceID]?.unreadPanelIDs.contains(reviewPanelID) == true)
        // Unread preempts approval. Starting at that review then visits
        // approval, later, and the starting review panel, without repeats.
        for expectedPanelID in [reviewPanelID, workingPanelID, laterPanelID, reviewPanelID] {
            #expect(store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.selectedWorkspace?.focusedPanelID == expectedPanelID)
        }
    }

    private func startNamedSession(
        _ fixture: TaskCoordinatorTests.Fixture, workspaceID: UUID, panelID: UUID, sessionID: String,
        override: String? = nil
    ) throws {
        let runtime = fixture.sessionRuntimeStore
        let date = Date()
        runtime.startSession(
            sessionID: sessionID, agent: .opencode, panelID: panelID,
            windowID: try #require(fixture.store.state.windows.first?.id), workspaceID: workspaceID,
            codexStatusTrackingSource: .externallyReported, displayTitleOverride: override,
            cwd: fixture.projectRoot, repoRoot: fixture.projectRoot, at: date
        )
        #expect(runtime.confirmNativeSessionBinding(
            managedSessionID: sessionID, panelID: panelID,
            record: ManagedAgentResumeRecord(
                agent: .opencode, nativeSessionID: sessionID,
                sessionFilePath: fixture.root.appendingPathComponent("\(sessionID).json").path,
                cwd: fixture.projectRoot, capturedAt: date
            )
        ))
    }

    private func reportTitle(_ title: String, sessionID: String, fixture: TaskCoordinatorTests.Fixture) -> Bool {
        fixture.sessionRuntimeStore.applyReportedProviderSessionName(
            sessionID: sessionID, agent: .opencode, nativeSessionID: sessionID, name: title
        )
    }

    @Test func providerTitlesReachTheBoardAndSidebarAndSurviveClosingTheTaskSpace() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = FakeGitHub()
        let board = makeBoard(fixture, gitHub: gitHub)
        let task = try await startTask(fixture, text: "Fix the unread dot")
        let workspaceID = try #require(task.taskSpaceWorkspaceID)
        let panelID = try #require(task.operation.taskSpace?.panelID)
        let launchedID = try #require(task.currentSessionID)
        let launched = try #require(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID[launchedID])
        #expect(launched.displayTitleOverride == nil, "Task launch must not mask provider names")
        #expect(board.items().first { $0.taskID == task.id }?.title == task.title)
        try startNamedSession(fixture, workspaceID: workspaceID, panelID: panelID, sessionID: "restored-owner")
        #expect(reportTitle("Unread dot repair", sessionID: "restored-owner", fixture: fixture))
        await waitUntil { fixture.record(task.id)?.title == "Unread dot repair" }
        #expect(board.items().first { $0.taskID == task.id }?.title == "Unread dot repair")
        let runtime = TerminalRuntimeRegistry()
        let sidebar = SidebarView(
            windowID: try #require(fixture.store.state.windows.first?.id), store: fixture.store,
            terminalRuntimeRegistry: runtime, sessionRuntimeStore: fixture.sessionRuntimeStore,
            annotationStyleStore: makeTestAnnotationStyleStore(), taskBoard: board,
            terminalRuntimeContext: TerminalWindowRuntimeContext(windowID: try #require(fixture.store.state.windows.first?.id), runtimeRegistry: runtime)
        )
        let workspace = try #require(fixture.store.state.workspacesByID[workspaceID])
        #expect(sidebar.subspaceRowModel(workspace: workspace, spawner: nil, windowWorkspaceIDs: [workspaceID]).title == "Unread dot repair")
        #expect(workspace.title == task.slug)
        #expect(fixture.record(task.id)?.slug == task.slug)

        // A title and exit in one publication burst must still be saved.
        #expect(reportTitle("Unread dot fixed", sessionID: "restored-owner", fixture: fixture))
        fixture.sessionRuntimeStore.stopSession(sessionID: "restored-owner", at: Date())
        fixture.sessionRuntimeStore.startSession(
            sessionID: "monitor", agent: .processWatch, panelID: panelID,
            windowID: try #require(fixture.store.state.windows.first?.id), workspaceID: workspaceID,
            codexStatusTrackingSource: .externallyReported, displayTitleOverride: "Watching a process",
            cwd: fixture.projectRoot, repoRoot: fixture.projectRoot, at: Date()
        )
        _ = fixture.store.send(.closeWorkspace(workspaceID: workspaceID))
        await waitUntil { fixture.record(task.id)?.title == "Unread dot fixed" }
        try fixture.coordinator.records.flush()
        #expect(fixture.savedRecord(task.id)?.title == "Unread dot fixed")
        #expect(board.items().first { $0.taskID == task.id }?.title == "Unread dot fixed")
        #expect(gitHub.calls.isEmpty, "A title change does not query GitHub")
    }

    @Test func aMovedTaskUsesItsOwnerAndKeepsExplicitTitles() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        let task = try await startTask(fixture, text: "Fix the unread dot")
        let workspaceID = try #require(task.taskSpaceWorkspaceID)
        let originalPanel = try #require(task.operation.taskSpace?.panelID)
        try startNamedSession(fixture, workspaceID: workspaceID, panelID: originalPanel, sessionID: "original")
        #expect(reportTitle("Original work", sessionID: "original", fixture: fixture))
        _ = fixture.store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil))
        let movedPanel = try #require(fixture.store.state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(movedPanel != originalPanel)
        try fixture.coordinator.records.save(id: task.id) {
            $0.operation.worktreeSession = TaskOperation.WorktreeSession(
                workspaceID: workspaceID, panelID: movedPanel, sessionID: "old-moved-id", forked: true
            )
        }
        try startNamedSession(fixture, workspaceID: workspaceID, panelID: movedPanel, sessionID: "restored-moved")
        #expect(reportTitle("Worktree repair", sessionID: "restored-moved", fixture: fixture))
        await waitUntil { fixture.record(task.id)?.title == "Worktree repair" }
        #expect(reportTitle("Unrelated work", sessionID: "original", fixture: fixture))
        #expect(board.items().first { $0.taskID == task.id }?.title == "Worktree repair")

        try fixture.coordinator.records.save(id: task.id) { $0.title = "My title"; $0.titleSetByUser = true }
        #expect(reportTitle("Another provider title", sessionID: "restored-moved", fixture: fixture))
        #expect(board.items().first { $0.taskID == task.id }?.title == "My title")
        // Wait for the deferred observer by doing another observable change.
        let other = try await startTask(fixture, text: "Other task")
        await waitUntil { fixture.record(other.id)?.setup == .started }
        #expect(fixture.record(task.id)?.title == "My title")
    }

    @Test func olderTaskSpacesUseTheFirstNamedAgentAcrossStopsAndRestores() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let workspaceID = try makeUntrackedTaskSpace(fixture, title: "temporary-task-name")
        let panelID = try #require(fixture.store.state.workspacesByID[workspaceID]?.focusedPanelID)
        try startNamedSession(fixture, workspaceID: workspaceID, panelID: panelID, sessionID: "first")
        // Construct the board after the sessions, as happens on startup.
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        func title() -> String? { board.items().first { $0.id == .taskSpace(workspaceID) }?.title }
        #expect(title() == "temporary-task-name")
        _ = fixture.store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil))
        let secondPanel = try #require(fixture.store.state.workspacesByID[workspaceID]?.focusedPanelID)
        try startNamedSession(fixture, workspaceID: workspaceID, panelID: secondPanel, sessionID: "second")
        #expect(reportTitle("Second task", sessionID: "second", fixture: fixture))
        #expect(title() == "Second task", "An unnamed first session must not hide an available title")
        #expect(reportTitle("Older task repair", sessionID: "first", fixture: fixture))
        #expect(title() == "Older task repair")
        fixture.sessionRuntimeStore.stopSession(sessionID: "first", at: Date())
        #expect(title() == "Older task repair")
        try startNamedSession(fixture, workspaceID: workspaceID, panelID: panelID, sessionID: "first-restored", override: "Chosen session title")
        #expect(reportTitle("Provider title", sessionID: "first-restored", fixture: fixture))
        #expect(title() == "Chosen session title")
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

        // The agent launched with its first prompt: that turn has begun even
        // before the agent reports it.
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

        // Once the user reads it, the task is idle.
        _ = fixture.store.send(.markPanelNotificationsRead(workspaceID: taskSpace, panelID: panel))
        let read = try item()
        #expect(read.stage == .idle)
        #expect(read.stage.group == .idle)
        #expect(read.agent == .idle)
        #expect(read.hasUnreadTurn == false)
        #expect(TaskBoardPresentation.statusLine(read) == "Codex · idle")
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: session, status: SessionStatus(kind: .idle, summary: "Waiting"), at: endedAt.addingTimeInterval(1)
        )
        #expect(try item().stage == .idle)

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
        #expect(try item().stage == .idle)

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

    @Test func aQuestionWaitsInNeedsYouUntilTheTasksAgentStartsNewWork() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        // The coordinator finds the task's agent through the live sessions,
        // as in the app.
        fixture.coordinator.sessions = LiveTaskSessions(
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            closeController: SessionCloseController(
                store: fixture.store,
                sessionRuntimeStore: fixture.sessionRuntimeStore,
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: fixture.store,
                    runtimeRegistry: TerminalRuntimeRegistry(),
                    slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                ),
                terminalCloseAssessment: { _ in nil },
                localDocumentCloseConfirmationState: { _ in nil },
                shouldBypassConfirmation: true
            ),
            exitController: nil,
            sendText: { _, _ in true }
        )
        let task = try await startTask(fixture, text: "Which hostname option?")
        let session = try #require(task.operation.agentLaunch?.sessionID)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let panel = try #require(task.operation.taskSpace?.panelID)
        let runtime = fixture.sessionRuntimeStore
        func item() throws -> TaskBoardItem { try #require(board.items().first { $0.id == .task(task.id) }) }
        let start = Date()

        // The agent marks its question while it works, then ends its turn.
        runtime.updateStatus(sessionID: session, status: SessionStatus(kind: .working, summary: "Working"), at: start)
        _ = try fixture.coordinator.needsReply(taskID: task.id, question: "Pick a hostname option")
        runtime.updateStatus(sessionID: session, status: SessionStatus(kind: .ready, summary: "Ready"), at: start.addingTimeInterval(1))
        _ = fixture.store.send(.recordDesktopNotification(workspaceID: taskSpace, panelID: panel, sessionID: session))
        #expect(try item().stage == .needsYou(.awaitingReply))
        #expect(TaskBoardPresentation.statusLine(try item()) == "Asks: Pick a hostname option")

        // Reading the turn does not answer it.
        _ = fixture.store.send(.markPanelNotificationsRead(workspaceID: taskSpace, panelID: panel))
        runtime.updateStatus(sessionID: session, status: SessionStatus(kind: .idle, summary: "Waiting"), at: start.addingTimeInterval(2))
        #expect(try item().stage == .needsYou(.awaitingReply))

        // Another agent in the task space does not answer it either.
        let windowID = try #require(fixture.store.state.windows.first?.id)
        runtime.startSession(
            sessionID: "helper", agent: .claude, panelID: UUID(), windowID: windowID, workspaceID: taskSpace,
            codexStatusTrackingSource: .externallyReported, cwd: nil, repoRoot: nil, at: start.addingTimeInterval(3)
        )
        runtime.updateStatus(sessionID: "helper", status: SessionStatus(kind: .working, summary: "Working"), at: start.addingTimeInterval(3))
        #expect(fixture.record(task.id)?.replyRequest != nil)
        runtime.stopSession(sessionID: "helper", at: start.addingTimeInterval(4))

        // The user's answer starts the agent's next turn and clears it.
        runtime.updateStatus(sessionID: session, status: SessionStatus(kind: .working, summary: "Working"), at: start.addingTimeInterval(5))
        #expect(fixture.record(task.id)?.replyRequest == nil)
        #expect(try item().stage == .running)

        // A later ready mark replaces a question.
        _ = try fixture.coordinator.needsReply(taskID: task.id, question: nil)
        #expect(fixture.record(task.id)?.replyRequest?.question == nil)
        _ = try fixture.coordinator.readyForReview(taskID: task.id)
        #expect(fixture.record(task.id)?.replyRequest == nil)
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
        let quiet = item("coordinator-brainstorm", taskID: UUID(), stage: .idle)
        let idleChild = item("composer-blank-line", taskID: UUID(), parent: parentID, stage: .idle)

        let sections = SidebarStatusSections.make([firstChild, quiet, other, parent, idleChild, secondChild, mergedChild])
        // A family lists together in its most urgent group: the idle child
        // stays under its running parent, dimmed, and is not counted there.
        #expect(sections.running.map(\.item.title) == [
            "pricing-page", "task-inbox", "composer-blank-line", "hotkey-capture", "ios-outbox",
        ])
        #expect(sections.running.map(\.isLinkedChild) == [false, false, true, true, true])
        #expect(sections.running.map(\.isContext) == [false, false, true, false, false])
        #expect(sections.count(.running) == 4)
        #expect(sections.idle.map(\.item.title) == ["coordinator-brainstorm"])
        #expect(sections.count(.idle) == 1)
        let tasksView = TasksViewSections.make([firstChild, quiet, other, parent, idleChild, secondChild, mergedChild])
        #expect(tasksView.idle.map(\.item.title) == ["coordinator-brainstorm", "composer-blank-line"])
        // The Tasks view lists Idle after Running and before To ship.
        #expect(tasksView.all.map(\.item.title).suffix(3) == ["coordinator-brainstorm", "composer-blank-line", "store-sidebar"])
        #expect(sections.toShip.map(\.count) == [1])
        let progress = TaskBoard.childProgress(of: parentID, items: [parent, firstChild, secondChild, mergedChild, other])
        #expect(progress?.merged == 1)
        #expect(progress?.total == 3)
    }

    private func statusItem(
        _ title: String,
        taskID: UUID = UUID(),
        parent: UUID? = nil,
        stage: TaskStage,
        project: String = "toastty"
    ) -> TaskBoardItem {
        let record = TaskRecord(
            id: taskID, createdAt: Date(), text: title, title: title, slug: title,
            source: .cli, setup: .started, parentTaskID: parent
        )
        return TaskBoardItem(
            id: .task(taskID), record: record, title: title, taskSpaceWorkspaceID: UUID(), projectWorkspaceID: nil,
            projectTitle: project, stage: stage, agent: .idle, pullRequest: nil, pullRequestState: nil,
            branch: nil, parentTaskID: parent, activityAt: Date()
        )
    }

    /// The case from the report: an idle parent whose child waits for a
    /// review lists with the child in Needs you, instead of apart in Idle.
    @Test func aFamilyListsInTheGroupOfItsMostUrgentTask() {
        let parentID = UUID()
        let thumbnail = statusItem("thumbnail", stage: .needsYou(.review))
        let child = statusItem("mcp-page-tools", parent: parentID, stage: .needsYou(.review), project: "emptyos")
        let space = statusItem("task-space-after-ship", stage: .needsYou(.agentFinished))
        let parent = statusItem("chatgpt-public-url", taskID: parentID, stage: .idle, project: "emptyos")
        let brainstorm = statusItem("coordinator-brainstorm", stage: .idle)

        // Newest activity first, as the board gives them.
        let sections = SidebarStatusSections.make([thumbnail, child, space, parent, brainstorm])
        #expect(sections.needsYou.map(\.item.title) == [
            "thumbnail", "chatgpt-public-url", "mcp-page-tools", "task-space-after-ship",
        ])
        #expect(sections.needsYou.map(\.isLinkedChild) == [false, false, true, false])
        #expect(sections.needsYou.map(\.isContext) == [false, true, false, false])
        #expect(sections.count(.needsYou) == 3)
        #expect(sections.idle.map(\.item.title) == ["coordinator-brainstorm"])

        // Once nothing in the family needs the user, it lists in Idle.
        var answered = child
        answered.stage = .idle
        let calm = SidebarStatusSections.make([thumbnail, answered, space, parent, brainstorm])
        #expect(calm.idle.map(\.item.title) == ["chatgpt-public-url", "mcp-page-tools", "coordinator-brainstorm"])
        #expect(calm.idle.map(\.isContext) == [false, false, false])
    }

    /// Reading a child must not move it within its held family either.
    @Test func aSelectedChildKeepsItsPlaceInItsFamily() {
        let parentID = UUID()
        let parent = statusItem("parent", taskID: parentID, stage: .idle)
        let zulu = statusItem("zulu", parent: parentID, stage: .needsYou(.agentFinished))
        let alpha = statusItem("alpha", parent: parentID, stage: .idle)
        let before = SidebarStatusSections.make([zulu, parent, alpha])
        #expect(before.needsYou.map(\.item.title) == ["parent", "alpha", "zulu"])

        let pin = SidebarStatusSections.pin(previous: nil, selected: zulu.id, displayed: before.slots)
        var read = zulu
        read.stage = .idle
        let held = SidebarStatusSections.make([alpha, parent, read], pin: pin)
        #expect(held.needsYou.map(\.item.title) == ["parent", "alpha", "zulu"])
        #expect(held.needsYou.map(\.isContext) == [true, true, true])
        #expect(held.idle.isEmpty)
    }

    @Test func everyTaskListsOnceWhateverItsParents() {
        let aID = UUID(), bID = UUID(), cID = UUID(), loopA = UUID(), loopB = UUID()
        let items = [
            statusItem("a", taskID: aID, stage: .idle),
            statusItem("b", taskID: bID, parent: aID, stage: .running),
            // A grandchild lists on its own: one level only.
            statusItem("c", taskID: cID, parent: bID, stage: .needsYou(.agentFinished)),
            // A parent that is finished, or missing, leaves its child on its own.
            statusItem("d", parent: UUID(), stage: .running),
            statusItem("loop-a", taskID: loopA, parent: loopB, stage: .idle),
            statusItem("loop-b", taskID: loopB, parent: loopA, stage: .idle),
        ]
        let sections = SidebarStatusSections.make(items)
        let listed = (sections.needsYou + sections.running + sections.idle).map(\.item.title)
        #expect(listed.sorted() == ["a", "b", "c", "d", "loop-a", "loop-b"])
        #expect(sections.needsYou.map(\.item.title) == ["c"])
        #expect(sections.running.map(\.item.title) == ["a", "b", "d"])
    }

    /// Selecting a task reads its turn. Its family keeps the group and slot
    /// it had on screen until the selection moves, and moves at once only
    /// when it becomes more urgent.
    @Test func theSelectedTaskHoldsItsSlotUntilTheSelectionMoves() {
        let first = statusItem("first", stage: .needsYou(.agentFinished))
        let clicked = statusItem("clicked", stage: .needsYou(.agentFinished))
        let last = statusItem("last", stage: .needsYou(.review))
        let quiet = statusItem("quiet", stage: .idle)
        let before = SidebarStatusSections.make([first, clicked, last, quiet])
        #expect(before.needsYou.map(\.item.title) == ["first", "clicked", "last"])

        let pin = SidebarStatusSections.pin(previous: nil, selected: clicked.id, displayed: before.slots)
        #expect(pin == SidebarStatusSections.Pin(subject: clicked.id, slot: .init(group: .needsYou, above: [first.id])))
        var read = clicked
        read.stage = .idle
        let held = SidebarStatusSections.make([first, read, last, quiet], pin: pin)
        #expect(held.needsYou.map(\.item.title) == ["first", "clicked", "last"])
        // Dimmed: the user read it, and it no longer needs them.
        #expect(held.needsYou.map(\.isContext) == [false, true, false])
        // The count says what really needs the user.
        #expect(held.count(.needsYou) == 2)
        #expect(held.idle.map(\.item.title) == ["quiet"])
        #expect(held.pin == pin)
        // The same selection keeps the pin; another selection lets it go.
        #expect(SidebarStatusSections.pin(previous: held.pin, selected: clicked.id, displayed: held.slots) == pin)
        let released = SidebarStatusSections.make(
            [first, read, last, quiet],
            pin: SidebarStatusSections.pin(previous: held.pin, selected: first.id, displayed: held.slots)
        )
        #expect(released.needsYou.map(\.item.title) == ["first", "last"])
        #expect(released.idle.map(\.item.title) == ["clicked", "quiet"])

        // A selected idle task that starts to need the user moves at once,
        // and holds in its new place from then on.
        let quietPin = SidebarStatusSections.pin(previous: nil, selected: quiet.id, displayed: before.slots)
        var asks = quiet
        asks.stage = .needsYou(.agentNeedsInput)
        let urgent = SidebarStatusSections.make([first, clicked, last, asks], pin: quietPin)
        #expect(urgent.needsYou.map(\.item.title).contains("quiet"))
        #expect(urgent.idle.isEmpty)
        #expect(urgent.pin?.slot.group == .needsYou)

        // Found on the mini: selecting another task releases the one held
        // before it, which leaves the group at the same time. The newly
        // selected task must not jump past the rows that were below it.
        let parentID = UUID()
        let parent = statusItem("parent", taskID: parentID, stage: .idle)
        let child = statusItem("child", parent: parentID, stage: .needsYou(.review))
        var answered = first
        answered.stage = .idle
        let previousPin = SidebarStatusSections.Pin(subject: first.id, slot: .init(group: .needsYou, above: []))
        let shown = SidebarStatusSections.make([clicked, child, answered, parent], pin: previousPin)
        #expect(shown.needsYou.map(\.item.title) == ["first", "clicked", "parent", "child"])
        let next = SidebarStatusSections.pin(previous: shown.pin, selected: clicked.id, displayed: shown.slots)
        let switched = SidebarStatusSections.make([child, answered, read, parent], pin: next)
        #expect(switched.needsYou.map(\.item.title) == ["clicked", "parent", "child"])
        #expect(switched.idle.map(\.item.title) == ["first"])
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
