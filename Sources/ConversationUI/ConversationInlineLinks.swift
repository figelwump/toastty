import Foundation

/// One inline Markdown link, `[label](url)`, found in plain text.
public struct ConversationInlineLink: Equatable, Sendable {
    /// The link's whole text, from `[` to `)`.
    public let range: Range<String.Index>
    /// The label with its backslash escapes removed.
    public let label: String
    public let url: URL
}

/// Finds inline Markdown links in text that is otherwise shown as typed,
/// such as the user's own message. It reads only the plain form
/// `[label](url)`: a label on one line, with `\[`, `\]` and `\\` escapes,
/// and a URL with a scheme and no spaces. Anything else is not a link.
public enum ConversationInlineLinks {
    public static func scan(_ text: String) -> [ConversationInlineLink] {
        guard text.contains("](") else { return [] }
        var links: [ConversationInlineLink] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                // An escaped character starts nothing.
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if character == "[", let link = link(in: text, at: index) {
                links.append(link)
                index = link.range.upperBound
                continue
            }
            index = text.index(after: index)
        }
        return links
    }

    /// The link that starts at the `[` at `start`, or `nil`.
    private static func link(in text: String, at start: String.Index) -> ConversationInlineLink? {
        var label = ""
        var index = text.index(after: start)
        while true {
            guard index < text.endIndex else { return nil }
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                let escaped = text[next]
                if escaped.isNewline { return nil }
                if escaped.isASCII, escaped.isPunctuation || escaped.isSymbol {
                    label.append(escaped)
                } else {
                    label.append(character)
                    label.append(escaped)
                }
                index = text.index(after: next)
                continue
            }
            if character == "]" { break }
            if character == "[" || character.isNewline { return nil }
            label.append(character)
            index = text.index(after: index)
        }
        let open = text.index(after: index)
        guard label.isEmpty == false, open < text.endIndex, text[open] == "(" else { return nil }
        let urlStart = text.index(after: open)
        var end = urlStart
        while true {
            guard end < text.endIndex else { return nil }
            let character = text[end]
            if character == ")" { break }
            if character.isWhitespace || character == "(" || character == "<" || character == ">" { return nil }
            end = text.index(after: end)
        }
        guard end > urlStart, let url = URL(string: String(text[urlStart..<end])), url.scheme != nil else { return nil }
        return ConversationInlineLink(range: start..<text.index(after: end), label: label, url: url)
    }
}
