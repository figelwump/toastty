import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// These rules decide queue order and whether a saved brief can still support
/// a user decision. Exercise facts rather than labels or view implementation.
struct CoordinatorReviewPresentationTests {
    private let firstHead = String(repeating: "a", count: 40)
    private let secondHead = String(repeating: "b", count: 40)
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let url = "https://github.com/example/toastty/pull/42"

    private func review(
        taskID: UUID = UUID(), priority: CoordinatorReviewBrief.Priority = .ready,
        createdAt: Date? = nil, head: String? = nil, base: String? = "landing"
    ) -> CoordinatorReviewItem {
        CoordinatorReviewItem(
            taskID: taskID, taskTitle: "Fix terminal focus", projectRoot: "/tmp/project",
            repository: "example/toastty", pullRequestURL: url, headSHA: head ?? firstHead,
            baseRefName: base,
            brief: CoordinatorReviewBrief(
                behaviorChange: "Keep the editor focused.", decisionNeeded: "Approve the focus change.",
                recommendation: "Approve after the keyboard check.", priority: priority
            ),
            createdAt: createdAt ?? date
        )
    }

    private func task(for review: CoordinatorReviewItem, head: String? = nil, draft: Bool = false) -> TaskBoardItem {
        TaskBoardItem(
            id: .task(review.taskID), title: review.taskTitle,
            stage: .needsYou(.review), agent: .idle,
            pullRequest: WorkspacePullRequestLink(annotationURL: review.pullRequestURL),
            pullRequestState: TaskPullRequestState(state: .open, isDraft: draft, headSHA: head ?? review.headSHA, baseRefName: review.baseRefName),
            activityAt: date
        )
    }

    private func entry(
        _ review: CoordinatorReviewItem? = nil, urgent: Bool = false, blocking: Bool = false
    ) -> CoordinatorReviewQueueEntry {
        CoordinatorReviewQueueEntry(
            facts: CoordinatorReviewTaskFacts(
                taskID: review?.taskID ?? UUID(), taskTitle: review?.taskTitle ?? "Ready without brief",
                projectRoot: "/tmp/project", pullRequestURL: url, headSHA: review?.headSHA ?? firstHead,
                baseRefName: review?.baseRefName ?? "landing",
                needsReview: true, isUrgent: urgent, blocksOtherWork: blocking
            ),
            review: review
        )
    }

    @Test
    func urgentThenBlockingThenReadyWithOldestFirstAndUserOverride() {
        let ready = entry(review())
        let urgent = entry(review(createdAt: date.addingTimeInterval(20)), urgent: true)
        let blocking = entry(review(), blocking: true)
        let olderReady = entry(review(createdAt: date.addingTimeInterval(-20)))
        var overridden = review(priority: .urgent)
        overridden.priorityOverride = .ready
        let userReady = entry(overridden, urgent: true)
        let ordered = CoordinatorReviewPresentation.queue(native: [ready, blocking, olderReady, userReady, urgent], saved: [])
        #expect(ordered.prefix(2).map(\.id) == [urgent.id, blocking.id])
        #expect(ordered[2].id == olderReady.id)
        #expect(ordered.suffix(2).contains(where: { $0.id == userReady.id }))
    }

    @Test
    func missingBriefAndSavedResultsRemainReachableWithoutDuplicateTaskRows() {
        let missing = entry()
        var merged = review(priority: .urgent)
        merged.observedOutcome = .init(state: .merged, headSHA: firstHead, observedAt: date)
        let current = review()
        let ordered = CoordinatorReviewPresentation.queue(native: [missing, entry(current)], saved: [current, merged])
        #expect(ordered.count == 3)
        #expect(ordered.contains(where: { $0.id == missing.id && $0.needsBrief }))
        #expect(ordered.last?.review?.id == merged.id)
        #expect(ordered.filter { $0.id == current.taskID }.count == 1)
    }

