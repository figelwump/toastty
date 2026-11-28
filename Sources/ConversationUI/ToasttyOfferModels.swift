import Foundation
import Observation
import RemoteProtocol

// MARK: - What the chat knows about the answers

/// The user's answers to the coordinator's offers, read from the
/// conversation and from the messages that wait to be typed. The cards show
/// from it which offers the user answered, and which message holds the
/// offers that are open now.
public struct ToasttyOfferAnswers: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var choice: CoordinatorOfferAnswer.Choice
        /// The event of the answer's message. `nil` for a message that
        /// waits, or that is typed and not in the conversation yet.
        var sequence: UInt64?
    }

    /// The newest answer to each offer, by the offer's ID.
    private(set) var entries: [String: Entry] = [:]
    /// The event of the newest message with offers.
    private(set) var newestOffersSequence: UInt64?

    public init() {}

    /// Reads the answers in `events`, which are in the conversation's order.
    @MainActor
    public init(events: [ConversationEvent]) {
        for event in events {
            switch event.payload {
            case .userMessage(let payload):
                guard let answers = CoordinatorMessageHeader.offerAnswers(of: payload.text) else { continue }
                for answer in answers {
                    entries[answer.offerID] = Entry(choice: answer.choice, sequence: event.sequence)
                }
            case .assistantMessage(let payload):
                if Self.hasOffers(payload.text) { newestOffersSequence = event.sequence }
            default:
                break
            }
        }
    }

    /// These answers with those of the messages that wait or that the
    /// conversation does not show yet, as Toastty types them.
    public func adding(waitingMessages: [String]) -> Self {
        var result = self
        for text in waitingMessages {
            guard let answers = CoordinatorMessageHeader.offerAnswers(of: text) else { continue }
            for answer in answers {
                result.entries[answer.offerID] = Entry(choice: answer.choice, sequence: nil)
            }
        }
        return result
    }

    /// The user's answer to the offer `offerID` of the message at
    /// `sequence`. An answer counts for the offers that came before it: the
    /// coordinator can offer the same thing again later.
    public func choice(for offerID: String, offeredAt sequence: UInt64) -> CoordinatorOfferAnswer.Choice? {
        guard let entry = entries[offerID] else { return nil }
        if let answered = entry.sequence, answered < sequence { return nil }
        return entry.choice
    }

    /// The message at `sequence` holds the offers that are open now. An
    /// older message's cards take no answer: a newer list replaced them,
    /// also a list with no offers.
    public func takesAnswers(at sequence: UInt64) -> Bool {
        guard let newestOffersSequence else { return true }
        return sequence >= newestOffersSequence
    }

    /// The message draws offer cards. A chat reads its answers again for
    /// each new event: the parsed message comes from the cache that draws
    /// it.
    @MainActor
    static func hasOffers(_ text: String) -> Bool {
        guard text.contains(CoordinatorOfferGroup.fenceMarker) else { return false }
        return ToasttyMarkdownParser.cachedBlocks(text).contains { block in
            if case .offers = block.style { return true }
            return false
        }
    }
}

/// The agent's message that a block of offers is in.
struct ToasttyOfferRow: Equatable {
    var rowID: ToasttyTranscriptRowID
    var timestamp: Date
}

// MARK: - What the reader chose and opened

/// The choices that the user made on offer cards and did not send yet, and
/// the cards and folds that are open. The transcript holds one, so the
/// choices stay while a card's row is off screen.
@MainActor @Observable
final class ToasttyOfferSelections {
    struct Key: Hashable {
        var rowID: ToasttyTranscriptRowID
        var offerID: String
    }

    private(set) var choices: [Key: CoordinatorOfferAnswer.Choice] = [:]
    var openOffers: Set<Key> = []
    var groupsShowingMore: Set<ToasttyTranscriptRowID> = []
    var groupsShowingSkips: Set<ToasttyTranscriptRowID> = []

    /// A click on Yes or Skip chooses it. A click on the chosen one takes
    /// the choice back.
    func choose(_ choice: CoordinatorOfferAnswer.Choice, for key: Key) {
        choices[key] = choices[key] == choice ? nil : choice
    }

    /// The offers of `offers` that have no answer in `answers`.
    func unanswered(_ offers: [CoordinatorOffer], in row: ToasttyOfferRow, answers: ToasttyOfferAnswers) -> [CoordinatorOffer] {
        offers.filter { answers.choice(for: $0.id, offeredAt: row.rowID.sequence) == nil }
    }

