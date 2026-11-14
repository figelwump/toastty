import CoreState
import Foundation

/// The groups a project card lists its rows in when the task system is on,
/// most urgent first. Sessions, task spaces and tasks without an open task
/// space share them. To ship and Done stay in the card's footer.
enum SidebarBucket: Int, CaseIterable, Comparable, Sendable {
    /// An agent or a task is stopped until the user acts: a question, an
    /// approval, an error, an unread finished turn, or a failed setup.
    case needsYou
    /// Finished work waits for the user's review: an open pull request, or
    /// work the agent marked ready. Nothing is stopped on it.
    case readyToReview
    case running
    case idle

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .readyToReview: "Ready to review"
        case .running: "Running"
        case .idle: "Idle"
        }
    }

    /// The buckets the Needs you segment lists, in their order.
    static let needsYouSegmentBuckets: [Self] = [.needsYou, .readyToReview]

    /// Whether the Needs you segment lists the bucket's rows.
    var isListedInNeedsYouSegment: Bool {
        Self.needsYouSegmentBuckets.contains(self)
    }

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
        let fromStatus: Self = switch row.status {
        case .ready, .question, .needsApproval, .error: .needsYou
        case .review: .readyToReview
        case .working: .running
        case .idle, .toShip, .done: .idle
        }
        guard let fromStage = row.stage.flatMap(Self.init) else { return fromStatus }
        return min(fromStatus, fromStage)
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

/// A row a card can list, with the bucket its own state puts it in.
struct SidebarBucketCandidate<Payload> {
    let key: SidebarRowKey
    let bucket: SidebarBucket
    /// The row of the task that started this one. Set only for a task whose
    /// parent task has a row somewhere in the window.
    var parent: SidebarRowKey? = nil
    let payload: Payload
}

/// A row as a bucket draws it.
struct SidebarBucketEntry<Payload>: Identifiable {
    let key: SidebarRowKey
    let payload: Payload
    /// The bucket the row's own state puts it in.
    let ownBucket: SidebarBucket
    /// Drawn under the task that started it.
    var isLinkedChild = false
    /// Drawn dimmed: the row's own state is in a calmer bucket. It lists
    /// here to keep its family together, or because it is selected and
    /// holds its place.
    var isContext = false
    /// Its parent task has a row, but the Needs you segment shows the row
    /// without it, so the row names the parent.
    var listsApartFromParent = false

    var id: SidebarRowKey { key }
}

/// Where the selected row holds while it stays selected. Selecting a row
/// reads its finished turn, which would move it to Idle from under the
/// pointer.
struct SidebarBucketPin: Equatable {
    let key: SidebarRowKey
    let bucket: SidebarBucket
}

/// Pure rules for the bucketed sidebar, kept apart from the view so they
/// can be tested without hosting it.
enum SidebarBuckets {
    /// A card's rows by bucket: every bucket in the All segment, Needs you
    /// and Ready to review in the Needs you segment.
    struct Layout<Payload> {
        var entries: [SidebarBucket: [SidebarBucketEntry<Payload>]] = [:]
        /// Where each row is drawn, for the next pin.
        var displayed: [SidebarRowKey: SidebarBucket] = [:]
        /// The pin, when its row is on this card.
        var pin: SidebarBucketPin?

        func entries(_ bucket: SidebarBucket) -> [SidebarBucketEntry<Payload>] {
            entries[bucket] ?? []
        }
    }

    /// How many rows each bucket holds by the rows' own state. A dimmed
    /// relative and a held row count where their own state is.
    static func counts<Payload>(_ candidates: [SidebarBucketCandidate<Payload>]) -> [SidebarBucket: Int] {
        Dictionary(grouping: candidates, by: \.bucket).mapValues(\.count)
    }

    /// The All segment. A task and the tasks it started list together, in
    /// the bucket of the most urgent one; one level only. Inside a bucket,
    /// rows keep `candidates` order, so a row moves only when its bucket
    /// changes. The pinned row's family keeps its bucket while the row
    /// calms down; it moves at once when the row starts work again or the
    /// family becomes more urgent.
    static func layout<Payload>(
        _ candidates: [SidebarBucketCandidate<Payload>],
        pin: SidebarBucketPin?
    ) -> Layout<Payload> {
        place(candidates, pin: pin, marksRowsApartFromParent: false)
    }

    /// The Needs you segment: only the rows whose own state needs the user,
    /// in Needs you and Ready to review, and the selected row while it
    /// holds. A family lists in the more urgent of the two, as in All. A
    /// child lists under its parent only when both list; otherwise it lists
    /// alone and says so.
    static func needsYou<Payload>(
        _ candidates: [SidebarBucketCandidate<Payload>],
        pin: SidebarBucketPin?
    ) -> Layout<Payload> {
        var heldKey: SidebarRowKey?
        if let pin, let selected = candidates.first(where: { $0.key == pin.key }),
           held(selected.bucket, pin: pin, selected: selected).isListedInNeedsYouSegment {
            heldKey = selected.key
        }
        let listed = candidates.filter { $0.bucket.isListedInNeedsYouSegment || $0.key == heldKey }
        return place(listed, pin: pin, marksRowsApartFromParent: true)
    }