    @Test
    func laterObservationsOfAnOldHeadDoNotReplaceTheNewBrief() {
        let taskID = UUID()
        var old = review(taskID: taskID)
        old.updatedAt = date.addingTimeInterval(200)
        let current = review(taskID: taskID, createdAt: date.addingTimeInterval(10), head: secondHead)
        let queue = CoordinatorReviewPresentation.queue(native: [], saved: [old, current])
        #expect(queue.count == 1)
        #expect(queue.first?.review?.id == current.id)
    }

    @Test
    func changedHeadBlocksDecisionsAndStillOffersThePreviousBrief() {
        let review = review()
        let changedTask = task(for: review, head: secondHead)
        let facts = CoordinatorReviewTaskFacts(
            taskID: review.taskID, taskTitle: review.taskTitle, projectRoot: review.projectRoot,
            pullRequestURL: url, headSHA: secondHead, needsReview: true
        )
        let queueEntry = CoordinatorReviewQueueEntry(facts: facts)
        #expect(CoordinatorReviewPresentation.displayedReview(queueEntry, saved: [review])?.id == review.id)
        #expect(CoordinatorReviewPresentation.state(review, task: changedTask) == .headChanged)
        #expect(CoordinatorReviewPresentation.canApprove(review, task: changedTask) == false)
        #expect(CoordinatorReviewPresentation.canRequestChanges(review, task: changedTask) == false)
    }

    @Test
    func intentDeliveryAndAgentReportsCannotConfirmAMerge() {
        var review = review()
        let task = task(for: review)
        review.userAction = CoordinatorReviewAction(kind: .merge, approvedHeadSHA: firstHead)
        #expect(CoordinatorReviewPresentation.state(review, task: task) == .approvalRecorded)
        review.userAction?.deliveryState = .dispatching
        #expect(CoordinatorReviewPresentation.state(review, task: task) == .sending)
        review.userAction?.deliveryState = .delivered
        #expect(CoordinatorReviewPresentation.state(review, task: task) == .delivered)
        review.userAction?.agentOutcome = .init(state: .merged)
        #expect(CoordinatorReviewPresentation.state(review, task: task) == .agentReportedMerge)
        #expect(CoordinatorReviewPresentation.canApprove(review, task: task) == false)
        review.observedOutcome = .init(state: .merged, headSHA: firstHead, observedAt: date)
        #expect(CoordinatorReviewPresentation.state(review, task: task) == .merged)
    }

    @Test
    func unsafeRepeatedDecisionsStayDisabledForUncertainOrFailedDelivery() {
        for delivery in [CoordinatorReviewAction.DeliveryState.uncertain, .failed] {
            var review = review()
            let task = task(for: review)
            review.userAction = CoordinatorReviewAction(kind: .merge, approvedHeadSHA: firstHead, deliveryState: delivery)
            #expect(CoordinatorReviewPresentation.canApprove(review, task: task) == false)
            #expect(CoordinatorReviewPresentation.canRequestChanges(review, task: task) == false)
            #expect(CoordinatorReviewPresentation.state(review, task: task) == (delivery == .uncertain ? .deliveryUncertain : .deliveryFailed))
        }
    }

    @Test
    func draftAndMissingTaskCannotBeApproved() {
        let review = review()
        #expect(CoordinatorReviewPresentation.canApprove(review, task: task(for: review)))
        #expect(CoordinatorReviewPresentation.canApprove(review, task: task(for: review, draft: true)) == false)
        #expect(CoordinatorReviewPresentation.canRequestChanges(review, task: task(for: review, draft: true)))
        #expect(CoordinatorReviewPresentation.canApprove(review, task: nil) == false)
    }

