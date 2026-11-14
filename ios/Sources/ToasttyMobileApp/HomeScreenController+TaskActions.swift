import Foundation
import RemoteProtocol
import ToasttyMobileDomain

/// What came back from asking the Mac to run a task action or start a
/// release.
enum ToasttyRemoteSendOutcome<Answer: Equatable & Sendable>: Equatable, Sendable {
    case answered(Answer)
    /// Nothing was sent: the connection is not live, or the Mac does not
    /// take the request.
    case notSent
    /// The request went out and no answer came back, so whether the Mac ran
    /// it is not known.
    case unconfirmed
}

typealias ToasttyTaskActionSendOutcome = ToasttyRemoteSendOutcome<RemoteTaskActionResult>
typealias ToasttyProjectReleaseSendOutcome = ToasttyRemoteSendOutcome<RemoteProjectReleaseResult>

enum ToasttyTaskArchiveCheckOutcome: Equatable, Sendable {
    case answered(RemoteTaskArchiveCheckResult)
    case unreachable
}

/// What the phone tells the user when a task action did not run.
struct ToasttyTaskActionFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

extension HomeScreenController {
    /// Task actions work only against a live Mac that takes them from this
    /// device. Otherwise the task bar shows its state read-only.
    var canActOnTasks: Bool {
        hostSupportsTaskActions && freshness == .live
    }

    func setHostSupportsTaskActions(_ isSupported: Bool) {
        hostSupportsTaskActions = isSupported
    }

    func installTaskActions(
        perform: @escaping @MainActor (RemoteTaskActionRequest) async -> ToasttyTaskActionSendOutcome,
        archiveCheck: @escaping @MainActor (RemoteTaskArchiveCheckRequest) async -> ToasttyTaskArchiveCheckOutcome
    ) {
        sendTaskAction = perform
        loadTaskArchiveCheck = archiveCheck
    }

    func isTaskActionInFlight(_ taskID: UUID) -> Bool {
        tasksWithActionInFlight.contains(taskID)
    }

