import Foundation

/// The groups a project card lists its rows in when the task system is on,
/// most urgent first. Sessions, task spaces and tasks without an open task
/// space share them. To ship and Done stay on the card's To ship line. The
/// Mac sidebar and the iPhone's Home use the same groups and the same rules
/// (`TaskBuckets`); each app decides a row's own bucket from its own state.
public enum TaskBucket: Int, CaseIterable, Comparable, Sendable {
    /// An agent or a task is stopped until the user acts: a question, an
    /// approval, an error, an unread finished turn, or a failed setup.
    case needsYou
    /// Finished work waits for the user's review: an open pull request, or
    /// work the agent marked ready. Nothing is stopped on it.
    case readyToReview
    case running
    case idle

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .readyToReview: "Ready to review"
        case .running: "Running"
        case .idle: "Idle"
        }
    }

    /// The buckets the Needs you segment lists, in their order.
    public static let needsYouSegmentBuckets: [Self] = [.needsYou, .readyToReview]

    /// Whether the Needs you segment lists the bucket's rows.
    public var isListedInNeedsYouSegment: Bool {
        Self.needsYouSegmentBuckets.contains(self)
    }
}

/// A row a card can list, with the bucket its own state puts it in. `Key`
/// names the row the same way from one pass to the next.
public struct TaskBucketCandidate<Key: Hashable, Payload> {
    public let key: Key
    public let bucket: TaskBucket
    /// The row of the task that started this one. Set only for a task whose
    /// parent task has a row among the candidates or elsewhere.
    public var parent: Key?
    public let payload: Payload

    public init(key: Key, bucket: TaskBucket, parent: Key? = nil, payload: Payload) {
        self.key = key
        self.bucket = bucket
        self.parent = parent
        self.payload = payload
    }
}

/// A row as a bucket draws it.
public struct TaskBucketEntry<Key: Hashable, Payload>: Identifiable {
    public let key: Key
    public let payload: Payload
    /// The bucket the row's own state puts it in.
    public let ownBucket: TaskBucket
    /// Drawn under the task that started it.
    public var isLinkedChild = false
    /// Drawn dimmed: the row's own state is in a calmer bucket. It lists
    /// here to keep its family together, or because it is selected and
    /// holds its place.
    public var isContext = false
    /// Its parent task has a row, but the Needs you segment shows the row
    /// without it, so the row names the parent.
    public var listsApartFromParent = false

    public var id: Key { key }

    public init(
        key: Key,
        payload: Payload,
        ownBucket: TaskBucket,
        isLinkedChild: Bool = false,
        isContext: Bool = false,
        listsApartFromParent: Bool = false
    ) {
        self.key = key
        self.payload = payload
        self.ownBucket = ownBucket
        self.isLinkedChild = isLinkedChild
        self.isContext = isContext
        self.listsApartFromParent = listsApartFromParent
    }
}

/// Where the selected row holds while it stays selected. Selecting a row
/// reads its finished turn, which would move it to Idle from under the
/// pointer.
public struct TaskBucketPin<Key: Hashable>: Equatable {
    public let key: Key
    public let bucket: TaskBucket

    public init(key: Key, bucket: TaskBucket) {
        self.key = key
        self.bucket = bucket
    }
}

extension TaskBucketPin: Sendable where Key: Sendable {}

/// Pure rules for bucketed project cards, kept apart from the views so they
/// can be tested without hosting them, and shared by the Mac and the iPhone.
public enum TaskBuckets<Key: Hashable> {
    public typealias Candidate<Payload> = TaskBucketCandidate<Key, Payload>
    public typealias Entry<Payload> = TaskBucketEntry<Key, Payload>
    public typealias Pin = TaskBucketPin<Key>

    /// A card's rows by bucket: every bucket in the All segment, Needs you
    /// and Ready to review in the Needs you segment.
    public struct Layout<Payload> {
        public var entries: [TaskBucket: [Entry<Payload>]] = [:]
        /// Where each row is drawn, for the next pin.
        public var displayed: [Key: TaskBucket] = [:]
        /// The pin, when its row is on this card.
        public var pin: Pin?

        public init() {}

        public func entries(_ bucket: TaskBucket) -> [Entry<Payload>] {
            entries[bucket] ?? []
        }
    }

    /// How many rows each bucket holds by the rows' own state. A dimmed
    /// relative and a held row count where their own state is.
    public static func counts<Payload>(_ candidates: [Candidate<Payload>]) -> [TaskBucket: Int] {
        Dictionary(grouping: candidates, by: \.bucket).mapValues(\.count)
    }

