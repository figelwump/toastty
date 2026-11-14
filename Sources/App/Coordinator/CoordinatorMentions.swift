import AppKit
import ConversationUI
import CoreState
import RemoteProtocol
import SwiftUI

/// A task that the user can mention in a message to the coordinator.
struct CoordinatorMentionCandidate: Equatable, Identifiable {
    /// The picker's groups, in the order the Tasks view lists them.
    enum Group: Int, CaseIterable, Comparable {
        case needsYou, working, idle, toShip, done, archived

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .idle: "Idle"
            case .toShip: "To ship"
            case .done: "Done"
            case .archived: "Archived"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let taskID: UUID
    var title: String
    var projectTitle: String?
    var pullRequestNumber: Int?
    var group: Group
    var markColor: ConversationChipColor
    /// When a done task finished. The picker lists recent ones before a
    /// search.
    var doneAt: Date?

    var id: UUID { taskID }

    /// The tasks on the board, newest activity first, as the board orders
    /// them. A task space without a task record cannot be mentioned: the
    /// coordinator reads tasks by their ID.
    static func candidates(from items: [TaskBoardItem]) -> [CoordinatorMentionCandidate] {
        items.compactMap { item in
            guard case .task(let taskID) = item.id else { return nil }
            return CoordinatorMentionCandidate(
                taskID: taskID,
                title: item.title,
                projectTitle: item.projectTitle,
                pullRequestNumber: item.pullRequest?.number,
                group: group(for: item.stage),
                markColor: CoordinatorTaskChips.chipColor(CoordinatorTaskChips.markColor(for: item)),
                doneAt: item.record?.doneAt ?? item.activityAt
            )
        }
    }

    static func group(for stage: TaskStage) -> Group {
        switch stage {
        case .needsYou: .needsYou
        case .starting, .running: .working
        case .idle: .idle
        case .toShip: .toShip
        case .done: .done
        case .archived: .archived
        }
    }
}

/// Which tasks the picker lists for what the user typed after `@`.
enum CoordinatorMentionSearch {
    struct Section: Equatable, Identifiable {
        let group: CoordinatorMentionCandidate.Group
        var candidates: [CoordinatorMentionCandidate]
        var id: CoordinatorMentionCandidate.Group { group }
    }

    /// Before a search, the picker lists done tasks that finished in this
    /// time. Older ones, and archived ones, show only for a search.
    static let recentDoneInterval: TimeInterval = 14 * 24 * 60 * 60
    static let maximumResults = 50

