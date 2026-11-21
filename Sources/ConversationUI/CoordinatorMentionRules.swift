import Foundation

// The rules for mentioning a task in a message to the coordinator, which
// the Mac's and the phone's coordinator chats share: where `@` starts a
// mention, and which tasks the list shows for what the user typed. Each app
// makes the candidates from its own task board and draws them its own way.

/// A task that the user can mention in a message to the coordinator.
public struct CoordinatorMentionCandidate: Equatable, Identifiable, Sendable {
    /// The list's groups, in the order the Tasks view lists them.
    public enum Group: Int, CaseIterable, Comparable, Sendable {
        case needsYou, working, idle, toShip, done, archived

        public var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .idle: "Idle"
            case .toShip: "To ship"
            case .done: "Done"
            case .archived: "Archived"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let taskID: UUID
    public var title: String
    public var projectTitle: String?
    public var pullRequestNumber: Int?
    public var group: Group
    /// The color of the task's stage dot.
    public var markColor: ConversationChipColor
    /// When a done task finished. The list shows recent ones before a
    /// search.
    public var doneAt: Date?

    public var id: UUID { taskID }

    public init(
        taskID: UUID,
        title: String,
        projectTitle: String?,
        pullRequestNumber: Int?,
        group: Group,
        markColor: ConversationChipColor,
        doneAt: Date?
    ) {
        self.taskID = taskID
        self.title = title
        self.projectTitle = projectTitle
        self.pullRequestNumber = pullRequestNumber
        self.group = group
        self.markColor = markColor
        self.doneAt = doneAt
    }

    /// A mention shows at most this many characters of the title.
    public static let maximumLabelLength = 40

    /// The title as a mention shows it: on one line, and shortened with an
    /// ellipsis when it is long.
    public static func label(title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.isEmpty == false else { return "Untitled task" }
        return oneLine.count > maximumLabelLength ? oneLine.prefix(maximumLabelLength - 1) + "…" : oneLine
    }
}

/// Which tasks the list shows for what the user typed after `@`.
public enum CoordinatorMentionSearch {
    public struct Section: Equatable, Identifiable, Sendable {
        public let group: CoordinatorMentionCandidate.Group
        public var candidates: [CoordinatorMentionCandidate]
        public var id: CoordinatorMentionCandidate.Group { group }

        public init(group: CoordinatorMentionCandidate.Group, candidates: [CoordinatorMentionCandidate]) {
            self.group = group
            self.candidates = candidates
        }
    }

    /// Before a search, the list shows done tasks that finished in this
    /// time. Older ones, and archived ones, show only for a search.
    public static let recentDoneInterval: TimeInterval = 14 * 24 * 60 * 60
    public static let maximumResults = 50

    /// The tasks that match `query`, by group in the Tasks view's order, and
    /// within a group in the order of `candidates`.
    public static func sections(
        query: String,
        candidates: [CoordinatorMentionCandidate],
        now: Date
    ) -> [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let listed: [CoordinatorMentionCandidate]
        if trimmed.isEmpty {
            listed = candidates.filter { candidate in
                switch candidate.group {
                case .archived: false
                case .done: candidate.doneAt.map { now.timeIntervalSince($0) <= recentDoneInterval } ?? false
                default: true
                }
            }
        } else {
            listed = candidates.filter { matches($0, query: trimmed) }
        }
        var sections: [Section] = []
        var count = 0
        for group in CoordinatorMentionCandidate.Group.allCases {
            let inGroup = listed.filter { $0.group == group }.prefix(maximumResults - count)
            guard inGroup.isEmpty == false else { continue }
            sections.append(Section(group: group, candidates: Array(inGroup)))
            count += inGroup.count
            if count >= maximumResults { break }
        }
        return sections
    }

    /// `#331` matches pull requests whose number starts with 331. Other
    /// text matches when each of its words is in the title or the project's
    /// name; digits alone also match a pull request number.
    public static func matches(_ candidate: CoordinatorMentionCandidate, query: String) -> Bool {
        if query.hasPrefix("#") {
            let digits = query.dropFirst()
            guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return false }
            guard let number = candidate.pullRequestNumber else { return false }
            return String(number).hasPrefix(digits)
        }
        if query.allSatisfy({ $0.isASCII && $0.isNumber }),
           let number = candidate.pullRequestNumber, String(number).hasPrefix(query) {
            return true
        }
        let haystack = [candidate.title, candidate.projectTitle ?? ""].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            haystack.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Whether the list closes for this search: a search of several words
    /// that matches nothing, so that ordinary text typed after an `@` does
    /// not keep the list open. One word that matches nothing keeps it open,
    /// to say that nothing matches.
    public static func endsTheSearch(query: String, sections: [Section]) -> Bool {
        sections.isEmpty && query.contains(where: \.isWhitespace)
    }
}

/// The `@` that starts a mention: at the start of the text, or after a
/// space or an opening bracket or quote, so that an email address starts
/// none. The words typed after it, on one line, are the search.
public enum CoordinatorMentionTrigger {
    public struct Match: Equatable, Sendable {
        /// The location of the `@`, in UTF-16 units.
        public var anchor: Int
        public var query: String

        public init(anchor: Int, query: String) {
            self.anchor = anchor
            self.query = query
        }
    }

    public static let maximumQueryLength = 60

    /// U+FFFC: a mention that the text shows as one object, such as the
    /// Mac's chip. The search stops before it, and an `@` right after it
    /// starts a mention.
    public static let objectReplacementCharacter: UInt16 = 0xFFFC

    public static func match(in text: NSString, caret: Int) -> Match? {
        guard caret > 0, caret <= text.length else { return nil }
        var index = caret
        let lowerBound = max(0, caret - maximumQueryLength - 1)
        while index > lowerBound {
            index -= 1
            let unit = text.character(at: index)
            if unit == atSign {
                if index > 0, startsAMention(after: text.character(at: index - 1)) == false { return nil }
                let query = text.substring(with: NSRange(location: index + 1, length: caret - index - 1))
                // "@ " is not a mention.
                if let first = query.unicodeScalars.first, first.properties.isWhitespace { return nil }
                return Match(anchor: index, query: query)
            }
            if isLineBreak(unit) || unit == objectReplacementCharacter { return nil }
        }
        return nil
    }

    private static let atSign = UInt16(UInt8(ascii: "@"))
    private static let openers = Set("([{\"'“‘".utf16)

    public static func startsAMention(after unit: UInt16) -> Bool {
        if openers.contains(unit) || unit == objectReplacementCharacter { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }
}
