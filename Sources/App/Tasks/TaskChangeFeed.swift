import CoreState
import Foundation

/// Tells a polling caller which tasks changed since its last `task.list`.
///
/// Each poll compares every task's snapshot with the one seen at the
/// previous poll by any caller, and stamps a task with the next sequence
/// number when it differs. A cursor is that sequence number, prefixed with
/// an ID for this app launch; a cursor from an earlier launch gets the full
/// list back with `reset`.
@MainActor
final class TaskChangeFeed {
    /// What decides whether a caller may see a task, kept for deleted tasks
    /// so a scoped caller only learns of deletions it could have seen.
    struct Visibility: Equatable {
        var workspaceIDs: [UUID]
        var creatorSessionID: String?
    }

    struct Entry {
        var snapshot: AutomationJSONValue
        var visibility: Visibility
    }

    struct Changes {
        var changedTaskIDs: Set<UUID>
        /// Tasks the feed first saw after the cursor; a subset of
        /// `changedTaskIDs`. Empty on `reset`, when the feed cannot tell.
        var createdTaskIDs: Set<UUID>
        var deletedTasks: [(id: UUID, visibility: Visibility)]
        var cursor: String
        /// The cursor was missing, malformed, or from another launch, so
        /// every task counts as changed.
        var reset: Bool
    }

    /// Deleted tasks are reported for this many later changes.
    static let maximumTombstones = 500

    private let launchID: String
    private var sequence = 0
    private var entries: [UUID: Entry] = [:]
    private var changedAt: [UUID: Int] = [:]
    private var createdAt: [UUID: Int] = [:]
    private var tombstones: [(id: UUID, sequence: Int, visibility: Visibility)] = []
    /// The newest sequence whose tombstones were dropped; an older cursor
    /// may have missed a deletion.
    private var droppedThrough = 0

    init(launchID: String = String(UUID().uuidString.prefix(8)).lowercased()) {
        self.launchID = launchID
    }

    /// Records the current snapshots and returns what changed after
    /// `cursor`. `snapshots` must hold every task, not only those the
    /// caller may see, so one caller's poll never hides a change from
    /// another.
    func observe(_ current: [UUID: Entry], since cursor: String?) -> Changes {
        var bumped = false
        func nextSequence() -> Int {
            if bumped == false {
                sequence += 1
                bumped = true
            }
            return sequence
        }
        for (id, entry) in current where entries[id]?.snapshot != entry.snapshot {
            if entries[id] == nil {
                createdAt[id] = nextSequence()
            }
            entries[id] = entry
            changedAt[id] = nextSequence()
        }
        for (id, entry) in entries where current[id] == nil {
            entries[id] = nil
            changedAt[id] = nil
            createdAt[id] = nil
            tombstones.append((id, nextSequence(), entry.visibility))
        }
        if tombstones.count > Self.maximumTombstones {
            let dropped = tombstones.prefix(tombstones.count - Self.maximumTombstones)
            droppedThrough = max(droppedThrough, dropped.map(\.sequence).max() ?? 0)
            tombstones.removeFirst(dropped.count)
        }

        let newCursor = "\(launchID).\(sequence)"
        guard let since = parse(cursor), since >= droppedThrough else {
            return Changes(changedTaskIDs: Set(current.keys), createdTaskIDs: [], deletedTasks: [], cursor: newCursor, reset: true)
        }
        return Changes(
            changedTaskIDs: Set(changedAt.compactMap { $0.value > since ? $0.key : nil }),
            createdTaskIDs: Set(createdAt.compactMap { $0.value > since ? $0.key : nil }),
            deletedTasks: tombstones.filter { $0.sequence > since }.map { ($0.id, $0.visibility) },
            cursor: newCursor,
            reset: false
        )
    }

    private func parse(_ cursor: String?) -> Int? {
        guard let cursor else { return nil }
        let parts = cursor.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0] == launchID, let value = Int(parts[1]), value >= 0, value <= sequence else {
            return nil
        }
        return value
    }
}
