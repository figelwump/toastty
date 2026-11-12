import Foundation
import SwiftUI

/// What a host changes about the shared transcript. The defaults are the
/// iPhone's, so a host that passes nothing gets the iPhone transcript.
public struct ToasttyTranscriptOptions: Equatable, Sendable {
    /// The widest the column of messages gets. `nil` fills the width, as on
    /// the iPhone. A wide Mac panel sets it so that lines stay readable.
    public var maximumContentWidth: CGFloat?
    /// What a card says when its question cannot be answered in this view.
    public var readOnlyInteractionMessage: String
    /// Where to read a request that the card shortened.
    public var shortenedPreviewMessage: String
    /// Whether each user and agent message has a button that copies the
    /// whole message. On the Mac it shows while the pointer is over the
    /// message.
    public var showsMessageCopyButton: Bool

    public init(
        maximumContentWidth: CGFloat? = nil,
        readOnlyInteractionMessage: String = "Respond on the desktop",
        shortenedPreviewMessage: String = "Preview shortened. Check the desktop for the full request.",
        showsMessageCopyButton: Bool = false
    ) {
        self.maximumContentWidth = maximumContentWidth
        self.readOnlyInteractionMessage = readOnlyInteractionMessage
        self.shortenedPreviewMessage = shortenedPreviewMessage
        self.showsMessageCopyButton = showsMessageCopyButton
    }
}

/// A message that the host typed for the agent, such as a digest of events.
/// It starts a turn as a user message does. The transcript shows it as one
/// muted line that opens to the full text.
public struct ToasttyHostMessagePresentation: Equatable, Sendable {
    /// The one line, for example "Toastty · 2 updates · 14:05".
    public var summary: String
    /// The text that was typed.
    public var text: String

    public init(summary: String, text: String) {
        self.summary = summary
        self.text = text
    }
}

// MARK: - Replies

/// The agent's message that a user's message answers. The user's bubble
/// shows one line of it above the user's text.
public struct ToasttyMessageQuote: Equatable, Sendable {
    /// The whole quoted message.
    public var text: String
    /// When the agent wrote it, as the host shows a time, such as "14:05".
    public var timeText: String?
    /// The quoted message's row, when the host found it among the rows it
    /// gave the transcript. A click on the quote then scrolls to that row.
    public var sourceRowID: ToasttyTranscriptRowID?

    public init(text: String, timeText: String? = nil, sourceRowID: ToasttyTranscriptRowID? = nil) {
        self.text = text
        self.timeText = timeText
        self.sourceRowID = sourceRowID
    }

    /// The quote on one line, for the strip in the bubble: the start of the
    /// message as plain text, with its line breaks as spaces. A link shows
    /// as its title, without Markdown's marks. The strip cuts it to its
    /// width.
    public var excerpt: String { Self.excerpt(of: text) }

