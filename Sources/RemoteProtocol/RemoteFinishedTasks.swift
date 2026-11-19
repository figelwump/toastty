import Foundation

/// The Mac's most recent Done and archived tasks, as it shares them with a
/// paired device, so that a chat's link to one of them shows the task's
/// chip as the Mac's chat does, and the coordinator chat's mention list
/// offers them as the Mac's does.
///
/// The task board lists only the tasks that are not finished, and finished
/// tasks whose task space is still open. Finished tasks build up over months,
/// too many for every session snapshot. The task board carries only
/// `RemoteTaskBoard.finishedTasksRevision`, which changes when this list
/// changes, and a device reads the list from `RemoteFinishedTasksPolicy.path`
/// when the revision is new.
///
/// Each task carries only what its chip, its detail and the mention list
/// show: no path, no message text, and no action.
public struct RemoteFinishedTasks: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Names the list. The Mac makes it from `tasks`, so the same tasks give
    /// the same revision, also after a relaunch.
    public var revision: String
    /// At most `RemoteFinishedTasksPolicy.limit` tasks, the most recently
    /// active first. A task that the board also lists, while its task space
    /// is open, can be here too; a client prefers the board's.
    public var tasks: [RemoteFinishedTask]

    public init(protocolVersion: String = RemoteGatewayProtocol.version, revision: String, tasks: [RemoteFinishedTask]) {
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, revision, tasks
    }

    /// A task this client cannot read, such as one with a value added later,
    /// is left out; the others stay.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        revision = try container.decode(String.self, forKey: .revision)
        tasks = try container.decode([LossyTask].self, forKey: .tasks).compactMap(\.task)
    }

    private struct LossyTask: Decodable {
        let task: RemoteFinishedTask?

        init(from decoder: any Decoder) throws {
            task = try? RemoteFinishedTask(from: decoder)
        }
    }
}

/// A Done or archived task: what a chat's chip for it and the task's detail
/// show.
public struct RemoteFinishedTask: Codable, Equatable, Sendable, Identifiable {
    /// The task's record ID, as a `toastty://task/<id>` link names it.
    public var id: UUID
    public var title: String
    /// `.done` or `.archived`.
    public var group: RemoteTaskGroup
    /// The stage's name and why, and the status line, as the Mac's task
    /// detail shows them: "Done", "merged", "Shipped".
    public var stageTitle: String
    public var stageReason: String
    public var statusLine: String
    /// The task's project, as the board names it: its workspace's title
    /// while it is open, else the name of the project's folder, never the
    /// whole path.
    public var projectTitle: String?
    public var pullRequest: RemoteTaskPullRequest?
    /// When the task finished, as the Mac's mention list reads it: the
    /// record's done time, else its latest change. A device's mention list
    /// shows the Done tasks of the last 14 days before a search. `nil` from
    /// a Mac from before the field: its finished tasks show only for a
    /// search.
    public var doneAt: Date?

    public init(
        id: UUID,
        title: String,
        group: RemoteTaskGroup,
        stageTitle: String,
        stageReason: String,
        statusLine: String,
        projectTitle: String? = nil,
        pullRequest: RemoteTaskPullRequest? = nil,
        doneAt: Date? = nil
    ) {
        self.id = id
        self.title = RemoteTaskSummary.bounded(title)
        self.group = group
        self.stageTitle = RemoteTaskSummary.bounded(stageTitle)
        self.stageReason = RemoteTaskSummary.bounded(stageReason)
        self.statusLine = RemoteTaskSummary.bounded(statusLine)
        self.projectTitle = projectTitle.map(RemoteTaskSummary.bounded)
        self.pullRequest = pullRequest
        self.doneAt = doneAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, group, stageTitle, stageReason, statusLine, projectTitle, pullRequest, doneAt
    }

    /// A pull request this client cannot read, such as one in a state added
    /// later, reads as none and keeps the task; so does a done time it
    /// cannot read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        group = try container.decode(RemoteTaskGroup.self, forKey: .group)
        stageTitle = try container.decode(String.self, forKey: .stageTitle)
        stageReason = try container.decode(String.self, forKey: .stageReason)
        statusLine = try container.decode(String.self, forKey: .statusLine)
        projectTitle = try container.decodeIfPresent(String.self, forKey: .projectTitle)
        pullRequest = (try? container.decodeIfPresent(RemoteTaskPullRequest.self, forKey: .pullRequest)) ?? nil
        doneAt = (try? container.decodeIfPresent(Date.self, forKey: .doneAt)) ?? nil
    }
}

/// Wire contract for reading the Mac's finished tasks.
public enum RemoteFinishedTasksPolicy {
    public static let path = "/api/task.finished"
    /// How many finished tasks the Mac shares: the most recently active. A
    /// link to an older one stays text.
    public static let limit = 200
}
