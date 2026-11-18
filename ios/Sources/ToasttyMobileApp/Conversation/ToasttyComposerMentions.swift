import ConversationUI
import Observation
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit

// @ mentions in the coordinator chat's message field. The rules for `@` and
// the search are the Mac's (`CoordinatorMentionRules.swift` in
// ConversationUI). Here a mention is the word `@Title` in the field, drawn
// in the accent color, and the task's link in the draft and in the message.

extension CoordinatorMentionCandidate {
    /// The tasks on the phone's task board that can be mentioned, newest
    /// activity first, as the Mac orders its board. A task space without a
    /// task record cannot be mentioned: the coordinator reads tasks by
    /// their ID.
    @MainActor
    static func candidates(from board: MobileTaskBoard?) -> [CoordinatorMentionCandidate] {
        (board?.tasks ?? [])
            .filter(\.hasRecord)
            .sorted { lhs, rhs in
                lhs.activityAt != rhs.activityAt ? lhs.activityAt > rhs.activityAt : lhs.title < rhs.title
            }
            .map { task in
                CoordinatorMentionCandidate(
                    taskID: task.id,
                    title: task.title,
                    projectTitle: task.projectTitle,
                    pullRequestNumber: task.pullRequest?.number,
                    group: group(for: task.group),
                    markColor: ToasttyTaskLinkChips.chipColor(ToasttyTaskDetailSheet.stageColor(task)),
                    // The board does not say when a task finished; its
                    // latest change is the Mac's fallback too.
                    doneAt: task.activityAt
                )
            }
    }

    static func group(for group: RemoteTaskGroup) -> Group {
        switch group {
        case .needsYou: .needsYou
        case .running: .working
        case .idle: .idle
        case .toShip: .toShip
        case .done: .done
        case .archived: .archived
        }
    }
}

/// A mentioned task in the message field: the attribute value of its word.
/// Each insertion has its own token, so two mentions of one task next to
/// each other stay two words.
final class ToasttyMentionToken: NSObject {
    let taskID: UUID
    /// The title as the word shows it.
    let label: String
    /// The task's link as the draft holds it. A word made from a link that
    /// is already in the text keeps that text, also when the task's title
    /// changed since, so the field and the draft stay the same text.
    let markdown: String

    init(candidate: CoordinatorMentionCandidate, markdown: String? = nil) {
        taskID = candidate.taskID
        label = CoordinatorMentionCandidate.label(title: candidate.title)
        self.markdown = markdown ?? CoordinatorTaskLink.markdown(taskID: candidate.taskID, title: candidate.title)
    }

    /// The word in the field.
    var text: String { "@" + label }
}

extension NSAttributedString.Key {
    /// A `ToasttyMentionToken` on the characters of a mention's word.
    static let toasttyMention = NSAttributedString.Key("toastty.composerMention")
}

/// The field's text and the draft's text. In the field a mention is a
/// highlighted word; in the draft, on the pasteboard and in the message, it
/// is the task's link.
enum ToasttyComposerMentionText {
    /// The mention's word, with the accent color, over `attributes`.
    static func mentionAttributes(
        _ token: ToasttyMentionToken,
        over attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[.toasttyMention] = token
        result[.foregroundColor] = UIColor(ToasttyDesignTokens.amber)
        result[.backgroundColor] = UIColor(ToasttyDesignTokens.amber).withAlphaComponent(0.14)
        return result
    }

    static func mention(
        _ candidate: CoordinatorMentionCandidate,
        attributes: [NSAttributedString.Key: Any],
        markdown: String? = nil
    ) -> NSAttributedString {
        let token = ToasttyMentionToken(candidate: candidate, markdown: markdown)
        return NSAttributedString(string: token.text, attributes: mentionAttributes(token, over: attributes))
    }

    /// Each mention's word, in order.
    static func mentions(in text: NSAttributedString) -> [(range: NSRange, token: ToasttyMentionToken)] {
        guard text.length > 0 else { return [] }
        var result: [(range: NSRange, token: ToasttyMentionToken)] = []
        text.enumerateAttribute(.toasttyMention, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let token = value as? ToasttyMentionToken { result.append((range, token)) }
        }
        return result
    }

