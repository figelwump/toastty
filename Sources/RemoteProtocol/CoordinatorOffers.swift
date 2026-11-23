import Foundation

/// A task or a policy rule that the coordinator offers the user.
///
/// The coordinator writes its open offers as one fenced code block with the
/// language `toastty-offers` in a chat message, and the coordinator's chat
/// draws the block as one group of cards. The block is data from an agent:
/// the chat shows its text, and only the user's click on a card answers an
/// offer (`CoordinatorMessageHeader.answersMessage`).
public struct CoordinatorOffer: Equatable, Sendable, Identifiable {
    /// The answer that the coordinator suggests.
    public enum Suggestion: String, Equatable, Sendable {
        case yes
        case skip
    }

    /// The coordinator's name for the offer, the same on each list that
    /// shows it. The user's answer names the offer by it.
    public var id: String
    /// What a yes makes, such as "task" or "rule". The card shows it as a
    /// short label.
    public var kind: String?
    public var title: String
    /// What the task does, or the line of the rule.
    public var what: String?
    /// A case in which the offer helps.
    public var example: String?
    /// Why the coordinator offers it now.
    public var why: String?
    /// What a yes starts or writes.
    public var yes: String?
    public var suggestion: Suggestion
    /// On which list the offer is, counted from 1, and after how many
    /// lists the coordinator drops it.
    public var list: Int?
    public var lists: Int?

    public init(
        id: String,
        kind: String? = nil,
        title: String,
        what: String? = nil,
        example: String? = nil,
        why: String? = nil,
        yes: String? = nil,
        suggestion: Suggestion = .yes,
        list: Int? = nil,
        lists: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.what = what
        self.example = example
        self.why = why
        self.yes = yes
        self.suggestion = suggestion
        self.list = list
        self.lists = lists
    }

    /// The offer is on its last list: the coordinator drops it after this
    /// one.
    public var isOnLastList: Bool {
        guard let list, let lists else { return false }
        return list >= lists
    }

    /// The longest ID. An ID is one word of ASCII letters, digits, `-`,
    /// `_` and `.`, so an answer's line names it exactly.
    public static let maximumIDLength = 64

    public static func isID(_ text: String) -> Bool {
        guard text.isEmpty == false, text.count <= maximumIDLength else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == ".")
        }
    }
}

/// The offers of one message.
public struct CoordinatorOfferGroup: Equatable, Sendable {
    /// The language of the fenced code block that holds the offers.
    public static let codeLanguage = "toastty-offers"
    /// A message with offers contains this text. A message without it has
    /// none, so a reader need not parse it.
    public static let fenceMarker = "```" + codeLanguage
    /// A block with more offers than this is not a group.
    public static let maximumOfferCount = 50

    public var offers: [CoordinatorOffer]

    public init(offers: [CoordinatorOffer]) {
        self.offers = offers
    }

    /// Reads the text of a `toastty-offers` block: `{"offers": [...]}`, or
    /// the array alone. `nil` when the text is not JSON, when it has no
    /// offer, or when an offer has no title or no usable ID, or an ID that
    /// another offer of the block has. The chat then shows the block as
    /// the text it is, so a broken block stays visible.
    public init?(json: String) {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        let decoded: [Wire]
        if let wrapped = try? decoder.decode(WireGroup.self, from: data) {
            decoded = wrapped.offers
        } else if let list = try? decoder.decode([Wire].self, from: data) {
            decoded = list
        } else {
            return nil
        }
        guard decoded.isEmpty == false, decoded.count <= Self.maximumOfferCount else { return nil }
        var seen: Set<String> = []
        var offers: [CoordinatorOffer] = []
        for wire in decoded {
            let title = Self.oneLine(wire.title)
            guard CoordinatorOffer.isID(wire.id), title.isEmpty == false, seen.insert(wire.id).inserted else { return nil }
            offers.append(CoordinatorOffer(
                id: wire.id,
                kind: wire.kind.map(Self.oneLine).flatMap { $0.isEmpty ? nil : String($0.prefix(12)) },
                title: title,
                what: Self.text(wire.what),
                example: Self.text(wire.example),
                why: Self.text(wire.why),
                yes: Self.text(wire.yes),
                suggestion: wire.suggested.flatMap { CoordinatorOffer.Suggestion(rawValue: $0.lowercased()) } ?? .yes,
                list: wire.list.flatMap { $0 > 0 ? $0 : nil },
                lists: wire.lists.flatMap { $0 > 0 ? $0 : nil }
            ))
        }
        self.offers = offers
    }

    private struct WireGroup: Decodable {
        var offers: [Wire]
    }

