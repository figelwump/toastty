import CoreState
import Foundation
import Testing

struct TaskStageTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let openPR = TaskPullRequestState(state: .open)
    private let draftPR = TaskPullRequestState(state: .open, isDraft: true)
    private let mergedPR = TaskPullRequestState(state: .merged, mergeCommit: "abc123")

    private func started(
        startWork: TaskStartWorkState? = nil,
        readyForReviewAt: Date? = nil,
        mergedAt: Date? = nil
    ) -> TaskStageFacts {
        TaskStageFacts(
            setup: .started,
            startWork: startWork,
            hasTaskSpace: true,
            readyForReviewAt: readyForReviewAt,
            mergedAt: mergedAt
        )
    }

    private func stage(
        _ facts: TaskStageFacts,
        _ live: TaskLiveFacts = TaskLiveFacts(taskSpaceOpen: true, agent: .idle),
        releaseTags: Bool = false
    ) -> TaskStage {
        TaskStage.derive(facts, live: live, releaseTagsConfigured: releaseTags)
    }

    // MARK: - Finished work

    @Test
    func archivedWinsOverEverything() {
        var facts = started(mergedAt: date)
        facts.archivedAt = date
        facts.doneAt = date
        #expect(stage(facts, TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput)) == .archived)
    }

    @Test
    func doneMarkOrShipmentMeansDone() {
        var marked = started()
        marked.doneAt = date
        #expect(stage(marked, TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput)) == .done)

        var shipped = started(mergedAt: date)
        shipped.shippedAt = date
        #expect(stage(shipped, releaseTags: true) == .done)
    }

    @Test
    func aMergeWaitsToShipOnlyWhereReleaseTagsAreSet() {
        let recorded = started(mergedAt: date)
        #expect(stage(recorded) == .done)
        #expect(stage(recorded, releaseTags: true) == .toShip)

        // GitHub's answer counts before the record catches up, and after the
        // task space closed.
        let seen = TaskLiveFacts(taskSpaceOpen: false, pullRequest: mergedPR)
        #expect(stage(started(), seen) == .done)
        #expect(stage(started(), seen, releaseTags: true) == .toShip)
    }

    // MARK: - Before the task space

    @Test
    func setupThatIsStillRunningIsStartingAndListsWithRunning() {
        for setup in [TaskSetupState.routing, .settingUp] {
            let facts = TaskStageFacts(setup: setup, hasTaskSpace: false)
            let result = stage(facts, TaskLiveFacts(taskSpaceOpen: false))
            #expect(result == .starting)
            #expect(result.needsUser == false)
            #expect(result.group == .running)
            #expect(result.isBeforeStart)
        }
        // A move into a worktree keeps the task space's row in Running.
        let moving = stage(started(startWork: .running))
        #expect(moving == .starting)
        #expect(moving.group == .running)
    }

    @Test
    func failuresBeforeTheTaskSpaceListWithNeedsYou() {
        let cases: [(TaskStageFacts, TaskStage.Attention)] = [
            (TaskStageFacts(setup: .needsWorkspace(reason: "no fit"), hasTaskSpace: false), .pickWorkspace(reason: "no fit")),
            (TaskStageFacts(setup: .setupFailed(reason: "hook failed"), hasTaskSpace: false), .setupFailed(reason: "hook failed")),
            (started(startWork: .failed(reason: "fork failed")), .moveFailed(reason: "fork failed")),
        ]
        for (facts, attention) in cases {
            let result = stage(facts, TaskLiveFacts(taskSpaceOpen: true, agent: .working))
            #expect(result == .needsYou(attention))
            #expect(result.needsUser)
            #expect(result.group == .needsYou)
            #expect(result.isBeforeStart)
        }
    }

    // MARK: - Running task spaces

    @Test
    func theAgentAskingForSomethingNeedsTheUser() {
        #expect(stage(started(), TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput)) == .needsYou(.agentNeedsInput))
        #expect(stage(started(), TaskLiveFacts(taskSpaceOpen: true, agent: .error)) == .needsYou(.agentError))
        // Its question comes before the open pull request.
        let asking = TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput, pullRequest: openPR, hasPullRequestLink: true)
        #expect(stage(started(), asking) == .needsYou(.agentNeedsInput))
        #expect(stage(started(), asking).group == .needsYou)
    }

    @Test
    func anOpenPullRequestWaitsForReviewOnlyWhileTheAgentIsIdle() {
        let idle = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: openPR, hasPullRequestLink: true)
        #expect(stage(started(), idle) == .needsYou(.review))

        var noAgent = idle
        noAgent.agent = .none
        #expect(stage(started(), noAgent) == .needsYou(.review))

        var working = idle
        working.agent = .working
        #expect(stage(started(), working) == .running)

        var draft = idle
        draft.pullRequest = draftPR
        #expect(stage(started(), draft) == .idle)

        var closed = idle
        closed.pullRequest = TaskPullRequestState(state: .closed)
        #expect(stage(started(), closed) == .idle)
    }

    @Test
    func withoutAnAnswerFromGitHubALinkedPullRequestCountsAsOpen() {
        let unknown = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: nil, hasPullRequestLink: true)
        #expect(stage(started(), unknown) == .needsYou(.review))
        #expect(stage(started(), TaskLiveFacts(taskSpaceOpen: true, agent: .idle)) == .idle)
    }

    @Test
    func workWithoutAPullRequestWaitsForReviewOnceMarkedReady() {
        let ready = started(readyForReviewAt: date)
        #expect(stage(ready) == .needsYou(.readyForReview))
        #expect(stage(ready, TaskLiveFacts(taskSpaceOpen: true, agent: .working)) == .running)
    }

    @Test
    func aFinishedTurnNeedsTheUserAfterTheReviewReasons() {
        let finished = TaskLiveFacts(taskSpaceOpen: true, agent: .finished)
        #expect(stage(started(), finished) == .needsYou(.agentFinished))
        #expect(stage(started(), finished).group == .needsYou)
        // An agent at its prompt with the turn read is idle, and so is a
        // task space with no agent.
        #expect(stage(started(), TaskLiveFacts(taskSpaceOpen: true, agent: .idle)) == .idle)
        #expect(stage(started(), TaskLiveFacts(taskSpaceOpen: true, agent: .none)) == .idle)
        #expect(TaskStage.idle.group == .idle)
        #expect(TaskStage.idle.needsUser == false)
        // One that waits on another task through a watch is running, read
        // or not.
        var waiting = finished
        waiting.waitsOnTask = true
        #expect(stage(started(), waiting) == .running)
        waiting.agent = .idle
        #expect(stage(started(), waiting) == .running)
        // Review reasons say more, so they come first.
        let review = TaskLiveFacts(taskSpaceOpen: true, agent: .finished, pullRequest: openPR, hasPullRequestLink: true)
        #expect(stage(started(), review) == .needsYou(.review))
        #expect(stage(started(readyForReviewAt: date), finished) == .needsYou(.readyForReview))
        // A merge under way stays running.
        var merging = review
        merging.merge = .checking
        #expect(stage(started(), merging) == .running)
    }

    @Test
    func aQuestionWaitsForTheUsersReplyWhetherTheTurnIsReadOrNot() {
        var asked = started()
        asked.replyRequestedAt = date
        let read = TaskLiveFacts(taskSpaceOpen: true, agent: .idle)
        #expect(stage(asked, read) == .needsYou(.awaitingReply))
        #expect(stage(asked, read).needsUser)
        #expect(stage(asked, TaskLiveFacts(taskSpaceOpen: true, agent: .finished)) == .needsYou(.awaitingReply))
        // After a relaunch the agent may be gone; the question still waits.
        #expect(stage(asked, TaskLiveFacts(taskSpaceOpen: true, agent: .none)) == .needsYou(.awaitingReply))
        // The question outranks a pull request or a ready mark: the reply
        // comes before the review.
        let review = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: openPR, hasPullRequestLink: true)
        #expect(stage(asked, review) == .needsYou(.awaitingReply))
        asked.readyForReviewAt = date
        #expect(stage(asked, read) == .needsYou(.awaitingReply))
        // Live agent states and a merge under way come first.
        #expect(stage(asked, TaskLiveFacts(taskSpaceOpen: true, agent: .working)) == .running)
        #expect(stage(asked, TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput)) == .needsYou(.agentNeedsInput))
        var merging = review
        merging.merge = .checking
        #expect(stage(asked, merging) == .running)
        // Finished work ignores a question left behind.
        asked.doneAt = date
        #expect(stage(asked, read) == .done)
    }

    @Test
    func aClosedTaskSpaceWithUnfinishedWorkNeedsTheUser() {
        let result = stage(started(), TaskLiveFacts(taskSpaceOpen: false))
        #expect(result == .needsYou(.taskSpaceClosed))
        #expect(result.group == .needsYou)
    }

    // MARK: - Tasks that coordinate child tasks

    /// A child's stage, merged unless it is archived or marked done.
    private func child(_ stage: TaskStage, merged: Bool? = nil) -> (stage: TaskStage, merged: Bool) {
        (stage, merged ?? (stage == .toShip || stage == .done))
    }

    private func parent(
        _ children: [(stage: TaskStage, merged: Bool)],
        _ live: TaskLiveFacts = TaskLiveFacts(taskSpaceOpen: true, agent: .idle),
        facts: TaskStageFacts? = nil
    ) -> (stage: TaskStage, finishedThroughChildren: Bool) {
        TaskStage.derivation(facts ?? started(), live: live, releaseTagsConfigured: false) {
            TaskChildrenOutcome(children: children)
        }
    }

    @Test
    func aParentFinishesWhenEveryChildHasFinishedAndOneMerged() {
        #expect(parent([child(.toShip), child(.toShip), child(.toShip)]) == (.toShip, true))
        #expect(parent([child(.done), child(.done)]) == (.done, true))
        // A child waiting for a release keeps the parent in To ship.
        #expect(parent([child(.done), child(.toShip)]) == (.toShip, true))
        // Archived children and children marked done without a merge count
        // as finished, but finish nothing alone.
        #expect(parent([child(.toShip), child(.archived)]) == (.toShip, true))
        #expect(parent([child(.done), child(.archived)]) == (.done, true))
        #expect(parent([child(.done), child(.done, merged: false)]) == (.done, true))
        #expect(parent([child(.archived), child(.archived)]) == (.idle, false))
        #expect(parent([child(.done, merged: false), child(.archived)]) == (.idle, false))
        #expect(parent([]) == (.idle, false))
    }

    @Test
    func aParentWithAnOpenChildStaysWhereItIs() {
        for open in [TaskStage.idle, .running, .starting, .needsYou(.review), .needsYou(.cleanupStopped(reason: "dirty"))] {
            #expect(parent([child(.toShip), child(open, merged: false)]) == (.idle, false), "\(open)")
        }
    }

    @Test
    func aParentThatStillOwnsWorkOrHasNewsForTheUserDoesNotMove() {
        let finished = [child(.toShip), child(.done)]
        // The agent marked the task as waiting for a reply or ready.
        var asked = started()
        asked.replyRequestedAt = date
        #expect(parent(finished, facts: asked) == (.needsYou(.awaitingReply), false))
        #expect(parent(finished, facts: started(readyForReviewAt: date)) == (.needsYou(.readyForReview), false))
        // An unread last turn waits for the user; once read, the task moves.
        #expect(parent(finished, TaskLiveFacts(taskSpaceOpen: true, agent: .finished)) == (.needsYou(.agentFinished), false))
        #expect(parent(finished, TaskLiveFacts(taskSpaceOpen: true, agent: .idle)) == (.toShip, true))
        // Live work and a pending watch on another task come first.
        #expect(parent(finished, TaskLiveFacts(taskSpaceOpen: true, agent: .working)) == (.running, false))
        #expect(parent(finished, TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput)) == (.needsYou(.agentNeedsInput), false))
        #expect(parent(finished, TaskLiveFacts(taskSpaceOpen: true, agent: .idle, waitsOnTask: true)) == (.running, false))
        // Recorded endings keep their own stage.
        var archived = started()
        archived.archivedAt = date
        #expect(parent(finished, facts: archived) == (.archived, false))
        var done = started()
        done.doneAt = date
        #expect(parent([child(.toShip)], facts: done) == (.done, false))
    }

    @Test
    func aReadyMarkFromBeforeTheNewestChildDoesNotHoldAFinishedParentBack() {
        var stale = started(readyForReviewAt: date)
        stale.newestChildCreatedAt = date.addingTimeInterval(60)
        #expect(parent([child(.done)], facts: stale) == (.done, true))
        #expect(parent([child(.toShip)], facts: stale) == (.toShip, true))
        #expect(parent([child(.done)], TaskLiveFacts(taskSpaceOpen: false), facts: stale) == (.done, true))
        // Until the children finish, the parent keeps showing its mark.
        #expect(parent([child(.done), child(.running)], facts: stale) == (.needsYou(.readyForReview), false))
        // Anything else the parent waits for still holds it: an unread
        // last turn, under the mark it shows, or a question.
        #expect(parent([child(.done)], TaskLiveFacts(taskSpaceOpen: true, agent: .finished), facts: stale) == (.needsYou(.readyForReview), false))
        var asked = stale
        asked.replyRequestedAt = date.addingTimeInterval(120)
        #expect(parent([child(.done)], facts: asked) == (.needsYou(.awaitingReply), false))
        // A mark set after the newest child says the parent still owns work.
        var current = started(readyForReviewAt: date.addingTimeInterval(120))
        current.newestChildCreatedAt = date.addingTimeInterval(60)
        #expect(parent([child(.done)], facts: current) == (.needsYou(.readyForReview), false))
    }

    @Test
    func aParentWithItsOwnPullRequestOrWorktreeKeepsTheUsualRules() {
        let finished = [child(.toShip)]
        // Its own pull request decides: open waits for review, a draft or a
        // closed one leaves it idle.
        #expect(parent(finished, TaskLiveFacts(taskSpaceOpen: true, agent: .idle, hasPullRequestLink: true)) == (.needsYou(.review), false))
        let draft = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: draftPR, hasPullRequestLink: true)
        #expect(parent(finished, draft) == (.idle, false))
        let closed = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: TaskPullRequestState(state: .closed), hasPullRequestLink: true)
        #expect(parent(finished, closed) == (.idle, false))
        var inWorktree = started()
        inWorktree.hasWorktree = true
        #expect(parent(finished, facts: inWorktree) == (.idle, false))
    }

    @Test
    func theChildrenAreReadOnlyForATaskThatCouldFinishThroughThem() {
        var asked = 0
        let busy = TaskStage.derivation(started(), live: TaskLiveFacts(taskSpaceOpen: true, agent: .working), releaseTagsConfigured: false) {
            asked += 1
            return .done
        }
        #expect(busy == (.running, false))
        #expect(asked == 0)
    }

    @Test
    func aClosedTaskSpaceDoesNotHoldAFinishedParentBack() {
        let closed = TaskLiveFacts(taskSpaceOpen: false)
        #expect(parent([child(.done)], closed) == (.done, true))
        // Before its children finish, the closed task space needs the user.
        #expect(parent([child(.done), child(.running)], closed) == (.needsYou(.taskSpaceClosed), false))
        // So does a question, a ready mark, or a watch the task still holds.
        var asked = started()
        asked.replyRequestedAt = date
        #expect(parent([child(.done)], closed, facts: asked) == (.needsYou(.taskSpaceClosed), false))
        #expect(parent([child(.done)], closed, facts: started(readyForReviewAt: date)) == (.needsYou(.taskSpaceClosed), false))
        #expect(parent([child(.done)], TaskLiveFacts(taskSpaceOpen: false, waitsOnTask: true)) == (.needsYou(.taskSpaceClosed), false))
    }

    // MARK: - Task spaces without a record

    @Test
    func observedTaskSpacesUseTheirDoneMarkAndPullRequest() {
        #expect(stage(.observed(doneAt: date)) == .done)
        #expect(stage(.observed(doneAt: nil)) == .idle)
        let merged = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: mergedPR, hasPullRequestLink: true)
        #expect(stage(.observed(doneAt: nil), merged, releaseTags: true) == .toShip)
        let review = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: openPR, hasPullRequestLink: true)
        #expect(stage(.observed(doneAt: nil), review) == .needsYou(.review))
    }

    // MARK: - Merge and cleanup

    @Test
    func aStoppedCleanupNeedsTheUserWhateverTheStageWouldBe() {
        var merged = started(mergedAt: date)
        merged.cleanupProblem = "the worktree has uncommitted changes"
        #expect(stage(merged) == .needsYou(.cleanupStopped(reason: "the worktree has uncommitted changes")))

        var archived = started()
        archived.archivedAt = date
        archived.cleanupProblem = "unsaved documents"
        #expect(stage(archived) == .needsYou(.cleanupStopped(reason: "unsaved documents")))
        #expect(stage(archived).group == .needsYou)

        // The merge owner's own stopped request counts before the record does.
        let live = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, cleanupProblem: "PR #7 was closed without merging.")
        #expect(stage(started(mergedAt: date), live) == .needsYou(.cleanupStopped(reason: "PR #7 was closed without merging.")))
    }

    @Test
    func aMergeUnderWayIsRunningUntilTheSkillStops() {
        for activity in [TaskMergeActivity.checking, .merging, .waitingForChecks, .cleaningUp] {
            let live = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: openPR, hasPullRequestLink: true, merge: activity)
            #expect(stage(started(), live) == .running, "\(activity)")
        }
        // A question from the agent still comes first.
        let asking = TaskLiveFacts(taskSpaceOpen: true, agent: .needsInput, pullRequest: openPR, merge: .checking)
        #expect(stage(started(), asking) == .needsYou(.agentNeedsInput))
        // The skill found a blocker and ended its turn: back to review.
        let stopped = TaskLiveFacts(taskSpaceOpen: true, agent: .idle, pullRequest: openPR, hasPullRequestLink: true)
        #expect(stage(started(), stopped) == .needsYou(.review))
    }

    @Test
    func finishedStagesLeaveTheSidebar() {
        // A merged task waiting for a release is not finished yet.
        #expect(TaskStage.toShip.isFinished == false)
        #expect(TaskStage.done.isFinished)
        #expect(TaskStage.archived.isFinished)
        #expect(TaskStage.needsYou(.review).isFinished == false)
        #expect(TaskStage.running.isFinished == false)
        #expect(TaskStage.idle.isFinished == false)
        #expect(TaskStage.Group.allCases.sorted() == [.needsYou, .running, .idle, .toShip, .done, .archived])
    }

    @Test
    func olderRecordsWithoutLifecycleFieldsStillDecode() throws {
        let record = TaskRecord(createdAt: date, text: "fix it", title: "fix it", slug: "fix-it", source: .cli, setup: .started)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for key in [
            "pullRequestURL", "readyForReviewAt", "mergedAt", "mergeCommit", "shippedAt", "releaseTag", "archivedAt", "doneAt",
            "mergeRequestedAt", "mergeCancelledAt", "mergeFailure", "cleanup", "release",
        ] {
            object.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == record)

        var adopted = record
        adopted.source = .adopted
        #expect(try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(adopted)).source == .adopted)
    }
}
