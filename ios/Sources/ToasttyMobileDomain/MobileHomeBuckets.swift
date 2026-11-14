import Foundation
import RemoteProtocol

/// One row on a Home project card, the same from one snapshot to the next.
public enum MobileHomeRowKey: Hashable, Sendable {
    /// A session in the project's own workspace.
    case conversation(UUID)
    /// A task space or other subspace row, by its workspace.
    case workspace(UUID)
    /// A task without a task space row.
    case task(UUID)
}

/// What a card row draws.
public enum MobileHomeRow: Equatable, Sendable {
    case conversation(MobileConversation)
    case subspace(MobileSubspaceRow)
    case task(RemoteTaskSummary)

    /// The task the row stands for, if any.
    public var task: RemoteTaskSummary? {
        switch self {
        case .conversation: nil
        case .subspace(let row): row.task
        case .task(let task): task
        }
    }

    /// The one tag a one-line row shows, as the Mac's Needs you segment
    /// picks it: the pull request, else the task that started this one when
    /// the row lists without it, else how many child tasks merged. A row in
    /// the Other tasks card falls back to its project.
    public func compactTag(listsApartFromParent: Bool, showsProject: Bool) -> MobileHomeRowTag? {
        if case .subspace(let row) = self,
           let pullRequest = row.workspace.annotations.first(where: { $0.key == MobileSubspaceRow.pullRequestAnnotationKey }) {
            return .pullRequestAnnotation(pullRequest)
        }
        guard let task else { return nil }
        if let pullRequest = task.pullRequest { return .pullRequest(pullRequest) }
        if listsApartFromParent, let parent = task.parentTaskTitle { return .parent(parent) }
        if let progress = task.childProgress, progress.total > 0 { return .childProgress(progress) }
        if showsProject, let project = task.projectTitle { return .project(project) }
        return nil
    }

    /// The second line a one-line row keeps: the agent's question, or what
    /// failed. A phone has no hover card to carry it, as the Mac's does.
    /// `nil` for every other row, which shows one line.
    public var compactDetail: String? {
        switch self {
        case .conversation(let conversation):
            return conversation.state.bucket == .error ? conversation.lastActivity : nil
        case .subspace(let row):
            switch row.status {
            case .question, .error: return row.summary
            case .ready, .needsApproval, .review, .working, .idle, .toShip, .done:
                return row.task.flatMap(Self.needsYouDetail)
            }
        case .task(let task):
            return Self.needsYouDetail(task)
        }
    }

    /// The Mac sends a task's `rowSummary` only for its question and for
    /// setup that did not finish, such as a failed setup.
    private static func needsYouDetail(_ task: RemoteTaskSummary) -> String? {
        guard task.group == .needsYou, task.mark != .review else { return nil }
        return task.rowSummary
    }
}

/// The one tag on a one-line row in the Needs you segment.
public enum MobileHomeRowTag: Equatable, Sendable {
    /// The task space's pull request annotation.
    case pullRequestAnnotation(RemoteWorkspaceAnnotation)
    /// The pull request of a task without an open task space.
    case pullRequest(RemoteTaskPullRequest)
    /// "↖ Parent title": the row lists without the task that started it.
    case parent(String)
    /// "1/2 merged".
    case childProgress(RemoteTaskChildProgress)
    /// The project, in the Other tasks card.
    case project(String)
}

/// The two numbers on the Needs you switcher: rows whose own state needs
/// the user, and rows whose own state waits for a review, as the Needs you
/// segment lists them across every card.
public struct MobileHomeNeedsYouCounts: Equatable, Sendable {
    public var needsYou: Int
    public var readyToReview: Int

    public init(needsYou: Int = 0, readyToReview: Int = 0) {
        self.needsYou = needsYou
        self.readyToReview = readyToReview
    }

    public init(_ cards: [MobileHomeCard]) {
        self.init(
            needsYou: cards.reduce(0) { $0 + ($1.counts[.needsYou] ?? 0) },
            readyToReview: cards.reduce(0) { $0 + ($1.counts[.readyToReview] ?? 0) }
        )
    }

    /// "Only what needs you, 4, 3 ready for review", leaving out a zero,
    /// as the Mac's switcher says it.
    public var accessibilityLabel: String {
        var parts = ["Only what needs you"]
        if needsYou > 0 { parts.append("\(needsYou)") }
        if readyToReview > 0 { parts.append("\(readyToReview) ready for review") }
        return parts.joined(separator: ", ")
    }
}

public typealias MobileHomeBucketLayout = TaskBuckets<MobileHomeRowKey>.Layout<MobileHomeRow>
public typealias MobileHomeBucketEntry = TaskBucketEntry<MobileHomeRowKey, MobileHomeRow>

