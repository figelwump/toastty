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
    public struct ThreadEntry: Codable, Equatable, Sendable {
        public var id: String
        public var at: Date
        public var role: CoordinatorEvent.ThreadRole
        public var text: String

        public init(id: String, at: Date, role: CoordinatorEvent.ThreadRole, text: String) {
            self.id = id
            self.at = at
            self.role = role
            self.text = text
        }
    }

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
        public var options: [String]
        public var answer: String?
        public var thread: [ThreadEntry]
        /// The newest card for this task that a later packet did not replace.
        public var isCurrent: Bool
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
            isNew: Bool = false,
            options: [String] = [],
            answer: String? = nil,
            thread: [ThreadEntry] = [],
            isCurrent: Bool = false
        ) {
            self.id = id
            self.at = at
            self.kind = kind
            self.taskID = taskID
            self.text = text
            self.options = options
            self.answer = answer
            self.thread = thread
            self.isCurrent = isCurrent
            self.packetVersion = packetVersion
            self.superseded = superseded
            self.isNew = isNew
        }
    }

    /// How long after a card's time a packet still counts as the one it
    /// announced, when no packet existed yet: the coordinator may post just
    /// before the publish lands.
    public static let postingSlack: TimeInterval = 60
    public static let maximumThreadEntries = 100

    /// `packets` holds each task's published versions, in any order.
    public static func cards(events: [CoordinatorEvent], packets: [UUID: [PacketStamp]]) -> [Card] {
        let stamps = packets.mapValues { $0.sorted { $0.version < $1.version } }
        var cards: [Card] = []
        var threads: [UUID: [ThreadEntry]] = [:]
        var questions: [UUID: UUID] = [:]
        var answers: [UUID: String] = [:]
        var sources = Set<SourceKey>()
        var anchors: [UUID: String] = [:]
        var tasksWithCards = Set<UUID>()
        for event in events {
            if let sourceID = event.sourceID,
               sources.insert(SourceKey(taskID: event.taskID, sourceID: sourceID)).inserted == false {
                continue
            }
            if event.kind == .reply || (event.kind == .note && event.taskID != nil) {
                guard let taskID = event.taskID, let text = event.text,
                      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      let role = event.kind == .note ? .coordinator : event.threadRole else { continue }
                threads[taskID, default: []].append(ThreadEntry(id: event.id.uuidString, at: event.at, role: role, text: text))
                if event.kind == .reply, role == .userTask || role == .userCoordinator,
                   let questionID = event.questionID, questions[questionID] == taskID, answers[questionID] == nil {
                    answers[questionID] = text
                }
                // A scoped note can precede the task's first card. Keep one
                // anchor if no other card exists, so its thread stays visible.
                if event.kind == .note, anchors[taskID] == nil {
                    anchors[taskID] = event.id.uuidString
                    cards.append(Card(id: event.id.uuidString, at: event.at, kind: .taskStarted, taskID: taskID, text: nil))
                }
                continue
            }
            var card = Card(
                id: event.id.uuidString, at: event.at, kind: event.kind,
                taskID: event.taskID, text: event.text, options: event.options
            )
            if let taskID = event.taskID {
                tasksWithCards.insert(taskID)
                if event.kind == .question { questions[event.id] = taskID }
            }
            if event.kind == .packet, let taskID = event.taskID, let versions = stamps[taskID] {
                // The newest packet at the card's time; a later one is a new
                // version, not what this card announced.
                let announced = versions.last { $0.createdAt <= event.at }
                    ?? versions.first { $0.createdAt <= event.at.addingTimeInterval(postingSlack) }
                card.packetVersion = announced?.version
            }
            cards.append(card)
        }
        cards.removeAll { card in
            guard let taskID = card.taskID else { return false }
            return tasksWithCards.contains(taskID) && anchors[taskID] == card.id
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
        cards = cards.enumerated()
            .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }
            .map(\.element)
        let recentThreads = threads.mapValues { entries in
            Array(entries.enumerated()
                .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }
                .suffix(maximumThreadEntries)
                .map(\.element))
        }
        var currentCards: [UUID: Int] = [:]
        for index in cards.indices {
            if let taskID = cards[index].taskID {
                cards[index].thread = recentThreads[taskID] ?? []
                if cards[index].superseded == false { currentCards[taskID] = index }
            }
            if cards[index].kind == .question, let questionID = UUID(uuidString: cards[index].id) {
                cards[index].answer = answers[questionID]
            }
        }
        for index in currentCards.values { cards[index].isCurrent = true }
        return cards
    }

    private struct SourceKey: Hashable {
        var taskID: UUID?
        var sourceID: String
    }
}