    /// The All segment. A task and the tasks it started list together, in
    /// the bucket of the most urgent one; one level only. Inside a bucket,
    /// rows keep `candidates` order, so a row moves only when its bucket
    /// changes. The pinned row's family keeps its bucket while the row
    /// calms down; it moves at once when the row starts work again or the
    /// family becomes more urgent.
    public static func layout<Payload>(
        _ candidates: [Candidate<Payload>],
        pin: Pin?
    ) -> Layout<Payload> {
        place(candidates, pin: pin, marksRowsApartFromParent: false)
    }

    /// The Needs you segment: only the rows whose own state needs the user,
    /// in Needs you and Ready to review, and the selected row while it
    /// holds. A family lists in the more urgent of the two, as in All. A
    /// child lists under its parent only when both list; otherwise it lists
    /// alone and says so.
    public static func needsYou<Payload>(
        _ candidates: [Candidate<Payload>],
        pin: Pin?
    ) -> Layout<Payload> {
        var heldKey: Key?
        if let pin, let selected = candidates.first(where: { $0.key == pin.key }),
           held(selected.bucket, pin: pin, selected: selected).isListedInNeedsYouSegment {
            heldKey = selected.key
        }
        let listed = candidates.filter { $0.bucket.isListedInNeedsYouSegment || $0.key == heldKey }
        return place(listed, pin: pin, marksRowsApartFromParent: true)
    }

    private static func place<Payload>(
        _ candidates: [Candidate<Payload>],
        pin: Pin?,
        marksRowsApartFromParent: Bool
    ) -> Layout<Payload> {
        var placed = families(candidates).map { (bucket: $0.bucket, family: $0) }
        var layout = Layout<Payload>()
        if let pin, let index = placed.firstIndex(where: { $0.family.contains(pin.key) }) {
            let family = placed[index].family
            let bucket = held(family.bucket, pin: pin, selected: family.member(pin.key))
            placed[index].bucket = bucket
            layout.pin = Pin(key: pin.key, bucket: bucket)
        }
        for bucket in TaskBucket.allCases {
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
    public static func pin(
        previous: Pin?,
        selected: Key?,
        displayed: [Key: TaskBucket]
    ) -> Pin? {
        guard let selected else { return nil }
        if let previous, previous.key == selected { return previous }
        return displayed[selected].map { Pin(key: selected, bucket: $0) }
    }

    /// The bucket a pinned row, or its family, is drawn in. It does not move
    /// to a calmer bucket while selected, but the selected row starting work
    /// moves it to Running at once, and anything more urgent moves it too.
    private static func held<Payload>(
        _ current: TaskBucket,
        pin: Pin,
        selected: Candidate<Payload>?
    ) -> TaskBucket {
        if selected?.bucket == .running { return current }
        return min(current, pin.bucket)
    }

    private struct Family<Payload> {
        var root: Candidate<Payload>
        var children: [Candidate<Payload>] = []

        var bucket: TaskBucket {
            ([root] + children).map(\.bucket).min() ?? root.bucket
        }

        func contains(_ key: Key) -> Bool {
            member(key) != nil
        }

        func member(_ key: Key) -> Candidate<Payload>? {
            ([root] + children).first { $0.key == key }
        }
    }

    /// Splits rows into families: each task whose parent is among the rows
    /// lists under that parent, unless the parent itself lists under
    /// another task. Every row is in exactly one family, in `candidates`
    /// order.
    private static func families<Payload>(_ candidates: [Candidate<Payload>]) -> [Family<Payload>] {
        let keys = Set(candidates.map(\.key))
        func parent(_ candidate: Candidate<Payload>) -> Key? {
            guard let parent = candidate.parent, parent != candidate.key, keys.contains(parent) else { return nil }
            return parent
        }
        let rootKeys = Set(candidates.filter { parent($0) == nil }.map(\.key))
        var childrenByParent: [Key: [Candidate<Payload>]] = [:]
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
        _ candidate: Candidate<Payload>,
        in bucket: TaskBucket,
        isLinkedChild: Bool = false,
        apartFromParent: Bool = false
    ) -> Entry<Payload> {
        Entry(
            key: candidate.key,
            payload: candidate.payload,
            ownBucket: candidate.bucket,
            isLinkedChild: isLinkedChild,
            isContext: candidate.bucket != bucket,
            listsApartFromParent: apartFromParent
        )
    }
}
