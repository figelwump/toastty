import SwiftUI

struct ToasttyMarkdownText: View {
    let text: String
    var preparedBlocks: [ToasttyMarkdownBlock]?
    var textColor: Color = ToasttyDesignTokens.primaryText

    var body: some View {
        // Matches the transcript stack spacing so the seams between chunks of
        // a split message are indistinguishable from in-message block gaps.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(preparedBlocks.map(Self.styledBlocks) ?? Self.blocks(text)) { block in
                blockView(block)
            }
        }
        .foregroundStyle(textColor)
        .lineSpacing(6)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func blockView(_ block: ToasttyMarkdownBlock) -> some View {
        switch block.style {
        case .paragraph:
            Text(block.content)
                .font(.body)
        case .heading(let level):
            Text(block.content)
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, block.id == 0 ? 0 : 2)
        case .list(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.isContinuation ? "" : marker.label)
                    .font(.body.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(block.content)
                    .font(.body)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 16)
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(ToasttyDesignTokens.border)
                    .frame(width: 3)
                Text(block.content)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
            }
        case .code(let language):
            VStack(alignment: .leading, spacing: 0) {
                if let language, language.isEmpty == false {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ToasttyDesignTokens.codeHeaderSurface)
                    Divider()
                        .overlay(ToasttyDesignTokens.border)
                }
                Text(block.content)
                    .font(.body.monospaced())
                    .lineSpacing(4)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToasttyDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                    style: .continuous
                )
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
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
                piece.foregroundColor = ToasttyDesignTokens.amberText
                piece.backgroundColor = ToasttyDesignTokens.chipSurface
            } else if isExternalWebLink(run.link) {
                piece.foregroundColor = ToasttyDesignTokens.externalLink
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
