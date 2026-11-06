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