    static func sections(
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
    static func matches(_ candidate: CoordinatorMentionCandidate, query: String) -> Bool {
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
}

/// The `@` that starts a mention: at the start of the text, or after a
/// space or an opening bracket or quote, so that an email address starts
/// none. The words typed after it, on one line, are the search.
enum CoordinatorMentionTrigger {
    struct Match: Equatable {
        /// The location of the `@`, in UTF-16 units.
        var anchor: Int
        var query: String
    }

    static let maximumQueryLength = 60

    static func match(in text: NSString, caret: Int) -> Match? {
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
            if isLineBreak(unit) || unit == attachmentCharacter { return nil }
        }
        return nil
    }

    private static let atSign = UInt16(UInt8(ascii: "@"))
    private static let attachmentCharacter: UInt16 = 0xFFFC
    private static let openers = Set("([{\"'“‘".utf16)

    static func startsAMention(after unit: UInt16) -> Bool {
        if openers.contains(unit) || unit == attachmentCharacter { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }
}

/// The mention picker's state: the `@` the user is typing after, the tasks
/// that match, and the selected one. The composer's text view keeps it up
/// to date and sends it the keys it takes; the composer draws it.
@MainActor
final class CoordinatorMentionPicker: ObservableObject {
    struct Session: Equatable {
        var anchor: Int
        var caret: Int
        var query: String
    }

    enum Key {
        case up, down, choose, cancel
    }

    @Published private(set) var session: Session?
    @Published var selectedIndex = 0
    /// The tasks that can be mentioned. Set by the composer on each update.
    var candidates: [CoordinatorMentionCandidate] = []
    weak var textView: CoordinatorComposerTextView?
    var now: () -> Date = Date.init
    /// The `@` that Escape closed the picker for: it does not open again
    /// for that `@`.
    private var dismissedAnchor: Int?

    var sections: [CoordinatorMentionSearch.Section] {
        guard let session else { return [] }
        return CoordinatorMentionSearch.sections(query: session.query, candidates: candidates, now: now())
    }

    var results: [CoordinatorMentionCandidate] {
        sections.flatMap(\.candidates)
    }

    var isOpen: Bool { session != nil }

    /// Follows the text and the caret. The picker shows while the caret
    /// is right after an `@` and its search. A search of several words
    /// that matches nothing closes it, so ordinary text after an `@` does
    /// not keep it open.
    func update(text: NSString, selection: NSRange) {
        guard selection.length == 0, let match = CoordinatorMentionTrigger.match(in: text, caret: selection.location) else {
            close(resetDismissal: true)
            return
        }
        if match.anchor == dismissedAnchor {
            close(resetDismissal: false)
            return
        }
        dismissedAnchor = nil
        let next = Session(anchor: match.anchor, caret: selection.location, query: match.query)
        let matchesNothing = CoordinatorMentionSearch.sections(query: next.query, candidates: candidates, now: now()).isEmpty
        if matchesNothing, next.query.contains(where: \.isWhitespace) {
            close(resetDismissal: false)
            return
        }
        if session?.query != next.query || session?.anchor != next.anchor, selectedIndex != 0 {
            selectedIndex = 0
        }
        if session != next {
            session = next
        }
    }

    /// A key while the picker is open. Returns false when the key is not
    /// the picker's: then the text view handles it. With no task to choose,
    /// only Escape is the picker's.
    func handle(_ key: Key) -> Bool {
        guard let session else { return false }
        if key == .cancel {
            dismissedAnchor = session.anchor
            close(resetDismissal: false)
            return true
        }
        let results = results
        guard results.isEmpty == false else { return false }
        switch key {
        case .up:
            selectedIndex = (min(selectedIndex, results.count - 1) - 1 + results.count) % results.count
        case .down:
            selectedIndex = (min(selectedIndex, results.count - 1) + 1) % results.count
        case .choose:
            choose(results[min(selectedIndex, results.count - 1)])
        case .cancel:
            break
        }
        return true
    }

    /// Puts the task's chip in place of the `@` and its search.
    func choose(_ candidate: CoordinatorMentionCandidate) {
        guard let session, let textView else { return }
        let range = NSRange(location: session.anchor, length: session.caret - session.anchor)
        close(resetDismissal: true)
        textView.insertMention(candidate, replacing: range)
    }

    /// ＋ › Mention a Task…: types `@` at the caret and opens the picker.
    func beginMention() {
        textView?.beginMention()
    }

    private func close(resetDismissal: Bool) {
        if resetDismissal { dismissedAnchor = nil }
        if session != nil { session = nil }
        if selectedIndex != 0 { selectedIndex = 0 }
    }
}

/// A mentioned task in the composer's text: one character that is drawn as
/// a chip and deletes as one. The draft holds it as the task's link.
final class CoordinatorMentionAttachment: NSTextAttachment {
    let taskID: UUID
    let title: String
    /// The task's link as the draft holds it. A chip made from a link that
    /// is already in the text keeps that text, also when the task's title
    /// changed since, so the field and the draft stay the same text.
    let markdown: String

    static let maximumTitleLength = 40

    init(
        taskID: UUID,
        title: String,
        pullRequestNumber: Int?,
        markColor: ConversationChipColor,
        font: NSFont,
        markdown: String? = nil
    ) {
        self.taskID = taskID
        self.title = title
        self.markdown = markdown ?? CoordinatorTaskLink.markdown(taskID: taskID, title: title)
        super.init(data: nil, ofType: nil)
        let label = Self.label(title: title)
        let detail = pullRequestNumber.map { " · #\($0)" }
        let chip = Self.chipImage(label: label, detail: detail, markColor: markColor, font: font)
        image = chip.image
        bounds = chip.bounds
        image?.accessibilityDescription = pullRequestNumber.map { "Task \(label), pull request \($0)" } ?? "Task \(label)"
    }

    convenience init(candidate: CoordinatorMentionCandidate, font: NSFont, markdown: String? = nil) {
        self.init(
            taskID: candidate.taskID,
            title: candidate.title,
            pullRequestNumber: candidate.pullRequestNumber,
            markColor: candidate.markColor,
            font: font,
            markdown: markdown
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func label(title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.isEmpty == false else { return "Untitled task" }
        return oneLine.count > maximumTitleLength ? oneLine.prefix(maximumTitleLength - 1) + "…" : oneLine
    }

    /// The chip fits in a line of the font, so a line with a chip is as
    /// tall as one without. It looks like the transcript's chips: a
    /// capsule with the stage's dot, the title and the pull request number.
    private static func chipImage(
        label: String,
        detail: String?,
        markColor: ConversationChipColor,
        font: NSFont
    ) -> (image: NSImage, bounds: CGRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(ToastyTheme.primaryText),
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(ToastyTheme.inactiveText),
        ]
        let titleWidth = ceil((label as NSString).size(withAttributes: titleAttributes).width)
        let detailWidth = detail.map { ceil(($0 as NSString).size(withAttributes: detailAttributes).width) } ?? 0
        let height = ceil(font.ascender - font.descender)
        let padding = round(height * 0.4)
        let dot = round(font.pointSize * 0.5)
        let gap = round(font.pointSize * 0.35)
        let width = padding + dot + gap + titleWidth + detailWidth + padding
        let size = NSSize(width: width, height: height)
        // Text drawn at y 0 has its baseline at -descender, as on the line.
        let dotColor = NSColor(red: markColor.red, green: markColor.green, blue: markColor.blue, alpha: 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let outline = rect.insetBy(dx: 0.5, dy: 0.5)
            let capsule = NSBezierPath(roundedRect: outline, xRadius: outline.height / 2, yRadius: outline.height / 2)
            NSColor.white.withAlphaComponent(0.08).setFill()
            capsule.fill()
            NSColor.white.withAlphaComponent(0.22).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: padding, y: (rect.height - dot) / 2, width: dot, height: dot)).fill()
            var x = padding + dot + gap
            (label as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: titleAttributes)
            x += titleWidth
            if let detail {
                (detail as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: detailAttributes)
            }
            return true
        }
        return (image, CGRect(x: 0, y: round(font.descender), width: width, height: height))
    }
}

/// The composer's text and the draft's text. In the field a mention is a
/// chip; in the draft, and on the pasteboard, it is the task's link.
enum CoordinatorMentionText {
    /// The text with each chip as its task's link.
    static func serialized(_ text: NSAttributedString) -> String {
        guard text.length > 0 else { return "" }
        var result = ""
        let string = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let mention = value as? CoordinatorMentionAttachment {
                // A run of chips is one run per chip only when they differ;
                // each chip is one character.
                for _ in 0..<range.length { result += mention.markdown }
            } else {
                result += string.substring(with: range)
            }
        }
        return result
    }

