import Foundation
import RemoteProtocol

/// The Mac's task board as Home reads it: each task by ID and by task
/// space, the Status groups, and what finished in each project. The Mac
/// computes every stage and word; the phone only looks them up.
public struct MobileTaskBoard: Equatable, Sendable {
    public let tasks: [RemoteTaskSummary]
    public let needsYou: [RemoteTaskBoardEntry]
    public let running: [RemoteTaskBoardEntry]
    public let idle: [RemoteTaskBoardEntry]
    public let toShip: [RemoteTaskShipLane]
    public let doneCount: Int
    /// The board as the Mac sent it.
    public let source: RemoteTaskBoard
    private let tasksByID: [UUID: RemoteTaskSummary]
    private let taskIDsByTaskSpaceID: [UUID: UUID]
    private let tallyByProjectID: [UUID: RemoteTaskProjectTally]

    public init(_ board: RemoteTaskBoard) {
        source = board
        tasks = board.tasks
        tasksByID = Dictionary(board.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // An entry or lane that names no listed task is left out, so every
        // row has a task to draw.
        let known = Set(tasksByID.keys)
        needsYou = board.needsYou.filter { known.contains($0.taskID) }
        running = board.running.filter { known.contains($0.taskID) }
        idle = board.idle.filter { known.contains($0.taskID) }
        toShip = board.toShip
        doneCount = board.doneCount
        taskIDsByTaskSpaceID = Dictionary(
            board.tasks.compactMap { task in task.taskSpaceWorkspaceID.map { ($0, task.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        tallyByProjectID = Dictionary(
            board.finishedByProject.map { ($0.projectWorkspaceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func task(id: UUID) -> RemoteTaskSummary? {
        tasksByID[id]
    }

    /// The task whose task space this workspace is.
    public func task(taskSpaceID: UUID) -> RemoteTaskSummary? {
        taskIDsByTaskSpaceID[taskSpaceID].flatMap { tasksByID[$0] }
    }

    /// The finished tasks that left a project's list.
    public func finished(projectID: UUID) -> RemoteTaskProjectTally? {
        tallyByProjectID[projectID].flatMap { $0.toShipCount + $0.doneCount > 0 ? $0 : nil }
    }

    /// The task that started this one, while it is on the board. A Done
    /// parent is not: the task's `parentTaskTitle` still names it.
    public func parent(of task: RemoteTaskSummary) -> RemoteTaskSummary? {
        task.parentTaskID.flatMap { $0 == task.id ? nil : tasksByID[$0] }
    }

    /// A project's To ship tasks, as its card lists them, newest merge
    /// first. Lanes group by project root, not by project workspace, so this
    /// picks each lane's tasks by the project they belong to.
    public func toShipTasks(projectID: UUID) -> [RemoteTaskSummary] {
        toShipTasks.filter { $0.projectWorkspaceID == projectID }
    }

    /// Every lane's tasks, newest merge first in each lane. An older Mac
    /// sends only each lane's newest few, so when two open projects share a
    /// root, the one with older merges can list fewer tasks than it counts.
    public var toShipTasks: [RemoteTaskSummary] {
        toShip.flatMap(Self.taskIDs).compactMap { tasksByID[$0] }
    }

    /// Whether the Mac sent every To ship task, not only each lane's newest.
    public var listsEveryToShipTask: Bool {
        toShip.allSatisfy { $0.taskIDs != nil }
    }

    /// A lane's tasks: all of them from a Mac that sends them, else its
    /// newest few.
    public static func taskIDs(_ lane: RemoteTaskShipLane) -> [UUID] {
        lane.taskIDs ?? lane.recentTaskIDs
    }

    /// The release a lane offers: `nil` when its project cannot release
    /// from Toastty, and from an older Mac.
    public static func release(_ lane: RemoteTaskShipLane, tasks: [RemoteTaskSummary]) -> MobileProjectRelease? {
        lane.releaseWorkspaceID.map { workspaceID in
            MobileProjectRelease(
                laneID: lane.id,
                projectTitle: lane.projectTitle,
                workspaceID: workspaceID,
                taskCount: lane.count,
                taskTitles: tasks.map(\.title),
                releaseTaskID: lane.releaseTaskID
            )
        }
    }

    public func entries(_ group: RemoteTaskGroup) -> [RemoteTaskBoardEntry] {
        switch group {
        case .needsYou: needsYou
        case .running: running
        case .idle: idle
        case .toShip, .done, .archived: []
        }
    }

    /// A group's header count: rows whose own stage is in the group, so a
    /// dimmed relative listed with its family does not count.
    public func count(_ group: RemoteTaskGroup) -> Int {
        entries(group).filter { tasksByID[$0.taskID]?.group == group }.count
    }

    public var toShipCount: Int {
        toShip.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool {
        needsYou.isEmpty && running.isEmpty && idle.isEmpty && toShip.isEmpty && doneCount == 0
    }
}

/// A project's Release… as a To ship lane or a project card offers it: the
/// workspace the Mac starts the release in, what waits to ship, and the
/// release under way, if any.
public struct MobileProjectRelease: Equatable, Sendable, Identifiable {
    public let laneID: String
    public let projectTitle: String
    /// The lane's `releaseWorkspaceID`, which the request names.
    public let workspaceID: UUID
    /// How many tasks wait to ship, as the lane counts them.
    public let taskCount: Int
    /// The titles of the tasks the phone lists, newest merge first.
    public let taskTitles: [String]
    /// The release task while it runs; the button then reads Releasing….
    public let releaseTaskID: UUID?

    public var id: String { laneID }
    public var isReleasing: Bool { releaseTaskID != nil }

    public init(
        laneID: String,
        projectTitle: String,
        workspaceID: UUID,
        taskCount: Int,
        taskTitles: [String] = [],
        releaseTaskID: UUID? = nil
    ) {
        self.laneID = laneID
        self.projectTitle = projectTitle
        self.workspaceID = workspaceID
        self.taskCount = taskCount
        self.taskTitles = taskTitles
        self.releaseTaskID = releaseTaskID
    }
}
