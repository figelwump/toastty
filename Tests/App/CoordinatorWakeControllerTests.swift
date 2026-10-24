import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

@MainActor
struct CoordinatorWakeControllerTests {
    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-wake-\(UUID())")
        var stateURL: URL { root.appendingPathComponent("coordinator-wake.json") }
        var snapshot = CoordinatorWakeController.Snapshot(enabled: true, sessionStatus: .running,
            hasBackingIdentity: true, candidates: [], input: .init(
                conversationID: RemoteConversationID(), inputEpoch: .init(bindingID: UUID())))
        var starts = 0
        var requests: [RemoteMessageSendRequest] = []
        var notices: [String] = []
        var result: RemoteMessageSendResult?
        var onSend: (@MainActor () async -> Void)?

        func controller() -> CoordinatorWakeController {
            CoordinatorWakeController(stateURL: stateURL, dependencies: .init(
                snapshot: { [unowned self] in snapshot },
                start: { [unowned self] in starts += 1; snapshot.sessionStatus = .error("fixture launch failed") },
                send: { [unowned self] request in
                    requests.append(request)
                    if let onSend { await onSend() }
                    return result ?? .accepted(epoch: request.expectedInputEpoch)
                }, notice: { [unowned self] in notices.append($0) }))
        }

        func persisted() throws -> CoordinatorWakeState {
            try JSONDecoder().decode(CoordinatorWakeState.self, from: Data(contentsOf: stateURL))
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func candidate(id: UUID = UUID(), stage: TaskStage = .needsYou(.review),
                           head: String = String(repeating: "a", count: 40), base: String = "main", hasBrief: Bool = false) -> CoordinatorWakeCandidate {
        .init(facts: .init(taskID: id, stage: stage, pullRequestURL: "https://github.com/example/repo/pull/1",
            pullRequestState: .init(state: .open, headSHA: head, baseRefName: base)), hasCurrentBrief: hasBrief)
    }

    @Test
    func coalescesMissingBriefsAndOnlyWakesAgainForChangedTaskFacts() async throws {
        let f = Fixture()
        f.snapshot.candidates = [candidate(), candidate()]
        let controller = f.controller()
        f.onSend = { [unowned f] in
            // Persistence must precede the first byte sent, not just the result.
            #expect((try? f.persisted().handled.count) == 2)
        }
        await controller.reconcile()
        #expect(f.requests.count == 1)
        #expect(try f.persisted().handled.count == 2)
        f.snapshot.candidates[0].hasCurrentBrief = true
        f.snapshot.candidates[1].hasCurrentBrief = true
        await controller.reconcile()
        await controller.reconcile()
        #expect(f.requests.count == 1)
        let changedID = f.snapshot.candidates[1].facts.taskID
        f.snapshot.candidates[1] = candidate(id: changedID, head: String(repeating: "b", count: 40))
        await controller.reconcile()
        #expect(f.requests.count == 2)
        #expect(try f.persisted().handled[changedID.uuidString] == f.snapshot.candidates[1].facts)
    }

    @Test(arguments: [TaskStage.done, .toShip])
    func currentBriefDoesNotHideLaterCompletedTaskOutcome(_ outcome: TaskStage) async throws {
        let f = Fixture()
        let original = candidate(hasBrief: true)
        f.snapshot.candidates = [original, candidate(stage: .done, hasBrief: true),
            candidate(stage: .toShip, hasBrief: false)]
        let controller = f.controller()
        await controller.reconcile()
        #expect(f.requests.isEmpty)
        f.snapshot.candidates[0] = candidate(id: original.facts.taskID, stage: outcome, hasBrief: true)
        await controller.reconcile()
        #expect(f.requests.count == 1)
        await controller.reconcile()
        #expect(f.requests.count == 1)
    }

    @Test
    func largeCoalescedUpdateKeepsUnsentTasksPending() async throws {
        let f = Fixture()
        f.snapshot.candidates = (0..<65).map { _ in candidate() }
        let controller = f.controller()
        await controller.reconcile()
        #expect(f.requests.count == 1)
        #expect(try f.persisted().handled.count == 64)
        await controller.reconcile()
        #expect(f.requests.count == 2)
        #expect(try f.persisted().handled.count == 65)
        await controller.reconcile()
        #expect(f.requests.count == 2)
    }

    @Test
    func temporaryMissingPRCacheDoesNotWakeOrReplacePersistedHead() async throws {
        let f = Fixture()
        let known = candidate(hasBrief: true)
        f.snapshot.candidates = [known]
        await f.controller().reconcile()
        let unknown = CoordinatorWakeCandidate(facts: .init(taskID: known.facts.taskID, stage: .needsYou(.review),
            pullRequestURL: known.facts.pullRequestURL), hasCurrentBrief: false, hasKnownIdentity: false)
        f.snapshot.candidates = [unknown]
        let restarted = f.controller()
        await restarted.reconcile()
        #expect(f.requests.isEmpty)
        #expect(try f.persisted().handled[known.facts.taskID.uuidString] == known.facts)
        f.snapshot.candidates = [known]
        await restarted.reconcile()
        #expect(f.requests.isEmpty)
    }

    @Test
    func destinationChangeWakesOnceAndMissingDestinationWaitsForPRFacts() async throws {
        let f = Fixture()
        let original = candidate(hasBrief: true)
        f.snapshot.candidates = [original]
        let controller = f.controller()
        await controller.reconcile()
        var unknown = original
        unknown.facts.baseRefName = nil
        unknown.hasKnownIdentity = false
        unknown.hasCurrentBrief = false
        f.snapshot.candidates = [unknown]
        await controller.reconcile()
        #expect(f.requests.isEmpty)
        f.snapshot.candidates = [candidate(id: original.facts.taskID, base: "release")]
        await controller.reconcile()
        #expect(f.requests.count == 1)
        #expect(try f.persisted().handled[original.facts.taskID.uuidString]?.baseRefName == "release")
        await controller.reconcile()
        #expect(f.requests.count == 1)
    }

    @Test
    func firstReadWaitsForHeadInsteadOfInventingMissingBrief() async {
        let f = Fixture()
        var unknown = candidate(hasBrief: false)
        unknown.hasKnownIdentity = false
        unknown.facts.headSHA = nil
        unknown.facts.pullRequestState = nil
        f.snapshot.candidates = [unknown]
        let controller = f.controller()
        await controller.reconcile()
        #expect(f.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.stateURL.path))
        f.snapshot.candidates = [candidate(id: unknown.facts.taskID, hasBrief: true)]
        await controller.reconcile()
        #expect(f.requests.isEmpty)
    }

    @Test
    func recordedMergeWakesWithoutCacheAndDoesNotRepeatOnHydration() async {
        let f = Fixture()
        let known = candidate(hasBrief: true)
        f.snapshot.candidates = [known]
        let controller = f.controller()
        await controller.reconcile()
        let completed = CoordinatorWakeCandidate(facts: .init(taskID: known.facts.taskID, stage: .done,
            pullRequestURL: known.facts.pullRequestURL, pullRequestState: .init(state: .merged)),
            hasCurrentBrief: false, hasKnownIdentity: false)
        f.snapshot.candidates = [completed]
        await controller.reconcile()
        #expect(f.requests.count == 1)
        f.snapshot.candidates = [.init(facts: .init(taskID: known.facts.taskID, stage: .done,
            pullRequestURL: known.facts.pullRequestURL,
            pullRequestState: .init(state: .merged, headSHA: known.facts.headSHA, baseRefName: known.facts.baseRefName, mergeCommit: String(repeating: "c", count: 40))),
            hasCurrentBrief: true)]
        await controller.reconcile()
        #expect(f.requests.count == 1)
    }

    @Test(arguments: ["draft", "attachments", "send", "queue", "interaction", "closedPrompt"])
    func userActivityAndInputAuthorityBlockWake(_ blocker: String) async throws {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        let available = f.snapshot.input
        switch blocker {
        case "draft": f.snapshot.input.hasDraft = true
        case "attachments": f.snapshot.input.hasAttachments = true
        case "send": f.snapshot.input.userSendInFlight = true
        case "queue": f.snapshot.input.hasQueuedMessages = true
        case "interaction": f.snapshot.input.hasPendingInteractions = true
        default: f.snapshot.input.inputEpoch = nil
        }
        let controller = f.controller()
        await controller.reconcile()
        #expect(f.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.stateURL.path))
        f.snapshot.input = available
        await controller.reconcile()
        #expect(f.requests.count == 1)
    }

    @Test
    func failedInitialAutomaticStartIsNotRetriedByNotificationsOrRestart() async throws {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        f.snapshot.sessionStatus = .stopped
        f.snapshot.hasBackingIdentity = false
        let controller = f.controller()
        await controller.reconcile()
        #expect(f.starts == 1)
        #expect(try f.persisted().automaticStartAttempted)
        await controller.reconcile()
        f.snapshot.sessionStatus = .stopped
        await controller.reconcile()
        let restarted = f.controller()
        await restarted.reconcile()
        #expect(f.starts == 1)
        #expect(f.requests.isEmpty)
        // Explicit user Start can recover it; automatic work then proceeds.
        f.snapshot.hasBackingIdentity = true
        f.snapshot.sessionStatus = .running
        await restarted.reconcile()
        #expect(f.requests.count == 1)
    }

    @Test(arguments: [CoordinatorSessionStatus.stopped, .waitingForRestore, .error("failed"), .starting])
    func existingBackingSessionNeverAutoRelaunches(_ status: CoordinatorSessionStatus) async {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        f.snapshot.sessionStatus = status
        let controller = f.controller()
        await controller.reconcile()
        await controller.reconcile()
        #expect(f.starts == 0)
        #expect(f.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func rejectedAndUncertainDeliveryNeverReplayAcrossRestart(uncertain: Bool) async throws {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        f.result = uncertain ? .uncertain : .rejected(reason: .epochMismatch)
        let controller = f.controller()
        await controller.reconcile()
        #expect(!f.notices.isEmpty)
        #expect(f.requests.count == 1)
        f.result = .duplicate
        await controller.reconcile()
        let restarted = f.controller()
        await restarted.reconcile()
        #expect(f.requests.count == 1)
    }

    @Test
    func concurrentReconciliationDoesNotSendTwice() async {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        let controller = f.controller()
        var release: CheckedContinuation<Void, Never>?
        f.onSend = { await withCheckedContinuation { release = $0 } }
        let first = Task { await controller.reconcile() }
        for _ in 0..<100 where release == nil { await Task.yield() }
        #expect(release != nil)
        await controller.reconcile()
        release?.resume()
        await first.value
        #expect(f.requests.count == 1)
    }

    @Test
    func disabledAndCorruptStoresDoNotStartOrSend() async throws {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        f.snapshot.enabled = false
        await f.controller().reconcile()
        #expect(f.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.stateURL.path))
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: f.stateURL)
        f.snapshot.enabled = true
        let controller = f.controller()
        await controller.reconcile()
        #expect(f.requests.isEmpty)
        #expect(f.starts == 0)
        #expect(!f.notices.isEmpty)
        #expect(try Data(contentsOf: f.stateURL) == Data("broken".utf8))
    }