    /// The text with each link to a task in `candidates` as that task's
    /// chip. Links to other tasks stay as typed.
    static func attributed(
        _ text: String,
        candidates: [UUID: CoordinatorMentionCandidate],
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString? {
        let links = ConversationInlineLinks.scan(text).compactMap { link -> (Range<String.Index>, CoordinatorMentionCandidate)? in
            guard let taskID = CoordinatorTaskLink.taskID(in: link.url), let candidate = candidates[taskID] else { return nil }
            return (link.range, candidate)
        }
        guard links.isEmpty == false else { return nil }
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: CoordinatorComposerTextEditor.defaultFontSize)
        let result = NSMutableAttributedString()
        var position = text.startIndex
        for (range, candidate) in links {
            result.append(NSAttributedString(string: String(text[position..<range.lowerBound]), attributes: attributes))
            // The chip shows the task's title now and keeps the link as typed.
            result.append(chip(candidate, font: font, attributes: attributes, markdown: String(text[range])))
            position = range.upperBound
        }
        result.append(NSAttributedString(string: String(text[position...]), attributes: attributes))
        return result
    }

    static func chip(
        _ candidate: CoordinatorMentionCandidate,
        font: NSFont,
        attributes: [NSAttributedString.Key: Any],
        markdown: String? = nil
    ) -> NSAttributedString {
        let chip = NSMutableAttributedString(attachment: CoordinatorMentionAttachment(
            candidate: candidate, font: font, markdown: markdown
        ))
        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }
}

/// The list above the composer while the user types after `@`: the tasks
/// that match, grouped by stage, with the selected one marked.
struct CoordinatorMentionPickerView: View {
    @ObservedObject var picker: CoordinatorMentionPicker
    var textScale: Double = 1

    static let maximumHeight: CGFloat = 280
    static let width: CGFloat = 420

    var body: some View {
        let sections = picker.sections
        let results = sections.flatMap(\.candidates)
        let selectedID = results.isEmpty ? nil : results[min(picker.selectedIndex, results.count - 1)].id
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                Text("No matching tasks")
                    .font(.system(size: 12 * textScale))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("coordinator.chat.mention.empty")
            } else {
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                Text(section.group.title.uppercased())
                                    .font(.system(size: 10 * textScale, weight: .semibold))
                                    .foregroundStyle(ToastyTheme.inactiveText)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                                ForEach(section.candidates) { candidate in
                                    row(candidate, isSelected: candidate.id == selectedID)
                                        .id(candidate.id)
                                        .onTapGesture { picker.choose(candidate) }
                                }
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: Self.maximumHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        scroller.scrollTo(id)
                    }
                }
                footer
            }
        }
        .frame(maxWidth: Self.width * min(textScale, 1.4), alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ToastyTheme.elevatedBackground)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(ToastyTheme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.chat.mention")
    }

    private func row(_ candidate: CoordinatorMentionCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: candidate.markColor.red, green: candidate.markColor.green, blue: candidate.markColor.blue))
                .frame(width: 8, height: 8)
            Text(candidate.title)
                .font(.system(size: 13 * textScale))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.detail(candidate))
                .font(.system(size: 11.5 * textScale))
                .foregroundStyle(ToastyTheme.inactiveText)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? ToastyTheme.accent.opacity(0.28) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("coordinator.chat.mention.\(candidate.taskID.uuidString)")
    }

    private var footer: some View {
        Text("↑↓ choose · ↩ or ⇥ insert · esc close")
            .font(.system(size: 11 * textScale))
            .foregroundStyle(ToastyTheme.inactiveText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(ToastyTheme.hairline).frame(height: 1)
            }
    }

    static func detail(_ candidate: CoordinatorMentionCandidate) -> String {
        [candidate.projectTitle, candidate.pullRequestNumber.map { "#\($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
