import Foundation

/// The Mac's task board, for a client that shows tasks. The Mac computes
/// each task's stage, its wording, and the board's groups, so the
/// Mac and the client always agree. The session snapshot carries it when the
/// host advertises `tasks`; it is absent while the task system is off and
/// from older hosts.
public struct RemoteTaskBoard: Codable, Equatable, Sendable {
    /// The tasks the groups below name, every task that waits to ship, and
    /// every task whose task space is open, in the Mac sidebar's order.
    public var tasks: [RemoteTaskSummary]
    /// The board's row groups. Each lists a task under the task
    /// that started it, in the group of the more urgent of the two.
    public var needsYou: [RemoteTaskBoardEntry]
    public var running: [RemoteTaskBoardEntry]
    public var idle: [RemoteTaskBoardEntry]
    /// One lane for each project with merged tasks that wait for a release.
    public var toShip: [RemoteTaskShipLane]
    public var doneCount: Int
    /// The finished tasks of each open project, which leave its card.
    public var finishedByProject: [RemoteTaskProjectTally]

    public init(
        tasks: [RemoteTaskSummary] = [],
        needsYou: [RemoteTaskBoardEntry] = [],
        running: [RemoteTaskBoardEntry] = [],
        idle: [RemoteTaskBoardEntry] = [],
        toShip: [RemoteTaskShipLane] = [],
        doneCount: Int = 0,
        finishedByProject: [RemoteTaskProjectTally] = []
    ) {
        self.tasks = tasks
        self.needsYou = needsYou
        self.running = running
        self.idle = idle
        self.toShip = toShip
        self.doneCount = doneCount
        self.finishedByProject = finishedByProject
    }
}

/// One row of a Status group.
public struct RemoteTaskBoardEntry: Codable, Equatable, Sendable {
    /// A `RemoteTaskSummary.id` in the same board.
    public var taskID: UUID
    /// Drawn under the task that started it.
    public var isLinkedChild: Bool
    /// Drawn dimmed: the task's own stage is in a calmer group, and it lists
    /// here to keep its family together.
    public var isContext: Bool

    public init(taskID: UUID, isLinkedChild: Bool = false, isContext: Bool = false) {
        self.taskID = taskID
        self.isLinkedChild = isLinkedChild
        self.isContext = isContext
    }
}

/// A project's merged tasks that wait for a release.
public struct RemoteTaskShipLane: Codable, Equatable, Sendable, Identifiable {
    /// The project's root directory, else its title. A lane groups by
    /// root, so its tasks can belong to more than one project workspace, or
    /// to none that is open. A client finds a project's To ship tasks by
    /// each task's `projectWorkspaceID`, as the Mac's project card does.
    public var id: String
    public var projectTitle: String
    public var count: Int
    /// The lane's most recently merged tasks, newest first; at most a few.
    /// Kept for older clients; `taskIDs` lists them all.
    public var recentTaskIDs: [UUID]
    /// Every task in the lane, newest merge first. The board's `tasks`
    /// lists each of them. Absent from older hosts, which send only
    /// `recentTaskIDs`.
    public var taskIDs: [UUID]?
    /// The project workspace that a release of this lane starts in, as the
    /// Mac's Release button uses it. A client sends it in
    /// `RemoteProjectReleaseRequest`. Absent when the project cannot release
    /// from Toastty or is not open, and from older hosts.
    public var releaseWorkspaceID: UUID?
    /// The project's release task while it runs: from its start until it
    /// ships, is done, or is archived. The Mac starts no second release of
    /// the project meanwhile. Absent otherwise, and from older hosts.
    public var releaseTaskID: UUID?

    public init(
        id: String,
        projectTitle: String,
        count: Int,
        recentTaskIDs: [UUID] = [],
        taskIDs: [UUID]? = nil,
        releaseWorkspaceID: UUID? = nil,
        releaseTaskID: UUID? = nil
    ) {
        self.id = id
        self.projectTitle = projectTitle
        self.count = count
        self.recentTaskIDs = recentTaskIDs
        self.taskIDs = taskIDs
        self.releaseWorkspaceID = releaseWorkspaceID
        self.releaseTaskID = releaseTaskID
    }
}

public struct RemoteTaskProjectTally: Codable, Equatable, Sendable {
    public var projectWorkspaceID: UUID
    public var toShipCount: Int
    public var doneCount: Int

    public init(projectWorkspaceID: UUID, toShipCount: Int, doneCount: Int) {
        self.projectWorkspaceID = projectWorkspaceID
        self.toShipCount = toShipCount
        self.doneCount = doneCount
    }
}