/// A project card in Home's All segment: the project's sessions, task
/// spaces and tasks without a task space, in the shared buckets, and its
/// To ship line. The Other tasks card has no workspace.
public struct MobileHomeCard: Identifiable {
    public let workspace: MobileWorkspace?
    public let title: String
    /// Rows by their own bucket, for the card's header.
    public let counts: [TaskBucket: Int]
    public let layout: MobileHomeBucketLayout
    /// The rows the Needs you segment lists: Needs you, then Ready to
    /// review. The ⑂ filter does not apply to them.
    public let needsYou: MobileHomeBucketLayout
    /// The project's latest To ship tasks that have no row in a bucket,
    /// newest merge first.
    public let toShipTasks: [RemoteTaskSummary]
    /// All of the project's To ship tasks, which can be more than the
    /// rows the board sends.
    public let toShipCount: Int
    public let doneCount: Int

    public var id: UUID { workspace?.id ?? MobileHomeBuckets.otherTasksCardID }
    public var isOtherTasks: Bool { workspace == nil }

    /// The rows in display order, for animating moves between buckets.
    public var orderedKeys: [MobileHomeRowKey] {
        TaskBucket.allCases.flatMap { layout.entries($0).map(\.key) }
    }

    /// The Needs you segment's rows in display order.
    public var needsYouOrderedKeys: [MobileHomeRowKey] {
        TaskBucket.needsYouSegmentBuckets.flatMap { needsYou.entries($0).map(\.key) }
    }

    /// Whether the Needs you segment lists the card.
    public var listsInNeedsYou: Bool { needsYou.entries.isEmpty == false }
}

/// Builds Home's project cards from the Mac's snapshot and task board, with
/// the same rules as the Mac sidebar's All segment (`TaskBuckets`).
public enum MobileHomeBuckets {
    public static let otherTasksCardID = UUID(uuidString: "00000000-0000-0000-0000-00000000071D")!
    public static let otherTasksCardTitle = "Other tasks"

    /// A session's bucket: an approval, an error or an unread finished turn
    /// (`ready` on the wire) needs the user; a working session runs; a
    /// finished turn that was read is idle.
    public static func bucket(_ conversation: MobileConversation) -> TaskBucket {
        switch conversation.state.bucket {
        case .needsApproval, .error, .ready: .needsYou
        case .working: .running
        case .idle: .idle
        }
    }

    /// A task's bucket from its stage: a review splits off from the rest of
    /// Needs you. `nil` for To ship, Done and Archived, which the card's
    /// To ship line counts.
    public static func bucket(_ task: RemoteTaskSummary) -> TaskBucket? {
        switch task.group {
        case .needsYou: task.mark == .review ? .readyToReview : .needsYou
        case .running: .running
        case .idle: .idle
        case .toShip, .done, .archived: nil
        }
    }

    /// A task space or other subspace row: the more urgent of what its
    /// sessions show and its task's stage. The row's status already shows a
    /// review over an unread turn, while an approval or an error in its
    /// sessions beats the review.
    public static func bucket(_ row: MobileSubspaceRow) -> TaskBucket {
        let fromStatus: TaskBucket = switch row.status {
        case .ready, .question, .needsApproval, .error: .needsYou
        case .review: .readyToReview
        case .working: .running
        case .idle, .toShip, .done: .idle
        }
        guard let fromStage = row.task.flatMap(bucket) else { return fromStatus }
        return min(fromStatus, fromStage)
    }

    /// The switcher's counts, from the cards the Needs you segment lists;
    /// `nil` without a task board.
    public static func needsYouCounts(in snapshot: MobileHomeSnapshot) -> MobileHomeNeedsYouCounts? {
        guard snapshot.taskBoard != nil else { return nil }
        return MobileHomeNeedsYouCounts(cards(in: snapshot))
    }

