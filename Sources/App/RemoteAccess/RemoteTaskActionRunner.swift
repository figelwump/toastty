import CoreState
import Foundation
import RemoteProtocol

/// Runs a task action, or a project's release, that a paired device asks
/// for, through the same `TaskCoordinator` calls as the Mac's own buttons.
///
/// The device names an action; the Mac decides whether it may run. Each
/// request is checked against the task as the snapshot would show it now,
/// so an action the Mac's current list does not offer is refused, whatever
/// the device's snapshot said. A repeat of a request with the same
/// `clientRequestID` returns the first answer and runs nothing again.
@MainActor
final class RemoteTaskActionRunner {
    private static let maximumRememberedActions = 128
    private static let maximumInFlightPerDevice = 4

    private struct RequestKey: Hashable {
        var deviceID: UUID
        var clientRequestID: String
    }

    private struct RememberedAction {
        var request: RemoteTaskActionRequest
        var finishedAt: Date
    }

    private struct RunningAction {
        var request: RemoteTaskActionRequest
        var task: Task<RemoteTaskActionResult, Never>
    }

    private let coordinator: () -> TaskCoordinator?
    /// Whether the device may still act on tasks at this instant: remote
    /// access is on, and the device is unrevoked, may send, and has its
    /// Task actions switch on. Read again after every wait.
    private let deviceMayAct: (UUID) -> Bool
    /// Whether the device may still start a release at this instant: as
    /// `deviceMayAct`, and its session start permission is on too.
    private let deviceMayRelease: (UUID) -> Bool
    /// The task as the snapshot would show it now, with the item it comes
    /// from; `nil` when the task system is off or the task is gone.
    private let currentTask: (UUID) -> (item: TaskBoardItem, summary: RemoteTaskSummary)?
    private let now: () -> Date

    private var inFlight: [RequestKey: RunningAction] = [:]
    /// Actions that ran, kept so a repeat of the same request returns the
    /// first answer instead of running again: a retried merge must not send
    /// the merge prompt twice. Held in memory for
    /// `RemoteTaskActionPolicy.duplicateRequestWindow`. Refusals are not
    /// kept, because nothing ran.
    private var remembered: [RequestKey: RememberedAction] = [:]

    init(
        coordinator: @escaping () -> TaskCoordinator?,
        deviceMayAct: @escaping (UUID) -> Bool,
        deviceMayRelease: @escaping (UUID) -> Bool,
        currentTask: @escaping (UUID) -> (item: TaskBoardItem, summary: RemoteTaskSummary)?,
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.deviceMayAct = deviceMayAct
        self.deviceMayRelease = deviceMayRelease
        self.currentTask = currentTask
        self.now = now
    }

    // MARK: - Action

    func perform(_ request: RemoteTaskActionRequest, device: RemoteDeviceRecord) async -> RemoteTaskActionResult {
        let key = RequestKey(deviceID: device.id, clientRequestID: request.clientRequestID)
        forgetExpired()
        if let earlier = remembered[key] {
            // The same ID for another request is a client bug, not a retry;
            // running nothing is the safe answer.
            guard earlier.request == request else { return .rejected(reason: .invalidRequest, message: nil) }
            return .performed
        }
        if let running = inFlight[key] {
            guard running.request == request else { return .rejected(reason: .invalidRequest, message: nil) }
            return await running.task.value
        }
        guard inFlight.keys.filter({ $0.deviceID == device.id }).count < Self.maximumInFlightPerDevice,
              remembered.count + inFlight.count < Self.maximumRememberedActions else {
            return .rejected(reason: .busy, message: nil)
        }
        // Not a child of the request's task: if the device disconnects, the
        // action still finishes and a repeat of the request finds its result.
        let task = Task { @MainActor [weak self] () -> RemoteTaskActionResult in
            guard let self else { return .rejected(reason: .tasksUnavailable, message: nil) }
            return await self.run(request, deviceID: device.id)
        }
        inFlight[key] = RunningAction(request: request, task: task)
        let result = await task.value
        inFlight[key] = nil
        if result == .performed {
            remembered[key] = RememberedAction(request: request, finishedAt: now())
        }
        return result
    }

    private func forgetExpired() {
        let cutoff = now().addingTimeInterval(-RemoteTaskActionPolicy.duplicateRequestWindow)
        remembered = remembered.filter { $0.value.finishedAt > cutoff }
    }

