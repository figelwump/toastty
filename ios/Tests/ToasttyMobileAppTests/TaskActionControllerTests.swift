import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

/// Task actions from the phone: one request ID per tap, one retry when the
/// answer is lost, and what the user is told when the Mac does not run it.
@MainActor
final class TaskActionControllerTests: XCTestCase {
    private let mergeItem = RemoteTaskActionItem(action: .merge, title: "Merge PR #36")

    func testTaskActionsNeedALiveMacThatTakesThem() {
        let controller = liveController(supportsTaskActions: false)
        XCTAssertFalse(controller.canActOnTasks)
        controller.update(
            snapshot: ToasttyMobileFixture.taskHome, connectionState: .live, freshness: .live,
            hostSupportsTaskActions: true
        )
        XCTAssertTrue(controller.canActOnTasks)
        controller.update(snapshot: ToasttyMobileFixture.taskHome, connectionState: .offline, freshness: .stale)
        XCTAssertFalse(controller.canActOnTasks)
    }

    func testALostAnswerIsRetriedOnceUnderTheSameRequestID() async throws {
        let controller = liveController()
        let recorder = RequestRecorder(outcomes: [.unconfirmed, .answered(.performed)])
        install(recorder, in: controller)
        let task = try reviewTask(controller)

        let failure = await controller.performTaskAction(mergeItem, on: task)

        XCTAssertNil(failure)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(Set(recorder.requests.map(\.clientRequestID)).count, 1)
        // The Mac refuses if the pull request is no longer the one shown.
        XCTAssertEqual(recorder.requests.first?.expectedPullRequestNumber, 36)
        XCTAssertEqual(recorder.requests.first?.action, .merge)
        XCTAssertFalse(recorder.requests.contains { $0.closePullRequest })
        XCTAssertEqual(controller.subspaceDoneNotice?.kind, .taskAction)
        XCTAssertFalse(controller.isTaskActionInFlight(task.id))
    }

    func testAnAnswerThatStaysLostSaysTheOutcomeIsUnknown() async throws {
        let controller = liveController()
        // The retry could not even be sent, so the first attempt's unknown
        // outcome stands.
        let recorder = RequestRecorder(outcomes: [.unconfirmed, .notSent])
        install(recorder, in: controller)

        let failure = await controller.performTaskAction(mergeItem, on: try reviewTask(controller))

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(try XCTUnwrap(failure).message.contains("couldn\u{2019}t confirm"))
        XCTAssertNil(controller.subspaceDoneNotice)
    }

    func testAPermissionRefusalOnTheRetryKeepsTheOutcomeUnknown() async throws {
        let controller = liveController()
        // The first attempt may have run before access was turned off, so
        // the phone must not say only that permission is missing.
        let recorder = RequestRecorder(outcomes: [
            .unconfirmed,
            .answered(.rejected(reason: .permissionDenied, message: nil)),
        ])
        install(recorder, in: controller)

        let failure = await controller.performTaskAction(mergeItem, on: try reviewTask(controller))

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(try XCTUnwrap(failure).message.contains("couldn\u{2019}t confirm"))
    }

    func testARequestThatWasNeverSentSaysNothingWasSent() async throws {
        let controller = liveController()
        let recorder = RequestRecorder(outcomes: [.notSent, .notSent])
        install(recorder, in: controller)

        let failure = await controller.performTaskAction(mergeItem, on: try reviewTask(controller))

        XCTAssertTrue(try XCTUnwrap(failure).message.contains("nothing was sent"))
    }

