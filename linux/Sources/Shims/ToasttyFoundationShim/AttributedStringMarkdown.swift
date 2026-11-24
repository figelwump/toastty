#if os(Linux)
import Foundation
import Markdown

// swift-corelibs-foundation has no `AttributedString(markdown:)` and no
// presentation intents. This builds the AttributedString that Apple's
// cmark-gfm-backed parser makes, from swift-markdown (also cmark-gfm), as
// far as Toastty reads it:
//
// - `link` on link text; code spans, code blocks and raw HTML carry none,
//   and an image's alt text carries none (Apple records `imageURL`).
// - `presentationIntent` on every run: its blocks from the innermost out,
//   each with an identity unique in the document, so runs of one block share
//   their first component's identity. Blocks follow each other with no
//   separator text, as in Apple's output.
// - `inlinePresentationIntent`: emphasis, strong, code, strikethrough, soft
//   and hard line breaks.
//
// Shared code that reads these: ToasttyMarkdownChunking and
// ToasttyMarkdownTable (ConversationUI), RemotePreviewLinkReference.

/// Apple's `PresentationIntent`, as far as Toastty reads it.
public struct PresentationIntent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case paragraph
        case header(level: Int)
        case orderedList
        case unorderedList
        case listItem(ordinal: Int)
        case codeBlock(languageHint: String?)
        case blockQuote
        case thematicBreak
        case table(columns: [TableColumn])
        case tableHeaderRow
        case tableRow(rowIndex: Int)
        case tableCell(columnIndex: Int)
    }

    public struct TableColumn: Hashable, Sendable {
        public enum Alignment: Hashable, Sendable {
            case left
            case center
            case right
        }

        public var alignment: Alignment

        public init(alignment: Alignment) {
            self.alignment = alignment
        }
    }

    public struct IntentType: Hashable, Sendable {
        public var kind: Kind
        public var identity: Int

        public init(kind: Kind, identity: Int) {
            self.kind = kind
            self.identity = identity
        }
    }

    /// The innermost block first.
    public var components: [IntentType]

    public init(components: [IntentType]) {
        self.components = components
    }
}

/// Apple's `InlinePresentationIntent`, with Apple's raw values.
public struct InlinePresentationIntent: OptionSet, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let emphasized = Self(rawValue: 1 << 0)
    public static let stronglyEmphasized = Self(rawValue: 1 << 1)
    public static let code = Self(rawValue: 1 << 2)
    public static let strikethrough = Self(rawValue: 1 << 5)
    public static let softBreak = Self(rawValue: 1 << 6)
    public static let lineBreak = Self(rawValue: 1 << 7)
    public static let inlineHTML = Self(rawValue: 1 << 8)
    public static let blockHTML = Self(rawValue: 1 << 9)
}

public enum PresentationIntentAttribute: AttributedStringKey {
    public typealias Value = PresentationIntent
    public static let name = "NSPresentationIntent"
}

public enum InlinePresentationIntentAttribute: AttributedStringKey {
    public typealias Value = InlinePresentationIntent
    public static let name = "NSInlinePresentationIntent"
}

extension AttributeScopes {
    /// The markdown attributes, reachable as `run.presentationIntent` and
    /// `run.inlinePresentationIntent` as on Apple platforms.
    public struct ToasttyMarkdownAttributes: AttributeScope {
        public let presentationIntent: PresentationIntentAttribute
        public let inlinePresentationIntent: InlinePresentationIntentAttribute
    }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.ToasttyMarkdownAttributes, T>
    ) -> T {
        self[T.self]
    }
}

extension AttributedString {
    public init(markdown: String) throws {
        var builder = MarkdownRunBuilder()
        builder.visit(Document(parsing: markdown))
        self = builder.result
    }
}

private struct MarkdownRunBuilder: MarkupWalker {
    var result = AttributedString()
    /// Open blocks, the outermost first.
    private var blocks: [PresentationIntent.IntentType] = []
    private var inline: InlinePresentationIntent = []
    private var linkStack: [URL?] = []
    private var nextIdentity = 1

    private mutating func append(_ text: String, adding extra: InlinePresentationIntent = []) {
        guard !text.isEmpty else { return }
        var run = AttributedString(text)
        if let url = linkStack.last ?? nil {
            run.link = url
        }
        if blocks.isEmpty == false {
            run.presentationIntent = PresentationIntent(components: blocks.reversed())
        }
        let intent = inline.union(extra)
        if intent.isEmpty == false {
            run.inlinePresentationIntent = intent
        }
        result.append(run)
    }

