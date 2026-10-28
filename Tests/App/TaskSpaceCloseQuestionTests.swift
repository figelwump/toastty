import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The question Toastty asks when the person closes a simple task's task
/// space, through the real Close Pane path, store, reducer, task coordinator
/// and board, with the start-work fixture's fake agents.
///
/// Failure modes: a task with a worktree or a pull request asking, a done or
/// archived task asking again, Cancel closing anything, a choice that does
/// not reach the task's stage, and a close that Toastty or an automation
/// starts asking.
@MainActor
struct TaskSpaceCloseQuestionTests {
    typealias Fixture = TaskStartWorkTests.Fixture

    /// `gh` that never answers, so stages come from links and the record.
    private struct OfflineGitHub: WorkspaceMergeCommandRunning {
        func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
            WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "offline", failure: nil)
        }
    }

    @MainActor
    final class Harness {
        let fixture: Fixture
        let sessionRuntimeStore = SessionRuntimeStore()
        let board: TaskBoardStore
        /// The answer the fake dialog gives; `nil` is Cancel.
        var answer: TaskSpaceCloseChoice?
        /// What the closing terminal runs; `nil` is an idle shell.
        var runningCommand: String? = "claude"
        private(set) var questions: [TaskSpaceCloseQuestion] = []
        /// Runs while the fake dialog is up.
        var onPresent: () -> Void = {}
        private(set) var controller: FocusedPanelCommandController!

        init() throws {
            fixture = try Fixture()
            board = TaskBoardStore(
                coordinator: fixture.coordinator,
                store: fixture.store,
                sessionRuntimeStore: sessionRuntimeStore,
                pullRequests: PullRequestStateCache(runner: OfflineGitHub()),
                refreshInterval: nil,
                releaseCheckInterval: nil
            )
            fixture.coordinator.board = board
            sessionRuntimeStore.taskCoordinator = fixture.coordinator
            let asker = TaskSpaceCloseAsker(
                question: { [unowned self] in sessionRuntimeStore.taskSpaceCloseQuestion(workspaceID: $0) },
                present: { [unowned self] question in
                    questions.append(question)
                    onPresent()
                    return answer
                },
                apply: { [unowned self] choice, question in
                    TaskActions.applyTaskSpaceCloseChoice(choice, question: question, coordinator: fixture.coordinator)
                }
            )
            controller = FocusedPanelCommandController(
                store: fixture.store,
                runtimeRegistry: TerminalRuntimeRegistry(),
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
                shouldConfirmClose: true,
                terminalCloseAssessmentProvider: { [unowned self] _ in
                    TerminalCloseConfirmationAssessment(requiresConfirmation: runningCommand != nil, runningCommand: runningCommand)
                },
                runningTerminalCloseConfirmationPresenter: { _ in
                    Issue.record("The task question replaces the terminal confirmation")
                    return false
                },
                taskSpaceCloseAsker: asker
            )
        }

        func stage(_ taskID: UUID) -> TaskStage? {
            board.items().first { $0.taskID == taskID }?.stage
        }

        func closeTaskSpace(_ task: TaskRecord, policy: FocusedPanelCommandController.CloseConfirmationPolicy = .interactive)
            -> FocusedPanelCommandController.CloseResult {
            controller.closeFocusedPanel(in: task.taskSpaceWorkspaceID, confirmationPolicy: policy)
        }

        func isOpen(_ task: TaskRecord) -> Bool {
            task.taskSpaceWorkspaceID.map { fixture.store.state.workspacesByID[$0] != nil } ?? false
        }
    }

    @Test func cancelClosesNothingAndMarkDoneClosesAndFinishesTheTask() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()
        #expect(harness.stage(task.id) == .idle)

        harness.answer = nil
        #expect(harness.closeTaskSpace(task) == .canceled)
        #expect(harness.isOpen(task))
        #expect(harness.questions.count == 1)
        // The running agent's warning moves into the question.
        #expect(harness.questions.first?.taskID == task.id)
        #expect(harness.questions.first?.informativeText.contains("Detected command: claude") == true)

        harness.answer = .markDone
        #expect(harness.closeTaskSpace(task) == .closed)
        #expect(harness.isOpen(task) == false)
        #expect(harness.stage(task.id) == .done)
        #expect(harness.fixture.record(task.id)?.doneAt != nil)
        #expect(harness.questions.count == 2)
    }

    @Test func archiveClosesAndArchivesTheTask() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()
        harness.answer = .archive

        #expect(harness.closeTaskSpace(task) == .closed)
        #expect(harness.isOpen(task) == false)
        await harness.fixture.waitUntil("the archive finishes") {
            harness.fixture.record(task.id)?.cleanup?.finishedAt != nil
        }
        #expect(harness.stage(task.id) == .archived)
        #expect(harness.fixture.record(task.id)?.cleanup?.problem == nil)
    }

    @Test func keepClosesAndLeavesTheTaskInNeedsYou() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()
        harness.answer = .keep

        #expect(harness.closeTaskSpace(task) == .closed)
        #expect(harness.isOpen(task) == false)
        #expect(harness.stage(task.id) == .needsYou(.taskSpaceClosed))
    }

    @Test func aCloseThatAnAutomationStartsDoesNotAsk() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()

        #expect(harness.closeTaskSpace(task, policy: .nonInteractive(terminateRunningProcess: true)) == .closed)
        #expect(harness.questions.isEmpty)
        #expect(harness.stage(task.id) == .needsYou(.taskSpaceClosed))
    }

    @Test func onlyAnUnfinishedTaskWithoutAWorktreeOrPullRequestAsks() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let store = harness.fixture.store
        let records = harness.fixture.coordinator.records
        func asks() -> Bool { harness.sessionRuntimeStore.taskSpaceCloseQuestion(workspaceID: taskSpace) != nil }
        #expect(asks())

        // A worktree, even one still being made.
        _ = records.update(id: task.id) {
            $0.operation.worktree = TaskOperation.Worktree(path: "/tmp/wt", branch: "b", checkoutRoot: "/tmp/repo", added: false)
        }
        #expect(asks() == false)
        _ = records.update(id: task.id) { $0.operation.worktree = nil }
        #expect(asks())

        // A pull request linked on the task space, which the board copies
        // onto the record, or on the record alone.
        _ = store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #9", url: "https://github.com/o/r/pull/9")
        ))
        #expect(asks() == false)
        _ = store.send(.clearWorkspaceAnnotation(workspaceID: taskSpace, key: "github-pr"))
        #expect(asks() == false)
        _ = records.update(id: task.id) { $0.pullRequestURL = nil }
        #expect(asks())
        _ = records.update(id: task.id) { $0.pullRequestURL = "https://github.com/o/r/pull/9" }
        #expect(asks() == false)
        _ = records.update(id: task.id) { $0.pullRequestURL = nil }
        #expect(asks())

        // A launch that failed after it made the task space.
        _ = records.update(id: task.id) { $0.setup = .setupFailed(reason: "launch failed") }
        #expect(asks())
        // In-progress setup now lists under Running, but closing it must
        // still use the terminal confirmation instead of finishing it.
        _ = records.update(id: task.id) { $0.setup = .settingUp }
        #expect(asks() == false)
        _ = records.update(id: task.id) { $0.setup = .started }

        // A finished task: done on the task space, or archived.
        _ = try harness.fixture.coordinator.markDone(taskID: task.id)
        #expect(asks() == false)
        _ = store.send(.setWorkspaceDone(workspaceID: taskSpace, doneAt: nil))
        _ = records.update(id: task.id) { $0.doneAt = nil }
        #expect(asks())
        _ = records.update(id: task.id) { $0.archivedAt = Date() }
        #expect(asks() == false)

        // A plain workspace is not a task space.
        #expect(harness.sessionRuntimeStore.taskSpaceCloseQuestion(workspaceID: harness.fixture.workspaceID) == nil)
    }

    @Test func aTabThatOpensWhileTheQuestionIsUpKeepsTheTaskAsItIs() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        harness.answer = .markDone
        harness.onPresent = {
            #expect(harness.fixture.store.send(.createWorkspaceTab(workspaceID: taskSpace, seed: nil)))
        }

        // The answered pane still closes, but the task space stays open.
        #expect(harness.closeTaskSpace(task) == .closed)
        #expect(harness.isOpen(task))
        #expect(harness.fixture.record(task.id)?.doneAt == nil)
        #expect(harness.stage(task.id) == .idle)
    }

    @Test func closingOneOfSeveralTabsDoesNotAsk() async throws {
        let harness = try Harness()
        let task = try await harness.fixture.startedTask()
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        #expect(harness.fixture.store.send(.createWorkspaceTab(workspaceID: taskSpace, seed: nil)))

        harness.runningCommand = nil
        #expect(harness.closeTaskSpace(task) == .closed)
        #expect(harness.isOpen(task))
        #expect(harness.questions.isEmpty)

        // The last tab's pane asks, without a warning for an idle shell.
        harness.answer = .keep
        #expect(harness.closeTaskSpace(task) == .closed)
        #expect(harness.questions.map(\.warning) == [nil])
        #expect(harness.isOpen(task) == false)
    }
}
