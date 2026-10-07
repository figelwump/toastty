import CoreState
import Foundation
import Testing

struct WorkspaceCleanupRequestTests {
    private let request = WorkspaceCleanupRequest(pullRequestNumber: 59, repoPath: "/work/task")

    private func with(_ phase: WorkspaceCleanupRequest.Phase) -> WorkspaceCleanupRequest {
        WorkspaceCleanupRequest(pullRequestNumber: 59, repoPath: "/work/task", phase: phase)
    }

    @Test
    func doneMarkMovesTheRequestToWaitForTheMerge() {
        #expect(request.reconciled(workspaceExists: true, isDone: false, pullRequestNumber: 59) == request)
        #expect(request.reconciled(workspaceExists: true, isDone: true, pullRequestNumber: 59) == with(.awaitingMerge))
    }

    @Test
    func newWorkAClosedWorkspaceOrADifferentPullRequestDropsTheRequest() {
        for phase in [WorkspaceCleanupRequest.Phase.awaitingMerge, .failed(reason: "skipped")] {
            #expect(with(phase).reconciled(workspaceExists: true, isDone: false, pullRequestNumber: 59) == nil)
            #expect(with(phase).reconciled(workspaceExists: true, isDone: true, pullRequestNumber: 59) == with(phase))
        }
        #expect(request.reconciled(workspaceExists: false, isDone: false, pullRequestNumber: nil) == nil)
        #expect(request.reconciled(workspaceExists: true, isDone: false, pullRequestNumber: 60) == nil)
        #expect(request.reconciled(workspaceExists: true, isDone: false, pullRequestNumber: nil) == nil)
    }

    @Test
    func runningCleanupKeepsItsRequestWhenItClosesTheWorkspace() {
        for running in [with(.cleaningUp), with(.closing)] {
            #expect(running.reconciled(workspaceExists: false, isDone: false, pullRequestNumber: nil) == running)
        }
        // A relaunch starts an interrupted cleanup over, but not a close.
        #expect(with(.cleaningUp).persisted == with(.awaitingMerge))
        #expect(with(.closing).persisted == nil)
        #expect(with(.failed(reason: "x")).persisted == with(.failed(reason: "x")))
    }

    @Test
    func pullRequestNumberComesFromTheURLOrTheText() {
        #expect(WorkspaceCleanupRequest.pullRequestNumber(text: "PR", url: "https://github.com/o/r/pull/63") == 63)
        #expect(WorkspaceCleanupRequest.pullRequestNumber(text: "PR", url: "https://github.com/o/r/pull/63/") == 63)
        #expect(WorkspaceCleanupRequest.pullRequestNumber(text: "PR #63", url: "https://github.com/o/r/pull/63/files") == 63)
        #expect(WorkspaceCleanupRequest.pullRequestNumber(text: "PR #12", url: nil) == 12)
        #expect(WorkspaceCleanupRequest.pullRequestNumber(text: "draft", url: nil) == nil)
        #expect(WorkspaceCleanupRequest.pullRequestNumber(text: "#", url: nil) == nil)
    }
}