    static func containsMention(_ text: NSAttributedString) -> Bool {
        guard text.length > 0 else { return false }
        var found = false
        text.enumerateAttribute(.toasttyMention, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value is ToasttyMentionToken {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The text with each mention as its task's link.
    static func serialized(_ text: NSAttributedString) -> String {
        replacingMentions(in: text) { $0.markdown }
    }

    /// The text that VoiceOver reads: each mention as "mention, <title>".
    static func spoken(_ text: NSAttributedString) -> String {
        replacingMentions(in: text) { "mention, \($0.label)" }
    }

    /// The text that the `@` rule reads: each mention as one object
    /// character per UTF-16 unit, so that a search stops before a mention
    /// and positions stay the field's.
    static func triggerText(_ text: NSAttributedString) -> NSString {
        let mentions = mentions(in: text)
        guard mentions.isEmpty == false else { return text.string as NSString }
        let result = NSMutableString(string: text.string)
        for (range, _) in mentions {
            result.replaceCharacters(in: range, with: String(repeating: "\u{FFFC}", count: range.length))
        }
        return result
    }

    /// The draft with each link to a task in `candidates` as that task's
    /// mention. Links to other tasks stay as typed. `nil` when the draft has
    /// no such link.
    static func attributed(
        _ text: String,
        candidates: [UUID: CoordinatorMentionCandidate],
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString? {
        guard candidates.isEmpty == false, text.range(of: "toastty:", options: .caseInsensitive) != nil else { return nil }
        let links = ConversationInlineLinks.scan(text).compactMap { link -> (Range<String.Index>, CoordinatorMentionCandidate)? in
            guard let taskID = CoordinatorTaskLink.taskID(in: link.url), let candidate = candidates[taskID] else { return nil }
            return (link.range, candidate)
        }
        guard links.isEmpty == false else { return nil }
        let result = NSMutableAttributedString()
        var position = text.startIndex
        for (range, candidate) in links {
            result.append(NSAttributedString(string: String(text[position..<range.lowerBound]), attributes: attributes))
            // The word shows the task's title now and keeps the link as typed.
            result.append(mention(candidate, attributes: attributes, markdown: String(text[range])))
            position = range.upperBound
        }
        result.append(NSAttributedString(string: String(text[position...]), attributes: attributes))
        return result
    }

    private static func replacingMentions(
        in text: NSAttributedString,
        with replacement: (ToasttyMentionToken) -> String
    ) -> String {
        let mentions = mentions(in: text)
        guard mentions.isEmpty == false else { return text.string }
        let string = text.string as NSString
        var result = ""
        var position = 0
        for (range, token) in mentions {
            result += string.substring(with: NSRange(location: position, length: range.location - position))
            result += replacement(token)
            position = NSMaxRange(range)
        }
        result += string.substring(from: position)
        return result
    }
}

/// The list of tasks to mention: the `@` the user types after, and the
/// tasks that match. The message field keeps it up to date from its own
/// edit and selection callbacks; the list above the composer draws it.
@MainActor @Observable
final class ToasttyMentionPicker {
    struct Session: Equatable {
        /// The location of the `@`, in UTF-16 units.
        var anchor: Int
        var query: String
    }

    private(set) var session: Session?
    private(set) var sections: [CoordinatorMentionSearch.Section] = []
    /// The tasks that can be mentioned. The message field sets them.
    @ObservationIgnored var candidates: [CoordinatorMentionCandidate] = []
    @ObservationIgnored weak var textView: ToasttyComposerUIKitTextView?
    @ObservationIgnored var now: () -> Date = Date.init
    /// The `@` that a tap outside the list closed it for: it does not open
    /// again for that `@`.
    @ObservationIgnored private var dismissedAnchor: Int?

    var isOpen: Bool { session != nil }

    /// Follows the text and the caret. The list shows while the caret is
    /// right after an `@` and its search, on one line. `text` shows each
    /// mention as object characters (`ToasttyComposerMentionText.triggerText`).
    func update(text: NSString, selection: NSRange) {
        guard selection.length == 0,
              let match = CoordinatorMentionTrigger.match(in: text, caret: selection.location) else {
            close(resetDismissal: true)
            return
        }
        if match.anchor == dismissedAnchor {
            close(resetDismissal: false)
            return
        }
        dismissedAnchor = nil
        let sections = CoordinatorMentionSearch.sections(query: match.query, candidates: candidates, now: now())
        if CoordinatorMentionSearch.endsTheSearch(query: match.query, sections: sections) {
            close(resetDismissal: false)
            return
        }
        let next = Session(anchor: match.anchor, query: match.query)
        if session != next { session = next }
        if self.sections != sections { self.sections = sections }
    }

    /// Closes the list. A new `@`, or the same one after the caret leaves
    /// it, opens it again.
    func close() {
        close(resetDismissal: true)
    }

    /// A tap outside the list: it closes, and typing on after the same `@`
    /// does not open it again.
    func dismiss() {
        guard let session else { return }
        dismissedAnchor = session.anchor
        close(resetDismissal: false)
    }

    /// Puts the task's mention in place of the `@` and its search. The row
    /// can be older than the board, which can change while the list shows,
    /// so the task's current title goes in.
    func choose(_ candidate: CoordinatorMentionCandidate) {
        close(resetDismissal: true)
        textView?.insertMention(candidates.first { $0.taskID == candidate.taskID } ?? candidate)
    }

    /// The paperclip's Mention a Task: types `@` at the caret, and the list
    /// opens.
    func beginMention() {
        textView?.beginMention()
    }

    private func close(resetDismissal: Bool) {
        if resetDismissal { dismissedAnchor = nil }
        if session != nil { session = nil }
        if sections.isEmpty == false { sections = [] }
    }
}

/// The list above the composer, over the chat, while the user types after
/// `@`, with the space above it: a touch there closes the list. Only this
/// view reads the list's state, so a key that changes the search updates
/// it and not the chat.
struct ToasttyMentionListOverlay: View {
    let picker: ToasttyMentionPicker

    var body: some View {
        if picker.isOpen {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in picker.dismiss() })
                        .accessibilityHidden(true)
                    ToasttyMentionList(picker: picker, availableHeight: geometry.size.height - 12)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
        }
    }
}

private struct ToasttyMentionList: View {
    let picker: ToasttyMentionPicker
    let availableHeight: CGFloat
    /// About four rows with their group's titles.
    @ScaledMetric(relativeTo: .subheadline) private var preferredHeight: CGFloat = 228

    var body: some View {
        let sections = picker.sections
        let query = picker.session?.query ?? ""
        Group {
            if sections.isEmpty {
                Text("No matching tasks")
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("toastty-mobile-mention-empty")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.group.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(ToasttyDesignTokens.mutedText)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.candidates) { candidate in
                                ToasttyMentionRow(candidate: candidate, query: query) {
                                    picker.choose(candidate)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollDismissesKeyboard(.never)
                .scrollIndicators(.visible)
                .frame(maxHeight: max(88, min(preferredHeight, availableHeight)))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
                .fill(ToasttyDesignTokens.raisedSurface)
                .shadow(color: .black.opacity(0.4), radius: 14, y: -4)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
                .strokeBorder(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks to mention")
        .accessibilityIdentifier("toastty-mobile-mention-list")
        .accessibilityAction(.escape) { picker.dismiss() }
    }
}

/// One task: its stage dot, its title with the search's words in the
/// accent color, and its project and pull request under it.
private struct ToasttyMentionRow: View {
    let candidate: CoordinatorMentionCandidate
    let query: String
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(red: candidate.markColor.red, green: candidate.markColor.green, blue: candidate.markColor.blue))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.highlighted(candidate.title, query: query))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail = Self.detail(candidate) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ToasttyMentionRowButtonStyle())
        .accessibilityLabel(Self.accessibilityLabel(candidate))
        .accessibilityIdentifier("toastty-mobile-mention-\(candidate.taskID.uuidString)")
    }

    static func detail(_ candidate: CoordinatorMentionCandidate) -> String? {
        let parts = [candidate.projectTitle, candidate.pullRequestNumber.map { "#\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func accessibilityLabel(_ candidate: CoordinatorMentionCandidate) -> String {
        [
            candidate.title,
            candidate.group.title,
            candidate.projectTitle,
            candidate.pullRequestNumber.map { "pull request \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// The title with each word of the search in the accent color. A
    /// search for a pull request number marks nothing in the title.
    static func highlighted(_ title: String, query: String) -> AttributedString {
        var result = AttributedString(title)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.isEmpty == false, query.hasPrefix("#") == false else { return result }
        for word in words {
            var searchRange = title.startIndex..<title.endIndex
            while let found = title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange),
                  found.isEmpty == false {
                if let lower = AttributedString.Index(found.lowerBound, within: result),
                   let upper = AttributedString.Index(found.upperBound, within: result) {
                    result[lower..<upper].foregroundColor = ToasttyDesignTokens.amber
                    result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                searchRange = found.upperBound..<title.endIndex
            }
        }
        return result
    }
}

private struct ToasttyMentionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? ToasttyDesignTokens.amber.opacity(0.16) : Color.clear)
    }
}
