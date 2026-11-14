import Foundation

/// Wire contract for acting on a task from a remote device.
///
/// The Mac decides which actions a task offers and sends them in each
/// `RemoteTaskSummary`. A client asks for one by name; the Mac checks it
/// against the task's current list again and refuses anything that list does
/// not offer, so a stale snapshot cannot act on an old state.
public enum RemoteTaskActionPolicy {
    public static let actionPath = "/api/task.action"
    public static let archiveCheckPath = "/api/task.archive-check"
    public static let maximumBodyBytes = 2048
    /// How long the Mac remembers an action it ran, so that a repeat with
    /// the same `clientRequestID` returns the first answer and runs nothing.
    /// A client must use a new ID after this window.
    public static let duplicateRequestWindow: TimeInterval = 600
    /// Messages from the Mac hold at most this many characters.
    public static let maximumMessageLength = 280

    public static func isValidClientRequestID(_ value: String) -> Bool {
        RemoteSessionStartPolicy.isValidClientRequestID(value)
    }

    /// Cuts a message past the limit and ends it with "…".
    public static func boundedMessage(_ text: String) -> String {
        guard text.count > maximumMessageLength else { return text }
        return String(text.prefix(maximumMessageLength - 1)) + "…"
    }
}

/// A task action a client may ask the Mac to run. Merge Without Checks and
/// deleting unpushed commits are not here: they stay on the Mac. Release acts
/// on a project, not a task: see `RemoteProjectReleaseRequest`.
public enum RemoteTaskAction: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    /// Merge the task's pull request the way the Mac's Merge button does.
    case merge
    /// Mark the task done and close its task space: the Mac's Mark Done and
    /// Complete Task.
    case markDone = "mark_done"
    /// Close the task without merging, after the archive check.
    case archive
    case cancelMerge = "cancel_merge"
    /// Try a stopped cleanup again.
    case cleanUp = "clean_up"
    /// Leave what a stopped cleanup left behind.
    case keepAsIs = "keep_as_is"
    /// Retry a failed setup, move, or triage.
    case retry
    case delete
}

/// One button or menu item: the action, and the Mac's title for it.
public struct RemoteTaskActionItem: Codable, Equatable, Hashable, Sendable {
    public var action: RemoteTaskAction
    public var title: String

    public init(action: RemoteTaskAction, title: String) {
        self.action = action
        self.title = title
    }
}

/// What the Merge control under a task space's title shows, as the Mac's
/// top bar shows it.
public enum RemoteTaskMergeControlKind: String, Codable, Equatable, Sendable {
    /// "Merge PR #N": the pull request is open and GitHub reports no blocker.
    case merge
    /// "Open PR #N": GitHub reports a blocker, so tapping opens the pull
    /// request; the menu still merges.
    case openPullRequest = "open_pull_request"
    /// "Merging PR #N…": the agent checks, Toastty waits for checks or
    /// merges, cleans up, or closes the pull request.
    case merging
    /// "Complete Task": no pull request, and the agent marked the work ready.
    case completeTask = "complete_task"
    /// "Cleanup Stopped · PR #N": the cleanup after the merge stopped.
    case cleanupStopped = "cleanup_stopped"
    /// "Done · PR #N" or "Done": the task finished and its task space is
    /// still open.
    case done
    /// "Archive Task…": any other stage without a pull request.
    case archive
}

public struct RemoteTaskMergeControl: Codable, Equatable, Sendable {
    public var kind: RemoteTaskMergeControlKind
    public var title: String
    /// Why the control reads as it does: the blocker GitHub reports, or why
    /// the cleanup stopped.
    public var detail: String?
    /// What tapping the control asks the Mac to do. Absent while it opens the
    /// pull request, shows progress, or only opens its menu.
    public var action: RemoteTaskActionItem?
    /// The ▼ menu, in the Mac's order.
    public var menu: [RemoteTaskActionItem]