/// Where a task stands. The group follows the task's own stage.
public enum RemoteTaskGroup: String, Codable, Equatable, Sendable {
    case needsYou = "needs_you"
    case running
    case idle
    case toShip = "to_ship"
    case done
    case archived
}

/// What a task's stage adds to its task space's status mark. An agent that
/// works, waits for approval, or stopped with an error still shows first;
/// without a mark, the task space's sessions decide.
public enum RemoteTaskMark: String, Codable, Equatable, Sendable {
    /// The agent asked the user a question and waits for the reply.
    case question
    /// A pull request, or work marked ready, waits for the user's review.
    case review
    case toShip = "to_ship"
    case done
    /// Setup or the move into a worktree is under way.
    case starting
}

public enum RemoteTaskPullRequestState: String, Codable, Equatable, Sendable {
    case open
    case draft
    case merged
    case closed
}

public struct RemoteTaskPullRequest: Codable, Equatable, Sendable {
    public var number: Int
    public var url: URL
    /// Absent until the Mac has asked GitHub.
    public var state: RemoteTaskPullRequestState?

    public init(number: Int, url: URL, state: RemoteTaskPullRequestState? = nil) {
        self.number = number
        self.url = url
        self.state = state
    }
}

/// How many of a parent task's child tasks have merged, as the Mac's
/// sidebar labels a parent's row: "2/3 merged". Archived children do not
/// count.
public struct RemoteTaskChildProgress: Codable, Equatable, Sendable {
    /// Children that are To ship or Done.
    public var merged: Int
    public var total: Int

    public init(merged: Int, total: Int) {
        self.merged = merged
        self.total = total
    }
}

public struct RemoteTaskSummary: Codable, Equatable, Sendable, Identifiable {
    /// Text fields hold at most this many characters.
    public static let maximumTextLength = 280

    /// The task's ID, or the workspace ID of a task space that Toastty only
    /// watches because it has no task record.
    public var id: UUID
    /// A watched task space has no record, and so no task actions.
    public var hasRecord: Bool
    public var title: String
    public var group: RemoteTaskGroup
    public var mark: RemoteTaskMark?
    /// One line on what the task is doing or waiting for, as the Mac's
    /// Status rows word it.
    public var statusLine: String
    /// Replaces the sessions' summary on the task space's row: the agent's
    /// question, or how setup is going.
    public var rowSummary: String?
    /// The stage's name and why, as the Mac's task detail shows them.
    public var stageTitle: String
    public var stageReason: String
    public var projectWorkspaceID: UUID?
    public var projectTitle: String?
    /// The task space while it is open.
    public var taskSpaceWorkspaceID: UUID?
    public var pullRequest: RemoteTaskPullRequest?
    /// The latest change the Mac knows of.
    public var activityAt: Date
    /// The Merge control under the task space's title, as the Mac's top bar
    /// shows it. Present while the task space is open; absent from older
    /// hosts.
    public var mergeControl: RemoteTaskMergeControl?
    /// The actions the Mac's task menu and detail offer now, in its order.
    /// Actions that stay on the Mac are left out. A client acts only on a
    /// host that advertises `task_actions`.
    public var actions: [RemoteTaskActionItem]
    /// When the user asked to release this task right after it merges,
    /// while the Mac's rows mark it: until the task is Done or archived.
    /// Absent without a request, and from older hosts.
    public var releaseAfterMergeRequestedAt: Date?
    /// The task that started this one, with its title, while the Mac still
    /// has it. The title travels with the ID because a Done or archived
    /// parent is not on the board. Absent from older hosts.
    public var parentTaskID: UUID?
    public var parentTaskTitle: String?
    /// Present on a parent task with child tasks that are not archived.
    /// Absent from older hosts.
    public var childProgress: RemoteTaskChildProgress?

    public init(
        id: UUID,
        hasRecord: Bool = true,
        title: String,
        group: RemoteTaskGroup,
        mark: RemoteTaskMark? = nil,
        statusLine: String,
        rowSummary: String? = nil,
        stageTitle: String,
        stageReason: String,
        projectWorkspaceID: UUID? = nil,
        projectTitle: String? = nil,
        taskSpaceWorkspaceID: UUID? = nil,
        pullRequest: RemoteTaskPullRequest? = nil,
        activityAt: Date,
        mergeControl: RemoteTaskMergeControl? = nil,
        actions: [RemoteTaskActionItem] = [],
        releaseAfterMergeRequestedAt: Date? = nil,
        parentTaskID: UUID? = nil,
        parentTaskTitle: String? = nil,
        childProgress: RemoteTaskChildProgress? = nil
    ) {
        self.id = id
        self.hasRecord = hasRecord
        self.title = Self.bounded(title)
        self.group = group
        self.mark = mark
        self.statusLine = Self.bounded(statusLine)
        self.rowSummary = rowSummary.map(Self.bounded)
        self.stageTitle = Self.bounded(stageTitle)
        self.stageReason = Self.bounded(stageReason)
        self.projectWorkspaceID = projectWorkspaceID
        self.projectTitle = projectTitle.map(Self.bounded)
        self.taskSpaceWorkspaceID = taskSpaceWorkspaceID
        self.pullRequest = pullRequest
        self.activityAt = activityAt
        self.mergeControl = mergeControl
        self.actions = actions
        self.releaseAfterMergeRequestedAt = releaseAfterMergeRequestedAt
        self.parentTaskID = parentTaskID
        self.parentTaskTitle = parentTaskTitle.map(Self.bounded)
        self.childProgress = childProgress
    }