    /// One card for each top-level workspace, in the Mac's sidebar order,
    /// then Other tasks when tasks have no open project. Empty without a
    /// task board: Home then keeps its All | Active lists. `hiding` leaves
    /// rows out of the buckets, as the ⑂ filter does, but not out of the
    /// counts.
    public static func cards(in snapshot: MobileHomeSnapshot, hiding: Set<MobileHomeRowKey> = []) -> [MobileHomeCard] {
        guard let board = snapshot.taskBoard else { return [] }
        let topLevelIDs = Set(snapshot.topLevelWorkspaces.map(\.id))
        // The snapshot's order: workspaces as the Mac's sidebar lists them,
        // and each workspace's sessions by title.
        let order = Dictionary(
            snapshot.workspaces.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let workspaceIDs = Set(order.keys)
        let topLevel = snapshot.workspaces.filter { topLevelIDs.contains($0.id) }
        var subspaceRowsByParentID: [UUID: [MobileSubspaceRow]] = [:]
        for workspace in topLevel {
            subspaceRowsByParentID[workspace.id] = snapshot.subspaceRows(of: workspace.id)
                .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
        let nestedIDs = Set(subspaceRowsByParentID.values.flatMap { $0.map(\.id) })

        // A task's row: its task space row when the snapshot lists its
        // task space, else its own.
        func rowKey(_ task: RemoteTaskSummary) -> MobileHomeRowKey {
            if let taskSpace = task.taskSpaceWorkspaceID, workspaceIDs.contains(taskSpace) {
                return .workspace(taskSpace)
            }
            return .task(task.id)
        }
        // A parent that left the board, such as a Done one, has no row,
        // but a child still lists apart from it, as on the Mac.
        func parentKey(_ task: RemoteTaskSummary?) -> MobileHomeRowKey? {
            guard let task else { return nil }
            if let parent = board.parent(of: task) { return rowKey(parent) }
            return task.parentTaskID.flatMap { $0 == task.id ? nil : .task($0) }
        }
        // Tasks that list by a row of their own: no task space row under a
        // card, and a stage the buckets list. Rows keep the board's order,
        // which is the Mac sidebar's.
        let recordTasks = board.tasks.filter { task in
            task.taskSpaceWorkspaceID.map(nestedIDs.contains) != true && bucket(task) != nil
        }
        func recordCandidates(_ tasks: [RemoteTaskSummary]) -> [TaskBucketCandidate<MobileHomeRowKey, MobileHomeRow>] {
            tasks.compactMap { task in
                bucket(task).map { TaskBucketCandidate(key: rowKey(task), bucket: $0, parent: parentKey(task), payload: .task(task)) }
            }
        }

        var cards: [MobileHomeCard] = []
        var openToShip = 0
        var openDone = 0
        for workspace in topLevel {
            let subspaceRows = subspaceRowsByParentID[workspace.id] ?? []
            var candidates = workspace.conversations.map { conversation in
                TaskBucketCandidate<MobileHomeRowKey, MobileHomeRow>(
                    key: .conversation(conversation.id), bucket: bucket(conversation), payload: .conversation(conversation)
                )
            }
            candidates += subspaceRows.map { row in
                TaskBucketCandidate(key: .workspace(row.id), bucket: bucket(row), parent: parentKey(row.task), payload: .subspace(row))
            }
            candidates += recordCandidates(recordTasks.filter { $0.projectWorkspaceID == workspace.id })
            let shownTaskIDs = Set(candidates.compactMap { $0.payload.task?.id })
            let tally = board.finished(projectID: workspace.id)
            openToShip += tally?.toShipCount ?? 0
            openDone += tally?.doneCount ?? 0
            cards.append(MobileHomeCard(
                workspace: workspace,
                title: workspace.title,
                counts: TaskBuckets<MobileHomeRowKey>.counts(candidates),
                layout: TaskBuckets.layout(candidates.filter { hiding.contains($0.key) == false }, pin: nil),
                needsYou: TaskBuckets.needsYou(candidates, pin: nil),
                toShipTasks: board.toShipTasks(projectID: workspace.id).filter { shownTaskIDs.contains($0.id) == false },
                toShipCount: tally?.toShipCount ?? 0,
                doneCount: tally?.doneCount ?? 0
            ))
        }

        // Finished tasks whose project is not open: the board's totals less
        // what the open projects count.
        let otherCandidates = recordCandidates(recordTasks.filter { $0.projectWorkspaceID.map(topLevelIDs.contains) != true })
        let otherToShip = max(0, board.toShipCount - openToShip)
        let otherDone = max(0, board.doneCount - openDone)
        if otherCandidates.isEmpty == false || otherToShip > 0 {
            cards.append(MobileHomeCard(
                workspace: nil,
                title: otherTasksCardTitle,
                counts: TaskBuckets<MobileHomeRowKey>.counts(otherCandidates),
                layout: TaskBuckets.layout(otherCandidates, pin: nil),
                needsYou: TaskBuckets.needsYou(otherCandidates, pin: nil),
                toShipTasks: board.toShip.flatMap(\.recentTaskIDs).compactMap(board.task(id:)).filter {
                    $0.projectWorkspaceID.map(topLevelIDs.contains) != true
                },
                toShipCount: otherToShip,
                doneCount: otherDone
            ))
        }
        return cards
    }
}
