import Foundation
import RemoteProtocol

/// The Tasks tab's groups, as the Mac's Tasks view lists them: To ship
/// first, one lane per project, then Needs you, Ready to review, Running and
/// Idle, then the Done count. Each group lists the tasks whose own stage is
/// in it, a child under its parent when both are there. A family in Needs
/// you lists under Ready to review when every member that needs the user
/// waits only for a review; a member whose own state is calmer is dimmed.
public struct MobileTaskSections: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        public let task: RemoteTaskSummary
        /// Drawn under the task that started it.
        public var isLinkedChild = false
        /// Drawn dimmed: the task's own state is in a calmer group, and it
        /// lists here to keep its family together.
        public var isContext = false

        public var id: UUID { task.id }

        public init(task: RemoteTaskSummary, isLinkedChild: Bool = false, isContext: Bool = false) {
            self.task = task
            self.isLinkedChild = isLinkedChild
            self.isContext = isContext
        }
    }

    /// A project's merged tasks that wait for a release.
    public struct Lane: Equatable, Identifiable, Sendable {
        public let id: String
        public let projectTitle: String
        public let count: Int
        /// The lane's tasks, newest merge first: all of them, or only the
        /// newest few from an older Mac.
        public let tasks: [RemoteTaskSummary]
        /// Release… on the lane's line, when its project can release.
        public let release: MobileProjectRelease?
    }

    public var toShip: [Lane] = []
    public var needsYou: [Entry] = []
    public var readyToReview: [Entry] = []
    public var running: [Entry] = []
    public var idle: [Entry] = []
    public var doneCount = 0

    public init() {}

    public static func make(_ board: MobileTaskBoard) -> Self {
        var sections = Self()
        sections.toShip = board.toShip.map { lane in
            let tasks = MobileTaskBoard.taskIDs(lane).compactMap(board.task(id:))
            return Lane(
                id: lane.id,
                projectTitle: lane.projectTitle,
                count: lane.count,
                tasks: tasks,
                release: MobileTaskBoard.release(lane, tasks: tasks)
            )
        }
        func entries(_ group: RemoteTaskGroup) -> [Entry] {
            grouped(board.tasks.filter { $0.group == group })
        }
        var family: [Entry] = []
        func placeFamily() {
            guard family.isEmpty == false else { return }
            let bucket = family.compactMap { MobileHomeBuckets.bucket($0.task) }.min() ?? .needsYou
            let placed = family.map { entry in
                var entry = entry
                entry.isContext = MobileHomeBuckets.bucket(entry.task) != bucket
                return entry
            }
            if bucket == .readyToReview { sections.readyToReview += placed } else { sections.needsYou += placed }
            family = []
        }
        for entry in entries(.needsYou) {
            if entry.isLinkedChild == false { placeFamily() }
            family.append(entry)
        }
        placeFamily()
        sections.running = entries(.running)
        sections.idle = entries(.idle)
        sections.doneCount = board.doneCount
        return sections
    }

    public func entries(_ bucket: TaskBucket) -> [Entry] {
        switch bucket {
        case .needsYou: needsYou
        case .readyToReview: readyToReview
        case .running: running
        case .idle: idle
        }
    }

    /// A group's header count: every row it lists, as the Mac's Tasks view
    /// counts. Only Needs you and Ready to review list a dimmed relative,
    /// which is a task in Needs you either way.
    public func count(_ bucket: TaskBucket) -> Int {
        entries(bucket).count
    }

    public var toShipCount: Int {
        toShip.reduce(0) { $0 + $1.count }
    }

    public var isEmpty: Bool {
        toShip.isEmpty && TaskBucket.allCases.allSatisfy { entries($0).isEmpty } && doneCount == 0
    }

    /// The lane that holds a project's To ship tasks. Lanes group by the
    /// project's root, so the lane is found through its tasks.
    public func laneID(projectID: UUID) -> String? {
        toShip.first { lane in lane.tasks.contains { $0.projectWorkspaceID == projectID } }?.id
    }

    /// Puts each task right after the task that started it when both are
    /// in the group; one level only, as the Mac's Tasks view does.
    static func grouped(_ tasks: [RemoteTaskSummary]) -> [Entry] {
        let taskIDs = Set(tasks.map(\.id))
        let topLevelIDs = Set(tasks.filter { task in
            task.parentTaskID.map { taskIDs.contains($0) == false || $0 == task.id } ?? true
        }.map(\.id))
        var placed: Set<UUID> = []
        var result: [Entry] = []
        for task in tasks where placed.contains(task.id) == false {
            let isChild = task.parentTaskID.map { topLevelIDs.contains($0) && $0 != task.id } ?? false
            if isChild { continue }
            result.append(Entry(task: task))
            placed.insert(task.id)
            guard topLevelIDs.contains(task.id) else { continue }
            for child in tasks where child.parentTaskID == task.id && child.id != task.id && placed.contains(child.id) == false {
                result.append(Entry(task: child, isLinkedChild: true))
                placed.insert(child.id)
            }
        }
        return result
    }
}