    @Test
    func decisionTargetRequiresTheCurrentBriefTheUserSelected() {
        let reviewed = review()
        let urgent = review(priority: .urgent)
        let queue = CoordinatorReviewPresentation.queue(native: [entry(reviewed), entry(urgent)], saved: [])
        #expect(queue.first?.review?.id == urgent.id)
        #expect(CoordinatorReviewPresentation.canDecide(urgent, currentReviewID: urgent.id, reviewed: reviewed) == false)
        #expect(CoordinatorReviewPresentation.canDecide(reviewed, currentReviewID: nil, reviewed: reviewed) == false)

        var observationUpdated = reviewed
        observationUpdated.revision += 1
        observationUpdated.observedOutcome = .init(state: .open, headSHA: firstHead, baseRefName: "landing", observedAt: date)
        #expect(CoordinatorReviewPresentation.canDecide(observationUpdated, currentReviewID: reviewed.id, reviewed: reviewed) == false)
        #expect(reviewed.revision == 1)
        #expect(CoordinatorReviewPresentation.canDecide(observationUpdated, currentReviewID: reviewed.id, reviewed: observationUpdated))
        var briefUpdated = observationUpdated
        briefUpdated.brief.behaviorChange = "A different behavior needs review."
        #expect(CoordinatorReviewPresentation.canDecide(briefUpdated, currentReviewID: reviewed.id, reviewed: reviewed) == false)
        #expect(CoordinatorReviewPresentation.canDecide(briefUpdated, currentReviewID: reviewed.id, reviewed: briefUpdated))
    }

    @Test
    func destinationMustBeRecordedAndMatchCurrentPullRequestBeforeDecisionOrRetry() {
        let historical = review(base: nil)
        #expect(CoordinatorReviewPresentation.state(historical, task: task(for: historical)) == .baseUnknown)
        #expect(CoordinatorReviewPresentation.canApprove(historical, task: task(for: historical)) == false)
        let current = review()
        var unknownDestination = task(for: current)
        unknownDestination.pullRequestState?.baseRefName = nil
        #expect(CoordinatorReviewPresentation.state(current, task: unknownDestination) == .baseUnknown)
        #expect(CoordinatorReviewPresentation.canRequestChanges(current, task: unknownDestination) == false)
        var changedDestination = task(for: current)
        changedDestination.pullRequestState?.baseRefName = "different-landing"
        #expect(CoordinatorReviewPresentation.state(current, task: changedDestination) == .baseChanged)
        #expect(CoordinatorReviewPresentation.canApprove(current, task: changedDestination) == false)

        var failed = current
        failed.userAction = .init(kind: .merge, approvedHeadSHA: firstHead, deliveryState: .failed)
        #expect(CoordinatorReviewPresentation.canRetry(failed, task: changedDestination) == false)
        #expect(CoordinatorReviewPresentation.canRetry(failed, task: unknownDestination) == false)
    }

    @Test
    func terminalFactsUseTheSameStateForDetailAndQueueAndDistinguishAnotherMergedTarget() {
        let reviewed = review(priority: .urgent)
        var merged = task(for: reviewed, head: secondHead)
        merged.pullRequestState?.state = .merged
        #expect(CoordinatorReviewPresentation.state(reviewed, task: merged) == .mergedDifferentHead)
        #expect(CoordinatorReviewPresentation.isComplete(entry(reviewed), task: merged))
        merged.pullRequestState?.headSHA = firstHead
        merged.pullRequestState?.baseRefName = "different-landing"
        #expect(CoordinatorReviewPresentation.state(reviewed, task: merged) == .mergedDifferentBase)
        #expect(CoordinatorReviewPresentation.isComplete(entry(reviewed), task: merged))

        let ready = review()
        let ordered = CoordinatorReviewPresentation.queue(native: [entry(reviewed), entry(ready)], saved: [], tasks: [merged, task(for: ready)])
        #expect(ordered.first?.id == ready.taskID)
        var closed = task(for: reviewed, head: secondHead)
        closed.pullRequestState?.state = .closed
        #expect(CoordinatorReviewPresentation.state(reviewed, task: closed) == .closed)
        #expect(CoordinatorReviewPresentation.isComplete(entry(reviewed), task: closed))
        var savedClosed = reviewed
        savedClosed.observedOutcome = .init(state: .closed, headSHA: secondHead, observedAt: date)
        #expect(CoordinatorReviewPresentation.state(savedClosed) == .closed)
    }

