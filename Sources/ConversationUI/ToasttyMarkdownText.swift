import SwiftUI

struct ToasttyMarkdownText: View {
    let text: String
    var preparedBlocks: [ToasttyMarkdownBlock]?
    var textColor: Color = ConversationDesignTokens.primaryText
    @Environment(\.conversationLinkPresenter) private var linkPresenter

    var body: some View {
        // Matches the transcript stack spacing so the seams between chunks of
        // a split message are indistinguishable from in-message block gaps.
        VStack(alignment: .leading, spacing: 12) {
            let blocks = preparedBlocks.map(Self.styledBlocks) ?? Self.blocks(text)
            #if canImport(AppKit) && !canImport(UIKit)
            ForEach(ToasttyMarkdownSegment.segments(blocks)) { segment in
                segmentView(segment)
            }
            #else
            ForEach(blocks) { block in
                blockView(block)
            }
            #endif
        }
        .foregroundStyle(textColor)
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
    }

    #if canImport(AppKit) && !canImport(UIKit)
    /// A drag on the Mac selects within one text view. Consecutive text
    /// blocks share one view, so a drag can select across paragraphs, headings,
    /// list items and quotes. Code blocks and tables keep their own views.
    @ViewBuilder
    private func segmentView(_ segment: ToasttyMarkdownSegment) -> some View {
        switch segment {
        case .text(let blocks):
            ToasttySelectableText(paragraphs: blocks.map(paragraph))
                // A heading after a code block or table keeps its own gap.
                .padding(.top, blocks.first.map(Self.isHeading) == true && blocks.first?.id != 0 ? 2 : 0)
        case .other(let block):
            blockView(block)
        }
    }

    /// The paragraph that matches the block's own view in `blockView`.
    private func paragraph(_ block: ToasttyMarkdownBlock) -> ToasttySelectableParagraph {
        let content = presented(block.content)
        switch block.style {
        case .heading(let level):
            return ToasttySelectableParagraph(
                text: content, textStyle: level <= 2 ? .headline : .subheadline,
                weight: .semibold, textColor: textColor, spacingBefore: 14
            )
        case .list(let marker, let depth):
            return ToasttySelectableParagraph(
                text: content, textColor: textColor, spacingBefore: 12,
                decoration: .listMarker(block.isContinuation ? "" : marker.label, depth: depth)
            )
        case .blockQuote:
            return ToasttySelectableParagraph(
                text: content, textColor: ConversationDesignTokens.secondaryText,
                spacingBefore: 12, decoration: .quote
            )
        case .paragraph, .code, .table:
            return ToasttySelectableParagraph(text: content, textColor: textColor, spacingBefore: 12)
        }
    }

    private static func isHeading(_ block: ToasttyMarkdownBlock) -> Bool {
        if case .heading = block.style { return true }
        return false
    }
    #endif

    @ViewBuilder
    private func blockView(_ block: ToasttyMarkdownBlock) -> some View {
        switch block.style {
        case .paragraph:
            ToasttySelectableText(presented(block.content), textColor: textColor)
        case .heading(let level):
            ToasttySelectableText(presented(block.content),
                                  textStyle: level <= 2 ? .headline : .subheadline,
                                  weight: .semibold, textColor: textColor)
                .padding(.top, block.id == 0 ? 0 : 2)
        case .list(let marker, let depth):
            HStack(alignment: .top, spacing: 8) {
                Text(block.isContinuation ? "" : marker.label)
                    .font(.body.monospaced())
                    .foregroundStyle(ConversationDesignTokens.secondaryText)
                    .frame(minWidth: 16, alignment: .trailing)
                ToasttySelectableText(presented(block.content), textColor: textColor)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(ConversationDesignTokens.border)
                    .frame(width: 3)
                ToasttySelectableText(presented(block.content), textColor: ConversationDesignTokens.secondaryText)
            }
        case .table(let table):
            ToasttyMarkdownTableView(table: table)
        case .code(let language):
            VStack(alignment: .leading, spacing: 0) {
                if let language, language.isEmpty == false {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(ConversationDesignTokens.mutedText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ConversationDesignTokens.codeHeaderSurface)
                    Divider()
                        .overlay(ConversationDesignTokens.border)
                }
                ToasttySelectableText(block.content, monospaced: true,
                                      textColor: textColor, lineSpacing: 4)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConversationDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(
                    cornerRadius: ConversationDesignTokens.controlCornerRadius,
                    style: .continuous
                )
                .stroke(ConversationDesignTokens.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: ConversationDesignTokens.controlCornerRadius,
                style: .continuous
            ))
        }
    }