    @Test
    func persistenceFailureAndReviewReadFailureDoNotDeliver() async throws {
        let f = Fixture()
        f.snapshot.candidates = [candidate()]
        let controller = f.controller()
        try FileManager.default.createDirectory(at: f.stateURL, withIntermediateDirectories: true)
        await controller.reconcile()
        #expect(f.requests.isEmpty)
        #expect(!f.notices.isEmpty)
        let g = Fixture()
        g.snapshot.candidates = [candidate()]
        g.snapshot.reviewReadError = "invalid store"
        let blocked = g.controller()
        for _ in 0..<5 { await blocked.reconcile() }
        #expect(g.requests.isEmpty)
        #expect(g.starts == 0)
        #expect(g.notices.count == 1)
    }

    @Test
    func attentionReasonsAndTaskReportsRemainMeaningfulWithoutTimestampNoise() {
        let id = UUID()
        let a = CoordinatorWakeFacts(taskID: id, stage: .needsYou(.setupFailed(reason: "missing project")))
        let b = CoordinatorWakeFacts(taskID: id, stage: .needsYou(.setupFailed(reason: "fetch failed")))
        #expect(a != b)
        #expect(a.stage.needsAttention)
        let head = String(repeating: "a", count: 40)
        var action = CoordinatorReviewAction(kind: .merge, approvedHeadSHA: head,
            agentOutcome: .init(state: .blocked, message: "tests failed"))
        let report = CoordinatorWakeFacts(taskID: id, stage: .needsYou(.review), action: action)
        action.agentOutcome?.reportedAt = Date().addingTimeInterval(100)
        action.updatedAt = Date().addingTimeInterval(100)
        #expect(report == CoordinatorWakeFacts(taskID: id, stage: .needsYou(.review), action: action))
        action.agentOutcome?.state = .failed
        #expect(report != CoordinatorWakeFacts(taskID: id, stage: .needsYou(.review), action: action))
    }

