import CoreState
import Foundation

enum CodexVisibleTextStatusParser {
    static func hasComputerUseApprovalPrompt(in activeScreen: String) -> Bool {
        let questionPrefix = "Allow Computer Use to use \""
        let footer = "enter to submit | esc to cancel"
        guard activeScreen.contains(questionPrefix), activeScreen.contains(footer) else { return false }

        let lines = TerminalVisibleTextSanitizer.sanitizedLines(activeScreen).suffix(24)
        guard lines.last == footer,
              let heading = lines.lastIndex(of: "Field 1/1") else { return false }
        let body = lines[lines.index(after: heading)..<lines.index(before: lines.endIndex)]
        guard body.first?.hasPrefix(questionPrefix) == true else { return false }
        let question = body.prefix { !$0.hasPrefix("App: ") && !$0.hasPrefix("1. ") && !$0.hasPrefix("› 1. ") }
        guard question.last?.hasSuffix("\"?") == true else { return false }

        // Codex adds › to the selected option and may wrap option descriptions.
        // Look for the option labels in order within the current bottom pane.
        let choices = ["1. Allow", "2. Allow for this session", "3. Always allow", "4. Cancel"]
        var nextChoice = choices.startIndex
        for row in body.dropFirst(question.count) {
            let line = row.hasPrefix("› ") ? String(row.dropFirst(2)) : row
            let choice = choices[nextChoice]
            if line == choice || line.hasPrefix(choice + " ") {
                nextChoice += 1
                if nextChoice == choices.endIndex { return true }
            }
        }
        return false
    }

    static func fatalErrorStatus(from visibleText: String) -> SessionStatus? {
        let visibleLines = TerminalVisibleTextSanitizer.sanitizedLines(visibleText)
        guard let detail = usageLimitErrorDetail(from: visibleLines) else {
            return nil
        }

        return SessionStatus(kind: .error, summary: "Error", detail: detail)
    }

    static func workingStatus(from visibleText: String) -> SessionStatus? {
        guard let detail = workingDetail(from: visibleText) else {
            return nil
        }

        return SessionStatus(kind: .working, summary: "Working", detail: detail)
    }

    static func statusLineWorkingStatus(from visibleText: String) -> SessionStatus? {
        guard let detail = statusLineWorkingDetail(from: visibleText) else {
            return nil
        }

        return SessionStatus(kind: .working, summary: "Working", detail: detail)
    }
}

private extension CodexVisibleTextStatusParser {
    static let usageLimitPrefix = "you've hit your usage limit."
    static let usageLimitURLFragment = "chatgpt.com/codex/settings/usage"
    static let fatalErrorWindowLineCount = 2
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

    static func usageLimitErrorDetail(from visibleLines: [String]) -> String? {
        guard visibleLines.isEmpty == false else {
            return nil
        }

        for lineIndex in stride(from: visibleLines.count - 1, through: 0, by: -1) {
            let windowEndIndex = min(visibleLines.count, lineIndex + fatalErrorWindowLineCount)
            let candidate = collapsedWhitespace(visibleLines[lineIndex..<windowEndIndex].joined(separator: " "))
            let normalizedCandidate = normalizedForMatching(candidate)
            guard normalizedCandidate.contains(usageLimitPrefix),
                  normalizedCandidate.contains(usageLimitURLFragment) else {
                continue
            }

            return candidate
        }

        return nil
    }

    static func workingDetail(from visibleText: String) -> String? {
        let visibleLines = TerminalVisibleTextSanitizer.sanitizedLines(visibleText)
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

    static func statusLineWorkingDetail(from visibleText: String) -> String? {
        let visibleLines = TerminalVisibleTextSanitizer.sanitizedLines(visibleText)
        guard visibleLines.isEmpty == false else {
            return nil
        }

        for line in visibleLines.reversed() {
            if let detail = statusLineDetail(from: line) {
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

    static func normalizedForMatching(_ value: String) -> String {
        collapsedWhitespace(value)
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
    }
}