    public init(
        kind: RemoteTaskMergeControlKind,
        title: String,
        detail: String? = nil,
        action: RemoteTaskActionItem? = nil,
        menu: [RemoteTaskActionItem] = []
    ) {
        self.kind = kind
        self.title = RemoteTaskSummary.bounded(title)
        self.detail = detail.map(RemoteTaskSummary.bounded)
        self.action = action
        self.menu = menu
    }

    /// Every action the control offers, by tap or from its menu.
    public var offeredActions: [RemoteTaskAction] {
        (action.map { [$0.action] } ?? []) + menu.map(\.action)
    }
}

// MARK: - Action

public struct RemoteTaskActionRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// The task's ID, as `RemoteTaskSummary.id` names it.
    public var taskID: UUID
    public var action: RemoteTaskAction
    /// Chosen by the client for one user intent. A retry after an unknown
    /// outcome repeats it, so the Mac runs the action at most once.
    public var clientRequestID: String
    /// The pull request number the client showed. The Mac refuses when the
    /// task's pull request is now a different one.
    public var expectedPullRequestNumber: Int?
    /// Archive only: also close the pull request on GitHub.
    public var closePullRequest: Bool

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        taskID: UUID,
        action: RemoteTaskAction,
        clientRequestID: String,
        expectedPullRequestNumber: Int? = nil,
        closePullRequest: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.taskID = taskID
        self.action = action
        self.clientRequestID = clientRequestID
        self.expectedPullRequestNumber = expectedPullRequestNumber
        self.closePullRequest = closePullRequest
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, taskID, action, clientRequestID, expectedPullRequestNumber, closePullRequest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        action = try container.decode(RemoteTaskAction.self, forKey: .action)
        clientRequestID = try container.decode(String.self, forKey: .clientRequestID)
        expectedPullRequestNumber = try container.decodeIfPresent(Int.self, forKey: .expectedPullRequestNumber)
        closePullRequest = try container.decodeIfPresent(Bool.self, forKey: .closePullRequest) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(action, forKey: .action)
        try container.encode(clientRequestID, forKey: .clientRequestID)
        try container.encodeIfPresent(expectedPullRequestNumber, forKey: .expectedPullRequestNumber)
        if closePullRequest { try container.encode(true, forKey: .closePullRequest) }
    }
}

/// Why the Mac did not run an action or answer an archive check.
public enum RemoteTaskActionRejectionReason: String, Codable, Equatable, Sendable {
    /// The device's Task actions switch is off on the Mac, or it lacks send
    /// access.
    case permissionDenied = "permission_denied"
    case taskNotFound = "task_not_found"
    /// The task's current action list does not offer it: the task moved on
    /// since the client's snapshot.
    case notOffered = "not_offered"
    /// The task's pull request is not the one the client showed.
    case pullRequestChanged = "pull_request_changed"
    /// The archive needs a choice that stays on the Mac, such as discarding
    /// uncommitted changes. The message says what.
    case needsMac = "needs_mac"
    /// The Mac tried and refused or failed. The message says why.
    case failed
    /// Too many actions from this device are under way.
    case busy
    case invalidRequest = "invalid_request"
    /// The Mac's task system is off.
    case tasksUnavailable = "tasks_unavailable"
    /// A reason this client does not know.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteTaskActionResult: Equatable, Sendable {
    /// The Mac ran the action, or started it: a merge, an archive and a
    /// cleanup continue in the background, and the snapshot shows how they go.
    case performed
    case rejected(reason: RemoteTaskActionRejectionReason, message: String?)
    /// The Mac answered with a status this client does not know. Whether
    /// the action ran is not known, so the client must not repeat it under a
    /// new ID as if nothing had run.
    case unrecognized
}