    private func run(_ request: RemoteTaskActionRequest, deviceID: UUID) async -> RemoteTaskActionResult {
        // Checks the device and the task's current list, now and again after
        // each wait, so neither a revoked device nor a stale request acts.
        func stillAllowed() throws {
            guard deviceMayAct(deviceID) else { throw Refusal(reason: .permissionDenied) }
            if case .failure(let refusal) = offered(
                request.action, taskID: request.taskID, expectedPullRequestNumber: request.expectedPullRequestNumber
            ) {
                throw refusal
            }
        }
        guard let coordinator = coordinator() else { return .rejected(reason: .tasksUnavailable, message: nil) }
        let taskID = request.taskID
        do {
            try stillAllowed()
            switch request.action {
            case .merge:
                // The Merge button's call: tasks.toml picks the agent's check
                // or a direct merge.
                try coordinator.requestMerge(taskID: taskID)
            case .markDone:
                // Mark Done and Complete Task: done, and the task space
                // closes. The phone asked the user already.
                try TaskActions.complete(taskID: taskID, coordinator: coordinator, confirm: { _, _ in true })
            case .archive:
                let check = try await coordinator.archiveCheck(taskID: taskID)
                if let blocked = Self.archiveBlockedReason(check) {
                    return .rejected(reason: .needsMac, message: blocked)
                }
                // Discarding changes and deleting unpushed commits stay on
                // the Mac; the archive's own checks refuse both again. Its
                // last check, after git, also confirms the device and the
                // pull request it may close.
                try await coordinator.archive(
                    taskID: taskID,
                    options: TaskArchiveOptions(
                        closePullRequest: request.closePullRequest && check.pullRequest != nil,
                        deleteUnpushedCommits: false,
                        discardChanges: false
                    ),
                    finalCheck: stillAllowed
                )
            case .cancelMerge:
                try coordinator.cancelMerge(taskID: taskID)
            case .cleanUp:
                // A stopped archive retries with the options chosen when it
                // started. Discarding or deleting stays on the Mac.
                if let cleanup = coordinator.records.record(id: taskID)?.cleanup, cleanup.kind == .archive,
                   let options = cleanup.archiveOptions, options.discardChanges || options.deleteUnpushedCommits {
                    return .rejected(
                        reason: .needsMac,
                        message: "This archive was started on the Mac to discard changes or delete commits. Clean it up on the Mac."
                    )
                }
                try coordinator.retryCleanup(taskID: taskID)
            case .keepAsIs:
                try coordinator.dismissCleanup(taskID: taskID)
            case .retry:
                try coordinator.retry(taskID: taskID)
            case .delete:
                try coordinator.delete(taskID: taskID)
            }
        } catch let refusal as Refusal {
            return .rejected(reason: refusal.reason, message: refusal.message)
        } catch let error as TaskError {
            return .rejected(reason: .failed, message: error.message)
        } catch {
            // Only the task code's own messages go to the device; another
            // error can carry paths or system detail.
            return .rejected(reason: .failed, message: nil)
        }
        ToasttyLog.info("Ran a task action from a remote device", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "action": request.action.rawValue,
        ])
        return .performed
    }

    // MARK: - Release

    /// Starts a release of the project, as the Mac's Release button does.
    /// The device's request ID is saved on the release task, so a repeat
    /// answers with that task and starts nothing, also after a restart.
    /// Nothing here waits, so a second request runs only after the first
    /// saved its task, and the coordinator then refuses it as under way.
    func release(_ request: RemoteProjectReleaseRequest, device: RemoteDeviceRecord) -> RemoteProjectReleaseResult {
        guard let coordinator = coordinator() else { return .rejected(reason: .tasksUnavailable, message: nil) }
        guard deviceMayRelease(device.id) else { return .rejected(reason: .permissionDenied, message: nil) }
        let record: TaskRecord
        do {
            record = try coordinator.release(
                workspaceID: request.workspaceID,
                caller: .remoteDevice(device.id),
                clientRequestID: request.clientRequestID
            )
        } catch let error as TaskError {
            let reason: RemoteProjectReleaseRejectionReason = switch error.reason {
            case .workspaceNotFound: .projectNotFound
            case .releaseNotConfigured: .notReleasable
            case .releaseUnderWay: .releaseUnderWay
            case nil: .failed
            }
            ToasttyLog.info("A paired device's release was refused", category: .tasks, metadata: [
                "device_id": device.id.uuidString,
                "reason": reason.rawValue,
            ])
            // The phone words the first two itself; the not-configured
            // message names a local path.
            let message = reason == .releaseUnderWay || reason == .failed ? RemoteTaskCreator.failureMessage(error) : nil
            return .rejected(reason: reason, message: message)
        } catch {
            return .rejected(reason: .failed, message: nil)
        }
        ToasttyLog.info("Started a release from a paired device", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "device_id": device.id.uuidString,
        ])
        return .started(taskID: record.id)
    }

    // MARK: - Archive check

    func archiveCheck(_ request: RemoteTaskArchiveCheckRequest) async -> RemoteTaskArchiveCheckResult {
        if case .failure(let refusal) = offered(.archive, taskID: request.taskID, expectedPullRequestNumber: nil) {
            return .rejected(reason: refusal.reason, message: refusal.message)
        }
        guard let coordinator = coordinator() else { return .rejected(reason: .tasksUnavailable, message: nil) }
        let check: TaskArchiveCheck
        do {
            check = try await coordinator.archiveCheck(taskID: request.taskID)
        } catch let error as TaskError {
            return .rejected(reason: .failed, message: error.message)
        } catch {
            return .rejected(reason: .failed, message: nil)
        }
        let record = coordinator.records.record(id: request.taskID)
        return .ready(RemoteTaskArchiveCheck(
            closesTaskSpace: record?.taskSpaceWorkspaceID.flatMap { coordinator.store.state.workspacesByID[$0] } != nil,
            agentSessions: check.agentSessions,
            removesWorktree: check.hasWorktree,
            uncommittedFiles: check.uncommittedFiles,
            branch: check.branch,
            unpushedCommits: check.unpushedCommits,
            orphanedCommits: check.orphanedCommits,
            unsavedDocuments: check.unsavedDocuments,
            pullRequest: check.pullRequest.flatMap { link in
                URL(string: link.url).map { RemoteTaskPullRequest(number: link.number, url: $0) }
            },
            blockedReason: Self.archiveBlockedReason(check)
        ))
    }

    /// Why a remote device may not archive: the archive would need a choice
    /// that stays on the Mac. The wording names where to go instead.
    static func archiveBlockedReason(_ check: TaskArchiveCheck) -> String? {
        if check.unsavedDocuments > 0 {
            return "The task space has unsaved documents. Save or close them on the Mac, then archive."
        }
        if check.uncommittedFiles > 0 {
            let files = check.uncommittedFiles == 1 ? "1 uncommitted file" : "\(check.uncommittedFiles) uncommitted files"
            return "The worktree has \(files). Commit and push them, or archive on the Mac to discard them."
        }
        if check.orphanedCommits > 0 {
            let commits = check.orphanedCommits == 1 ? "1 commit" : "\(check.orphanedCommits) commits"
            return "The worktree's HEAD has \(commits) on no branch, remote branch or tag. "
                + "Push or branch them, or archive on the Mac to delete them."
        }
        return nil
    }

    // MARK: - Offer check

    private struct Refusal: Error {
        var reason: RemoteTaskActionRejectionReason
        var message: String?
    }

    /// The task, when the Mac's current list for it offers `action` and its
    /// pull request is still the one the device showed.
    private func offered(
        _ action: RemoteTaskAction,
        taskID: UUID,
        expectedPullRequestNumber: Int?
    ) -> Result<(item: TaskBoardItem, summary: RemoteTaskSummary), Refusal> {
        guard coordinator() != nil else { return .failure(Refusal(reason: .tasksUnavailable)) }
        guard let current = currentTask(taskID), current.summary.hasRecord else {
            return .failure(Refusal(reason: .taskNotFound))
        }
        if let expectedPullRequestNumber, current.summary.pullRequest?.number != expectedPullRequestNumber {
            return .failure(Refusal(
                reason: .pullRequestChanged,
                message: current.summary.pullRequest.map { "The task's pull request is now PR #\($0.number)." }
                    ?? "The task no longer has a pull request."
            ))
        }
        guard current.summary.offers(action) else {
            // The task's state now, so the device can say what changed.
            return .failure(Refusal(reason: .notOffered, message: current.summary.statusLine))
        }
        return .success(current)
    }
}
