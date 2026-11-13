import Combine
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
        var failsRequests = false

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
        var heldCount: Int { lock.withLock { held.count } }

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
            if lock.withLock({ failsRequests }) {
                return WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "gh: offline", failure: nil)
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
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
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
        _ = fixture.store.send(.recordDesktopNotification(workspaceID: untracked, panelID: try #require(fixture.store.state.workspacesByID[untracked]?.focusedPanelID)))
        #expect(fixture.store.nextUnreadOrActivePanelTargetFromCommand(
            preferredWindowID: fixture.store.state.windows.first?.id, sessionRuntimeStore: fixture.sessionRuntimeStore
        )?.workspaceID != untracked)

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

    @Test(arguments: [TaskStage.done, .archived, .toShip])
    func jumpSkipsQuietUnreadInCompletedTasks(stage: TaskStage) async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        if stage == .toShip {
            fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*")])
        }
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let task = try await startTask(fixture, text: "Finish the work")
        let workspaceID = try #require(task.taskSpaceWorkspaceID)
        let panelID = try #require(task.operation.taskSpace?.panelID)
        let sessionID = try #require(task.currentSessionID)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: sessionID, status: SessionStatus(kind: .ready, summary: "Finished"), at: Date()
        )
        try fixture.coordinator.records.save(id: task.id) {
            if stage == .archived { $0.archivedAt = Date() } else { Self.merge(&$0) }
        }
        #expect(board.items().first { $0.taskID == task.id }?.stage == stage)
        // The task's completion is authoritative even before its workspace
        // has a done mark or cleanup has closed it.
        #expect(fixture.store.state.workspacesByID[workspaceID]?.doneAt == nil)
        #expect(fixture.store.state.workspacesByID[workspaceID]?.unreadPanelIDs.contains(panelID) == true)
        let windowID = try #require(fixture.store.state.windows.first?.id)
        #expect(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
            store: fixture.store, preferredWindowID: windowID, sessionRuntimeStore: fixture.sessionRuntimeStore
        ) == false)
        #expect(fixture.store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID, sessionRuntimeStore: fixture.sessionRuntimeStore
        ) == false)
        #expect(fixture.store.selectedWorkspace?.id == fixture.workspaceID)
        #expect(fixture.store.state.workspacesByID[workspaceID]?.unreadPanelIDs.contains(panelID) == true)

        // A stopped cleanup needs attention, even after work finished.
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: workspaceID, doneAt: Date()))
        try fixture.coordinator.records.save(id: task.id) {
            $0.cleanup = TaskCleanup(kind: stage == .archived ? .archive : .merge, problem: "Cleanup stopped")
        }
        #expect(board.items().first { $0.taskID == task.id }?.stage == .needsYou(.cleanupStopped(reason: "Cleanup stopped")))
        #expect(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
            store: fixture.store, preferredWindowID: windowID, sessionRuntimeStore: fixture.sessionRuntimeStore
        ))
        #expect(fixture.store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID, sessionRuntimeStore: fixture.sessionRuntimeStore
        ))
        #expect(fixture.store.selectedWorkspace?.id == workspaceID)
    }

    @Test(arguments: [false, true])
    func jumpUsesSavedMergeAcceptanceWithoutARestoredMergeRequest(skillStopped: Bool) async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let task = try await startTask(fixture, text: "Merge the work")
        let workspaceID = try #require(task.taskSpaceWorkspaceID)
        let panelID = try #require(task.operation.taskSpace?.panelID)
        let readyAt = Date().addingTimeInterval(1)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: try #require(task.currentSessionID), status: SessionStatus(kind: .ready, summary: "Ready"), at: readyAt
        )
        try fixture.coordinator.records.save(id: task.id) {
            $0.pullRequestURL = pullRequestURL
            $0.mergeRequestedAt = readyAt.addingTimeInterval(skillStopped ? -1 : 1)
        }
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: workspaceID, doneAt: Date()))
        let restored = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(restored)
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        restored.board = board
        fixture.sessionRuntimeStore.taskCoordinator = restored
        #expect(fixture.sessionRuntimeStore.workspaceMergeRequests.isEmpty)
        #expect(board.items().first { $0.taskID == task.id }?.stage == (skillStopped ? .needsYou(.review) : .running))
        let windowID = try #require(fixture.store.state.windows.first?.id)
        #expect(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
            store: fixture.store, preferredWindowID: windowID, sessionRuntimeStore: fixture.sessionRuntimeStore
        ))
        #expect(fixture.store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID, sessionRuntimeStore: fixture.sessionRuntimeStore
        ))
        #expect(fixture.store.selectedWorkspace?.focusedPanelID == panelID)
        #expect(fixture.store.state.workspacesByID[workspaceID]?.doneAt != nil)
    }

    /// Complete and Archive both move focus on. An unread panel in another
    /// window outranks a review, but focus stays in the window that showed
    /// the task space.
    @Test(arguments: [false, true], [false, true])
    func finishingTheShownTaskMovesFocusToTheNextActiveTaskSpace(unreadInAnotherWindow: Bool, archive: Bool) async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let store = fixture.store
        let runtime = fixture.sessionRuntimeStore
        fixture.coordinator.closeFinishedTaskSpace = { [unowned store, unowned runtime] workspaceID in
            store.closeTaskSpaceFocusingNextActive(workspaceID: workspaceID, sessionRuntimeStore: runtime)
        }
        let windowID = try #require(store.state.windows.first?.id)

        let task = try await startTask(fixture, text: "Answer the question")
        let taskSpaceID = try #require(task.taskSpaceWorkspaceID)
        for kind in [SessionStatusKind.working, .idle] {
            runtime.updateStatus(
                sessionID: try #require(task.currentSessionID), status: SessionStatus(kind: kind, summary: "\(kind)"), at: Date()
            )
        }
        try fixture.coordinator.readyForReview(taskID: task.id)
        // The workspace after the task space has nothing to do; the one
        // after that waits for review.
        let quietID = try makeUntrackedTaskSpace(fixture, title: "Nothing to do")
        let reviewID = try makeUntrackedTaskSpace(fixture, title: "Review the linked PR")
        let reviewPanelID = try #require(store.state.workspacesByID[reviewID]?.focusedPanelID)
        _ = store.send(.setWorkspaceAnnotation(
            workspaceID: reviewID, key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        #expect(store.state.window(id: windowID)?.workspaceIDs.firstIndex(of: quietID)
            == store.state.window(id: windowID)?.workspaceIDs.firstIndex(of: taskSpaceID).map { $0 + 1 })
        if unreadInAnotherWindow {
            #expect(store.send(.createWindow(seed: nil, initialFrame: nil)))
            let otherWindow = try #require(store.state.windows.first { $0.id != windowID })
            let otherWorkspaceID = try #require(otherWindow.selectedWorkspaceID)
            let otherPanelID = try #require(store.state.workspacesByID[otherWorkspaceID]?.focusedPanelID)
            #expect(store.send(.recordDesktopNotification(workspaceID: otherWorkspaceID, panelID: otherPanelID)))
            #expect(store.nextUnreadOrActivePanelTargetFromCommand(
                preferredWindowID: windowID, sessionRuntimeStore: runtime
            )?.panelID == otherPanelID)
        }
        _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: taskSpaceID))
        #expect(store.state.selectedWindowID == windowID)

        if archive {
            try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions())
            await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }
            #expect(fixture.record(task.id)?.archivedAt != nil)
        } else {
            try fixture.coordinator.complete(taskID: task.id)
            #expect(fixture.record(task.id)?.doneAt != nil)
        }

        #expect(store.state.workspacesByID[taskSpaceID] == nil)
        // A plain close would select the quiet neighbor.
        #expect(store.selectedWorkspace?.id == reviewID)
        #expect(store.selectedWorkspace?.focusedPanelID == reviewPanelID)
    }

    @Test func completingATaskThatIsNotShownLeavesTheSelectionAlone() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let store = fixture.store
        let runtime = fixture.sessionRuntimeStore
        fixture.coordinator.closeFinishedTaskSpace = { [unowned store, unowned runtime] workspaceID in
            store.closeTaskSpaceFocusingNextActive(workspaceID: workspaceID, sessionRuntimeStore: runtime)
        }
        let windowID = try #require(store.state.windows.first?.id)
        let task = try await startTask(fixture, text: "Answer the question")
        let taskSpaceID = try #require(task.taskSpaceWorkspaceID)
        let reviewID = try makeUntrackedTaskSpace(fixture, title: "Review the linked PR")
        _ = store.send(.setWorkspaceAnnotation(
            workspaceID: reviewID, key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: fixture.workspaceID))

        try fixture.coordinator.complete(taskID: task.id)

        #expect(store.state.workspacesByID[taskSpaceID] == nil)
        #expect(store.selectedWorkspace?.id == fixture.workspaceID)
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
        #expect(sidebar.subspaceRowModel(workspace: workspace, spawner: nil).title == "Unread dot repair")
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

    @Test func pendingChecksRefreshSoonerThanSettledPullRequests() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let task = try await startTask(fixture, text: "Refresh completed checks")
        let workspaceID = try #require(task.taskSpaceWorkspaceID)
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: workspaceID, key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #124", url: pullRequestURL)
        ))
        let gitHub = FakeGitHub()
        gitHub.answer(pullRequestURL, state: "OPEN", mergeStateStatus: "CLEAN")
        var clock = Date(timeIntervalSince1970: 1000)
        let cache = PullRequestStateCache(runner: gitHub, now: { clock })
        let board = TaskBoardStore(
            coordinator: fixture.coordinator, store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore, pullRequests: cache,
            releaseCheckInterval: nil
        )
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        // A restored PR is fetched immediately, before the first periodic tick.
        await waitUntil { cache.answer(for: link) != nil }
        let initialCalls = gitHub.calls.count
        clock = clock.addingTimeInterval(119)
        board.refreshOpenPullRequests(onlyIfDue: true)
        #expect(gitHub.calls.count == initialCalls)

        clock = clock.addingTimeInterval(1)
        gitHub.answer(pullRequestURL, state: "OPEN", mergeStateStatus: "UNSTABLE",
                      checks: #"[{"status":"IN_PROGRESS"}]"#)
        board.refreshOpenPullRequests(onlyIfDue: true)
        await cache.refresh(link).value
        #expect(cache.state(for: link)?.mergeBlocker == .checksRunning)
        let pendingCalls = gitHub.calls.count
        clock = clock.addingTimeInterval(14)
        board.refreshOpenPullRequests(onlyIfDue: true)
        #expect(gitHub.calls.count == pendingCalls)

        clock = clock.addingTimeInterval(1)
        gitHub.answer(pullRequestURL, state: "OPEN", mergeStateStatus: "CLEAN",
                      checks: #"[{"status":"COMPLETED","conclusion":"SUCCESS"}]"#)
        board.refreshOpenPullRequests(onlyIfDue: true)
        await waitUntil { cache.state(for: link)?.mergeability?.checks == .passing }
        #expect(gitHub.calls.count == pendingCalls + 1)
        #expect(cache.state(for: link)?.mergeBlocker == nil)
        let settledCalls = gitHub.calls.count
        clock = clock.addingTimeInterval(15)
        board.refreshOpenPullRequests(onlyIfDue: true)
        #expect(gitHub.calls.count == settledCalls)

        // Inherited passing checks do not make a field-limited answer settled.
        cache.store(TaskPullRequestState(state: .open, headSHA: "head1"), for: link, observedAt: clock)
        clock = clock.addingTimeInterval(15)
        board.refreshOpenPullRequests(onlyIfDue: true)
        await waitUntil { gitHub.calls.count == settledCalls + 1 && !cache.isRefreshing(link) }
    }

    @Test func unknownAndFailedAnswersDoNotKeepReadinessForever() async throws {
        let gitHub = FakeGitHub()
        var clock = Date(timeIntervalSince1970: 1000)
        let cache = PullRequestStateCache(runner: gitHub, now: { clock })
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        func store(_ head: String, _ mergeState: PullRequestMergeability.MergeState) {
            cache.store(TaskPullRequestState(
                state: .open, headSHA: head,
                mergeability: PullRequestMergeability(mergeState: mergeState, checks: .running)
            ), for: link, observedAt: clock)
        }
        store("aaa", .unstable)
        clock = clock.addingTimeInterval(15)
        store("aaa", .unknown)
        #expect(cache.state(for: link)?.mergeBlocker == .checksRunning)
        #expect(cache.answer(for: link)?.mergeability?.mergeState == .unknown)
        // Repeated unknown answers do not restart the 30 second grace period.
        clock = clock.addingTimeInterval(15)
        store("aaa", .unknown)
        #expect(cache.state(for: link)?.mergeability?.mergeState == .unknown)
        store("aaa", .clean)
        store("bbb", .unknown)
        #expect(cache.state(for: link)?.mergeability?.mergeState == .unknown)
        #expect(cache.state(for: link)?.mergeability?.checks == .running)

        store("bbb", .unstable)
        gitHub.failsRequests = true
        clock = clock.addingTimeInterval(15)
        await cache.refresh(link).value
        #expect(cache.state(for: link)?.mergeBlocker == .checksRunning)
        let failedCalls = gitHub.calls.count
        clock = clock.addingTimeInterval(14)
        cache.refreshIfNeeded(link)
        #expect(gitHub.calls.count == failedCalls)
        clock = clock.addingTimeInterval(1)
        cache.refreshIfNeeded(link)
        await waitUntil { gitHub.calls.count == failedCalls + 2 && !cache.isRefreshing(link) }
        #expect(cache.state(for: link)?.mergeability == nil)
        #expect(cache.answer(for: link)?.mergeability?.checks == .running)

        // Readiness-field fallback has the same expiry and cannot extend it.
        gitHub.failsRequests = false
        gitHub.rejectsReadinessFields = true
        gitHub.answer(pullRequestURL, state: "OPEN")
        store("head1", .unstable)
        clock = clock.addingTimeInterval(15)
        await cache.refresh(link).value
        #expect(cache.state(for: link)?.mergeBlocker == .checksRunning)
        clock = clock.addingTimeInterval(15)
        await cache.refresh(link).value
        #expect(cache.state(for: link)?.mergeability == nil)
        #expect(cache.answer(for: link)?.mergeability?.checks == .running)

        // A first failure after the known answer is already old gets no
        // extra grace, and still keeps check history for task alerts.
        store("head1", .unstable)
        clock = clock.addingTimeInterval(45)
        gitHub.failsRequests = true
        await cache.refresh(link).value
        #expect(cache.state(for: link)?.mergeability == nil)
        #expect(cache.answer(for: link)?.mergeability?.checks == .running)
    }

    @Test func anOlderFailedRequestDoesNotReplaceANewerGoodAnswer() async throws {
        let gitHub = FakeGitHub()
        var clock = Date(timeIntervalSince1970: 1000)
        let cache = PullRequestStateCache(runner: gitHub, now: { clock })
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        gitHub.holdsAnswers = true
        gitHub.failsRequests = true
        let request = cache.refresh(link)
        await waitUntil { gitHub.heldCount == 1 }
        clock = clock.addingTimeInterval(60)
        cache.store(TaskPullRequestState(
            state: .open, headSHA: "new",
            mergeability: PullRequestMergeability(mergeState: .clean, checks: .passing)
        ), for: link, observedAt: clock)
        gitHub.holdsAnswers = false
        gitHub.release()
        await request.value
        #expect(cache.entries[link.url]?.lastError == nil)
        #expect(cache.state(for: link)?.mergeability?.checks == .passing)
    }

    @Test func readinessExpiresWhileARefreshIsStillRunning() async throws {
        let gitHub = FakeGitHub()
        var clock = Date(timeIntervalSince1970: 1000)
        let cache = PullRequestStateCache(runner: gitHub, now: { clock })
        let link = try #require(WorkspacePullRequestLink(annotationURL: pullRequestURL))
        cache.store(TaskPullRequestState(
            state: .open, headSHA: "head1",
            mergeability: PullRequestMergeability(mergeState: .unstable, checks: .running)
        ), for: link, observedAt: clock)
        clock = clock.addingTimeInterval(15)
        cache.store(TaskPullRequestState(
            state: .open, headSHA: "head1",
            mergeability: PullRequestMergeability(mergeState: .unknown)
        ), for: link, observedAt: clock)
        gitHub.answer(pullRequestURL, state: "OPEN", mergeStateStatus: "UNKNOWN")
        gitHub.holdsAnswers = true
        let request = cache.refresh(link)
        await waitUntil { gitHub.heldCount == 1 }
        var publications = 0
        let observation = cache.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        clock = clock.addingTimeInterval(15)
        cache.refreshIfNeeded(link)
        #expect(publications == 1, "The header must redraw when grace expires, even while a request is held")
        #expect(cache.state(for: link)?.mergeability?.mergeState == .unknown)
        #expect(gitHub.calls.count == 1)
        gitHub.release()
        await request.value
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

    // MARK: - Tasks that coordinate child tasks

    /// A task as `task create` records it, here without a task space. A
    /// child names the task that started it.
    @discardableResult
    private func insertTask(
        _ fixture: TaskCoordinatorTests.Fixture,
        _ title: String,
        id: UUID = UUID(),
        parent: UUID? = nil,
        change: (inout TaskRecord) -> Void = { _ in }
    ) throws -> TaskRecord {
        var record = TaskRecord(
            id: id, createdAt: Date(), text: title, title: title, slug: title, source: .cli,
            workspaceID: fixture.workspaceID, projectRoot: fixture.projectRoot, setup: .started, parentTaskID: parent
        )
        change(&record)
        try fixture.coordinator.records.insert(record)
        return record
    }

    private static func merge(_ record: inout TaskRecord) {
        record.pullRequestURL = "https://github.com/example/toastty/pull/\(abs(record.id.hashValue) % 1000 + 200)"
        record.mergedAt = Date()
        record.mergeCommit = String(record.id.uuidString.prefix(12))
    }

    /// The observed case: a task whose agent split the work into child
    /// tasks stayed Idle after they merged, until the user archived it.
    @Test func aCoordinatingTaskFinishesThroughItsChildrenOnceItsLastTurnIsRead() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(path: fixture.projectRoot, releaseTags: "v*")])
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let parent = try await startTask(fixture, text: "Act on the signup feedback")
        let session = try #require(parent.operation.agentLaunch?.sessionID)
        let taskSpace = try #require(parent.taskSpaceWorkspaceID)
        let panel = try #require(parent.operation.taskSpace?.panelID)
        func item(_ id: UUID) throws -> TaskBoardItem { try #require(board.items().first { $0.id == .task(id) }) }
        func rowItem() throws -> TaskBoardItem? {
            let workspace = try #require(fixture.store.state.workspacesByID[taskSpace])
            return board.item(taskSpace: workspace, statuses: fixture.sessionRuntimeStore.workspaceStatuses(for: taskSpace))
        }

        let copy = try insertTask(fixture, "signup-copy", parent: parent.id, change: Self.merge)
        let email = try insertTask(fixture, "signup-email", parent: parent.id)
        // The parent's agent started them and is at its prompt; one child is
        // still open, so the parent is Idle.
        let start = Date().addingTimeInterval(1)
        fixture.sessionRuntimeStore.updateStatus(sessionID: session, status: SessionStatus(kind: .working, summary: "Working"), at: start)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: session, status: SessionStatus(kind: .ready, summary: "Ready"), at: start.addingTimeInterval(0.5)
        )
        _ = fixture.store.send(.markPanelNotificationsRead(workspaceID: taskSpace, panelID: panel))
        let idle = try item(parent.id)
        #expect(idle.stage == .idle, "\(idle.stage), agent \(idle.agent)")
        #expect(idle.finishedThroughChildren == false)

        // The last child merges, and the parent's agent reports on it. The
        // user has not read that turn, so the parent waits in Needs you.
        _ = fixture.coordinator.records.update(id: email.id, Self.merge)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: session, status: SessionStatus(kind: .working, summary: "Working"), at: start.addingTimeInterval(1)
        )
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: session, status: SessionStatus(kind: .ready, summary: "Ready"), at: start.addingTimeInterval(1.5)
        )
        _ = fixture.store.send(.recordDesktopNotification(workspaceID: taskSpace, panelID: panel, sessionID: session))
        let unread = try item(parent.id)
        #expect(unread.stage == .needsYou(.agentFinished), "\(unread.stage)")
        #expect(try rowItem()?.stage == .needsYou(.agentFinished))

        // Once read, the parent waits to ship with its children. Nothing is
        // stored on it, and its task space stays open.
        _ = fixture.store.send(.markPanelNotificationsRead(workspaceID: taskSpace, panelID: panel))
        let shipping = try item(parent.id)
        #expect(shipping.stage == .toShip, "\(shipping.stage)")
        #expect(shipping.finishedThroughChildren)
        #expect(TaskBoardPresentation.statusLine(shipping) == "Child tasks merged · waiting for a release")
        #expect(TaskBoardPresentation.detailActions(shipping).isEmpty)
        let record = try #require(fixture.record(parent.id))
        #expect(record.mergedAt == nil && record.doneAt == nil && record.shippedAt == nil && record.archivedAt == nil)
        #expect(fixture.store.state.workspacesByID[taskSpace] != nil)
        // The task space's own row, the top bar and the close question read
        // the same stage.
        #expect(try rowItem()?.stage == .toShip)
        #expect(try rowItem()?.finishedThroughChildren == true)
        // Release lists the children's merges, not the parent.
        #expect(Set(fixture.coordinator.toShipTasks(projectRoot: fixture.projectRoot).map(\.id)) == [copy.id, email.id])
        // A watch on the parent sees the stage, with the children's merge.
        #expect(fixture.coordinator.stageConditionsByTaskID()[parent.id] == [.readyForReview, .merged, .toShip])

        // The children ship: the parent is Done.
        for child in [copy, email] {
            _ = fixture.coordinator.records.update(id: child.id) {
                $0.shippedAt = Date()
                $0.releaseTag = "v1.0.0"
            }
        }
        let done = try item(parent.id)
        #expect(done.stage == .done)
        #expect(done.finishedThroughChildren)
        #expect(TaskBoardPresentation.stageDescription(done).why == "child tasks finished")
        #expect(fixture.coordinator.stageConditionsByTaskID()[parent.id] == [.readyForReview, .merged, .toShip, .done])
        _ = fixture.store.send(.recordDesktopNotification(workspaceID: taskSpace, panelID: panel))
        #expect(fixture.store.canFocusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: fixture.store.state.windows.first?.id, sessionRuntimeStore: fixture.sessionRuntimeStore
        ) == false)
        _ = fixture.store.send(.markPanelNotificationsRead(workspaceID: taskSpace, panelID: panel))

        // A new child opens the parent's work again, until it finishes too.
        let followUp = try insertTask(fixture, "signup-follow-up", parent: parent.id)
        #expect(try item(parent.id).stage == .idle)
        _ = fixture.coordinator.records.update(id: followUp.id) { $0.archivedAt = Date() }
        #expect(try item(parent.id).stage == .done)

        // Closing the task space does not send a finished parent back to
        // Needs you.
        _ = fixture.store.send(.closeWorkspace(workspaceID: taskSpace))
        #expect(try item(parent.id).stage == .done)
    }

    /// The observed case: the parent's agent marked its first answer ready
    /// for review, then started a child task when the user replied. The old
    /// mark kept the parent open after the child merged.
    @Test func aReadyMarkFromBeforeTheChildrenDoesNotKeepAFinishedParentOpen() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        func stage(_ id: UUID) -> TaskStage? { board.items().first { $0.id == .task(id) }?.stage }
        let marked = Date()
        let parent = try insertTask(fixture, "rebuild-ios-workspace") { $0.readyForReviewAt = marked }
        let fix = try insertTask(fixture, "fix-destination-check", parent: parent.id) {
            $0.createdAt = marked.addingTimeInterval(60)
        }
        #expect(stage(parent.id) == .needsYou(.readyForReview))

        _ = fixture.coordinator.records.update(id: fix.id, Self.merge)
        #expect(stage(parent.id) == .done)
        #expect(board.items().first { $0.id == .task(parent.id) }?.finishedThroughChildren == true)

        // Marked ready again after its child, the parent still owns work.
        _ = fixture.coordinator.records.update(id: parent.id) { $0.readyForReviewAt = marked.addingTimeInterval(120) }
        #expect(stage(parent.id) == .needsYou(.readyForReview))
    }

    @Test func onlyMergedWorkFinishesAParentAndNestedParentsFollow() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        func stage(_ id: UUID) -> TaskStage? { board.items().first { $0.id == .task(id) }?.stage }
        let plan = try insertTask(fixture, "plan-onboarding")
        let parent = try insertTask(fixture, "coordinate-signup", parent: plan.id)
        // Children closed without a merge finish nothing.
        try insertTask(fixture, "investigate-drop-off", parent: parent.id) { $0.doneAt = Date() }
        try insertTask(fixture, "abandoned-redesign", parent: parent.id) { $0.archivedAt = Date() }
        #expect(stage(parent.id) == .idle)
        #expect(stage(plan.id) == .idle)

        // One merged child finishes the parent, without release tags as
        // Done, and the parent finishes the task above it.
        try insertTask(fixture, "fix-signup", parent: parent.id, change: Self.merge)
        #expect(stage(parent.id) == .done)
        #expect(stage(plan.id) == .done)
        #expect(board.items().first { $0.id == .task(plan.id) }?.finishedThroughChildren == true)

        // A parent with a pull request of its own keeps the usual rules.
        _ = fixture.coordinator.records.update(id: parent.id) { $0.pullRequestURL = "https://github.com/example/toastty/pull/301" }
        #expect(stage(parent.id) == .needsYou(.review))
        #expect(stage(plan.id) == .idle)
    }

    @Test func tasksWhoseParentsLoopDoNotFinishThroughEachOther() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = makeBoard(fixture, gitHub: FakeGitHub())
        let first = UUID(), second = UUID(), itself = UUID()
        try insertTask(fixture, "first", id: first, parent: second)
        try insertTask(fixture, "second", id: second, parent: first)
        try insertTask(fixture, "merged-under-first", parent: first, change: Self.merge)
        try insertTask(fixture, "its-own-parent", id: itself, parent: itself)
        try insertTask(fixture, "merged-under-itself", parent: itself, change: Self.merge)
        let items = board.items()
        for id in [first, second, itself] {
            #expect(items.first { $0.id == .task(id) }?.stage == .idle)
        }
    }

    @Test func aParentInToShipCountsInItsLaneButDoesNotOfferARelease() {
        let parentID = UUID()
        var parent = statusItem("act-on-signup-feedback", taskID: parentID, stage: .toShip, project: "emptyos")
        parent.finishedThroughChildren = true
        parent.projectWorkspaceID = UUID()
        var child = statusItem("signup-copy", parent: parentID, stage: .toShip, project: "emptyos")
        child.projectWorkspaceID = UUID()
        // The family leaves Idle; the parent counts as a task to ship, and
        // Release comes from the child's merge.
        let sections = SidebarStatusSections.make([parent, child], releasable: { _ in true })
        #expect(sections.idle.isEmpty && sections.needsYou.isEmpty)
        #expect(sections.toShip.map(\.count) == [2])
        #expect(sections.toShip.first?.releaseWorkspaceID == child.projectWorkspaceID)
        #expect(sections.toShipLabel(isExpanded: false) == "To ship, 2 tasks, collapsed, emptyos 2")
        // With its children in another project, the parent's lane has
        // nothing to release.
        let alone = SidebarStatusSections.make([parent], releasable: { _ in true })
        #expect(alone.toShip.map(\.count) == [1])
        #expect(alone.toShip.first?.releaseWorkspaceID == nil)
        #expect(TasksViewSections.make([parent], releasable: { _ in true }).toShip.first?.releaseWorkspaceID == nil)
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
        // A family lists together in its most urgent group, in the order
        // given: the idle child stays under its running parent, dimmed, and
        // is not counted there.
        #expect(sections.running.map(\.item.title) == [
            "pricing-page", "task-inbox", "hotkey-capture", "composer-blank-line", "ios-outbox",
        ])
        #expect(sections.running.map(\.isLinkedChild) == [false, false, true, true, true])
        #expect(sections.running.map(\.isContext) == [false, false, false, true, false])
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

    /// Status lists tasks in the order of the project cards: by project,
    /// then by task space in window order, whatever the board's activity
    /// order. Tasks with no task space follow their project's, oldest first.
    @Test func statusListsTasksInTheSidebarOrder() {
        let projectA = UUID(), projectB = UUID(), spaceA1 = UUID(), spaceB1 = UUID(), spaceA2 = UUID()
        func item(_ title: String, project: UUID?, space: UUID?, createdAt: TimeInterval) -> TaskBoardItem {
            var item = statusItem(title, stage: .needsYou(.review))
            item.projectWorkspaceID = project
            item.taskSpaceWorkspaceID = space
            item.record?.createdAt = Date(timeIntervalSince1970: createdAt)
            return item
        }
        // Newest activity first, as the board gives them.
        let board = [
            item("a2", project: projectA, space: spaceA2, createdAt: 1),
            item("b1", project: projectB, space: spaceB1, createdAt: 2),
            item("a-unplaced-new", project: projectA, space: nil, createdAt: 9),
            item("no-project", project: nil, space: nil, createdAt: 0),
            item("a-unplaced-old", project: projectA, space: nil, createdAt: 3),
            item("a1", project: projectA, space: spaceA1, createdAt: 4),
        ]
        let ordered = SidebarStatusSections.sidebarOrder(
            board, workspaceIDs: [projectA, projectB, spaceA1, spaceB1, spaceA2]
        )
        let expected = ["a1", "a2", "a-unplaced-old", "a-unplaced-new", "b1", "no-project"]
        #expect(ordered.map(\.title) == expected)
        #expect(SidebarStatusSections.make(ordered).needsYou.map(\.item.title) == expected)
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

        // A family lists at its root's place in the sidebar order.
        let sections = SidebarStatusSections.make([thumbnail, child, space, parent, brainstorm])
        #expect(sections.needsYou.map(\.item.title) == [
            "thumbnail", "task-space-after-ship", "chatgpt-public-url", "mcp-page-tools",
        ])
        #expect(sections.needsYou.map(\.isLinkedChild) == [false, false, false, true])
        #expect(sections.needsYou.map(\.isContext) == [false, false, true, false])
        #expect(sections.count(.needsYou) == 3)
        #expect(sections.idle.map(\.item.title) == ["coordinator-brainstorm"])

        // Once nothing in the family needs the user, it lists in Idle.
        var answered = child
        answered.stage = .idle
        let calm = SidebarStatusSections.make([thumbnail, answered, space, parent, brainstorm])
        #expect(calm.idle.map(\.item.title) == ["chatgpt-public-url", "mcp-page-tools", "coordinator-brainstorm"])
        #expect(calm.idle.map(\.isContext) == [false, false, false])
    }

    /// Reading a child holds its whole family in the group, in place.
    @Test func aSelectedChildHoldsItsFamilyInItsGroup() {
        let parentID = UUID()
        let parent = statusItem("parent", taskID: parentID, stage: .idle)
        let zulu = statusItem("zulu", parent: parentID, stage: .needsYou(.agentFinished))
        let alpha = statusItem("alpha", parent: parentID, stage: .idle)
        let before = SidebarStatusSections.make([zulu, parent, alpha])
        #expect(before.needsYou.map(\.item.title) == ["parent", "zulu", "alpha"])

        let pin = SidebarStatusSections.pin(previous: nil, selected: zulu.id, displayed: before.groups)
        var read = zulu
        read.stage = .idle
        let held = SidebarStatusSections.make([read, parent, alpha], pin: pin)
        #expect(held.needsYou.map(\.item.title) == ["parent", "zulu", "alpha"])
        #expect(held.needsYou.map(\.isContext) == [true, true, true])
        #expect(held.idle.isEmpty)

        read.stage = .running
        let resumed = SidebarStatusSections.make([read, parent, alpha], pin: held.pin)
        #expect(resumed.needsYou.isEmpty)
        #expect(resumed.running.map(\.item.title) == ["parent", "zulu", "alpha"])
        #expect(resumed.running.map(\.isContext) == [true, false, true])
        #expect(resumed.count(.running) == 1)

        var asking = alpha
        asking.stage = .needsYou(.agentNeedsInput)
        let needsInput = SidebarStatusSections.make([read, parent, asking], pin: resumed.pin)
        #expect(needsInput.needsYou.map(\.item.title) == ["parent", "zulu", "alpha"])
        #expect(needsInput.count(.needsYou) == 1)
        #expect(needsInput.running.isEmpty)
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

    /// Selecting a task reads its turn. Its family keeps the group it had on
    /// screen until the selection moves or work resumes, and moves at once
    /// when it becomes more urgent. Inside a group, rows keep the sidebar order.
    @Test func theSelectedTaskHoldsItsGroupUntilTheSelectionMoves() {
        let first = statusItem("first", stage: .needsYou(.agentFinished))
        let clicked = statusItem("clicked", stage: .needsYou(.agentFinished))
        let last = statusItem("last", stage: .needsYou(.review))
        let quiet = statusItem("quiet", stage: .idle)
        let before = SidebarStatusSections.make([first, clicked, last, quiet])
        #expect(before.needsYou.map(\.item.title) == ["first", "clicked", "last"])

        let pin = SidebarStatusSections.pin(previous: nil, selected: clicked.id, displayed: before.groups)
        #expect(pin == SidebarStatusSections.Pin(subject: clicked.id, group: .needsYou))
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
        #expect(SidebarStatusSections.pin(previous: held.pin, selected: clicked.id, displayed: held.groups) == pin)
        let released = SidebarStatusSections.make(
            [first, read, last, quiet],
            pin: SidebarStatusSections.pin(previous: held.pin, selected: first.id, displayed: held.groups)
        )
        #expect(released.needsYou.map(\.item.title) == ["first", "last"])
        #expect(released.idle.map(\.item.title) == ["clicked", "quiet"])

        // A selected idle task that starts to need the user moves at once,
        // and holds in its new place from then on.
        let quietPin = SidebarStatusSections.pin(previous: nil, selected: quiet.id, displayed: before.groups)
        var asks = quiet
        asks.stage = .needsYou(.agentNeedsInput)
        let urgent = SidebarStatusSections.make([first, clicked, last, asks], pin: quietPin)
        #expect(urgent.needsYou.map(\.item.title).contains("quiet"))
        #expect(urgent.idle.isEmpty)
        #expect(urgent.pin?.group == .needsYou)

        // Selecting another task releases the one held before it, which
        // leaves the group at the same time. The rest keep their order.
        let parentID = UUID()
        let parent = statusItem("parent", taskID: parentID, stage: .idle)
        let child = statusItem("child", parent: parentID, stage: .needsYou(.review))
        var answered = first
        answered.stage = .idle
        let previousPin = SidebarStatusSections.Pin(subject: first.id, group: .needsYou)
        let shown = SidebarStatusSections.make([answered, clicked, parent, child], pin: previousPin)
        #expect(shown.needsYou.map(\.item.title) == ["first", "clicked", "parent", "child"])
        let next = SidebarStatusSections.pin(previous: shown.pin, selected: clicked.id, displayed: shown.groups)
        let switched = SidebarStatusSections.make([answered, read, parent, child], pin: next)
        #expect(switched.needsYou.map(\.item.title) == ["clicked", "parent", "child"])
        #expect(switched.idle.map(\.item.title) == ["first"])
    }

    @Test(arguments: [true, false])
    func readingASelectedTaskHoldsItsGroupWhenARelativeRuns(selectedChild: Bool) {
        let parentID = UUID()
        var parent = statusItem("parent", taskID: parentID, stage: selectedChild ? .running : .needsYou(.agentFinished))
        var child = statusItem("child", parent: parentID, stage: selectedChild ? .needsYou(.agentFinished) : .running)
        let selected = selectedChild ? child.id : parent.id
        let before = SidebarStatusSections.make([parent, child])
        let pin = SidebarStatusSections.pin(previous: nil, selected: selected, displayed: before.groups)
        if selectedChild { child.stage = .idle } else { parent.stage = .idle }
        let held = SidebarStatusSections.make([parent, child], pin: pin)
        #expect(held.needsYou.map(\.item.title) == ["parent", "child"])
        #expect(held.needsYou.map(\.isContext) == [true, true])
        #expect(held.count(.needsYou) == 0)
        #expect(held.running.isEmpty)

        if selectedChild { child.stage = .running } else { parent.stage = .running }
        let resumed = SidebarStatusSections.make([parent, child], pin: held.pin)
        #expect(resumed.needsYou.isEmpty)
        #expect(resumed.running.map(\.item.title) == ["parent", "child"])
        #expect(resumed.running.map(\.isContext) == [false, false])
        #expect(resumed.count(.running) == 2)
    }

    @Test(arguments: [TaskStage.starting, .running])
    func aSelectedTaskMovesToRunningWhenWorkResumes(stage: TaskStage) {
        let waiting = statusItem("waiting", stage: .needsYou(.review))
        let selected = statusItem("selected", stage: .needsYou(.agentFinished))
        let before = SidebarStatusSections.make([waiting, selected])
        let pin = SidebarStatusSections.pin(previous: nil, selected: selected.id, displayed: before.groups)

        // Reading the turn keeps the row in place. Resuming work releases it,
        // both directly from Needs you and after the user has read the turn.
        var read = selected
        read.stage = .idle
        let held = SidebarStatusSections.make([waiting, read], pin: pin)
        for previous in [before, held] {
            var resumed = selected
            resumed.stage = stage
            let running = SidebarStatusSections.make([waiting, resumed], pin: previous.pin ?? pin)
            #expect(running.needsYou.map(\.item.title) == ["waiting"])
            #expect(running.running.map(\.item.title) == ["selected"])
            #expect(running.running.map(\.isContext) == [false])
            #expect(running.count(.running) == 1)
            #expect(running.count(.needsYou) == 1)

            // Repeated refreshes cannot restore the old Needs you hold.
            let refreshed = SidebarStatusSections.make([waiting, resumed], pin: running.pin)
            #expect(refreshed == running)
            resumed.stage = .idle
            let quiet = SidebarStatusSections.make([waiting, resumed], pin: refreshed.pin)
            #expect(quiet.running.map(\.isContext) == [true])
            for attention in [TaskStage.Attention.agentNeedsInput, .agentFinished] {
                resumed.stage = .needsYou(attention)
                let asking = SidebarStatusSections.make([waiting, resumed], pin: quiet.pin)
                #expect(asking.needsYou.map(\.item.title) == ["waiting", "selected"])
                #expect(asking.running.isEmpty)
            }
        }
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
