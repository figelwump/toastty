import Foundation

/// The cards the coordinator chat shows, in time order, built from the
/// coordinator's posts in `events.jsonl` and the packets each task
/// published. A card holds only what names it; the chat reads everything
/// else from the task's live state.
///
/// A packet card shows the packet that was newest when it was posted.
/// When a task's agent publishes a newer version, the chat adds a card for
/// it at the time it was published, marked new, and earlier packet cards for
/// that task collapse to one line.
public enum CoordinatorChatTimeline {
    public struct PacketStamp: Equatable, Sendable {
        public var version: Int
        public var createdAt: Date

        public init(version: Int, createdAt: Date) {
            self.version = version
            self.createdAt = createdAt
        }
    }

    public struct Card: Equatable, Sendable {
        /// The event's ID, or `packet-<task>-v<N>` for a card the chat added
        /// for a newer packet.
        public var id: String
        public var at: Date
        public var kind: CoordinatorEvent.Kind
        public var taskID: UUID?
        public var text: String?
        /// For a packet card: the version it shows. `nil` when the task has no
        /// packet yet.
        public var packetVersion: Int?
        /// A packet card for a version that a newer one replaced.
        public var superseded: Bool
        /// A packet card for a version after the first one the chat showed.
        public var isNew: Bool

        public init(
            id: String,
            at: Date,
            kind: CoordinatorEvent.Kind,
            taskID: UUID?,
            text: String?,
            packetVersion: Int? = nil,
            superseded: Bool = false,
            isNew: Bool = false
        ) {
            self.id = id
            self.at = at
            self.kind = kind
            self.taskID = taskID
            self.text = text
            self.packetVersion = packetVersion
            self.superseded = superseded
            self.isNew = isNew
        }
    }

    /// How long after a card's time a packet still counts as the one it
    /// announced, when no packet existed yet: the coordinator may post just
    /// before the publish lands.
    public static let postingSlack: TimeInterval = 60

    /// `packets` holds each task's published versions, in any order.
    public static func cards(events: [CoordinatorEvent], packets: [UUID: [PacketStamp]]) -> [Card] {
        let stamps = packets.mapValues { $0.sorted { $0.version < $1.version } }
        var cards = events.map { event -> Card in
            var card = Card(id: event.id.uuidString, at: event.at, kind: event.kind, taskID: event.taskID, text: event.text)
            if event.kind == .packet, let taskID = event.taskID, let versions = stamps[taskID] {
                // The newest packet at the card's time; a later one is a new
                // version, not what this card announced.
                let announced = versions.last { $0.createdAt <= event.at }
                    ?? versions.first { $0.createdAt <= event.at.addingTimeInterval(postingSlack) }
                card.packetVersion = announced?.version
            }
            return card
        }

        // A task with any card gets a card for each packet no card announces:
        // the latest, and each one published after the task's first card.
        // So an added v1 card stays, collapsed, when v2 comes, whether or
        // not the coordinator posts a card for v2.
        let taskIDs = Set(cards.compactMap(\.taskID))
        for taskID in taskIDs {
            let taskCards = cards.filter { $0.taskID == taskID }
            let announced = Set(taskCards.filter { $0.kind == .packet }.compactMap(\.packetVersion))
            let firstCardAt = taskCards.map(\.at).min() ?? .distantPast
            let latest = stamps[taskID]?.last?.version
            for stamp in stamps[taskID] ?? []
            where announced.contains(stamp.version) == false && (stamp.createdAt >= firstCardAt || stamp.version == latest) {
                cards.append(Card(
                    id: "packet-\(taskID.uuidString)-v\(stamp.version)",
                    at: stamp.createdAt,
                    kind: .packet,
                    taskID: taskID,
                    text: nil,
                    packetVersion: stamp.version
                ))
            }
        }

        // The first card for the latest version stays open; every other
        // packet card of the task collapses.
        for taskID in taskIDs {
            let indices = cards.indices.filter { cards[$0].taskID == taskID && cards[$0].kind == .packet }
            guard let latest = stamps[taskID]?.last?.version else { continue }
            let current = indices.first { cards[$0].packetVersion == latest }
            let earliestShown = indices.compactMap { cards[$0].packetVersion }.min()
            for index in indices {
                if index == current {
                    cards[index].isNew = earliestShown.map { latest > $0 } ?? false
                } else {
                    cards[index].superseded = true
                }
            }
        }
        // Stable for cards at the same time: events keep file order.
        return cards.enumerated()
            .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }
            .map(\.element)
    }
}