    private enum CodingKeys: String, CodingKey {
        case id, hasRecord, title, group, mark, statusLine, rowSummary, stageTitle, stageReason
        case projectWorkspaceID, projectTitle, taskSpaceWorkspaceID, pullRequest, activityAt, mergeControl, actions
        case releaseAfterMergeRequestedAt, parentTaskID, parentTaskTitle, childProgress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        hasRecord = try container.decode(Bool.self, forKey: .hasRecord)
        title = try container.decode(String.self, forKey: .title)
        group = try container.decode(RemoteTaskGroup.self, forKey: .group)
        mark = try container.decodeIfPresent(RemoteTaskMark.self, forKey: .mark)
        statusLine = try container.decode(String.self, forKey: .statusLine)
        rowSummary = try container.decodeIfPresent(String.self, forKey: .rowSummary)
        stageTitle = try container.decode(String.self, forKey: .stageTitle)
        stageReason = try container.decode(String.self, forKey: .stageReason)
        projectWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .projectWorkspaceID)
        projectTitle = try container.decodeIfPresent(String.self, forKey: .projectTitle)
        taskSpaceWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .taskSpaceWorkspaceID)
        pullRequest = try container.decodeIfPresent(RemoteTaskPullRequest.self, forKey: .pullRequest)
        activityAt = try container.decode(Date.self, forKey: .activityAt)
        mergeControl = try container.decodeIfPresent(RemoteTaskMergeControl.self, forKey: .mergeControl)
        actions = try container.decodeIfPresent([RemoteTaskActionItem].self, forKey: .actions) ?? []
        releaseAfterMergeRequestedAt = try container.decodeIfPresent(Date.self, forKey: .releaseAfterMergeRequestedAt)
        parentTaskID = try container.decodeIfPresent(UUID.self, forKey: .parentTaskID)
        parentTaskTitle = try container.decodeIfPresent(String.self, forKey: .parentTaskTitle)
        childProgress = try container.decodeIfPresent(RemoteTaskChildProgress.self, forKey: .childProgress)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hasRecord, forKey: .hasRecord)
        try container.encode(title, forKey: .title)
        try container.encode(group, forKey: .group)
        try container.encodeIfPresent(mark, forKey: .mark)
        try container.encode(statusLine, forKey: .statusLine)
        try container.encodeIfPresent(rowSummary, forKey: .rowSummary)
        try container.encode(stageTitle, forKey: .stageTitle)
        try container.encode(stageReason, forKey: .stageReason)
        try container.encodeIfPresent(projectWorkspaceID, forKey: .projectWorkspaceID)
        try container.encodeIfPresent(projectTitle, forKey: .projectTitle)
        try container.encodeIfPresent(taskSpaceWorkspaceID, forKey: .taskSpaceWorkspaceID)
        try container.encodeIfPresent(pullRequest, forKey: .pullRequest)
        try container.encode(activityAt, forKey: .activityAt)
        try container.encodeIfPresent(mergeControl, forKey: .mergeControl)
        if actions.isEmpty == false { try container.encode(actions, forKey: .actions) }
        try container.encodeIfPresent(releaseAfterMergeRequestedAt, forKey: .releaseAfterMergeRequestedAt)
        try container.encodeIfPresent(parentTaskID, forKey: .parentTaskID)
        try container.encodeIfPresent(parentTaskTitle, forKey: .parentTaskTitle)
        try container.encodeIfPresent(childProgress, forKey: .childProgress)
    }

    /// Whether the Mac offers `action` for this task now: in its action
    /// list or in its Merge control.
    public func offers(_ action: RemoteTaskAction) -> Bool {
        actions.contains { $0.action == action } || mergeControl?.offeredActions.contains(action) == true
    }

    /// Cuts text past the limit and ends it with "…".
    public static func bounded(_ text: String) -> String {
        guard text.count > maximumTextLength else { return text }
        return String(text.prefix(maximumTextLength - 1)) + "…"
    }
}