    @Test
    func onlyExplicitRecoverableRequestsCanBeRetriedWithoutEnablingOrdinaryDuplicateApproval() {
        for delivery in [CoordinatorReviewAction.DeliveryState.uncertain, .failed] {
            var reviewed = review()
            reviewed.userAction = .init(kind: .merge, approvedHeadSHA: firstHead, deliveryState: delivery)
            #expect(CoordinatorReviewPresentation.canRetry(reviewed, task: task(for: reviewed)))
            #expect(CoordinatorReviewPresentation.canApprove(reviewed, task: task(for: reviewed)) == false)
            #expect(CoordinatorReviewPresentation.canRetry(reviewed, task: task(for: reviewed, head: secondHead)) == false)
        }
        var delivered = review()
        delivered.userAction = .init(kind: .merge, approvedHeadSHA: firstHead, deliveryState: .delivered, agentOutcome: .init(state: .blocked))
        #expect(CoordinatorReviewPresentation.canRetry(delivered, task: task(for: delivered)))
        delivered.userAction?.agentOutcome = .init(state: .checking)
        #expect(CoordinatorReviewPresentation.canRetry(delivered, task: task(for: delivered)) == false)
        #expect(CoordinatorReviewPresentation.canRetry(delivered, task: nil) == false)
    }

    @Test
    func savedOnlyIncompleteHistoryDoesNotDisplaceAnActiveReview() {
        let active = review()
        let savedOnly = review(priority: .urgent, createdAt: date.addingTimeInterval(-200))
        let ordered = CoordinatorReviewPresentation.queue(native: [entry(active)], saved: [active, savedOnly])
        #expect(ordered.map(\.taskID) == [active.taskID, savedOnly.taskID])
    }

    @Test
    func openSelectionPinsBriefAndRevisionUntilExplicitRefreshDespiteIncomingQueueUpdates() {
        let original = review()
        var selection = CoordinatorReviewPresentation.Selection()
        selection.selectInitial([entry(original)], saved: [original])
        let urgent = review(priority: .urgent)
        var updated = original
        updated.revision += 1
        updated.brief.behaviorChange = "New incoming brief content"
        let incoming = CoordinatorReviewPresentation.queue(native: [entry(updated), entry(urgent)], saved: [updated, urgent])

        selection.selectInitial(incoming, saved: [updated, urgent])
        #expect(selection.taskID == original.taskID)
        #expect(selection.reviewedBrief == original)
        #expect(CoordinatorReviewPresentation.canDecide(updated, currentReviewID: updated.id, reviewed: selection.reviewedBrief) == false)
        selection.selectInitial([entry(urgent)], saved: [urgent])
        #expect(selection.taskID == original.taskID)
        #expect(selection.reviewedBrief == original)

        selection.select(entry(updated), saved: [updated, urgent])
        #expect(selection.reviewedBrief?.revision == updated.revision)
        #expect(selection.reviewedBrief?.brief == updated.brief)
        #expect(CoordinatorReviewPresentation.canDecide(updated, currentReviewID: updated.id, reviewed: selection.reviewedBrief))

        let nextHead = review(taskID: original.taskID, head: secondHead)
        selection.selectInitial([entry(nextHead)], saved: [nextHead])
        #expect(selection.reviewedBrief?.id == updated.id)
        #expect(CoordinatorReviewPresentation.canDecide(nextHead, currentReviewID: nextHead.id, reviewed: selection.reviewedBrief) == false)
    }

    @Test
    func unknownOrAbbreviatedLiveHeadCannotUseHistoricalObservationForDecisionOrRetry() {
        var reviewed = review()
        reviewed.observedOutcome = .init(state: .open, headSHA: firstHead, baseRefName: "landing", observedAt: date)
        for head in [nil, String(firstHead.prefix(7))] as [String?] {
            var currentTask = task(for: reviewed)
            currentTask.pullRequestState?.headSHA = head
            #expect(CoordinatorReviewPresentation.state(reviewed, task: currentTask) == .headUnknown)
            #expect(CoordinatorReviewPresentation.canApprove(reviewed, task: currentTask) == false)
            #expect(CoordinatorReviewPresentation.canRequestChanges(reviewed, task: currentTask) == false)
            var failed = reviewed
            failed.userAction = .init(kind: .merge, approvedHeadSHA: firstHead, deliveryState: .failed)
            #expect(CoordinatorReviewPresentation.canRetry(failed, task: currentTask) == false)
        }
    }
}