    @Test
    func publishingBriefDoesNotChangeTaskFactIdentity() throws {
        let record = TaskRecord(createdAt: Date(), text: "Review change", title: "Change", slug: "change", source: .cli)
        let url = "https://github.com/example/repo/pull/1"
        let head = String(repeating: "b", count: 40)
        let item = TaskBoardItem(id: .task(record.id), record: record, title: record.title,
            stage: .needsYou(.review), agent: .idle,
            pullRequest: WorkspacePullRequestLink(annotationURL: url),
            pullRequestState: .init(state: .open, headSHA: head, baseRefName: "main"), activityAt: Date())
        let oldReview = CoordinatorReviewItem(taskID: record.id, taskTitle: record.title,
            projectRoot: "/fixture", repository: "example/repo", pullRequestURL: url,
            headSHA: String(repeating: "a", count: 40), baseRefName: "main",
            brief: .init(behaviorChange: "Old change", decisionNeeded: "Review", recommendation: "Wait"),
            userAction: .init(kind: .merge, approvedHeadSHA: String(repeating: "a", count: 40),
                agentOutcome: .init(state: .headChanged, message: "Head changed")))
        let before = try #require(CoordinatorWakeCandidate.reconcile(items: [item], reviews: [oldReview]).first)
        var current = CoordinatorReviewItem(taskID: record.id, taskTitle: record.title,
            projectRoot: "/fixture", repository: "example/repo", pullRequestURL: url, headSHA: head, baseRefName: "main",
            brief: .init(behaviorChange: "New change", decisionNeeded: "Review", recommendation: "Accept"))
        let published = try #require(CoordinatorWakeCandidate.reconcile(items: [item], reviews: [oldReview, current]).first)
        #expect(!before.hasCurrentBrief)
        #expect(published.hasCurrentBrief)
        #expect(before.facts == published.facts)
        current.revision += 1
        current.updatedAt = Date().addingTimeInterval(200)
        current.brief.recommendation = "Accept after manual check"
        let revised = try #require(CoordinatorWakeCandidate.reconcile(items: [item], reviews: [current]).first)
        #expect(published.facts == revised.facts)
        var retargeted = item
        retargeted.pullRequestState?.baseRefName = "release"
        let changedBase = try #require(CoordinatorWakeCandidate.reconcile(items: [retargeted], reviews: [current]).first)
        #expect(!changedBase.hasCurrentBrief)
        #expect(changedBase.hasKnownIdentity)
        #expect(changedBase.facts != revised.facts)
        retargeted.pullRequestState?.baseRefName = nil
        let unknownBase = try #require(CoordinatorWakeCandidate.reconcile(items: [retargeted], reviews: [current]).first)
        #expect(!unknownBase.hasCurrentBrief)
        #expect(!unknownBase.hasKnownIdentity)
    }

    @Test
    func duplicateTaskFactsCannotAlternateNotifications() async {
        let f = Fixture()
        let first = candidate()
        f.snapshot.candidates = [first, candidate(id: first.facts.taskID, stage: .toShip)]
        let controller = f.controller()
        for _ in 0..<5 { await controller.reconcile() }
        #expect(f.requests.count == 1)
    }
}
