import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// How the board reads a merge that is under way, and what the Tasks view
/// offers for it. These have many cases that the end-to-end tests cannot
/// reach cheaply.
@MainActor
struct TaskLifecyclePresentationTests {
    private let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let link = WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/7")!

    private func record(mergeRequested: Bool = true) -> TaskRecord {
        var record = TaskRecord(createdAt: requestedAt.addingTimeInterval(-600), text: "fix", title: "fix", slug: "fix", source: .cli, setup: .started)
        record.mergeRequestedAt = mergeRequested ? requestedAt : nil
        record.pullRequestURL = link.url
        return record
    }

    private func status(_ kind: SessionStatusKind, at date: Date) -> WorkspaceSessionStatus {
        WorkspaceSessionStatus(
            sessionID: "s",
            panelID: UUID(),
            workspaceID: UUID(),
            agent: .claude,
            status: SessionStatus(kind: kind, summary: kind.rawValue),
            cwd: nil,
            updatedAt: date,
            statusUpdatedAt: date,
            isActive: true
        )
    }

    private func activity(
        _ record: TaskRecord,
        phase: WorkspaceMergeRequest.Phase? = nil,
        agent: TaskAgentActivity = .idle,
        statuses: [WorkspaceSessionStatus] = [],
        pullRequest: TaskPullRequestState? = nil
    ) -> TaskMergeActivity? {
        TaskBoard.mergeActivity(
            record: record,
            request: phase.map { WorkspaceMergeRequest(pullRequest: link, repoPath: "/tmp", phase: $0) },
            pullRequestState: pullRequest,
            agent: agent,
            statuses: statuses
        )
    }

    @Test
    func theMergeOwnersRequestSaysWhatToasttyIsDoing() {
        let task = record()
        #expect(activity(task, phase: .merging(thenCleanUp: true)) == .merging)
        #expect(activity(task, phase: .awaitingChecks(acceptedHead: "abc", thenCleanUp: true)) == .waitingForChecks)
        #expect(activity(task, phase: .awaitingMerge) == .cleaningUp)
        #expect(activity(task, phase: .cleaningUp) == .cleaningUp)
        // A stopped cleanup is not activity; the stage reads its reason.
        #expect(activity(task, phase: .failed(reason: "dirty")) == nil)
    }

    @Test
    func theAgentChecksUntilItEndsATurnAfterTheRequest() {
        let task = record()
        // The prompt is queued: the agent's last status is older.
        #expect(activity(task, statuses: [status(.ready, at: requestedAt.addingTimeInterval(-5))]) == .checking)
        #expect(activity(task, agent: .working, statuses: [status(.working, at: requestedAt.addingTimeInterval(5))]) == .checking)
        // The skill reported back and stopped: the user decides again.
        #expect(activity(task, statuses: [status(.ready, at: requestedAt.addingTimeInterval(30))]) == nil)
        #expect(activity(task, agent: .needsInput, statuses: [status(.needsApproval, at: requestedAt.addingTimeInterval(5))]) == nil)
        #expect(activity(task, agent: .none) == nil)
        // Nothing to check once there is no acceptance, or GitHub merged it.
        #expect(activity(record(mergeRequested: false), agent: .working) == nil)
        #expect(activity(task, agent: .working, pullRequest: TaskPullRequestState(state: .merged)) == nil)
    }

    @Test
    func theDetailPaneOffersWhatFitsTheStage() {
        func item(_ stage: TaskStage, merge: TaskMergeActivity? = nil, pullRequest: Bool = true, record: TaskRecord? = nil) -> TaskBoardItem {
            TaskBoardItem(
                id: .task(UUID()),
                record: record ?? self.record(mergeRequested: false),
                title: "fix",
                taskSpaceWorkspaceID: UUID(),
                stage: stage,
                agent: .idle,
                pullRequest: pullRequest ? link : nil,
                merge: merge,
                activityAt: requestedAt
            )
        }
        typealias Action = TaskBoardPresentation.DetailAction
        #expect(TaskBoardPresentation.detailActions(item(.needsYou(.review))) == [.merge, .mergeWithoutChecks, .archive])
        #expect(TaskBoardPresentation.detailActions(item(.running)) == [.merge, .mergeWithoutChecks, .archive])
        #expect(TaskBoardPresentation.detailActions(item(.running, merge: .checking)) == [.cancelMerge])
        #expect(TaskBoardPresentation.detailActions(item(.running, merge: .waitingForChecks)) == [.cancelMerge])
        #expect(TaskBoardPresentation.detailActions(item(.running, merge: .merging)) == [Action]())
        #expect(TaskBoardPresentation.detailActions(item(.needsYou(.readyForReview), pullRequest: false)) == [.markDone, .archive])
        #expect(TaskBoardPresentation.detailActions(item(.needsYou(.cleanupStopped(reason: "dirty")))) == [.cleanUp, .keepAsIs])
        #expect(TaskBoardPresentation.detailActions(item(.needsYou(.taskSpaceClosed))) == [.archive])
        for finished in [TaskStage.toShip, .done, .archived] {
            #expect(TaskBoardPresentation.detailActions(item(finished)).isEmpty)
        }
        // A release ships through its tags, not a done mark.
        var release = record(mergeRequested: false)
        release.release = TaskRelease(childTaskIDs: [])
        #expect(TaskBoardPresentation.detailActions(item(.running, pullRequest: false, record: release)) == [.archive])
    }

