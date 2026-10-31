import CoreState
import Foundation
import Testing

struct WorkspaceMergeRequestTests {
    private let link = WorkspacePullRequestLink(annotationURL: "https://github.com/o/r/pull/59")!

    private func with(_ phase: WorkspaceMergeRequest.Phase) -> WorkspaceMergeRequest {
        WorkspaceMergeRequest(pullRequest: link, repoPath: "/work/task", phase: phase)
    }

    @Test
    func newWorkAClosedWorkspaceOrADifferentPullRequestDropsAWaitingRequest() {
        let other = WorkspacePullRequestLink(annotationURL: "https://github.com/o/r/pull/60")
        // New work clears the done mark, and that also cancels a merge still
        // waiting for checks.
        for phase in [
            WorkspaceMergeRequest.Phase.awaitingMerge,
            .awaitingChecks(acceptedHead: "a1b2c3d4", thenCleanUp: false),
            .failed(reason: "skipped"),
        ] {
            #expect(with(phase).reconciled(workspaceExists: true, isDone: true, pullRequest: link) == with(phase))
            #expect(with(phase).reconciled(workspaceExists: true, isDone: false, pullRequest: link) == nil)
            #expect(with(phase).reconciled(workspaceExists: false, isDone: true, pullRequest: link) == nil)
            #expect(with(phase).reconciled(workspaceExists: true, isDone: true, pullRequest: other) == nil)
            #expect(with(phase).reconciled(workspaceExists: true, isDone: true, pullRequest: nil) == nil)
        }
    }

    @Test
    func aRunningScriptKeepsItsRequestUntilItReportsBack() throws {
        for running in [with(.merging(thenCleanUp: true)), with(.cleaningUp), with(.closing)] {
            #expect(running.reconciled(workspaceExists: false, isDone: false, pullRequest: nil) == running)
        }
        // A relaunch starts an interrupted cleanup over, but not a merge or a close.
        #expect(with(.cleaningUp).persisted == with(.awaitingMerge))
        #expect(with(.merging(thenCleanUp: true)).persisted == nil)
        #expect(with(.closing).persisted == nil)
        #expect(with(.failed(reason: "x")).persisted == with(.failed(reason: "x")))
        let waiting = with(.awaitingChecks(acceptedHead: "a1b2c3d4", thenCleanUp: true))
        #expect(waiting.persisted == waiting)
        // Restarting an adopted task's interrupted cleanup must not permit
        // deletion of a checkout discovered only by its branch name.
        var restricted = with(.cleaningUp)
        restricted.requiresAbsentWorktree = true
        let saved = try JSONEncoder().encode(#require(restricted.persisted))
        let restored = try JSONDecoder().decode(WorkspaceMergeRequest.self, from: saved)
        #expect(restored.phase == .awaitingMerge)
        #expect(restored.requiresAbsentWorktree == true)
    }

    @Test
    func pullRequestLinkReadsGitHubPullRequestURLs() {
        let files = WorkspacePullRequestLink(annotationURL: "https://github.com/o/r/pull/63/files")
        #expect(files?.number == 63)
        #expect(files?.url == "https://github.com/o/r/pull/63")
        #expect(files?.displayName == "o/r#63")
        #expect(WorkspacePullRequestLink(annotationURL: "https://github.com/o/r/pull/63/")?.url == "https://github.com/o/r/pull/63")
        #expect(WorkspacePullRequestLink(annotationURL: "https://github.com/o/r/issues/63") == nil)
        #expect(WorkspacePullRequestLink(annotationURL: "https://example.com/o/r/pull/63") == nil)
        #expect(WorkspacePullRequestLink(annotationURL: "https://github.com/o/r/pull/x") == nil)
        #expect(WorkspacePullRequestLink(annotationURL: nil) == nil)
    }
}
