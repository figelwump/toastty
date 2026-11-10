#if os(Linux)
import Foundation
import Markdown

/// swift-corelibs-foundation has no `AttributedString(markdown:)`. Shared code
/// (RemotePreviewLinkReference) only reads plain text runs and `link`
/// attributes, so this builds an AttributedString with the same link runs
/// Apple's cmark-gfm-backed parser produces: link text carries the
/// destination URL, code spans/blocks and raw HTML carry none.
extension AttributedString {
    public init(markdown: String) throws {
        var builder = MarkdownLinkRunBuilder()
        builder.visit(Document(parsing: markdown))
        self = builder.result
    }
}

private struct MarkdownLinkRunBuilder: MarkupWalker {
    var result = AttributedString()
    private var linkStack: [URL?] = []

    private mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        var run = AttributedString(text)
        if let url = linkStack.last ?? nil {
            run.link = url
        }
        result.append(run)
    }

    mutating func visitText(_ text: Text) { append(text.string) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) { append(inlineCode.code) }
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) { append(codeBlock.code) }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) { append(" ") }
    mutating func visitLineBreak(_ lineBreak: LineBreak) { append("\n") }

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
