import Foundation

/// The cards the coordinator chat shows, in time order, built from the
/// coordinator's posts in `events.jsonl` and the packets each task
/// published. A card holds only what names it; the chat reads everything
/// else from the task's live state.
///
/// Each task has one card at its newest activity. Its latest question or
/// task event supplies the content until a newer packet is published.
/// An unanswered question stays visible until the user answers it. Earlier questions and replies stay in the task's bounded thread.
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
        public var answerPending: Bool
        public var answeredQuestionIDs: [UUID] = []
        public var thread: [ThreadEntry]
        /// True for each surviving task card.
        public var isCurrent: Bool
        /// The task's latest packet, including on a question or start card.
        public var packetVersion: Int?
        /// Published packet versions, oldest version first.
        public var packetVersions: [Int]
        /// Retained for callers; folded task cards are never superseded.
        public var superseded: Bool
        /// The task has a packet after the first version the chat showed.
        public var isNew: Bool

        public init(
            id: String,
            at: Date,
            kind: CoordinatorEvent.Kind,
            taskID: UUID?,
            text: String?,
            packetVersion: Int? = nil,
            packetVersions: [Int] = [],
            superseded: Bool = false,
            isNew: Bool = false,
            options: [String] = [],
            answer: String? = nil,
            answerPending: Bool = false,
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
            self.answerPending = answerPending
            self.thread = thread
            self.isCurrent = isCurrent
            self.packetVersion = packetVersion
            self.packetVersions = packetVersions
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
        var sources = Set<SourceKey>()
        let orderedEvents = events.enumerated().sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }.filter { _, event in
            guard let sourceID = event.sourceID else { return true }
            return sources.insert(SourceKey(taskID: event.taskID, sourceID: sourceID)).inserted
        }
        // A provider reply can carry a timestamp before its question. Match
        // by identity independently of the activity order used for cards.
        var questions: [UUID: CoordinatorEvent] = [:]
        for (_, event) in orderedEvents where event.kind == .question { questions[event.id] = event }
        // Delivery updates reuse the reply ID. State only advances, so a
        // delayed pending record cannot undo rejection or acceptance.
        var routeReplyOrders: [UUID: Int] = [:]
        var routeReplyRanks: [UUID: Int] = [:]
        for (order, event) in orderedEvents where event.kind == .reply && event.taskID == nil {
            let rank: Int
            switch event.delivery {
            case .pending: rank = 0
            case .rejected: rank = 1
            case .accepted, nil: rank = 2
            }
            if let previous = routeReplyRanks[event.id], previous > rank { continue }
            routeReplyRanks[event.id] = rank
            routeReplyOrders[event.id] = order
        }
        var cards: [PositionedCard] = []
        var tasks: [UUID: TaskCard] = [:]
        var threads: [UUID: [ThreadEntry]] = [:]
        var latestTaskQuestions: [UUID: CoordinatorEvent] = [:]
        var answers: [UUID: String] = [:]
        var pendingAnswers = Set<UUID>()
        for (order, event) in orderedEvents {
            if event.kind == .reply, event.taskID == nil, routeReplyOrders[event.id] != order { continue }
            if event.kind == .reply || (event.kind == .note && event.taskID != nil) {
                // Delivery states are used for taskless routing. If a task
                // reply carries one, only acceptance can enter its thread.
                if event.kind == .reply, event.taskID != nil,
                   event.delivery == .pending || event.delivery == .rejected { continue }
                guard let text = event.text,
                      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      let role = event.kind == .note ? .coordinator : event.threadRole else { continue }
                if event.kind == .reply, let questionID = event.questionID,
                   let question = questions[questionID], question.taskID == event.taskID,
                   answers[questionID] == nil {
                    if question.taskID != nil, role == .userTask || role == .userCoordinator {
                        answers[questionID] = text
                    } else if question.taskID == nil, role == .userCoordinator, question.options.contains(text) {
                        switch event.delivery {
                        case .pending: pendingAnswers.insert(questionID)
                        case .accepted, nil: answers[questionID] = text
                        case .rejected: break
                        }
                    }
                }
                guard let taskID = event.taskID else { continue }
                threads[taskID, default: []].append(ThreadEntry(id: event.id.uuidString, at: event.at, role: role, text: text))
                // Notes can introduce a task before its first start, packet,
                // or question event. Replies alone do not introduce cards.
                if event.kind == .note, tasks[taskID] == nil {
                    tasks[taskID] = TaskCard(
                        card: Card(id: event.id.uuidString, at: event.at, kind: .taskStarted, taskID: taskID, text: nil),
                        contentAt: .distantPast, firstAt: event.at, order: order
                    )
                }
                if tasks[taskID] != nil {
                    tasks[taskID]?.card.at = event.at
                    tasks[taskID]?.order = order
                }
                continue
            }
            let card = Card(
                id: event.id.uuidString, at: event.at, kind: event.kind,
                taskID: event.taskID, text: event.text, options: event.options
            )
            if event.kind == .question {
                if let taskID = event.taskID { latestTaskQuestions[taskID] = event }
                if let taskID = event.taskID, let text = event.text,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    threads[taskID, default: []].append(ThreadEntry(
                        id: event.id.uuidString, at: event.at, role: .coordinator, text: text
                    ))
                }
            }
            if let taskID = event.taskID {
                tasks[taskID] = TaskCard(
                    card: card, contentAt: event.at, firstAt: tasks[taskID]?.firstAt ?? event.at, order: order
                )
            } else {
                cards.append(PositionedCard(card: card, order: order))
            }
        }

        // A task's card follows its latest activity, while notes and replies
        // leave the content intact. Packet timestamps can update both.
        for (packetOrder, taskID) in tasks.keys.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            guard var task = tasks[taskID] else { continue }
            // A later task event must not hide a question that still needs
            // an answer. Its timestamp continues to count as task activity.
            if task.card.kind != .question, let question = latestTaskQuestions[taskID], answers[question.id] == nil {
                task.card.id = question.id.uuidString
                task.card.kind = .question
                task.card.text = question.text
                task.card.options = question.options
                task.contentAt = question.at
            }
            let hasOpenQuestion = task.card.kind == .question
                && UUID(uuidString: task.card.id).map { answers[$0] == nil } == true
            let versions = (packets[taskID] ?? []).sorted {
                $0.version == $1.version ? $0.createdAt < $1.createdAt : $0.version < $1.version
            }
            var seenVersions = Set<Int>()
            task.card.packetVersions = versions.compactMap { seenVersions.insert($0.version).inserted ? $0.version : nil }
            if let latest = versions.last {
                task.card.packetVersion = latest.version
                let firstShown = versions.last { $0.createdAt <= task.firstAt } ?? versions.first
                task.card.isNew = firstShown.map { latest.version > $0.version } ?? false
                if latest.createdAt > task.contentAt, hasOpenQuestion == false {
                    task.card.id = "packet-\(taskID.uuidString)-v\(latest.version)"
                    task.card.kind = .packet
                    task.card.text = nil
                    task.card.options = []
                }
                if latest.createdAt > task.card.at {
                    task.card.at = latest.createdAt
                    task.order = events.count + packetOrder
                }
            }
            task.card.isCurrent = true
            task.card.answeredQuestionIDs = questions.values.filter {
                $0.taskID == taskID && answers[$0.id] != nil
            }.map(\.id).sorted { $0.uuidString < $1.uuidString }
            // The visible question is already on the card. Keep all earlier
            // questions in time order with the notes and replies.
            task.card.thread = Array((threads[taskID] ?? []).filter {
                task.card.kind != .question || $0.id != task.card.id
            }.suffix(maximumThreadEntries))
            cards.append(PositionedCard(card: task.card, order: task.order))
        }
        return cards.sorted {
            $0.card.at == $1.card.at ? $0.order < $1.order : $0.card.at < $1.card.at
        }.map { positioned in
            var card = positioned.card
            if card.kind == .question, let questionID = UUID(uuidString: card.id) {
                card.answer = answers[questionID]
                card.answerPending = card.answer == nil && pendingAnswers.contains(questionID)
            }
            return card
        }
    }

    private struct TaskCard {
        var card: Card
        var contentAt: Date
        var firstAt: Date
        var order: Int
    }

    private struct PositionedCard {
        var card: Card
        var order: Int
    }

    private struct SourceKey: Hashable {
        var taskID: UUID?
        var sourceID: String
    }
}