    private static func place<Payload>(
        _ candidates: [SidebarBucketCandidate<Payload>],
        pin: SidebarBucketPin?,
        marksRowsApartFromParent: Bool
    ) -> Layout<Payload> {
        var placed = families(candidates).map { (bucket: $0.bucket, family: $0) }
        var layout = Layout<Payload>()
        if let pin, let index = placed.firstIndex(where: { $0.family.contains(pin.key) }) {
            let family = placed[index].family
            let bucket = held(family.bucket, pin: pin, selected: family.member(pin.key))
            placed[index].bucket = bucket
            layout.pin = SidebarBucketPin(key: pin.key, bucket: bucket)
        }
        for bucket in SidebarBucket.allCases {
            let entries = placed.filter { $0.bucket == bucket }.flatMap { placed in
                let root = placed.family.root
                return [entry(root, in: bucket, apartFromParent: marksRowsApartFromParent && root.parent != nil)]
                    + placed.family.children.map { entry($0, in: bucket, isLinkedChild: true) }
            }
            guard entries.isEmpty == false else { continue }
            layout.entries[bucket] = entries
            for entry in entries {
                layout.displayed[entry.key] = bucket
            }
        }
        return layout
    }

    /// The pin for the selected row: kept while the same row stays
    /// selected, else taken from the bucket the row was drawn in.
    static func pin(
        previous: SidebarBucketPin?,
        selected: SidebarRowKey?,
        displayed: [SidebarRowKey: SidebarBucket]
    ) -> SidebarBucketPin? {
        guard let selected else { return nil }
        if let previous, previous.key == selected { return previous }
        return displayed[selected].map { SidebarBucketPin(key: selected, bucket: $0) }
    }

    /// The bucket a pinned row, or its family, is drawn in. It does not move
    /// to a calmer bucket while selected, but the selected row starting work
    /// moves it to Running at once, and anything more urgent moves it too.
    private static func held<Payload>(
        _ current: SidebarBucket,
        pin: SidebarBucketPin,
        selected: SidebarBucketCandidate<Payload>?
    ) -> SidebarBucket {
        if selected?.bucket == .running { return current }
        return min(current, pin.bucket)
    }

    private struct Family<Payload> {
        var root: SidebarBucketCandidate<Payload>
        var children: [SidebarBucketCandidate<Payload>] = []

        var bucket: SidebarBucket {
            ([root] + children).map(\.bucket).min() ?? root.bucket
        }

        func contains(_ key: SidebarRowKey) -> Bool {
            member(key) != nil
        }

        func member(_ key: SidebarRowKey) -> SidebarBucketCandidate<Payload>? {
            ([root] + children).first { $0.key == key }
        }
    }

    /// Splits rows into families: each task whose parent is among the rows
    /// lists under that parent, unless the parent itself lists under
    /// another task. Every row is in exactly one family, in `candidates`
    /// order.
    private static func families<Payload>(_ candidates: [SidebarBucketCandidate<Payload>]) -> [Family<Payload>] {
        let keys = Set(candidates.map(\.key))
        func parent(_ candidate: SidebarBucketCandidate<Payload>) -> SidebarRowKey? {
            guard let parent = candidate.parent, parent != candidate.key, keys.contains(parent) else { return nil }
            return parent
        }
        let rootKeys = Set(candidates.filter { parent($0) == nil }.map(\.key))
        var childrenByParent: [SidebarRowKey: [SidebarBucketCandidate<Payload>]] = [:]
        for candidate in candidates {
            if let parent = parent(candidate), rootKeys.contains(parent) {
                childrenByParent[parent, default: []].append(candidate)
            }
        }
        let childKeys = Set(childrenByParent.values.flatMap { $0.map(\.key) })
        return candidates.filter { childKeys.contains($0.key) == false }.map { root in
            Family(root: root, children: childrenByParent[root.key] ?? [])
        }
    }

    private static func entry<Payload>(
        _ candidate: SidebarBucketCandidate<Payload>,
        in bucket: SidebarBucket,
        isLinkedChild: Bool = false,
        apartFromParent: Bool = false
    ) -> SidebarBucketEntry<Payload> {
        SidebarBucketEntry(
            key: candidate.key,
            payload: candidate.payload,
            ownBucket: candidate.bucket,
            isLinkedChild: isLinkedChild,
            isContext: candidate.bucket != bucket,
            listsApartFromParent: apartFromParent
        )
    }
}