    /// The host's presenter decides how each link is drawn. It runs when the
    /// text is drawn, after the parsed-block cache, because its answer can
    /// change while the message does not.
    private func presented(_ content: AttributedString) -> AttributedString {
        ConversationLinkDecoration.apply(content, presenter: linkPresenter)
    }

    /// Parsed-block cache: with eager transcript layout every message re-parses
    /// on each body evaluation without it. Keyed by the raw markdown text.
    private static let parsedBlockCache: NSCache<NSString, ParsedMarkdownBlocks> = {
        let cache = NSCache<NSString, ParsedMarkdownBlocks>()
        cache.countLimit = 600
        return cache
    }()

    private final class ParsedMarkdownBlocks {
        let blocks: [ToasttyMarkdownBlock]
        init(_ blocks: [ToasttyMarkdownBlock]) { self.blocks = blocks }
    }

    static func blocks(_ text: String) -> [ToasttyMarkdownBlock] {
        let key = text as NSString
        if let cached = parsedBlockCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = styledBlocks(ToasttyMarkdownParser.parse(text))
        parsedBlockCache.setObject(ParsedMarkdownBlocks(parsed), forKey: key)
        return parsed
    }

    private static func styledBlocks(_ blocks: [ToasttyMarkdownBlock]) -> [ToasttyMarkdownBlock] {
        blocks.map { block in
            if case .table(let table) = block.style {
                let styled = ToasttyMarkdownTable(columns: table.columns, rows: table.rows.map { row in
                    .init(id: row.id, cells: row.cells.map(stylingInlineContent))
                })
                return ToasttyMarkdownBlock(
                    id: block.id,
                    content: block.content,
                    style: .table(styled),
                    isContinuation: block.isContinuation
                )
            }
            guard case .code = block.style else {
                return ToasttyMarkdownBlock(
                    id: block.id,
                    content: stylingInlineContent(block.content),
                    style: block.style,
                    isContinuation: block.isContinuation
                )
            }
            return block
        }
    }

    /// Tints inline code and semantic external web links. Inline code wins
    /// when Markdown assigns both attributes, while the link itself remains
    /// intact for SwiftUI interaction.
    private static func stylingInlineContent(_ content: AttributedString) -> AttributedString {
        guard content.runs.contains(where: {
            $0.inlinePresentationIntent?.contains(.code) == true
                || isExternalWebLink($0.link)
        }) else { return content }

        var styled = AttributedString()
        for run in content.runs {
            var piece = AttributedString(content[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.foregroundColor = ConversationDesignTokens.amberText
                piece.backgroundColor = ConversationDesignTokens.chipSurface
            } else if isExternalWebLink(run.link) {
                piece.foregroundColor = ConversationDesignTokens.externalLink
            }
            styled.append(piece)
        }
        return styled
    }

    private static func isExternalWebLink(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return url.host?.isEmpty == false
    }

}

/// A run of text blocks that share one text view, or a block with its own view.
enum ToasttyMarkdownSegment: Identifiable, Equatable {
    case text([ToasttyMarkdownBlock])
    case other(ToasttyMarkdownBlock)

    /// The first block's ID, so a run that grows while a reply streams keeps
    /// its text view and selection.
    var id: Int {
        switch self {
        case .text(let blocks): blocks.first?.id ?? -1
        case .other(let block): block.id
        }
    }

    static func segments(_ blocks: [ToasttyMarkdownBlock]) -> [ToasttyMarkdownSegment] {
        var segments: [ToasttyMarkdownSegment] = []
        var run: [ToasttyMarkdownBlock] = []
        for block in blocks {
            switch block.style {
            case .paragraph, .heading, .list, .blockQuote:
                run.append(block)
            case .code, .table:
                if !run.isEmpty { segments.append(.text(run)) }
                run = []
                segments.append(.other(block))
            }
        }
        if !run.isEmpty { segments.append(.text(run)) }
        return segments
    }
}
