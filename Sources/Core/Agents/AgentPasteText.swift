import Foundation
import RemoteProtocol

/// The text of a message that Toastty types into an agent's terminal as one
/// paste, followed by a Return.
public enum AgentPasteText {
    /// `text`, with each image path that Claude Code would read as an image
    /// file put in a code span, so that the Return after the paste submits
    /// the message.
    ///
    /// Claude Code (checked on 2.1.326) looks at each line of a paste. It
    /// cuts the line at each space that comes before `/`, `'/` or `"/`. When
    /// the line is one piece, or every piece looks like a path, it reads each
    /// piece that ends in `.png`, `.jpg`, `.jpeg`, `.gif` or `.webp` as an
    /// image file. That read is asynchronous, and Claude Code discards a
    /// Return that arrives during it. The message then stays in the prompt
    /// as `[Image #N]` until someone presses Return. A piece in a code span
    /// ends in a backtick, so Claude Code keeps it as text.
    ///
    /// A path piece goes in a code span whole. On a line of prose, such as
    /// `fix logo.png`, only the last word does. Other lines do not change,
    /// and text that this function returns does not change again.
    /// Codex reads a paste as an image only when the whole paste is one
    /// image path, and it reads it before the Return, so the rule is
    /// harmless there.
    public static func keepingImagePathsAsText(_ text: String) -> String {
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard let rewritten = rewrittenLine(line) else { return line }
            changed = true
            return rewritten
        }
        return changed ? lines.joined(separator: "\n") : text
    }

    // MARK: - Claude Code's rule

    /// A space before a path: where Claude Code cuts a pasted line.
    private static let pieceBoundary = regex(#" (?=["']?(?:/|[A-Za-z]:\\))"#)
    /// A path with at least one folder, or a Windows path.
    private static let unquotedPath = regex(#"^(?:/(?!/)[^ \r\\/]*(?:\\.[^ \r\\/]*)*/|[A-Za-z]:\\|\\\\)[^\r]*$"#)
    private static let quotedPath = regex(#"^(["'])(?:/[^/\r]+/|[A-Za-z]:\\|\\\\)[^\r]*\1$"#)
    private static let unescapedSpace = regex(#"[^\\] "#)
    private static let imageExtension = regex(#"\.(png|jpe?g|gif|webp)$"#, options: .caseInsensitive)

    /// The line with its image pieces in code spans, or `nil` when Claude
    /// Code reads no image in it.
    private static func rewrittenLine(_ line: String) -> String? {
        let pieces = split(line)
        let filled = pieces.filter { trimmed($0).isEmpty == false }
        if filled.count > 1, filled.allSatisfy(isPath) == false { return nil }
        guard filled.contains(where: isImage) else { return nil }
        return pieces.map { isImage($0) ? spanned($0) : $0 }.joined(separator: " ")
    }

    /// The line cut at each `pieceBoundary`, without the space there.
    private static func split(_ line: String) -> [String] {
        let whole = line as NSString
        var pieces: [String] = []
        var start = 0
        for match in pieceBoundary.matches(in: line, range: NSRange(location: 0, length: whole.length)) {
            pieces.append(whole.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(whole.substring(from: start))
        return pieces
    }

    private static func isPath(_ piece: String) -> Bool {
        let piece = trimmed(piece)
        return matches(quotedPath, piece)
            || (matches(unquotedPath, piece) && (matches(unescapedSpace, piece) == false || isImage(piece)))
    }

    private static func isImage(_ piece: String) -> Bool {
        matches(imageExtension, unescaped(unquoted(trimmed(piece))))
    }

    /// The piece with its path, or the last word of its prose, in a code
    /// span. The spaces around the piece stay.
    private static func spanned(_ piece: String) -> String {
        let core = trimmed(piece)
        guard let coreRange = piece.range(of: core) else { return piece }
        var replaced = core
        if isPath(core) {
            replaced = RemoteAttachmentDeliveryText.codeSpan(core)
        } else if let lastSpace = core.lastIndex(of: " ") {
            let word = core[core.index(after: lastSpace)...]
            replaced = String(core[...lastSpace]) + RemoteAttachmentDeliveryText.codeSpan(String(word))
        } else {
            replaced = RemoteAttachmentDeliveryText.codeSpan(core)
        }
        return piece.replacingCharacters(in: coreRange, with: replaced)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    /// A backslash escapes the character after it; two make one.
    private static func unescaped(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            if let next = iterator.next() {
                result.append(next)
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constant; a failure is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
