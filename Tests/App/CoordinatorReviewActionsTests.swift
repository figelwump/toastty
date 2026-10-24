import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The real task/store/PR-cache boundary with disposable git checkouts and
/// recorded terminal delivery. No GitHub or production task is changed.
@MainActor
struct CoordinatorReviewActionsTests {
    actor PullRequestRunner: WorkspaceMergeCommandRunning {
        var head: String
        var state = "OPEN"
        var base: String? = "main"
        var failure = false
        init(head: String) { self.head = head }
        func setHead(_ value: String) { head = value }
        func setState(_ value: String) { state = value }
        func setBase(_ value: String?) { base = value }
        func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
            if failure { return .init(exitCode: 1, stdout: "", stderr: "offline", failure: nil) }
            let object: [String: Any] = [
                "state": state, "headRefOid": head, "baseRefName": base.map { $0 as Any } ?? NSNull(), "isDraft": false,
                "mergeCommit": state == "MERGED" ? ["oid": String(repeating: "b", count: 40)] : NSNull(),
            ]
            return .init(exitCode: 0, stdout: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self), stderr: "", failure: nil)
        }
    }

    @MainActor
    final class Fixture {
        let tasks: TaskStartWorkTests.Fixture
        let reviews: CoordinatorReviewStore
        let runner: PullRequestRunner
        let cache: PullRequestStateCache
        let actions: CoordinatorReviewActions
        let record: TaskRecord
        let head: String
        let review: CoordinatorReviewItem
        let link = WorkspacePullRequestLink(annotationURL: "https://github.com/example/project/pull/7")!

        init() async throws {
            let fixture = try TaskStartWorkTests.Fixture()
            let created = try await fixture.coordinator.create(TaskCreateRequest(
                text: "Fix the composer", workspaceID: fixture.workspaceID, agent: "claude", startWork: true
            ))
            await fixture.waitUntil("setup ends") { fixture.record(created.id)?.setup != .settingUp }
            let task = try #require(fixture.record(created.id))
            let commit = try TaskGitTestRepository.git(["rev-parse", "HEAD"], in: try #require(task.worktree?.path))
            fixture.sessions.report(try #require(task.currentSessionID), .ready)
            let pullRequest = WorkspacePullRequestLink(annotationURL: "https://github.com/example/project/pull/7")!
            fixture.store.send(.setWorkspaceAnnotation(
                workspaceID: try #require(task.taskSpaceWorkspaceID), key: "github-pr",
                annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: pullRequest.url))
            ))
            let savedReviews = CoordinatorReviewStore(fileURL: fixture.repository.root.appendingPathComponent("reviews.json"))
            let requestRunner = PullRequestRunner(head: commit)
            let requests = PullRequestStateCache(runner: requestRunner)
            let reviewActions = CoordinatorReviewActions(store: savedReviews, tasks: fixture.coordinator, pullRequests: requests, deliveryPollInterval: .milliseconds(10))
            let item = try savedReviews.upsertPublication(CoordinatorReviewItem(
                taskID: task.id, taskTitle: task.title, projectRoot: fixture.repository.project,
                repository: pullRequest.repository, pullRequestURL: pullRequest.url, headSHA: commit, baseRefName: "main",
                brief: .init(behaviorChange: "The composer preserves text.", decisionNeeded: "Approve the change.", verification: ["Tests pass."], gaps: [], recommendation: "Approve after reading the diff.")
            ))
            tasks = fixture
            record = task
            head = commit
            reviews = savedReviews
            runner = requestRunner
            cache = requests
            actions = reviewActions
            review = item
        }

        func waitForDelivery() async {
            await tasks.waitUntil("review delivery") { reviews.item(id: review.id)?.userAction?.deliveryState != .pending && reviews.item(id: review.id)?.userAction?.deliveryState != .dispatching }
        }
    }

    @Test func approvalPersistsTheReviewedHeadAndUsesRepositoryContext() async throws {
        let f = try await Fixture()
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let action = try #require(f.reviews.item(id: f.review.id)?.userAction)
        #expect(action.approvedHeadSHA == f.head)
        #expect(action.deliveryState == .delivered)
        #expect(f.tasks.record(f.record.id)?.reviewActionIntentID == action.intentID)
        let message = try #require(f.tasks.sessions.delivered.last?.text)
        #expect(message.contains(f.head))
        #expect(message.contains("Follow this repository's instructions and merge skills."))
        #expect(message.contains("--review-intent \(action.intentID.uuidString)"))
        #expect(message.contains("coordinator review report"))
        #expect(!message.contains("Use the toastty-task-merge skill."))
        let restarted = CoordinatorReviewStore(fileURL: f.tasks.repository.root.appendingPathComponent("reviews.json"))
        #expect(restarted.item(id: f.review.id)?.userAction == action)
    }

    @Test func approvalCannotAcceptAHeadThatMovedSinceTheBrief() async throws {
        let f = try await Fixture()
        await f.runner.setHead(String(repeating: "c", count: 40))
        await #expect(throws: (any Error).self) {
            try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        }
        #expect(f.reviews.item(id: f.review.id)?.userAction == nil)
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.state == .headChanged)
        #expect(f.tasks.sessions.delivered.isEmpty)
    }

    @Test func busyAgentGetsNoStaleApprovalAfterItsTurnEnds() async throws {
        let f = try await Fixture()
        let session = try #require(f.record.currentSessionID)
        f.tasks.sessions.report(session, .working)
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        #expect(f.tasks.sessions.delivered.isEmpty)
        await f.runner.setHead(String(repeating: "d", count: 40))
        f.tasks.sessions.report(session, .ready)
        await f.waitForDelivery()
        #expect(f.tasks.sessions.delivered.isEmpty)
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.state == .headChanged)
    }

    @Test func reviewedMergeCannotOmitOrReplaceTheAcceptedHead() async throws {
        let f = try await Fixture()
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let intent = try #require(f.reviews.item(id: f.review.id)?.userAction?.intentID)
        let missing = #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: nil, caller: .unmanaged)
        }
        #expect(missing?.message.contains("approved commit") == true)
        #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: String(repeating: "f", count: 40), caller: .unmanaged, reviewIntentID: intent)
        }
        #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: f.head, caller: .unmanaged, reviewIntentID: UUID())
        }
        // A persisted intent fails closed before its service is installed.
        f.tasks.coordinator.coordinatorReviewActions = nil
        #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: f.head, caller: .unmanaged)
        }
    }

    @Test func uncertainFeedbackSurvivesRestartWithoutAutomaticReplay() async throws {
        let f = try await Fixture()
        f.tasks.sessions.deliveryResult = .uncertain
        try await f.actions.requestChanges(reviewID: f.review.id, expectedRevision: f.review.revision, feedback: "Keep the existing keyboard shortcut.")
        await f.waitForDelivery()
        let saved = try #require(f.reviews.item(id: f.review.id)?.userAction)
        #expect(saved.deliveryState == .uncertain)
        #expect(saved.feedback == "Keep the existing keyboard shortcut.")
        #expect(f.tasks.sessions.delivered.count == 1)
        let restored = CoordinatorReviewStore(fileURL: f.tasks.repository.root.appendingPathComponent("reviews.json"))
        let resumedActions = CoordinatorReviewActions(store: restored, tasks: f.tasks.coordinator, pullRequests: f.cache)
        #expect(restored.item(id: f.review.id)?.userAction?.deliveryState == .uncertain)
        try await Task.sleep(for: .milliseconds(40))
        #expect(f.tasks.sessions.delivered.count == 1)
        _ = resumedActions
    }

    @Test func anAgentReportDoesNotConfirmAMergeAndCannotReplaceAnIntent() async throws {
        let f = try await Fixture()
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let intent = try #require(f.reviews.item(id: f.review.id)?.userAction?.intentID)
        try f.actions.report(reviewID: f.review.id, intentID: intent, outcome: .merged, detail: "The merge command returned.")
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.state == .open)
        #expect(throws: (any Error).self) {
            try f.actions.report(reviewID: f.review.id, intentID: UUID(), outcome: .merged, detail: "Wrong intent")
        }
        await f.runner.setState("MERGED")
        await f.cache.refresh(f.link).value
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.state == .merged)
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.mergeCommit == String(repeating: "b", count: 40))
    }
    @Test func sameHeadRetargetRequiresNewReview() async throws {
        let f = try await Fixture()
        await f.runner.setBase("release")
        await #expect(throws: (any Error).self) {
            try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        }
        #expect(f.reviews.item(id: f.review.id)?.userAction == nil)
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.state == .headChanged)
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.baseRefName == "release")
    }

    @Test func explicitRetryRetainsTheUncertainIntentAndRejectsItsLaterMerge() async throws {
        let f = try await Fixture()
        f.tasks.sessions.deliveryResult = .uncertain
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let old = try #require(f.reviews.item(id: f.review.id))
        let oldIntent = try #require(old.userAction?.intentID)
        f.tasks.sessions.deliveryResult = .delivered
        try await f.actions.retryDelivery(reviewID: old.id, expectedRevision: old.revision)
        await f.waitForDelivery()
        let updated = try #require(f.reviews.item(id: old.id))
        #expect(updated.userAction?.intentID != oldIntent)
        #expect(updated.userAction?.deliveryState == .delivered)
        #expect(updated.actionHistory?.last?.intentID == oldIntent)
        #expect(updated.actionHistory?.last?.deliveryState == .uncertain)
        #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: f.head, caller: .unmanaged, reviewIntentID: oldIntent)
        }
        #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: f.head, caller: .unmanaged)
        }
    }

    @Test func cancellationAndRestartCannotLeaveALegacyMergeCheckingFlag() async throws {
        let f = try await Fixture()
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let intent = try #require(f.reviews.item(id: f.review.id)?.userAction?.intentID)
        try f.tasks.coordinator.cancelMerge(taskID: f.record.id)
        #expect(f.reviews.item(id: f.review.id)?.userAction?.deliveryState == .failed)
        #expect(f.tasks.record(f.record.id)?.mergeRequestedAt == nil)
        #expect(throws: TaskError.self) {
            try f.tasks.coordinator.merge(taskID: f.record.id, expectedHead: f.head, caller: .unmanaged, reviewIntentID: intent)
        }
        let current = try #require(f.reviews.item(id: f.review.id))
        let pending = CoordinatorReviewAction(kind: .merge, approvedHeadSHA: f.head)
        try f.reviews.update(id: current.id, expectedRevision: current.revision) { $0.userAction = pending }
        try f.tasks.coordinator.records.save(id: f.record.id) {
            $0.reviewActionIntentID = pending.intentID
            $0.mergeRequestedAt = Date()
        }
        let restored = CoordinatorReviewStore(fileURL: f.tasks.repository.root.appendingPathComponent("reviews.json"))
        let resumed = CoordinatorReviewActions(store: restored, tasks: f.tasks.coordinator, pullRequests: f.cache)
        #expect(restored.item(id: f.review.id)?.userAction?.deliveryState == .failed)
        #expect(f.tasks.record(f.record.id)?.mergeRequestedAt == nil)
        #expect(f.tasks.record(f.record.id)?.reviewActionIntentID == pending.intentID)
        _ = resumed
    }

    @Test func aBlockedDeliveredRequestCanBeRetriedWithoutChangingItsCommit() async throws {
        let f = try await Fixture()
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let intent = try #require(f.reviews.item(id: f.review.id)?.userAction?.intentID)
        try f.actions.report(reviewID: f.review.id, intentID: intent, outcome: .blocked, detail: "Waiting for review threads.")
        let blocked = try #require(f.reviews.item(id: f.review.id))
        try await f.actions.retryDelivery(reviewID: blocked.id, expectedRevision: blocked.revision)
        await f.waitForDelivery()
        #expect(f.reviews.item(id: blocked.id)?.userAction?.intentID != intent)
        #expect(f.reviews.item(id: blocked.id)?.actionHistory?.last?.agentOutcome?.state == .blocked)
    }

    @Test func inputDuringTheWaitPreservesTheTaskDraftInsteadOfAppendingAnIntent() async throws {
        let f = try await Fixture()
        let session = try #require(f.record.currentSessionID)
        f.tasks.sessions.report(session, .working)
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        let action = try #require(f.reviews.item(id: f.review.id)?.userAction)
        f.tasks.sessions.inputAt[try #require(f.record.operation.taskSpace?.panelID)] = action.requestedAt.addingTimeInterval(0.1)
        f.tasks.sessions.report(session, .ready)
        await f.waitForDelivery()
        #expect(f.tasks.sessions.delivered.isEmpty)
        #expect(f.reviews.item(id: f.review.id)?.userAction?.deliveryState == .failed)
        #expect(f.reviews.item(id: f.review.id)?.userAction?.deliveryDetail?.contains("Input reached") == true)
    }

    @Test func duplicateClicksCreateOnlyOneIntentAndOneTaskMessage() async throws {
        let f = try await Fixture()
        let first = Task { @MainActor in try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision) }
        let second = Task { @MainActor in try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision) }
        var accepted = 0
        if case .success = await first.result { accepted += 1 }
        if case .success = await second.result { accepted += 1 }
        #expect(accepted == 1)
        await f.waitForDelivery()
        #expect(f.tasks.sessions.delivered.count == 1)
    }

    @Test func projectSettingsAreKeptWhenTheTaskAgentMustRestart() async throws {
        let f = try await Fixture()
        f.tasks.config.defaults = .init(agent: "codex", model: "gpt-6.1-sol", mergePrompt: "Check the project prerequisites.")
        f.tasks.config.workspaces = [.init(path: f.tasks.repository.project, mergeSkill: "project-merge")]
        f.tasks.sessions.stop(try #require(f.record.currentSessionID))
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        let launch = try #require(f.tasks.launcher.calls.last)
        #expect(launch.profileID == "claude")
        #expect(launch.model == nil)
        #expect(launch.prompt.hasPrefix("Use the project-merge skill.\n\nCheck the project prerequisites."))
        #expect(launch.prompt.contains(f.head))
    }

    @Test func anIncompleteNativeResponseCannotConfirmTheReviewedDestination() async throws {
        let f = try await Fixture()
        try await f.actions.approveAndMerge(reviewID: f.review.id, expectedRevision: f.review.revision)
        await f.waitForDelivery()
        await f.runner.setBase(nil)
        await f.runner.setState("MERGED")
        await f.cache.refresh(f.link).value
        #expect(f.reviews.item(id: f.review.id)?.observedOutcome.state != .merged)
    }

}
