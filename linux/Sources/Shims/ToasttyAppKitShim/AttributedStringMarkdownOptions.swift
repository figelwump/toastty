import Foundation
import Markdown
import ToasttyFoundationShim

extension AttributedString {
    /// Darwin's markdown parsing options, as far as Toastty uses them.
    public struct MarkdownParsingOptions: Sendable {
        public enum InterpretedSyntax: Sendable {
            case full
            case inlineOnly
            case inlineOnlyPreservingWhitespace
        }

        public enum FailurePolicy: Sendable {
            case throwError
            case returnPartiallyParsedIfPossible
        }

        public var allowsExtendedAttributes: Bool
        public var interpretedSyntax: InterpretedSyntax
        public var failurePolicy: FailurePolicy

        public init(
            allowsExtendedAttributes: Bool = false,
            interpretedSyntax: InterpretedSyntax = .full,
            failurePolicy: FailurePolicy = .throwError
        ) {
            self.allowsExtendedAttributes = allowsExtendedAttributes
            self.interpretedSyntax = interpretedSyntax
            self.failurePolicy = failurePolicy
        }
    }

    /// `.full` uses the block parser from ToasttyFoundationShim. The
    /// inline-only modes keep every line's block markers and line breaks as
    /// literal text and resolve only inline syntax (emphasis, code, links);
    /// `link` attributes match Darwin. Styling attributes are not produced.
    public init(markdown: String, options: MarkdownParsingOptions) throws {
        guard options.interpretedSyntax != .full else {
            try self.init(markdown: markdown)
            return
        }
        var result = AttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(AttributedString(options.interpretedSyntax == .inlineOnly ? " " : "\n"))
            }
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(indentation.count)
            if options.interpretedSyntax == .inlineOnlyPreservingWhitespace, indentation.isEmpty == false {
                result.append(AttributedString(String(indentation)))
            }
            guard content.isEmpty == false else { continue }
            // Escape a leading block marker so the paragraph parser keeps it.
            let escaped = Self.escapingLeadingBlockMarker(String(content))
            var builder = InlineRunBuilder()
            builder.visit(Document(parsing: escaped))
            result.append(builder.result)
        }
        self = result
    }

    /// Escapes a line start the block parser would treat as structure
    /// (heading, quote, bullet, ordered item, fence, thematic break) while
    /// leaving inline syntax such as a leading `**bold**` alone.
    private static func escapingLeadingBlockMarker(_ line: String) -> String {
        guard let first = line.first else { return line }
        let rest = line.dropFirst()
        let second = rest.first
        func isBlank(_ character: Character?) -> Bool { character == nil || character == " " || character == "\t" }
        let compact = line.filter { $0 != " " && $0 != "\t" }
        if compact.count >= 3, let marker = compact.first, "-*_".contains(marker), compact.allSatisfy({ $0 == marker }) {
            return "\\" + line // thematic break
        }
        switch first {
        case ">":
            return "\\" + line
        case "#":
            let hashes = line.prefix { $0 == "#" }
            return hashes.count <= 6 && isBlank(line.dropFirst(hashes.count).first) ? "\\" + line : line
        case "-", "+", "*":
            return isBlank(second) ? "\\" + line : line
        case "`", "~":
            return line.hasPrefix(String(repeating: first, count: 3)) ? "\\" + line : line
        default:
            let digits = line.prefix { $0.isNumber }
            if digits.isEmpty == false, digits.count <= 9,
               let next = line.dropFirst(digits.count).first, next == "." || next == ")",
               isBlank(line.dropFirst(digits.count + 1).first) {
                return digits + "\\" + line.dropFirst(digits.count)
            }
            return line
        }
    }
}

private struct InlineRunBuilder: MarkupWalker {
    var result = AttributedString()
    private var linkStack: [URL?] = []

    private mutating func append(_ text: String) {
        guard text.isEmpty == false else { return }
        var run = AttributedString(text)
        if let url = linkStack.last ?? nil {
            run.link = url
        }
        result.append(run)
    }

    mutating func visitText(_ text: Markdown.Text) { append(text.string) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) { append(inlineCode.code) }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { append(" ") }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { append("\n") }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { append(inlineHTML.rawHTML) }

    mutating func visitLink(_ link: Link) {
        linkStack.append(link.destination.flatMap { URL(string: $0) })
        descendInto(link)
        linkStack.removeLast()
    }

    mutating func visitImage(_ image: Image) {
        linkStack.append(nil)
        descendInto(image)
        linkStack.removeLast()
    }
}