    public static func excerpt(of text: String) -> String {
        let start = String(text.prefix(2_000))
        let plain = (try? AttributedString(
            markdown: start,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )).map { String($0.characters) } ?? start
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The agent's message that the user chose to reply to.
public struct ToasttyMessageReplyRequest: Equatable, Sendable {
    public var rowID: ToasttyTranscriptRowID
    /// The whole message, also when the transcript draws it as several rows.
    public var text: String
    public var timestamp: Date

    public init(rowID: ToasttyTranscriptRowID, text: String, timestamp: Date) {
        self.rowID = rowID
        self.text = text
        self.timestamp = timestamp
    }
}

/// The transcript's Reply action on an agent's message. The host's action
/// is not compared: it is the same for the life of one transcript.
struct ToasttyMessageReplyAction {
    let reply: @MainActor (ToasttyMessageReplyRequest) -> Void
}

/// Scrolls the transcript to the row that a quote names.
struct ToasttyRevealRowAction {
    let reveal: @MainActor (ToasttyTranscriptRowID) -> Void
}

private struct ToasttyMessageReplyActionKey: EnvironmentKey {
    static let defaultValue: ToasttyMessageReplyAction? = nil
}

private struct ToasttyRevealRowActionKey: EnvironmentKey {
    static let defaultValue: ToasttyRevealRowAction? = nil
}

extension EnvironmentValues {
    /// `nil`, the default, offers no Reply on agent messages.
    var toasttyMessageReply: ToasttyMessageReplyAction? {
        get { self[ToasttyMessageReplyActionKey.self] }
        set { self[ToasttyMessageReplyActionKey.self] = newValue }
    }

    var toasttyRevealRow: ToasttyRevealRowAction? {
        get { self[ToasttyRevealRowActionKey.self] }
        set { self[ToasttyRevealRowActionKey.self] = newValue }
    }
}

// MARK: - Links the host draws itself

/// A link drawn as a small labelled mark instead of as link text: a colored
/// dot, a title and an optional detail. A click still goes to the host's
/// `openURL` with the link's URL.
public struct ConversationLinkChip: Hashable, Sendable {
    public var markColor: ConversationChipColor
    public var title: String
    public var detail: String?

    public init(markColor: ConversationChipColor, title: String, detail: String? = nil) {
        self.markColor = markColor
        self.title = title
        self.detail = detail
    }
}

/// A color as plain numbers, so a chip can be an attribute of text.
public struct ConversationChipColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// How the host wants one link in a message drawn.
public enum ConversationLinkPresentation: Equatable, Sendable {
    /// Text with no link: a click does nothing.
    case plainText
    case chip(ConversationLinkChip)
}

/// Decides how links in assistant messages are drawn. The transcript asks
/// for each link when it draws, so `revision` must change when an answer
/// would: a chip then follows the record it shows.
public struct ConversationLinkPresenter: Sendable {
    public let revision: Int
    /// `nil` leaves the link as the transcript draws every link.
    public let presentation: @MainActor @Sendable (URL) -> ConversationLinkPresentation?

    public init(
        revision: Int,
        presentation: @escaping @MainActor @Sendable (URL) -> ConversationLinkPresentation?
    ) {
        self.revision = revision
        self.presentation = presentation
    }
}

extension ConversationLinkPresenter: Equatable {
    /// Two presenters with one revision answer alike: see `revision`.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }
}

private struct ConversationLinkPresenterKey: EnvironmentKey {
    static let defaultValue: ConversationLinkPresenter? = nil
}

private struct ToasttyTranscriptOptionsKey: EnvironmentKey {
    static let defaultValue = ToasttyTranscriptOptions()
}

extension EnvironmentValues {
    /// The host's link presenter. `nil`, the default, draws every link as
    /// link text.
    public var conversationLinkPresenter: ConversationLinkPresenter? {
        get { self[ConversationLinkPresenterKey.self] }
        set { self[ConversationLinkPresenterKey.self] = newValue }
    }

    var toasttyTranscriptOptions: ToasttyTranscriptOptions {
        get { self[ToasttyTranscriptOptionsKey.self] }
        set { self[ToasttyTranscriptOptionsKey.self] = newValue }
    }
}

/// Marks the text of a chip, so the platform's text view can draw its
/// outline. The text keeps its link.
enum ConversationChipAttribute: AttributedStringKey {
    typealias Value = ConversationLinkChip
    static let name = "toastty.conversationChip"
}

enum ConversationLinkDecoration {
    /// Draws each link the presenter answers for: as a chip, or as plain
    /// text. Other links, and text with no links, come back unchanged.
    @MainActor
    static func apply(_ content: AttributedString, presenter: ConversationLinkPresenter?) -> AttributedString {
        guard let presenter, content.runs.contains(where: { $0.link != nil }) else { return content }
        var result = AttributedString()
        // A link with inline styles spans several runs. Each chip is drawn
        // once, at the link's first run.
        var replacedLink: URL?
        for run in content.runs {
            guard let url = run.link, let presentation = presenter.presentation(url) else {
                replacedLink = nil
                result.append(AttributedString(content[run.range]))
                continue
            }
            switch presentation {
            case .plainText:
                replacedLink = nil
                var piece = AttributedString(content[run.range])
                piece.link = nil
                result.append(piece)
            case .chip(let chip):
                guard replacedLink != url else { continue }
                replacedLink = url
                result.append(chipText(chip, url: url))
            }
        }
        return result
    }

    /// The chip's text: its mark, title and detail. No-break spaces keep
    /// the chip on one line where the line allows it, and pad its outline.
    private static func chipText(_ chip: ConversationLinkChip, url: URL) -> AttributedString {
        let noBreakSpace = "\u{00A0}"
        func piece(_ string: String, color: Color) -> AttributedString {
            var text = AttributedString(string)
            text.foregroundColor = color
            text.link = url
            text[ConversationChipAttribute.self] = chip
            return text
        }
        let title = chip.title.replacingOccurrences(of: " ", with: noBreakSpace)
        var text = piece("\(noBreakSpace)●\(noBreakSpace)", color: chip.markColor.color)
        text.append(piece(title, color: ConversationDesignTokens.primaryText))
        if let detail = chip.detail, detail.isEmpty == false {
            text.append(piece(
                "\(noBreakSpace)·\(noBreakSpace)\(detail.replacingOccurrences(of: " ", with: noBreakSpace))",
                color: ConversationDesignTokens.secondaryText
            ))
        }
        text.append(piece(noBreakSpace, color: ConversationDesignTokens.primaryText))
        return text
    }
}

extension View {
    /// Mac buttons get a bezel unless a style says otherwise. The iPhone
    /// keeps its default style.
    @ViewBuilder
    func conversationPlainButtonOnMac() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }
}