public struct RemoteTaskActionResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteTaskActionResult

    public init(protocolVersion: String = RemoteGatewayProtocol.version, result: RemoteTaskActionResult) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, status, reason, message
    }

    private enum Status: String {
        case performed
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        switch Status(rawValue: try container.decode(String.self, forKey: .status)) {
        case .performed:
            result = .performed
        case .rejected:
            result = .rejected(
                reason: try container.decodeIfPresent(RemoteTaskActionRejectionReason.self, forKey: .reason) ?? .unknown,
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case nil:
            result = .unrecognized
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        switch result {
        case .performed:
            try container.encode(Status.performed.rawValue, forKey: .status)
        case .rejected(let reason, let message):
            try container.encode(Status.rejected.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message.map(RemoteTaskActionPolicy.boundedMessage), forKey: .message)
        case .unrecognized:
            try container.encode("unrecognized", forKey: .status)
        }
    }
}

// MARK: - Archive check

public struct RemoteTaskArchiveCheckRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var taskID: UUID

    public init(protocolVersion: String = RemoteGatewayProtocol.version, taskID: UUID) {
        self.protocolVersion = protocolVersion
        self.taskID = taskID
    }
}

/// What archiving the task would end and lose, read on the Mac before
/// anything changes. The archive sheet shows it.
public struct RemoteTaskArchiveCheck: Codable, Equatable, Sendable {
    /// The archive closes the task space and ends this many agent sessions.
    public var closesTaskSpace: Bool
    public var agentSessions: Int
    public var removesWorktree: Bool
    /// Changed, staged or untracked files in the worktree.
    public var uncommittedFiles: Int
    /// The task's local branch, kept while it has commits no remote has.
    public var branch: String?
    public var unpushedCommits: Int
    /// Commits at the worktree's HEAD on no branch, remote branch or tag.
    public var orphanedCommits: Int
    public var unsavedDocuments: Int
    /// The pull request the archive can close on GitHub.
    public var pullRequest: RemoteTaskPullRequest?
    /// Why the client may not archive, worded by the Mac: a choice that
    /// stays on the Mac, such as discarding uncommitted changes. `nil` when
    /// the client may archive.
    public var blockedReason: String?

    public init(
        closesTaskSpace: Bool,
        agentSessions: Int,
        removesWorktree: Bool,
        uncommittedFiles: Int,
        branch: String?,
        unpushedCommits: Int,
        orphanedCommits: Int,
        unsavedDocuments: Int,
        pullRequest: RemoteTaskPullRequest?,
        blockedReason: String?
    ) {
        self.closesTaskSpace = closesTaskSpace
        self.agentSessions = agentSessions
        self.removesWorktree = removesWorktree
        self.uncommittedFiles = uncommittedFiles
        self.branch = branch.map(RemoteTaskSummary.bounded)
        self.unpushedCommits = unpushedCommits
        self.orphanedCommits = orphanedCommits
        self.unsavedDocuments = unsavedDocuments
        self.pullRequest = pullRequest
        self.blockedReason = blockedReason.map(RemoteTaskActionPolicy.boundedMessage)
    }
}

public enum RemoteTaskArchiveCheckResult: Equatable, Sendable {
    case ready(RemoteTaskArchiveCheck)
    case rejected(reason: RemoteTaskActionRejectionReason, message: String?)
    case unrecognized
}

public struct RemoteTaskArchiveCheckResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteTaskArchiveCheckResult

    public init(protocolVersion: String = RemoteGatewayProtocol.version, result: RemoteTaskArchiveCheckResult) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, status, check, reason, message
    }

    private enum Status: String {
        case ready
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        switch Status(rawValue: try container.decode(String.self, forKey: .status)) {
        case .ready:
            result = .ready(try container.decode(RemoteTaskArchiveCheck.self, forKey: .check))
        case .rejected:
            result = .rejected(
                reason: try container.decodeIfPresent(RemoteTaskActionRejectionReason.self, forKey: .reason) ?? .unknown,
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case nil:
            result = .unrecognized
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        switch result {
        case .ready(let check):
            try container.encode(Status.ready.rawValue, forKey: .status)
            try container.encode(check, forKey: .check)
        case .rejected(let reason, let message):
            try container.encode(Status.rejected.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message.map(RemoteTaskActionPolicy.boundedMessage), forKey: .message)
        case .unrecognized:
            try container.encode("unrecognized", forKey: .status)
        }
    }
}