    @Test
    func projectsWithTheSameTitleKeepSeparateReleaseLanes() {
        func shipped(root: String, workspaceID: UUID) -> TaskBoardItem {
            var task = record(mergeRequested: false)
            task.projectRoot = root
            return TaskBoardItem(
                id: .task(UUID()), record: task, title: "fix", projectWorkspaceID: workspaceID,
                projectTitle: "app", stage: .toShip, agent: .none, activityAt: requestedAt
            )
        }
        let first = UUID(), second = UUID()
        let items = [shipped(root: "/a/app", workspaceID: first), shipped(root: "/b/app", workspaceID: second)]
        let sidebar = SidebarStatusSections.make(items, releasable: { _ in true })
        #expect(sidebar.toShip.count == 2)
        #expect(Set(sidebar.toShip.compactMap(\.releaseWorkspaceID)) == [first, second])
        let view = TasksViewSections.make(items, releasable: { _ in true })
        #expect(view.toShip.count == 2)
        #expect(Set(view.toShip.compactMap(\.releaseWorkspaceID)) == [first, second])
    }

    @Test
    func statusLinesNameTheMergeAndTheStoppedCleanup() {
        var item = TaskBoardItem(
            id: .task(UUID()),
            record: record(),
            title: "fix",
            stage: .running,
            agent: .working,
            merge: .waitingForChecks,
            activityAt: requestedAt
        )
        #expect(TaskBoardPresentation.statusLine(item) == "Waiting for checks")
        item.merge = .checking
        #expect(TaskBoardPresentation.statusLine(item) == "Merging…")
        item.merge = nil
        item.stage = .needsYou(.cleanupStopped(reason: "dirty"))
        #expect(TaskBoardPresentation.statusLine(item) == "Merged · clean up?")
        item.record?.cleanup = TaskCleanup(kind: .archive, problem: "dirty")
        #expect(TaskBoardPresentation.statusLine(item) == "⚠ archive stopped")
        #expect(TaskBoardPresentation.stageDescription(item) == ("Needs you", "dirty"))
    }

    @Test
    func theArchiveAlertSaysWhatGoesAndWhatStays() {
        let task = TaskRecord(
            createdAt: requestedAt,
            text: "fix",
            title: "fix",
            slug: "fix",
            source: .cli,
            setup: .started,
            operation: TaskOperation(taskSpace: TaskOperation.TaskSpace(workspaceID: UUID(), panelID: UUID()))
        )
        var check = TaskArchiveCheck(
            hasWorktree: true,
            detached: false,
            branch: "fix/fix",
            uncommittedFiles: 0,
            unpushedCommits: 0,
            pullRequest: link,
            agentSessions: 1,
            unsavedDocuments: 0
        )
        #expect(TaskActions.archiveSummary(record: task, check: check) == [
            "Closes the task space and ends its 1 agent session.",
            "Removes the worktree.",
            "Deletes the local branch fix/fix. It stays on the remote.",
        ])
        check.uncommittedFiles = 2
        check.unpushedCommits = 3
        check.agentSessions = 0
        #expect(TaskActions.archiveSummary(record: task, check: check) == [
            "Closes the task space.",
            "Removes the worktree and its 2 uncommitted files.",
            "Keeps the branch fix/fix: 3 of its commits are on no remote branch.",
        ])
        #expect(TaskCoordinator.archiveRefusal(check, options: TaskArchiveOptions())?.contains("2 uncommitted files") == true)
        #expect(TaskCoordinator.archiveRefusal(check, options: TaskArchiveOptions(discardChanges: true)) == nil)
        // Unpushed commits on the branch only keep the branch; commits that
        // only the worktree's HEAD holds stop the archive.
        check.uncommittedFiles = 0
        #expect(TaskCoordinator.archiveRefusal(check, options: TaskArchiveOptions()) == nil)
        check.orphanedCommits = 2
        #expect(TaskCoordinator.archiveRefusal(check, options: TaskArchiveOptions())?.contains("2 commits on no branch") == true)
        #expect(TaskCoordinator.archiveRefusal(check, options: TaskArchiveOptions(deleteUnpushedCommits: true)) == nil)
        #expect(TaskActions.archiveSummary(record: task, check: check).contains("2 commits at the worktree's HEAD are on no branch, remote branch or tag."))
    }

    @Test
    func remoteTagsMapToTheCommitsTheyName() {
        let output = """
        1111111111111111111111111111111111111111\trefs/tags/v1.0
        2222222222222222222222222222222222222222\trefs/tags/v1.1
        3333333333333333333333333333333333333333\trefs/tags/v1.1^{}
        4444444444444444444444444444444444444444\trefs/heads/main
        """
        #expect(TaskCoordinator.remoteTagCommits(output) == [
            "v1.0": "1111111111111111111111111111111111111111",
            "v1.1": "3333333333333333333333333333333333333333",
        ])
    }
}