    private mutating func inBlock(_ kind: PresentationIntent.Kind, _ markup: Markup) {
        blocks.append(PresentationIntent.IntentType(kind: kind, identity: nextIdentity))
        nextIdentity += 1
        descendInto(markup)
        blocks.removeLast()
    }

    private mutating func withInline(_ intent: InlinePresentationIntent, _ markup: Markup) {
        let saved = inline
        inline.formUnion(intent)
        descendInto(markup)
        inline = saved
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) { inBlock(.paragraph, paragraph) }
    mutating func visitHeading(_ heading: Heading) { inBlock(.header(level: heading.level), heading) }
    mutating func visitBlockQuote(_ blockQuote: BlockQuote) { inBlock(.blockQuote, blockQuote) }
    mutating func visitOrderedList(_ orderedList: OrderedList) { inBlock(.orderedList, orderedList) }
    mutating func visitUnorderedList(_ unorderedList: UnorderedList) { inBlock(.unorderedList, unorderedList) }

    mutating func visitListItem(_ listItem: ListItem) {
        // Ordinals count from the list's start, as cmark-gfm reports them.
        let start = (listItem.parent as? OrderedList).map { Int($0.startIndex) } ?? 1
        inBlock(.listItem(ordinal: start + listItem.indexInParent), listItem)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        blocks.append(PresentationIntent.IntentType(
            kind: .codeBlock(languageHint: codeBlock.language.flatMap { $0.isEmpty ? nil : $0 }),
            identity: nextIdentity
        ))
        nextIdentity += 1
        // No link inside code.
        linkStack.append(nil)
        append(codeBlock.code)
        linkStack.removeLast()
        blocks.removeLast()
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        blocks.append(PresentationIntent.IntentType(kind: .paragraph, identity: nextIdentity))
        nextIdentity += 1
        linkStack.append(nil)
        append(html.rawHTML, adding: .blockHTML)
        linkStack.removeLast()
        blocks.removeLast()
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        // Apple's parser gives a thematic break no text, so no run.
        nextIdentity += 1
    }

    mutating func visitTable(_ table: Table) {
        let columns = table.columnAlignments.map { alignment -> PresentationIntent.TableColumn in
            switch alignment {
            case .center: PresentationIntent.TableColumn(alignment: .center)
            case .right: PresentationIntent.TableColumn(alignment: .right)
            case .left, .none: PresentationIntent.TableColumn(alignment: .left)
            }
        }
        blocks.append(PresentationIntent.IntentType(kind: .table(columns: columns), identity: nextIdentity))
        nextIdentity += 1
        blocks.append(PresentationIntent.IntentType(kind: .tableHeaderRow, identity: nextIdentity))
        nextIdentity += 1
        visitCells(of: table.head)
        blocks.removeLast()
        for (index, row) in table.body.rows.enumerated() {
            blocks.append(PresentationIntent.IntentType(kind: .tableRow(rowIndex: index + 1), identity: nextIdentity))
            nextIdentity += 1
            visitCells(of: row)
            blocks.removeLast()
        }
        blocks.removeLast()
    }

    private mutating func visitCells(of row: Markup) {
        for (index, cell) in row.children.enumerated() {
            blocks.append(PresentationIntent.IntentType(kind: .tableCell(columnIndex: index), identity: nextIdentity))
            nextIdentity += 1
            descendInto(cell)
            blocks.removeLast()
        }
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) { append(text.string) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        linkStack.append(nil)
        append(inlineCode.code, adding: .code)
        linkStack.removeLast()
    }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        linkStack.append(nil)
        append(inlineHTML.rawHTML, adding: .inlineHTML)
        linkStack.removeLast()
    }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { append(" ", adding: .softBreak) }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { append("\n", adding: .lineBreak) }
    mutating func visitEmphasis(_ emphasis: Emphasis) { withInline(.emphasized, emphasis) }
    mutating func visitStrong(_ strong: Strong) { withInline(.stronglyEmphasized, strong) }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) { withInline(.strikethrough, strikethrough) }

    mutating func visitLink(_ link: Link) {
        linkStack.append(link.destination.flatMap { URL(string: $0) })
        descendInto(link)
        linkStack.removeLast()
    }

    mutating func visitImage(_ image: Image) {
        // Apple's parser records images as `imageURL`, never as `link`.
        linkStack.append(nil)
        descendInto(image)
        linkStack.removeLast()
    }
}
#endif
