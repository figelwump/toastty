import CoreState
import Foundation

enum CodexVisibleTextStatusParser {
    static func workingStatus(from visibleText: String) -> SessionStatus? {
        guard let detail = workingDetail(from: visibleText) else {
            return nil
        }

        return SessionStatus(kind: .working, summary: "Working", detail: detail)
    }
}

private extension CodexVisibleTextStatusParser {
    static let actionableBulletPrefixes: [String] = [
        "Applying ",
        "Applied ",
        "Creating ",
        "Created ",
        "Deleting ",
        "Deleted ",
        "Editing ",
        "Edited ",
        "Executing ",
        "Executed ",
        "Listing ",
        "Listed ",
        "Ran ",
        "Reading ",
        "Read ",
        "Renaming ",
        "Renamed ",
        "Running ",
        "Searching ",
        "Searched ",
        "Updated ",
        "Updating ",
        "Wrote ",
        "Writing ",
    ]

    static func workingDetail(from visibleText: String) -> String? {
        let visibleLines = TerminalVisibleTextInspector.sanitizedLines(visibleText)
        guard visibleLines.isEmpty == false else {
            return nil
        }

        for line in visibleLines.reversed() {
            if let detail = statusLineDetail(from: line) {
                return detail
            }

            if let detail = actionableBulletDetail(from: line) {
                return detail
            }
        }

        return nil
    }

    static func statusLineDetail(from rawLine: String) -> String? {
        let line = collapsedWhitespace(rawLine)
        guard line.hasSuffix("esc to interrupt)") else {
            return nil
        }

        let detail = line
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let detail, detail.isEmpty == false else {
            return nil
        }
        guard detail.caseInsensitiveCompare("Working") != .orderedSame else {
            return nil
        }

        return detail
    }

    static func actionableBulletDetail(from rawLine: String) -> String? {
        let line = collapsedWhitespace(rawLine)
        guard line.hasPrefix("• ") else {
            return nil
        }

        let detail = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard detail.isEmpty == false else {
            return nil
        }

        guard actionableBulletPrefixes.contains(where: { detail.hasPrefix($0) }) else {
            return nil
        }

        return detail
    }

    static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }
}