    private struct Wire: Decodable {
        var id: String
        var kind: String?
        var title: String
        var what: String?
        var example: String?
        var why: String?
        var yes: String?
        var suggested: String?
        var list: Int?
        var lists: Int?
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func text(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}

/// The user's answer to one offer, from a click on its card.
public struct CoordinatorOfferAnswer: Equatable, Sendable {
    public enum Choice: String, Equatable, Sendable {
        case yes
        case skip
    }

    public var offerID: String
    /// The offer's title as the card showed it, so that the answer says
    /// what the user saw.
    public var title: String
    public var choice: Choice

    public init(offerID: String, title: String, choice: Choice) {
        self.offerID = offerID
        self.title = title
        self.choice = choice
    }
}

extension CoordinatorMessageHeader {
    // MARK: - Answers to offers

    /// The first words of the user's answers to offers, from the cards of
    /// the coordinator's chat.
    public static let answersPrefix = "[Toastty] Answers from the user"
    static let answersOffersLabel = " | to your offers"

    /// The first line of the user's answers. The number of answers says
    /// where they end.
    public static func answersLine(count: Int, time: String?) -> String {
        let when = time.map { " of \(replyTime($0))" } ?? ""
        let answers = count == 1 ? "1 answer" : "\(count) answers"
        return "\(answersPrefix)\(answersOffersLabel)\(when), \(answers)"
    }

    /// The text to type for the user's answers: Toastty's first line, then
    /// one line for each answer with the choice, the offer's ID and its
    /// title, such as `- yes: safari-check "A check of the sign-up page"`.
    /// `time` is when the coordinator wrote the message with the offers.
    public static func answersMessage(_ answers: [CoordinatorOfferAnswer], time: String?) -> String {
        ([answersLine(count: answers.count, time: time)] + answers.map(answerLine)).joined(separator: "\n")
    }

    static func answerLine(_ answer: CoordinatorOfferAnswer) -> String {
        "- \(answer.choice.rawValue): \(answer.offerID) \(quoted(answer.title))"
    }

    /// The answers of a message as `answersMessage` wrote it. `nil` for any
    /// other message, also when its first line promises more answers than
    /// follow or a line is not an answer.
    public static func offerAnswers(of message: String) -> [CoordinatorOfferAnswer]? {
        guard message.hasPrefix(answersPrefix) else { return nil }
        let lines = message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, first.hasPrefix(answersPrefix + answersOffersLabel) else { return nil }
        guard let comma = first.range(of: ", ", options: .backwards) else { return nil }
        let countWords = first[comma.upperBound...].split(separator: " ")
        guard countWords.count == 2, countWords[1] == "answer" || countWords[1] == "answers",
              let count = Int(countWords[0]), count > 0, lines.count > count else { return nil }
        var answers: [CoordinatorOfferAnswer] = []
        for line in lines.dropFirst().prefix(count) {
            guard let answer = offerAnswer(inLine: line) else { return nil }
            answers.append(answer)
        }
        return answers
    }

    private static func offerAnswer(inLine line: Substring) -> CoordinatorOfferAnswer? {
        guard line.hasPrefix("- "), let colon = line.range(of: ": ") else { return nil }
        guard let choice = CoordinatorOfferAnswer.Choice(rawValue: String(line[line.index(line.startIndex, offsetBy: 2)..<colon.lowerBound])) else {
            return nil
        }
        let rest = line[colon.upperBound...]
        guard let space = rest.firstIndex(of: " ") else { return nil }
        let id = String(rest[..<space])
        let title = rest[rest.index(after: space)...]
        guard CoordinatorOffer.isID(id), title.count >= 2, title.hasPrefix("\""), title.hasSuffix("\"") else { return nil }
        return CoordinatorOfferAnswer(offerID: id, title: String(title.dropFirst().dropLast()), choice: choice)
    }

    /// The answers as the user's bubble shows them: one line for each, such
    /// as "Yes: A check of the sign-up page".
    static func answersDisplayText(_ answers: [CoordinatorOfferAnswer]) -> String {
        answers.map { answer in
            "\(answer.choice == .yes ? "Yes" : "Skip"): \(answer.title)"
        }.joined(separator: "\n")
    }

    // MARK: - A question about one offer

    /// The message that the user's question about one offer answers: one
    /// line that names the offer. The question is a reply that quotes it
    /// (`replyMessage`), so the coordinator reads which offer the user
    /// asks about.
    public static func offerQuote(_ offer: CoordinatorOffer) -> String {
        "Offer \(offer.id): \(offer.title)"
    }
}
