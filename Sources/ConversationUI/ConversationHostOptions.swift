import Foundation
import RemoteProtocol
import SwiftUI

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

extension ConversationChipColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

private struct ConversationLinkPresenterKey: EnvironmentKey {
    static let defaultValue: ConversationLinkPresenter? = nil
}

private struct ToasttyTranscriptOptionsKey: EnvironmentKey {
    static let defaultValue = ToasttyTranscriptOptions()
}

private struct ShowQuestionTerminalKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
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

    /// A host with a local terminal can open it from an answerable question.
    public var showQuestionTerminal: (@MainActor @Sendable () -> Void)? {
        get { self[ShowQuestionTerminalKey.self] }
        set { self[ShowQuestionTerminalKey.self] = newValue }
    }
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

    /// Text that is shown as typed, such as the user's own message, with
    /// each inline link that the presenter draws as a chip in its place.
    /// Every other character, also of a link the presenter does not draw
    /// as a chip, stays as typed.
    @MainActor
    static func applyChips(toPlainText text: String, presenter: ConversationLinkPresenter?) -> AttributedString {
        guard let presenter else { return AttributedString(text) }
        let links = ConversationInlineLinks.scan(text)
        guard links.isEmpty == false else { return AttributedString(text) }
        var result = AttributedString()
        var position = text.startIndex
        for link in links {
            guard case .chip(let chip)? = presenter.presentation(link.url) else { continue }
            result.append(AttributedString(String(text[position..<link.range.lowerBound])))
            result.append(chipText(chip, url: link.url))
            position = link.range.upperBound
        }
        result.append(AttributedString(String(text[position...])))
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
        var text = piece(noBreakSpace, color: chip.markColor.color)
        var mark = piece("●", color: chip.markColor.color)
        if chip.showsActivity { mark[ConversationChipSpinnerAttribute.self] = true }
        text.append(mark)
        text.append(piece(noBreakSpace, color: chip.markColor.color))
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
