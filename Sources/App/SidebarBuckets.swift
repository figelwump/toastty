import CoreState
import Foundation
import RemoteProtocol

/// The groups a project card lists its rows in when the task system is on.
/// The groups and the rules that place rows in them are shared with the
/// iPhone (`TaskBucket`, `TaskBuckets`); this file maps the Mac's own task
/// stages, sessions and task space rows to a bucket.
typealias SidebarBucket = TaskBucket

extension TaskBucket {
    /// A task stage's bucket: its group, with a review split off from the
    /// rest of Needs you. `nil` for To ship and Done, which the card's
    /// footer counts, and for Archived.
    init?(_ stage: TaskStage) {
        switch stage {
        case .needsYou(.review), .needsYou(.readyForReview): self = .readyToReview
        case .needsYou: self = .needsYou
        case .starting, .running: self = .running
        case .idle: self = .idle
        case .toShip, .done, .archived: return nil
        }
    }

    /// A session or program row: an approval, an error, an unread finished
    /// turn, or a sub-agent that needs the user. A finished turn that was
    /// read is Idle.
    static func session(kind: SessionStatusKind, isUnread: Bool, childNeedsAttention: Bool = false) -> Self {
        if childNeedsAttention { return .needsYou }
        switch kind {
        case .needsApproval, .error: return .needsYou
        case .ready: return isUnread ? .needsYou : .idle
        case .working: return .running
        case .idle: return .idle
        }
    }

    /// A task space or other subspace row: the more urgent of what its
    /// sessions show and its task's stage. The stage covers a task that
    /// needs the user while no agent asks, such as a failed setup. A row
    /// shows its review over a finished turn that is not read yet, so a
    /// task that just opened its pull request lists in Ready to review.
    static func subspace(_ row: SidebarSubspacePresentation.Row) -> Self {
        subspace(status: row.status, stage: row.stage)
    }

    static func subspace(status: SidebarSubspacePresentation.RowStatus, stage: TaskStage?) -> Self {
        let fromStatus: Self = switch status {
        case .ready, .question, .needsApproval, .error: .needsYou
        case .review: .readyToReview
        case .working: .running
        case .idle, .toShip, .done, .waiting: .idle
        }
        guard let fromStage = stage.flatMap(Self.init) else { return fromStatus }
        return min(fromStatus, fromStage)
    }

    /// A task in the Tasks view: the bucket of its task space's row, as the
    /// sidebar lists that row, or its stage's alone without an open task
    /// space. So a task whose agent ended its turn to wait on another task
    /// lists in Needs you while that turn is unread. `nil` for To ship, Done
    /// and Archived, which keep their own groups.
    static func task(_ item: TaskBoardItem) -> Self? {
        guard let fromStage = Self(item.stage) else { return nil }
        guard let status = item.taskSpaceStatus else { return fromStage }
        return subspace(status: status, stage: item.stage)
    }
}

/// One row in the sidebar, the same from one pass to the next.
enum SidebarRowKey: Hashable, Sendable {
    /// A session or program row in a project workspace, by its panel.
    case panel(UUID)
    /// A task space or other subspace row, by its workspace.
    case workspace(UUID)
    /// A task without an open task space in the window.
    case task(TaskBoardItem.Subject)
}

typealias SidebarBucketCandidate<Payload> = TaskBucketCandidate<SidebarRowKey, Payload>
typealias SidebarBucketEntry<Payload> = TaskBucketEntry<SidebarRowKey, Payload>
typealias SidebarBucketPin = TaskBucketPin<SidebarRowKey>
/// The shared rules, keyed by the sidebar's rows.
typealias SidebarBuckets = TaskBuckets<SidebarRowKey>

/// One line a bucket draws in the All segment: a row, or the merged child
/// tasks of a parent, folded into one "N/M merged" line after its open
/// children.
enum SidebarBucketItem<Payload>: Identifiable {
    case row(SidebarBucketEntry<Payload>)
    /// The parent's finished children, in the order the bucket lists them.
    case finishedChildren(parent: SidebarRowKey, rows: [SidebarBucketEntry<Payload>])

    enum ID: Hashable {
        case row(SidebarRowKey)
        case finishedChildren(parent: SidebarRowKey)
    }

    var id: ID {
        switch self {
        case .row(let entry): .row(entry.key)
        case .finishedChildren(let parent, _): .finishedChildren(parent: parent)
        }
    }
}

extension TaskBuckets where Key == SidebarRowKey {
    /// The finished rows that fold under their parent: each row that
    /// `isFinished` accepts and that lists under its parent. The rule for
    /// "lists under its parent" is the one `TaskBuckets` uses for families:
    /// the parent is among the rows and has no parent among them itself.
    /// A finished row without a listed parent does not fold; see
    /// `finishedFamilyKeys`.
    static func foldedKeys<Payload>(
        _ candidates: [Candidate<Payload>],
        isFinished: (Candidate<Payload>) -> Bool
    ) -> Set<Key> {
        let parents = listedParents(candidates)
        return Set(candidates.filter { parents[$0.key] != nil && isFinished($0) }.map(\.key))
    }

    /// The rows that leave the buckets for the card's To ship and Done
    /// lines: each family whose every row `isFinished` accepts. A family is
    /// a row and the rows that list under it, by the rule `foldedKeys`
    /// uses; a row alone is a family of one. A family with an open row
    /// keeps its finished rows, which fold under the parent. The family of
    /// `keeping`, the pinned row, stays in the buckets while it is
    /// selected, as a pinned row keeps its bucket.
    static func finishedFamilyKeys<Payload>(
        _ candidates: [Candidate<Payload>],
        keeping: Key? = nil,
        isFinished: (Candidate<Payload>) -> Bool
    ) -> Set<Key> {
        let parents = listedParents(candidates)
        let families = Dictionary(grouping: candidates) { parents[$0.key] ?? $0.key }
        return Set(families.values.filter { family in
            family.allSatisfy(isFinished) && family.contains { $0.key == keeping } == false
        }.flatMap { $0.map(\.key) })
    }

    /// Each row that lists under its parent, with that parent: the parent
    /// is among the rows and has no parent among them itself.
    private static func listedParents<Payload>(_ candidates: [Candidate<Payload>]) -> [Key: Key] {
        let keys = Set(candidates.map(\.key))
        func parent(_ candidate: Candidate<Payload>) -> Key? {
            guard let parent = candidate.parent, parent != candidate.key, keys.contains(parent) else { return nil }
            return parent
        }
        let rootKeys = Set(candidates.filter { parent($0) == nil }.map(\.key))
        var parents: [Key: Key] = [:]
        for candidate in candidates {
            if let parent = parent(candidate), rootKeys.contains(parent) {
                parents[candidate.key] = parent
            }
        }
        return parents
    }

    /// A bucket's entries with each family's folded children moved into
    /// one line after the family's other children.
    static func items<Payload>(_ entries: [Entry<Payload>], folded: Set<Key>) -> [SidebarBucketItem<Payload>] {
        var items: [SidebarBucketItem<Payload>] = []
        var root: Key?
        var finished: [Entry<Payload>] = []
        func closeFamily() {
            if let root, finished.isEmpty == false {
                items.append(.finishedChildren(parent: root, rows: finished))
            }
            finished = []
        }
        for entry in entries {
            if entry.isLinkedChild == false {
                closeFamily()
                root = entry.key
                items.append(.row(entry))
            } else if folded.contains(entry.key), root != nil {
                finished.append(entry)
            } else {
                items.append(.row(entry))
            }
        }
        closeFamily()
        return items
    }
}
