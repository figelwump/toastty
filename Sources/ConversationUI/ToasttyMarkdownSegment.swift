import Foundation

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
