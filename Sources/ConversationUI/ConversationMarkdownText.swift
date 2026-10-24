import SwiftUI

public struct ConversationMarkdownText: View {
    let text: String
    let preparedBlocks: [ConversationMarkdownBlock]?
    let textColor: Color
    let theme: ConversationTheme

    public init(text: String, preparedBlocks: [ConversationMarkdownBlock]? = nil,
                textColor: Color? = nil, theme: ConversationTheme = .toastty) {
        self.text = text
        self.preparedBlocks = preparedBlocks
        self.textColor = textColor ?? theme.primaryText
        self.theme = theme
    }

    public var body: some View {
        // Matches the transcript stack spacing so the seams between chunks of
        // a split message are indistinguishable from in-message block gaps.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(preparedBlocks.map { Self.styledBlocks($0, theme: theme) } ?? Self.blocks(text, theme: theme)) { block in
                blockView(block)
            }
        }
        .foregroundStyle(textColor)
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: ConversationMarkdownBlock) -> some View {
        switch block.style {
        case .paragraph:
            ConversationSelectableText(block.content, textColor: textColor, theme: theme)
        case .heading(let level):
            ConversationSelectableText(block.content,
                                  textStyle: level <= 2 ? .headline : .subheadline,
                                  weight: .semibold, textColor: textColor, theme: theme)
                .padding(.top, block.id == 0 ? 0 : 2)
        case .list(let marker, let depth):
            HStack(alignment: .top, spacing: 8) {
                Text(block.isContinuation ? "" : marker.label)
                    .font(.body.monospaced())
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: 16, alignment: .trailing)
                ConversationSelectableText(block.content, textColor: textColor, theme: theme)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.border)
                    .frame(width: 3)
                ConversationSelectableText(block.content, textColor: theme.secondaryText, theme: theme)
            }
        case .table(let table):
            ConversationMarkdownTableView(table: table, theme: theme)
        case .code(let language):
            VStack(alignment: .leading, spacing: 0) {
                if let language, language.isEmpty == false {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(theme.mutedText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.codeHeaderSurface)
                    Divider()
                        .overlay(theme.border)
                }
                ConversationSelectableText(block.content, monospaced: true,
                                      textColor: textColor, lineSpacing: 4, theme: theme)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.raisedSurface)
            .overlay {
                RoundedRectangle(
                    cornerRadius: theme.controlCornerRadius,
                    style: .continuous
                )
                .stroke(theme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: theme.controlCornerRadius,
                style: .continuous
            ))
        }
    }

    /// Parsed-block cache: with eager transcript layout every message re-parses
    /// on each body evaluation without it. Keyed by the raw markdown text.
    private static let parsedBlockCache: NSCache<NSString, ParsedMarkdownBlocks> = {
        let cache = NSCache<NSString, ParsedMarkdownBlocks>()
        cache.countLimit = 600
        return cache
    }()

    private final class ParsedMarkdownBlocks {
        let blocks: [ConversationMarkdownBlock]
        var styledBlocks: [ConversationMarkdownBlock]
        var theme: ConversationTheme

        init(_ blocks: [ConversationMarkdownBlock], styledBlocks: [ConversationMarkdownBlock],
             theme: ConversationTheme) {
            self.blocks = blocks
            self.styledBlocks = styledBlocks
            self.theme = theme
        }
    }

    public static func blocks(_ text: String, theme: ConversationTheme = .toastty) -> [ConversationMarkdownBlock] {
        let key = text as NSString
        if let cached = parsedBlockCache.object(forKey: key) {
            if cached.theme != theme {
                cached.styledBlocks = styledBlocks(cached.blocks, theme: theme)
                cached.theme = theme
            }
            return cached.styledBlocks
        }
        let parsed = ConversationMarkdownParser.parse(text)
        let styled = styledBlocks(parsed, theme: theme)
        parsedBlockCache.setObject(ParsedMarkdownBlocks(parsed, styledBlocks: styled, theme: theme), forKey: key)
        return styled
    }

    private static func styledBlocks(_ blocks: [ConversationMarkdownBlock], theme: ConversationTheme) -> [ConversationMarkdownBlock] {
        blocks.map { block in
            if case .table(let table) = block.style {
                let styled = ConversationMarkdownTable(columns: table.columns, rows: table.rows.map { row in
                    .init(id: row.id, cells: row.cells.map { stylingInlineContent($0, theme: theme) })
                })
                return ConversationMarkdownBlock(
                    id: block.id,
                    content: block.content,
                    style: .table(styled),
                    isContinuation: block.isContinuation
                )
            }
            guard case .code = block.style else {
                return ConversationMarkdownBlock(
                    id: block.id,
                    content: stylingInlineContent(block.content, theme: theme),
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
    private static func stylingInlineContent(_ content: AttributedString, theme: ConversationTheme) -> AttributedString {
        guard content.runs.contains(where: {
            $0.inlinePresentationIntent?.contains(.code) == true
                || isExternalWebLink($0.link)
        }) else { return content }

        var styled = AttributedString()
        for run in content.runs {
            var piece = AttributedString(content[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.foregroundColor = theme.amberText
                piece.backgroundColor = theme.chipSurface
            } else if isExternalWebLink(run.link) {
                piece.foregroundColor = theme.externalLink
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
