import CoreState
import Foundation

/// What the sidebar shows of each task's cards in the coordinator chat. The
/// chat controller updates it after each refresh and each time an open page
/// says what it shows, so the sidebar never reads `events.jsonl` to draw.
@MainActor
final class CoordinatorChatCardIndex: ObservableObject {
    struct TaskCards: Equatable {
        /// The kind of the task's newest card.
        var latestKind: CoordinatorEvent.Kind
        /// Whether the task's current packet card is marked new: a packet
        /// version after the first one the chat showed.
        var isNew: Bool
    }

    /// An index that stays empty, for hosts without the chat.
    static let disabled = CoordinatorChatCardIndex()

    @Published private(set) var tasks: [UUID: TaskCards] = [:]
    /// The task whose card the chat page has open, while the page shows the
    /// chat rather than All tasks.
    @Published private(set) var openTaskID: UUID?

    func update(tasks: [UUID: TaskCards], openTaskID: UUID?) {
        // Publishing only changes keeps the sidebar from redrawing on every
        // chat refresh.
        if self.tasks != tasks { self.tasks = tasks }
        if self.openTaskID != openTaskID { self.openTaskID = openTaskID }
    }

    /// Each task's cards, from chat items in time order.
    static func tasks(from items: [CoordinatorChatItem]) -> [UUID: TaskCards] {
        var result: [UUID: TaskCards] = [:]
        for item in items {
            guard case .card(let card) = item,
                  let taskID = card.task.flatMap({ UUID(uuidString: $0.id) }),
                  let kind = CoordinatorEvent.Kind(rawValue: card.kind) else { continue }
            var cards = result[taskID] ?? TaskCards(latestKind: kind, isNew: false)
            cards.latestKind = kind
            if kind == .packet, card.superseded == false { cards.isNew = card.isNew }
            result[taskID] = cards
        }
        return result
    }
}
