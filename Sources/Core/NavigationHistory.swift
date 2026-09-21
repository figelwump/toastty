import Foundation

public enum NavigationHistoryDirection: Equatable, Sendable {
    case back
    case forward
}

public struct NavigationHistoryDestination: Equatable, Sendable {
    public let index: Int
    public let panelID: UUID

    public init(index: Int, panelID: UUID) {
        self.index = index
        self.panelID = panelID
    }
}

/// Session-only visits to panels. Live ownership and native focus remain the caller's responsibility.
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var entries: [UUID] = []
    public private(set) var cursor: Int?
    public let capacity: Int

    public init(capacity: Int = 100) {
        precondition(capacity > 0, "Navigation history capacity must be positive")
        self.capacity = capacity
    }

    /// Records successful explicit navigation between live panels. Maintenance focus changes do not call this.
    public mutating func recordVisit(from origin: UUID?, to destination: UUID) {
        guard origin != destination else { return }

        if let cursor {
            entries.removeSubrange((cursor + 1)..<entries.count)
        }

        // Closing a panel or activating a window can change the actual origin without moving the cursor.
        if let origin {
            appendUnlessAdjacentDuplicate(origin)
        }
        appendUnlessAdjacentDuplicate(destination)

        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        cursor = entries.count - 1
    }

    /// Looks beyond the cursor without mutating it, so failed selection leaves history unchanged.
    public func destination(
        direction: NavigationHistoryDirection,
        currentPanelID: UUID?,
        isLive: (UUID) -> Bool
    ) -> NavigationHistoryDestination? {
        guard let cursor else { return nil }
        let step = direction == .back ? -1 : 1
        var index = cursor + step
        while entries.indices.contains(index) {
            let panelID = entries[index]
            if panelID != currentPanelID, isLive(panelID) {
                return NavigationHistoryDestination(index: index, panelID: panelID)
            }
            index += step
        }
        return nil
    }

    /// Call only after the destination's synchronous selection succeeds.
    @discardableResult
    public mutating func commitTraversal(to index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        cursor = index
        return true
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        cursor = nil
    }

    private mutating func appendUnlessAdjacentDuplicate(_ panelID: UUID) {
        guard entries.last != panelID else { return }
        entries.append(panelID)
    }
}