    /// Asks the Mac to run `item` on `task`, as the user chose it on the
    /// phone. One request ID covers the user's tap: a request whose answer
    /// was lost goes once more under the same ID, so the Mac runs it at most
    /// once. Returns why the action did not run, or `nil` once the Mac ran
    /// or started it.
    func performTaskAction(
        _ item: RemoteTaskActionItem,
        on task: RemoteTaskSummary,
        closePullRequest: Bool = false
    ) async -> ToasttyTaskActionFailure? {
        let failureTitle = "Couldn\u{2019}t \(Self.verb(item)) \u{201C}\(task.title)\u{201D}"
        guard canActOnTasks else {
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Toastty isn\u{2019}t connected to a Mac that takes task actions from this iPhone."
            )
        }
        // A second tap while the first request is on its way does nothing.
        guard tasksWithActionInFlight.insert(task.id).inserted else { return nil }
        defer { tasksWithActionInFlight.remove(task.id) }
        let request = RemoteTaskActionRequest(
            taskID: task.id,
            action: item.action,
            clientRequestID: UUID().uuidString,
            // The Mac refuses when the task's pull request is no longer the
            // one this phone showed, as in the merge confirmation.
            expectedPullRequestNumber: task.pullRequest?.number,
            closePullRequest: item.action == .archive && closePullRequest
        )
        let outcome = await sendRetryingOnce(
            { await self.sendTaskActionRequest(request) },
            isPermissionRefusal: { if case .rejected(.permissionDenied, _) = $0 { true } else { false } }
        )
        switch outcome {
        case .answered(.performed):
            announceTaskAction(Self.performedMessage(item.action, task: task))
            return nil
        case .answered(.rejected(let reason, let message)):
            return ToasttyTaskActionFailure(title: failureTitle, message: Self.message(for: reason, macMessage: message))
        case .answered(.unrecognized):
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Your Mac answered in a way this app does not understand. Check the task on your Mac before trying again."
            )
        case .unconfirmed:
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Toastty couldn\u{2019}t confirm whether your Mac did this. Check the task before trying again."
            )
        case .notSent:
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Toastty couldn\u{2019}t reach your Mac, so nothing was sent. Try again when it reconnects."
            )
        }
    }

    /// Sends once, and once more under the same request ID when the first
    /// try was not sent or not answered. A first try that went out keeps its
    /// unknown outcome when the retry was not sent, or was refused for
    /// permission before the Mac could look the request up: the first may
    /// still have run.
    private func sendRetryingOnce<Answer>(
        _ send: () async -> ToasttyRemoteSendOutcome<Answer>,
        isPermissionRefusal: (Answer) -> Bool
    ) async -> ToasttyRemoteSendOutcome<Answer> {
        var outcome = await send()
        switch outcome {
        case .notSent, .unconfirmed:
            try? await Task.sleep(for: taskActionRetryDelay)
            let retried = await send()
            switch (outcome, retried) {
            case (.unconfirmed, .notSent):
                break
            case (.unconfirmed, .answered(let answer)) where isPermissionRefusal(answer):
                break
            default:
                outcome = retried
            }
        case .answered:
            break
        }
        return outcome
    }

    /// Reads what archiving the task would end and lose, before the archive
    /// sheet offers it.
    func taskArchiveCheck(taskID: UUID) async -> ToasttyTaskArchiveCheckOutcome {
        let request = RemoteTaskArchiveCheckRequest(taskID: taskID)
        if let loadTaskArchiveCheck {
            return await loadTaskArchiveCheck(request)
        }
        guard runtimeMode == .fixture else { return .unreachable }
        try? await Task.sleep(for: .milliseconds(300))
        let board = hostSnapshot.taskBoard?.source ?? RemoteTaskBoard()
        return .answered(ToasttyMobileFixture.archiveCheck(taskID: taskID, board: board))
    }

    private func sendTaskActionRequest(_ request: RemoteTaskActionRequest) async -> ToasttyTaskActionSendOutcome {
        if let sendTaskAction {
            return await sendTaskAction(request)
        }
        guard runtimeMode == .fixture else { return .notSent }
        // Fixture mode has no Mac: the fixture answers and changes the board
        // after a pause that stands in for the round trip.
        try? await Task.sleep(for: .milliseconds(400))
        let board = hostSnapshot.taskBoard?.source ?? RemoteTaskBoard()
        let answer = ToasttyMobileFixture.applyTaskAction(request, to: board)
        applyFixtureHostSnapshot { snapshot in
            var workspaces = snapshot.workspaces
            if let closed = answer.closedTaskSpaceID {
                workspaces.removeAll { $0.id == closed }
            }
            return MobileHomeSnapshot(hostName: snapshot.hostName, workspaces: workspaces, taskBoard: MobileTaskBoard(answer.board))
        }
        return .answered(answer.result)
    }

    // MARK: - Release

    /// A release works only against a live Mac that starts releases for
    /// this device.
    var canReleaseProjects: Bool {
        hostSupportsProjectRelease && freshness == .live
    }

    func setHostSupportsProjectRelease(_ isSupported: Bool) {
        hostSupportsProjectRelease = isSupported
    }

    func installProjectRelease(
        perform: @escaping @MainActor (RemoteProjectReleaseRequest) async -> ToasttyProjectReleaseSendOutcome
    ) {
        sendProjectRelease = perform
    }

    func isProjectReleaseInFlight(_ release: MobileProjectRelease) -> Bool {
        projectReleasesInFlight.contains(release.laneID)
    }

    /// Asks the Mac to start a release of the project, after the user said
    /// yes. One request ID covers the tap, as for a task action, so a
    /// request whose answer was lost goes once more and the Mac answers with
    /// the release it started. Returns why no release started, or `nil`
    /// once the Mac started one; the board then lists its task.
    func releaseProject(_ release: MobileProjectRelease) async -> ToasttyTaskActionFailure? {
        let failureTitle = "Couldn\u{2019}t release \u{201C}\(release.projectTitle)\u{201D}"
        guard canReleaseProjects else {
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Toastty isn\u{2019}t connected to a Mac that starts releases from this iPhone."
            )
        }
        guard projectReleasesInFlight.insert(release.laneID).inserted else { return nil }
        defer { projectReleasesInFlight.remove(release.laneID) }
        let request = RemoteProjectReleaseRequest(workspaceID: release.workspaceID, clientRequestID: UUID().uuidString)
        let outcome = await sendRetryingOnce(
            { await self.sendProjectReleaseRequest(request) },
            isPermissionRefusal: { if case .rejected(.permissionDenied, _) = $0 { true } else { false } }
        )
        switch outcome {
        case .answered(.started):
            announceTaskAction("Starting a release of \u{201C}\(release.projectTitle)\u{201D} on your Mac.")
            return nil
        case .answered(.rejected(let reason, let message)):
            return ToasttyTaskActionFailure(title: failureTitle, message: Self.message(for: reason, macMessage: message))
        case .answered(.unrecognized):
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Your Mac answered in a way this app does not understand. Check Tasks on your Mac before trying again."
            )
        case .unconfirmed:
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Toastty couldn\u{2019}t confirm whether your Mac started the release. Check Tasks before trying again."
            )
        case .notSent:
            return ToasttyTaskActionFailure(
                title: failureTitle,
                message: "Toastty couldn\u{2019}t reach your Mac, so nothing was sent. Try again when it reconnects."
            )
        }
    }

    private func sendProjectReleaseRequest(_ request: RemoteProjectReleaseRequest) async -> ToasttyProjectReleaseSendOutcome {
        if let sendProjectRelease {
            return await sendProjectRelease(request)
        }
        guard runtimeMode == .fixture else { return .notSent }
        // As for a task action: the fixture answers and starts the release
        // task on its board after a pause.
        try? await Task.sleep(for: .milliseconds(400))
        let board = hostSnapshot.taskBoard?.source ?? RemoteTaskBoard()
        let answer = ToasttyMobileFixture.applyProjectRelease(request, to: board)
        applyFixtureHostSnapshot { snapshot in
            MobileHomeSnapshot(hostName: snapshot.hostName, workspaces: snapshot.workspaces, taskBoard: MobileTaskBoard(answer.board))
        }
        return .answered(answer.result)
    }

    /// Why the Mac did not start a release, for the user.
    static func message(for reason: RemoteProjectReleaseRejectionReason, macMessage: String?) -> String {
        switch reason {
        case .permissionDenied:
            return "A release from this iPhone needs both Task actions and Start sessions on for it in Toastty Settings > "
                + "Remote Access on your Mac. Turn them on, then try again."
        case .projectNotFound:
            return "The project is no longer open on your Mac."
        case .notReleasable:
            return "This project has no release skill or release prompt. Set release_skill or release_prompt for it in "
                + "~/.toastty/tasks.toml on your Mac."
        case .releaseUnderWay:
            return macMessage ?? "A release of this project is already under way."
        case .failed:
            return macMessage ?? "Your Mac could not start the release."
        case .invalidRequest:
            return "Your Mac did not accept the request. Update Toastty on both devices."
        case .tasksUnavailable:
            return "Tasks are turned off on your Mac."
        case .unknown:
            return macMessage ?? "Your Mac refused the release."
        }
    }

    // MARK: - Wording

    /// The verb a failure title uses, from the Mac's item title.
    static func verb(_ item: RemoteTaskActionItem) -> String {
        switch item.action {
        case .merge: "merge"
        case .markDone: "complete"
        case .archive: "archive"
        case .cancelMerge: "cancel the merge of"
        case .cleanUp: "clean up"
        case .keepAsIs: "keep"
        case .retry: "retry"
        case .delete: "delete"
        }
    }

    static func performedMessage(_ action: RemoteTaskAction, task: RemoteTaskSummary) -> String {
        let title = "\u{201C}\(task.title)\u{201D}"
        switch action {
        case .merge:
            return task.pullRequest.map { "Merging PR #\($0.number) on your Mac." } ?? "Merging \(title) on your Mac."
        case .markDone: return "\(title) is done."
        case .archive: return "Archiving \(title) on your Mac."
        case .cancelMerge: return "Cancelled the merge of \(title)."
        case .cleanUp: return "Cleaning up \(title) on your Mac."
        case .keepAsIs: return "Left \(title) as it is."
        case .retry: return "Retrying \(title) on your Mac."
        case .delete: return "Deleted \(title)."
        }
    }

    /// Why the Mac did not run an action, for the user. The Mac's own
    /// message says what changed or what failed.
    static func message(for reason: RemoteTaskActionRejectionReason, macMessage: String?) -> String {
        switch reason {
        case .permissionDenied:
            return "Turn on Task actions for this iPhone in Toastty Settings > Remote Access on your Mac, then try again."
        case .taskNotFound:
            return "Your Mac no longer has this task."
        case .notOffered:
            return macMessage.map { "The task changed on your Mac. It now reads: \($0)." }
                ?? "The task changed on your Mac. Check it and try again."
        case .pullRequestChanged:
            return ["The task\u{2019}s pull request changed on your Mac.", macMessage].compactMap { $0 }.joined(separator: " ")
        case .needsMac:
            return macMessage ?? "Finish this on your Mac."
        case .failed:
            return macMessage ?? "Your Mac could not do this."
        case .busy:
            return "Your Mac is busy with other task actions. Try again in a moment."
        case .invalidRequest:
            return "Your Mac did not accept the request. Update Toastty on both devices."
        case .tasksUnavailable:
            return "Tasks are turned off on your Mac."
        case .unknown:
            return macMessage ?? "Your Mac refused the action."
        }
    }
}
