import Foundation

/// Layout chunks contain already-parsed content. Parsing the entire message
/// first preserves document-wide links and block structure across cell seams.
struct ToasttyMarkdownChunk: Equatable, Sendable {
    let blocks: [ToasttyMarkdownBlock]
}

enum ToasttyMarkdownChunking {
    static let chunkThreshold = 3_000
    static let chunkBudget = 2_000

    static func split(_ text: String) -> [ToasttyMarkdownChunk] {
        let blocks = ToasttyMarkdownParser.parse(text)
        let hasTallTable = blocks.contains { block in
            guard case .table(let table) = block.style else { return false }
            return table.rows.count - 1 > ToasttyMarkdownTable.maximumBodyRowsPerChunk
        }
        guard text.count > chunkThreshold || hasTallTable else { return [.init(blocks: blocks)] }
        var chunks: [ToasttyMarkdownChunk] = []
        var current: [ToasttyMarkdownBlock] = []
        var currentCount = 0
        var nextPieceID = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(.init(blocks: current))
            current.removeAll(keepingCapacity: true)
            currentCount = 0
        }

        for block in blocks {
            for piece in splitBlock(block) {
                let count = piece.content.characters.count
                if currentCount > 0, currentCount + count > chunkBudget {
                    // Keep a heading with the first content it introduces.
                    if let last = current.last, case .heading = last.style, current.count > 1 {
                        current.removeLast()
                        flush()
                        current.append(last)
                        currentCount = last.content.characters.count
                    } else {
                        flush()
                    }
                }
                current.append(ToasttyMarkdownBlock(
                    id: nextPieceID,
                    content: piece.content,
                    style: piece.style,
                    isContinuation: piece.isContinuation
                ))
                nextPieceID += 1
                currentCount += count
                // Sparse table sections need their own layout cell even when
                // their text fits together within the character budget.
                if case .table = piece.style { flush() }
            }
        }
        flush()
        return chunks.isEmpty ? [.init(blocks: blocks)] : chunks
    }

    private static func splitBlock(_ block: ToasttyMarkdownBlock) -> [ToasttyMarkdownBlock] {
        if case .table(let table) = block.style {
            return table.split(rowBudget: chunkBudget).enumerated().map { index, part in
                ToasttyMarkdownBlock(
                    id: block.id,
                    content: part.content,
                    style: .table(part),
                    isContinuation: index > 0
                )
            }
        }
        let content = block.content
        let characters = content.characters
        var start = characters.startIndex
        var pieces: [ToasttyMarkdownBlock] = []
        while start < characters.endIndex {
            var end = characters.index(start, offsetBy: chunkBudget, limitedBy: characters.endIndex)
                ?? characters.endIndex
            if end < characters.endIndex {
                // Prefer line/word boundaries, retaining every original
                // character and attribute (including link destinations).
                let range = characters[start..<end]
                if let newline = range.lastIndex(of: "\n") {
                    end = characters.index(after: newline)
                } else if let space = range.lastIndex(where: { $0.isWhitespace }) {
                    end = characters.index(after: space)
                }
            }
            pieces.append(ToasttyMarkdownBlock(
                id: block.id,
                content: AttributedString(content[start..<end]),
                style: block.style,
                isContinuation: !pieces.isEmpty
            ))
            start = end
        }
        return pieces
    }
}

/// Foundation owns Markdown grammar; layout consumes its semantic blocks.
enum ToasttyMarkdownParser {
    static func parse(_ text: String) -> [ToasttyMarkdownBlock] {
        guard let attributed = try? AttributedString(markdown: text) else {
            return [ToasttyMarkdownBlock(
                id: 0,
                content: AttributedString(text),
                style: .paragraph
            )]
        }

        var blocks: [ToasttyMarkdownBlock] = []
        var currentPresentationIdentity: Int?
        var currentContent = AttributedString()
        var currentStyle = ToasttyMarkdownBlock.Style.paragraph
        var currentTable: ToasttyMarkdownTableBuilder?

        func flushCurrentBlock() {
            guard currentContent.characters.isEmpty == false else { return }
            blocks.append(ToasttyMarkdownBlock(
                id: blocks.count,
                content: currentContent,
                style: currentStyle
            ))
            currentContent = AttributedString()
        }

        func flushTable() {
            guard let table = currentTable?.table else { return }
            blocks.append(ToasttyMarkdownBlock(
                id: blocks.count,
                content: table.content,
                style: .table(table)
            ))
            currentTable = nil
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            if let position = ToasttyMarkdownTableBuilder.Position(intent) {
                flushCurrentBlock()
                currentPresentationIdentity = nil
                if currentTable?.id != position.tableID {
                    flushTable()
                    currentTable = ToasttyMarkdownTableBuilder(position: position)
                }
                currentTable?.append(AttributedString(attributed[run.range]), at: position)
                continue
            }
            flushTable()
            let identity = intent?.components.first?.identity
            if identity != currentPresentationIdentity {
                flushCurrentBlock()
                currentPresentationIdentity = identity
                currentStyle = Self.style(for: intent)
            }
            currentContent.append(AttributedString(attributed[run.range]))
        }
        flushCurrentBlock()
        flushTable()

        if blocks.isEmpty, text.isEmpty == false {
            return [ToasttyMarkdownBlock(
                id: 0,
                content: AttributedString(text),
                style: .paragraph
            )]
        }
        return blocks
    }

    private static func style(
        for intent: PresentationIntent?
    ) -> ToasttyMarkdownBlock.Style {
        guard let intent else { return .paragraph }

        var headingLevel: Int?
        var codeLanguage: String?
        var isCode = false
        var isBlockQuote = false
        var listOrdinal: Int?
        var listMarker: ToasttyMarkdownBlock.ListMarker?
        var listDepth = 0

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                headingLevel = level
            case .codeBlock(let language):
                isCode = true
                codeLanguage = language
            case .blockQuote:
                isBlockQuote = true
            case .listItem(let ordinal):
                if listOrdinal == nil { listOrdinal = ordinal }
            case .orderedList:
                listDepth += 1
                if listMarker == nil {
                    listMarker = .ordered(listOrdinal ?? 1)
                }
            case .unorderedList:
                listDepth += 1
                if listMarker == nil { listMarker = .bullet }
            case .paragraph, .thematicBreak, .table, .tableHeaderRow,
                 .tableRow(_), .tableCell(_):
                break
            @unknown default:
                break
            }
        }

        if isCode { return .code(language: codeLanguage) }
        if let headingLevel { return .heading(level: headingLevel) }
        if let listMarker { return .list(marker: listMarker, depth: listDepth) }
        if isBlockQuote { return .blockQuote }
        return .paragraph
    }
}

struct ToasttyMarkdownBlock: Identifiable, Equatable, Sendable {
    enum ListMarker: Equatable, Sendable {
        case bullet
        case ordered(Int)

        var label: String {
            switch self {
            case .bullet: "•"
            case .ordered(let ordinal): "\(ordinal)."
            }
        }
    }

    enum Style: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case list(marker: ListMarker, depth: Int)
        case blockQuote
        case code(language: String?)
        case table(ToasttyMarkdownTable)
    }

    let id: Int
    let content: AttributedString
    let style: Style
    var isContinuation = false
}