    /// Skip is the choice for each of `offers` that has no answer.
    func allSkipped(_ offers: [CoordinatorOffer], in row: ToasttyOfferRow, answers: ToasttyOfferAnswers) -> Bool {
        let open = unanswered(offers, in: row, answers: answers)
        return open.isEmpty == false && open.allSatisfy { choices[Key(rowID: row.rowID, offerID: $0.id)] == .skip }
    }

    /// "Skip all": chooses Skip for each of `offers` that has no answer. A
    /// second click takes those choices back.
    func toggleSkipAll(_ offers: [CoordinatorOffer], in row: ToasttyOfferRow, answers: ToasttyOfferAnswers) {
        let takesBack = allSkipped(offers, in: row, answers: answers)
        for offer in unanswered(offers, in: row, answers: answers) {
            choices[Key(rowID: row.rowID, offerID: offer.id)] = takesBack ? nil : .skip
        }
    }

    /// The choices that are not sent, in the order of the offers. An offer
    /// that has its answer in `answers` takes no second one.
    func pendingAnswers(
        for group: CoordinatorOfferGroup,
        in row: ToasttyOfferRow,
        answers: ToasttyOfferAnswers
    ) -> [CoordinatorOfferAnswer] {
        unanswered(group.offers, in: row, answers: answers).compactMap { offer in
            choices[Key(rowID: row.rowID, offerID: offer.id)].map {
                CoordinatorOfferAnswer(offerID: offer.id, title: offer.plainTitle, choice: $0)
            }
        }
    }

    /// The host took these answers: they are choices no longer.
    func didSend(_ answers: [CoordinatorOfferAnswer], in row: ToasttyOfferRow) {
        for answer in answers {
            choices[Key(rowID: row.rowID, offerID: answer.offerID)] = nil
        }
    }
}

/// Which offers of a group show as cards at once.
struct ToasttyOfferGroupLayout: Equatable {
    /// At most this many offers show as cards before the reader asks for
    /// more.
    static let cardCount = 5

    /// The first offers that the coordinator suggests, as cards.
    var shown: [CoordinatorOffer]
    /// The other offers that it suggests, behind one line.
    var more: [CoordinatorOffer]
    /// The offers that it would skip, behind one line.
    var skips: [CoordinatorOffer]

    init(_ group: CoordinatorOfferGroup) {
        let suggested = group.offers.filter { $0.suggestion == .yes }
        shown = Array(suggested.prefix(Self.cardCount))
        more = Array(suggested.dropFirst(Self.cardCount))
        skips = group.offers.filter { $0.suggestion == .skip }
    }
}

extension CoordinatorOffer {
    /// The title as plain text on one line, without Markdown's marks.
    var plainTitle: String { ToasttyMessageQuote.excerpt(of: title) }

    /// "list 2 of 3", "list 3 of 3 · last time", or "new" on its first list.
    var listText: String? {
        guard let list else { return nil }
        if list == 1 { return "new" }
        guard let lists else { return "list \(list)" }
        return "list \(list) of \(lists)" + (isOnLastList ? " · last time" : "")
    }

    /// The card's details, each with its label. A rule's text is its line.
    var details: [(label: String, text: String)] {
        let isRule = kind?.lowercased() == "rule"
        let fields: [(String, String?)] = [
            (isRule ? "The line" : "What it does", what),
            ("When it helps", example),
            ("Why now", why),
            (isRule ? "A yes writes" : "A yes starts", yes),
        ]
        return fields.compactMap { label, text in text.map { (label, $0) } }
    }
}

@MainActor
enum ToasttyOfferGroupPresentation {
    /// A message as its accessibility label says it: the text around the
    /// offers, and the count of the offers in place of their data. A
    /// message without offers is its text.
    static func spokenText(of text: String) -> String {
        guard text.contains(CoordinatorOfferGroup.fenceMarker) else { return text }
        let blocks = ToasttyMarkdownParser.cachedBlocks(text)
        guard blocks.contains(where: { if case .offers = $0.style { true } else { false } }) else { return text }
        return blocks.compactMap { block in
            if case .offers(let group) = block.style {
                if group.offers.isEmpty { return nil }
                return group.offers.count == 1 ? "1 offer" : "\(group.offers.count) offers"
            }
            return String(block.content.characters)
        }.joined(separator: "\n")
    }

    static func footerText(takesAnswers: Bool, pending: Int, answered: Int, total: Int) -> String {
        guard takesAnswers else { return "A newer list has the offers that are open now." }
        if pending > 0 { return pending == 1 ? "1 answer not sent" : "\(pending) answers not sent" }
        if answered == 0 { return "No answers yet" }
        return answered >= total ? "All \(total) answered" : "\(answered) of \(total) answered"
    }
}