    func testAnAnswerThisAppCannotReadIsNotRepeated() async throws {
        let controller = liveController()
        let recorder = RequestRecorder(outcomes: [.answered(.unrecognized)])
        install(recorder, in: controller)

        let failure = await controller.performTaskAction(mergeItem, on: try reviewTask(controller))

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(failure).message.contains("Check the task on your Mac"))
    }

    func testRefusalsSayWhatChangedOrWhatToDo() async throws {
        let controller = liveController()
        let recorder = RequestRecorder(outcomes: [
            .answered(.rejected(reason: .permissionDenied, message: nil)),
            .answered(.rejected(reason: .notOffered, message: "Merging…")),
        ])
        install(recorder, in: controller)
        let task = try reviewTask(controller)

        let denied = await controller.performTaskAction(mergeItem, on: task)
        XCTAssertEqual(denied?.title, "Couldn\u{2019}t merge \u{201C}compact-session-rows\u{201D}")
        XCTAssertTrue(try XCTUnwrap(denied).message.contains("Turn on Task actions for this iPhone"))

        let stale = await controller.performTaskAction(mergeItem, on: task)
        XCTAssertEqual(stale?.message, "The task changed on your Mac. It now reads: Merging….")
        // Each tap is its own intent with its own ID; refusals are not retried.
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertNotEqual(recorder.requests[0].clientRequestID, recorder.requests[1].clientRequestID)
    }

    func testOnlyAnArchiveAsksToCloseThePullRequest() async throws {
        let controller = liveController()
        let recorder = RequestRecorder(outcomes: [.answered(.performed), .answered(.performed)])
        install(recorder, in: controller)
        let task = try reviewTask(controller)

        _ = await controller.performTaskAction(RemoteTaskActionItem(action: .archive, title: "Archive…"), on: task, closePullRequest: true)
        _ = await controller.performTaskAction(mergeItem, on: task, closePullRequest: true)

        XCTAssertEqual(recorder.requests.map(\.closePullRequest), [true, false])
    }

    func testASecondTapWhileTheFirstIsOnItsWaySendsNothing() async throws {
        let controller = liveController()
        let gate = RequestGate()
        let recorder = RequestRecorder(outcomes: [.answered(.performed)], gate: gate)
        install(recorder, in: controller)
        let task = try reviewTask(controller)

        let first = Task { await controller.performTaskAction(mergeItem, on: task) }
        try await waitUntil { controller.isTaskActionInFlight(task.id) }
        let second = await controller.performTaskAction(mergeItem, on: task)
        XCTAssertNil(second)
        await gate.open()
        _ = await first.value

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertFalse(controller.isTaskActionInFlight(task.id))
    }

    func testMergeMarkDoneAndDeleteAskFirstAndTheRestRunAtOnce() throws {
        let task = try XCTUnwrap(ToasttyMobileFixture.taskHome.taskBoard?.task(id: ToasttyMobileFixture.reviewTaskID))
        let merge = try XCTUnwrap(ToasttyTaskActionConfirmation.make(mergeItem, task: task))
        XCTAssertEqual(merge.title, "Merge PR #36?")
        XCTAssertEqual(merge.confirmTitle, "Merge PR #36")
        XCTAssertFalse(merge.isDestructive)
        XCTAssertNotNil(ToasttyTaskActionConfirmation.make(RemoteTaskActionItem(action: .markDone, title: "Complete Task"), task: task))
        XCTAssertEqual(
            ToasttyTaskActionConfirmation.make(RemoteTaskActionItem(action: .delete, title: "Delete Task"), task: task)?.isDestructive,
            true
        )
        for action in [RemoteTaskAction.cancelMerge, .cleanUp, .keepAsIs, .retry, .archive] {
            XCTAssertNil(ToasttyTaskActionConfirmation.make(RemoteTaskActionItem(action: action, title: "x"), task: task))
        }
    }

    // MARK: - Fixture

    func testTheFixtureMergesAndThenCancelsTheMerge() async throws {
        let controller = HomeScreenController(
            runtimeMode: .fixture, snapshot: ToasttyMobileFixture.taskHome, connectionState: .live
        )
        XCTAssertTrue(controller.canActOnTasks)
        let task = try reviewTask(controller)
        XCTAssertEqual(task.mergeControl?.kind, .merge)

        let merged = await controller.performTaskAction(mergeItem, on: task)
        XCTAssertNil(merged)
        let merging = try reviewTask(controller)
        XCTAssertEqual(merging.mergeControl?.kind, .merging)
        XCTAssertEqual(merging.mergeControl?.title, "Merging PR #36…")

        // The Mac's list changed, so the old Merge item is refused now.
        let again = await controller.performTaskAction(mergeItem, on: merging)
        XCTAssertNotNil(again)

        let cancel = try XCTUnwrap(merging.mergeControl?.menu.first)
        let cancelled = await controller.performTaskAction(cancel, on: merging)
        XCTAssertNil(cancelled)
        XCTAssertEqual(try reviewTask(controller).mergeControl?.kind, .merge)
    }

    func testTheFixtureArchiveCheckBlocksUncommittedChanges() async throws {
        let controller = HomeScreenController(
            runtimeMode: .fixture, snapshot: ToasttyMobileFixture.taskHome, connectionState: .live
        )
        guard case .answered(.ready(let clean)) = await controller.taskArchiveCheck(taskID: ToasttyMobileFixture.reviewTaskID),
              case .answered(.ready(let blocked)) = await controller.taskArchiveCheck(taskID: ToasttyMobileFixture.archiveTaskID) else {
            return XCTFail("Expected archive checks")
        }
        XCTAssertNil(clean.blockedReason)
        XCTAssertEqual(clean.unpushedCommits, 2)
        XCTAssertEqual(clean.pullRequest?.number, 36)
        XCTAssertEqual(blocked.uncommittedFiles, 3)
        XCTAssertNotNil(blocked.blockedReason)

        // Archiving closes the task space.
        let task = try XCTUnwrap(controller.snapshot.taskBoard?.task(id: ToasttyMobileFixture.reviewTaskID))
        let failure = await controller.performTaskAction(RemoteTaskActionItem(action: .archive, title: "Archive…"), on: task)
        XCTAssertNil(failure)
        XCTAssertNil(controller.snapshot.taskBoard?.task(id: ToasttyMobileFixture.reviewTaskID))
        XCTAssertNil(controller.workspace(id: ToasttyMobileFixture.needsApprovalSubspaceID))
    }

    // MARK: - Release

    func testReleaseNeedsALiveMacThatStartsReleases() {
        let controller = liveController()
        XCTAssertFalse(controller.canReleaseProjects)
        controller.update(
            snapshot: ToasttyMobileFixture.taskHome, connectionState: .live, freshness: .live,
            hostSupportsProjectRelease: true
        )
        XCTAssertTrue(controller.canReleaseProjects)
        controller.update(snapshot: ToasttyMobileFixture.taskHome, connectionState: .offline, freshness: .stale)
        XCTAssertFalse(controller.canReleaseProjects)
    }

    func testAReleaseAsksFirstNamingTheProjectAndWhatShips() throws {
        let release = try toasttyRelease(liveController())
        let confirmation = ToasttyTaskActionConfirmation.release(release)
        XCTAssertEqual(confirmation.title, "Release \u{201C}toastty\u{201D}?")
        XCTAssertEqual(confirmation.confirmTitle, "Release")
        XCTAssertFalse(confirmation.isDestructive)
        XCTAssertTrue(confirmation.message.hasPrefix("Your Mac starts a release task for 3 merged tasks waiting to ship."))
        XCTAssertTrue(confirmation.message.hasSuffix(
            "\u{2022} Parent task rollup\n\u{2022} Share sheet links\n\u{2022} Steer chip fix"
        ))
    }

    func testALostReleaseAnswerIsRetriedOnceAndASecondTapSendsNothing() async throws {
        let controller = liveController(supportsRelease: true)
        let gate = RequestGate()
        let recorder = ReleaseRecorder(outcomes: [.unconfirmed, .answered(.started(taskID: UUID()))], gate: gate)
        controller.installProjectRelease(perform: { await recorder.answer($0) })
        let release = try toasttyRelease(controller)

        let first = Task { await controller.releaseProject(release) }
        try await waitUntil { controller.isProjectReleaseInFlight(release) }
        let second = await controller.releaseProject(release)
        XCTAssertNil(second)
        await gate.open()
        let failure = await first.value

        XCTAssertNil(failure)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(Set(recorder.requests.map(\.clientRequestID)).count, 1)
        XCTAssertEqual(recorder.requests.first?.workspaceID, ToasttyMobileFixture.previewWorkspaceID)
        XCTAssertEqual(controller.subspaceDoneNotice?.message, "Starting a release of \u{201C}toastty\u{201D} on your Mac.")
        XCTAssertFalse(controller.isProjectReleaseInFlight(release))
    }

    func testReleaseRefusalsSayWhatToDo() async throws {
        let controller = liveController(supportsRelease: true)
        let underWay = "A release of toastty is already under way: Release toastty."
        let recorder = ReleaseRecorder(outcomes: [
            .answered(.rejected(reason: .permissionDenied, message: nil)),
            .answered(.rejected(reason: .releaseUnderWay, message: underWay)),
            .answered(.rejected(reason: .notReleasable, message: nil)),
        ])
        controller.installProjectRelease(perform: { await recorder.answer($0) })
        let release = try toasttyRelease(controller)

        let denied = await controller.releaseProject(release)
        XCTAssertEqual(denied?.title, "Couldn\u{2019}t release \u{201C}toastty\u{201D}")
        XCTAssertTrue(try XCTUnwrap(denied).message.contains("both Task actions and Start sessions"))
        let busy = await controller.releaseProject(release)
        XCTAssertEqual(busy?.message, underWay)
        let notConfigured = await controller.releaseProject(release)
        XCTAssertTrue(try XCTUnwrap(notConfigured).message.contains("release_prompt"))
        // Refusals are not retried.
        XCTAssertEqual(recorder.requests.count, 3)
    }

    func testTheFixtureStartsOneReleaseThenTheLaneReadsReleasing() async throws {
        let controller = HomeScreenController(
            runtimeMode: .fixture, snapshot: ToasttyMobileFixture.taskHome, connectionState: .live
        )
        XCTAssertTrue(controller.canReleaseProjects)
        let release = try toasttyRelease(controller)
        XCTAssertFalse(release.isReleasing)

        let failure = await controller.releaseProject(release)
        XCTAssertNil(failure)
        let lane = try XCTUnwrap(controller.snapshot.taskBoard.map(MobileTaskSections.make)?.toShip.first)
        XCTAssertEqual(lane.release?.isReleasing, true)
        // The release task lists like any other task.
        let task = try XCTUnwrap(lane.release?.releaseTaskID.flatMap { controller.snapshot.taskBoard?.task(id: $0) })
        XCTAssertEqual(task.title, "Release toastty")
        XCTAssertEqual(task.group, .running)

        // A request from a stale screen is refused while it runs.
        let again = await controller.releaseProject(release)
        XCTAssertEqual(again?.message, "A release of toastty is already under way: Release toastty.")
    }

    // MARK: - Helpers

    private func toasttyRelease(_ controller: HomeScreenController) throws -> MobileProjectRelease {
        try XCTUnwrap(controller.snapshot.taskBoard.map(MobileTaskSections.make)?.toShip.first?.release)
    }

    private func liveController(supportsTaskActions: Bool = true, supportsRelease: Bool = false) -> HomeScreenController {
        let controller = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.example")!),
            snapshot: ToasttyMobileFixture.taskHome, connectionState: .live
        )
        controller.taskActionRetryDelay = .zero
        if supportsTaskActions || supportsRelease {
            controller.update(
                snapshot: ToasttyMobileFixture.taskHome, connectionState: .live, freshness: .live,
                hostSupportsTaskActions: supportsTaskActions,
                hostSupportsProjectRelease: supportsRelease
            )
        }
        return controller
    }

    private func install(_ recorder: RequestRecorder, in controller: HomeScreenController) {
        controller.installTaskActions(
            perform: { request in await recorder.answer(request) },
            archiveCheck: { _ in .unreachable }
        )
    }

    private func reviewTask(_ controller: HomeScreenController) throws -> RemoteTaskSummary {
        try XCTUnwrap(controller.snapshot.taskBoard?.task(id: ToasttyMobileFixture.reviewTaskID))
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while condition() == false {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class RequestRecorder {
    private var outcomes: [ToasttyTaskActionSendOutcome]
    private let gate: RequestGate?
    private(set) var requests: [RemoteTaskActionRequest] = []

    init(outcomes: [ToasttyTaskActionSendOutcome], gate: RequestGate? = nil) {
        self.outcomes = outcomes
        self.gate = gate
    }

    func answer(_ request: RemoteTaskActionRequest) async -> ToasttyTaskActionSendOutcome {
        requests.append(request)
        await gate?.wait()
        return outcomes.isEmpty ? .notSent : outcomes.removeFirst()
    }
}

@MainActor
private final class ReleaseRecorder {
    private var outcomes: [ToasttyProjectReleaseSendOutcome]
    private let gate: RequestGate?
    private(set) var requests: [RemoteProjectReleaseRequest] = []

    init(outcomes: [ToasttyProjectReleaseSendOutcome], gate: RequestGate? = nil) {
        self.outcomes = outcomes
        self.gate = gate
    }

    func answer(_ request: RemoteProjectReleaseRequest) async -> ToasttyProjectReleaseSendOutcome {
        requests.append(request)
        await gate?.wait()
        return outcomes.isEmpty ? .notSent : outcomes.removeFirst()
    }
}

/// Holds a request until the test lets it finish.
private actor RequestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
