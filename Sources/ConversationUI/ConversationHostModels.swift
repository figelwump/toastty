import Foundation
import RemoteProtocol

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
    /// A turn's work stays folded under one line, also while the turn runs,
    /// and that line shows that the agent works. The coordinator's chats
    /// set it: there the answer is what the reader follows. Without it, the
    /// running turn's work is open, so that the agent's notes show as they
    /// come, and the line at the end of the chat shows that it works.
    public var foldsRunningWork: Bool
    /// Whether the transcript shows its own banner while its connection is
    /// paused, has failed, or it catches up. The iPhone sets it to false:
    /// its header and a floating notice show the connection, and a banner
    /// above the messages would move them each time the app reconnects.
    /// The working row then also stays while the transcript recovers.
    public var showsConnectionStatus: Bool

    public init(
        maximumContentWidth: CGFloat? = nil,
        readOnlyInteractionMessage: String = "Respond on the desktop",
        shortenedPreviewMessage: String = "Preview shortened. Check the desktop for the full request.",
        showsMessageCopyButton: Bool = false,
        foldsRunningWork: Bool = false,
        showsConnectionStatus: Bool = true
    ) {
        self.maximumContentWidth = maximumContentWidth
        self.readOnlyInteractionMessage = readOnlyInteractionMessage
        self.shortenedPreviewMessage = shortenedPreviewMessage
        self.showsMessageCopyButton = showsMessageCopyButton
        self.foldsRunningWork = foldsRunningWork
        self.showsConnectionStatus = showsConnectionStatus
    }
}

/// A message that the host typed for the agent, such as a digest of events.
/// It starts a turn as a user message does. The transcript shows it as one
/// muted line that opens to the full text, or as a sender-labelled card.
public struct ToasttyHostMessagePresentation: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case disclosure
        case sender(name: String, timeText: String)
    }

    /// The one line, for example "Toastty · 2 updates · 14:05".
    public var summary: String
    /// The line without its time, for example "Toastty · 2 updates". While
    /// the turn that the message started runs, the line shows this and the
    /// turn's running time. `nil` keeps `summary`.
    public var title: String?
    /// The full text, without the sender header for a sender card.
    public var text: String
    public var style: Style
    /// The host knows that the turn this message started needs no reader.
    /// The line then also folds the whole turn: its work and its answer
    /// show only when the line is open. Questions and approvals stay
    /// visible.
    public var foldsTurn: Bool

    public init(
        summary: String,
        title: String? = nil,
        text: String,
        foldsTurn: Bool = false,
        style: Style = .disclosure
    ) {
        self.summary = summary
        self.title = title
        self.text = text
        self.foldsTurn = foldsTurn
        self.style = style
    }

    /// The message is one line that opens to its text, such as a digest.
    /// A sender's card shows its text.
    public var isLine: Bool {
        if case .disclosure = style { return true }
        return false
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

extension CoordinatorReplyTarget {
    /// The message that Reply chose. Its text and time are kept as the
    /// reply writes them, so a waiting reply that comes back with Edit is
    /// the same reply, also for a message that ends with a blank line.
    public init(_ request: ToasttyMessageReplyRequest) {
        self.init(
            text: CoordinatorMessageHeader.quoteText(request.text),
            time: CoordinatorMessageHeader.replyTime(request.timestamp.formatted(date: .omitted, time: .shortened))
        )
    }

    /// Ask on an offer card: the reply quotes one line that names the
    /// offer (`offerQuote`). `offeredAt` is when the coordinator wrote the
    /// message with the offers.
    public init(offer: CoordinatorOffer, offeredAt: Date) {
        self.init(
            text: CoordinatorMessageHeader.quoteText(CoordinatorMessageHeader.offerQuote(offer)),
            time: CoordinatorMessageHeader.replyTime(CoordinatorChatTranscript.timeText(offeredAt))
        )
    }
}

/// A link drawn as a small labelled mark instead of as link text: a colored
/// dot, a title and an optional detail. A click still goes to the host's
/// `openURL` with the link's URL.
public struct ConversationLinkChip: Hashable, Sendable {
    public var markColor: ConversationChipColor
    public var title: String
    public var detail: String?
    /// Draws a spinner in the mark's color in place of the dot, for work
    /// that is in progress. The chip keeps the dot's size.
    public var showsActivity: Bool

    public init(markColor: ConversationChipColor, title: String, detail: String? = nil,
                showsActivity: Bool = false) {
        self.markColor = markColor
        self.title = title
        self.detail = detail
        self.showsActivity = showsActivity
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

extension ConversationLinkPresenter {
    /// Draws a `toastty://task/<id>` link to a task in `chips` as that
    /// task's chip. The text is an agent's, so only that exact form names a
    /// task: a link to any other task, and any other `toastty:` link, is
    /// plain text that a tap cannot open. Other links stay as the
    /// transcript draws them.
    public static func taskChips(_ chips: [UUID: ConversationLinkChip]) -> ConversationLinkPresenter {
        ConversationLinkPresenter(revision: chips.hashValue) { url in
            taskLinkPresentation(for: url, chips: chips)
        }
    }

    /// See `taskChips(_:)`. `nil` for a link that is not Toastty's.
    public static func taskLinkPresentation(
        for url: URL,
        chips: [UUID: ConversationLinkChip]
    ) -> ConversationLinkPresentation? {
        guard CoordinatorTaskLink.isToasttyURL(url) else { return nil }
        guard let taskID = CoordinatorTaskLink.taskID(in: url), let chip = chips[taskID] else {
            return .plainText
        }
        return .chip(chip)
    }
}

extension ConversationLinkChip {
    /// A task chip's title holds at most this many characters.
    public static let maximumTaskTitleLength = 60

    /// A task's title on one line, shortened for its chip.
    public static func taskTitle(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.isEmpty == false else { return "Untitled task" }
        return oneLine.count > maximumTaskTitleLength ? oneLine.prefix(maximumTaskTitleLength - 1) + "…" : oneLine
    }
}

/// Marks the text of a chip, so the platform's text view can draw its
/// outline. The text keeps its link.
enum ConversationChipAttribute: AttributedStringKey {
    typealias Value = ConversationLinkChip
    static let name = "toastty.conversationChip"
}

/// Marks a chip's dot that the platform's text view replaces with a
/// spinner. The dot stays in the text, so the chip keeps its size and line
/// height. A text view that draws no spinner shows the dot.
enum ConversationChipSpinnerAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "toastty.conversationChipSpinner"
}
