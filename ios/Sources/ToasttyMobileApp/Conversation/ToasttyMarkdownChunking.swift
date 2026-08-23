import Foundation

/// Splits long markdown into standalone chunks at top-level blank lines so a
/// giant assistant message renders as several transcript blocks instead of one
/// unbreakable `LazyVStack` cell. Single huge cells get their estimated height
/// corrected during scrolling, which snaps the viewport to the cell boundary
/// and makes live-edge scroll targeting land short.
enum ToasttyMarkdownChunking {
    /// Messages at or below this size stay whole; roughly two phone screens
    /// of body text.
    static let chunkThreshold = 3_000
    /// Target upper bound for each emitted chunk once a message is split.
    static let chunkBudget = 2_000

    static func split(_ text: String) -> [String] {
        guard text.count > chunkThreshold else { return [text] }

        var chunks: [String] = []
        var current: [String] = []
        var currentCount = 0

        func flush() {
            guard current.isEmpty == false else { return }
            chunks.append(current.joined(separator: "\n\n"))
            current.removeAll(keepingCapacity: true)
            currentCount = 0
        }

        for segment in segments(of: text) {
            let pieces = segment.count > chunkBudget ? splitOversized(segment) : [segment]
            for piece in pieces {
                if currentCount > 0, currentCount + piece.count > chunkBudget {
                    // Carry a trailing heading over so it stays with the
                    // content it titles.
                    if let last = current.last, isHeading(last), current.count > 1 {
                        current.removeLast()
                        flush()
                        current.append(last)
                        currentCount = last.count
                    } else {
                        flush()
                    }
                }
                current.append(piece)
                currentCount += piece.count + 2
            }
        }
        flush()
        return chunks.isEmpty ? [text] : chunks
    }

    /// Top-level markdown segments: runs of lines separated by blank lines,
    /// treating fenced code blocks as atomic even when they contain blanks.
    private static func segments(of text: String) -> [String] {
        var segments: [String] = []
        var current: [String] = []
        var openFence: String?

        func flush() {
            guard current.isEmpty == false else { return }
            segments.append(current.joined(separator: "\n"))
            current.removeAll(keepingCapacity: true)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = openFence {
                current.append(line)
                if closesFence(trimmed, openedBy: fence) {
                    openFence = nil
                }
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            current.append(line)
            if let fence = fenceDelimiter(of: trimmed) {
                openFence = fence
            }
        }
        flush()
        return segments
    }

    /// Splits a single oversized segment. A fenced code block is re-fenced per
    /// piece so every chunk stays valid markdown; other segments split at line
    /// boundaries, falling back to whitespace for single giant lines.
    private static func splitOversized(_ segment: String) -> [String] {
        let lines = segment.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let opening = lines.first,
           let fence = fenceDelimiter(of: opening.trimmingCharacters(in: .whitespaces)),
           lines.count > 2,
           closesFence(lines[lines.count - 1].trimmingCharacters(in: .whitespaces), openedBy: fence) {
            let interior = Array(lines[1 ..< lines.count - 1])
            return packLines(interior, budget: chunkBudget).map { body in
                ([opening] + body + [fence]).joined(separator: "\n")
            }
        }

        if lines.count > 1 {
            return packLines(lines, budget: chunkBudget).map { $0.joined(separator: "\n") }
        }
        return splitAtWhitespace(segment)
    }

    private static func packLines(_ lines: [String], budget: Int) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var currentCount = 0
        for line in lines {
            if currentCount > 0, currentCount + line.count > budget {
                groups.append(current)
                current = []
                currentCount = 0
            }
            current.append(line)
            currentCount += line.count + 1
        }
        if current.isEmpty == false { groups.append(current) }
        return groups
    }

    private static func splitAtWhitespace(_ line: String) -> [String] {
        var pieces: [String] = []
        var remainder = Substring(line)
        while remainder.count > chunkBudget {
            let limit = remainder.index(remainder.startIndex, offsetBy: chunkBudget)
            let breakIndex = remainder[..<limit].lastIndex(where: \.isWhitespace) ?? limit
            let piece = remainder[..<breakIndex].trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { break }
            pieces.append(piece)
            remainder = remainder[breakIndex...].drop(while: \.isWhitespace)
        }
        if remainder.isEmpty == false { pieces.append(String(remainder)) }
        return pieces.isEmpty ? [line] : pieces
    }

    private static func fenceDelimiter(of trimmed: String) -> String? {
        for fenceCharacter: Character in ["`", "~"] {
            let run = trimmed.prefix(while: { $0 == fenceCharacter })
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func closesFence(_ trimmed: String, openedBy fence: String) -> Bool {
        guard let character = fence.first else { return false }
        let run = trimmed.prefix(while: { $0 == character })
        return run.count >= fence.count && trimmed.dropFirst(run.count).isEmpty
    }

    private static func isHeading(_ segment: String) -> Bool {
        segment.contains("\n") == false && segment.hasPrefix("#")
    }
}
