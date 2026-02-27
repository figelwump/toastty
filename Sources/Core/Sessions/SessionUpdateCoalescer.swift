import Foundation

public struct SessionFileUpdate: Equatable, Sendable {
    public var sessionID: String
    public var files: [String]
    public var cwd: String?
    public var repoRoot: String?

    public init(sessionID: String, files: [String], cwd: String?, repoRoot: String?) {
        self.sessionID = sessionID
        self.files = files
        self.cwd = cwd
        self.repoRoot = repoRoot
    }
}

public struct CoalescedSessionUpdate: Equatable, Sendable {
    public var sessionID: String
    public var files: [String]
    public var cwd: String?
    public var repoRoot: String?
    public var firstEventAt: Date
    public var lastEventAt: Date

    public init(
        sessionID: String,
        files: [String],
        cwd: String?,
        repoRoot: String?,
        firstEventAt: Date,
        lastEventAt: Date
    ) {
        self.sessionID = sessionID
        self.files = files
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
    }
}

public struct SessionUpdateCoalescer: Equatable, Sendable {
    public var window: TimeInterval
    private var pendingBySessionID: [String: CoalescedSessionUpdate]

    public init(window: TimeInterval = 0.5) {
        self.window = window
        self.pendingBySessionID = [:]
    }

    public mutating func ingest(_ update: SessionFileUpdate, at now: Date) {
        if var pending = pendingBySessionID[update.sessionID] {
            var seen = Set(pending.files)
            for file in update.files where seen.insert(file).inserted {
                pending.files.append(file)
            }

            // Nil values mean "no update" so previously known non-nil context is preserved.
            if let cwd = update.cwd {
                pending.cwd = cwd
            }
            if let repoRoot = update.repoRoot {
                pending.repoRoot = repoRoot
            }
            pending.lastEventAt = now
            pendingBySessionID[update.sessionID] = pending
            return
        }

        pendingBySessionID[update.sessionID] = CoalescedSessionUpdate(
            sessionID: update.sessionID,
            files: deduplicatePreservingOrder(update.files),
            cwd: update.cwd,
            repoRoot: update.repoRoot,
            firstEventAt: now,
            lastEventAt: now
        )
    }

    public mutating func flushReady(at now: Date) -> [CoalescedSessionUpdate] {
        var ready: [CoalescedSessionUpdate] = []
        for update in pendingBySessionID.values where now.timeIntervalSince(update.lastEventAt) >= window {
            ready.append(update)
        }

        ready.sort {
            if $0.lastEventAt == $1.lastEventAt {
                return $0.sessionID < $1.sessionID
            }
            return $0.lastEventAt < $1.lastEventAt
        }
        for update in ready {
            pendingBySessionID.removeValue(forKey: update.sessionID)
        }
        return ready
    }

    public mutating func flushAll() -> [CoalescedSessionUpdate] {
        var updates = Array(pendingBySessionID.values)
        updates.sort {
            if $0.lastEventAt == $1.lastEventAt {
                return $0.sessionID < $1.sessionID
            }
            return $0.lastEventAt < $1.lastEventAt
        }
        pendingBySessionID.removeAll(keepingCapacity: true)
        return updates
    }

    private func deduplicatePreservingOrder(_ files: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(files.count)
        for file in files where seen.insert(file).inserted {
            ordered.append(file)
        }
        return ordered
    }
}
