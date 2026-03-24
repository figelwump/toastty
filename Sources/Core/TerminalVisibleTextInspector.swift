import Foundation

public struct TerminalCloseConfirmationAssessment: Equatable, Sendable {
    public let requiresConfirmation: Bool
    public let runningCommand: String?

    public init(requiresConfirmation: Bool, runningCommand: String? = nil) {
        self.requiresConfirmation = requiresConfirmation
        self.runningCommand = runningCommand
    }
}

public enum TerminalVisibleTextInspector {
    public static func assessCloseConfirmation(for visibleText: String) -> TerminalCloseConfirmationAssessment {
        let visibleLines = sanitizedLines(visibleText)
        guard visibleLines.isEmpty == false else {
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }

        if let promptContext = recentPromptContext(from: visibleLines) {
            switch promptContext {
            case .interactive:
                return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
            case .command(let command, _):
                return TerminalCloseConfirmationAssessment(
                    requiresConfirmation: true,
                    runningCommand: truncatedCommand(command)
                )
            }
        }

        return TerminalCloseConfirmationAssessment(
            requiresConfirmation: true,
            runningCommand: inferredRunningCommand(
                from: visibleLines,
                includeAgentLaunchCommands: true
            )
        )
    }

    public static func showsInteractiveShellPrompt(_ visibleText: String) -> Bool {
        guard let promptContext = recentPromptContext(from: sanitizedLines(visibleText)) else {
            return false
        }

        switch promptContext {
        case .interactive:
            return true
        case .command(_, let token):
            return agentLaunchCommandTokens.contains(token) == false
        }
    }

    /// Returns true only when visible text shows an idle shell prompt with no
    /// foreground command token. This is stricter than
    /// `showsInteractiveShellPrompt(_:)`, which intentionally also treats
    /// non-agent prompt commands as interactive for close-confirmation
    /// heuristics.
    public static func showsIdleShellPrompt(_ visibleText: String) -> Bool {
        guard let promptContext = recentPromptContext(from: sanitizedLines(visibleText)) else {
            return false
        }

        if case .interactive = promptContext {
            return true
        }
        return false
    }

    public static func recentPromptCommandToken(_ visibleText: String) -> String? {
        guard let promptContext = recentPromptContext(from: sanitizedLines(visibleText)) else {
            return nil
        }

        switch promptContext {
        case .interactive:
            return nil
        case .command(_, let token):
            return token
        }
    }

    public static func inferredRunningCommand(
        _ visibleText: String,
        includeAgentLaunchCommands: Bool = false
    ) -> String? {
        inferredRunningCommand(
            from: sanitizedLines(visibleText),
            includeAgentLaunchCommands: includeAgentLaunchCommands
        )
    }

    public static func appearsBusy(_ visibleText: String) -> Bool {
        let visibleLines = sanitizedLines(visibleText)
        guard visibleLines.isEmpty == false else {
            return false
        }

        guard let promptObservation = recentPromptObservation(from: visibleLines) else {
            // For the generic sidebar subtitle, any pane with visible non-prompt
            // content counts as busy. That intentionally includes fullscreen
            // terminal programs such as editors and pagers.
            return true
        }

        return promptObservation.offsetFromBottom > 0
    }

    public static func sanitizedLines(_ visibleText: String) -> [String] {
        let filteredScalars = visibleText.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A, 0x0D:
                return true
            default:
                return scalar.value >= 0x20 && scalar.value != 0x7F
            }
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars))
        return sanitized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func inferredRunningCommand(
        from visibleLines: [String],
        includeAgentLaunchCommands: Bool
    ) -> String? {
        guard visibleLines.isEmpty == false else { return nil }
        let firstCandidateIndex = max(0, visibleLines.count - promptScanLineWindow)

        for visibleLineIndex in stride(from: visibleLines.count - 1, through: firstCandidateIndex, by: -1) {
            let offset = visibleLines.count - 1 - visibleLineIndex
            guard offset <= recentPromptLineMaxDistanceFromBottom else {
                break
            }
            guard let command = promptLineDetails(at: visibleLineIndex, in: visibleLines)?.command else {
                continue
            }

            let normalized = collapsedWhitespace(command)
            guard normalized.isEmpty == false else {
                continue
            }
            let token = leadingCommandToken(in: normalized) ?? ""
            guard token.isEmpty == false else {
                continue
            }
            guard includeAgentLaunchCommands || agentLaunchCommandTokens.contains(token) == false else {
                continue
            }
            return truncatedCommand(normalized)
        }

        return nil
    }

    private static func recentPromptContext(from visibleLines: [String]) -> PromptContext? {
        recentPromptObservation(from: visibleLines)?.context
    }

    private static func recentPromptObservation(from visibleLines: [String]) -> PromptObservation? {
        guard visibleLines.isEmpty == false else { return nil }
        let firstCandidateIndex = max(0, visibleLines.count - promptScanLineWindow)

        for visibleLineIndex in stride(from: visibleLines.count - 1, through: firstCandidateIndex, by: -1) {
            let offset = visibleLines.count - 1 - visibleLineIndex
            guard offset <= recentPromptLineMaxDistanceFromBottom else {
                break
            }
            guard let promptLine = promptLineDetails(at: visibleLineIndex, in: visibleLines) else {
                continue
            }

            guard let command = promptLine.command else {
                return PromptObservation(context: .interactive, offsetFromBottom: offset)
            }

            let token = leadingCommandToken(in: command) ?? ""
            guard token.isEmpty == false else {
                return PromptObservation(context: .interactive, offsetFromBottom: offset)
            }
            return PromptObservation(
                context: .command(command: command, token: token),
                offsetFromBottom: offset
            )
        }

        return nil
    }

    private static func promptLineDetails(at visibleLineIndex: Int, in visibleLines: [String]) -> PromptLineDetails? {
        let line = visibleLines[visibleLineIndex]
        if let strictPromptLine = parsedPromptLine(line) {
            return PromptLineDetails(command: normalizedPromptCommand(strictPromptLine.command))
        }

        if let loosePromptLine = parsedLoosePromptLine(line) {
            return loosePromptLine
        }

        let previousLine = visibleLineIndex > 0 ? visibleLines[visibleLineIndex - 1] : nil
        if let hostPromptLine = parsedTwoLineHostPromptLine(line, previousLine: previousLine) {
            return hostPromptLine
        }

        return nil
    }

    private static func parsedPromptLine(_ line: String) -> (cwdToken: String, command: String?)? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 3 else { return nil }
        guard parts[0].contains("@") else { return nil }
        let promptMarker = parts[2]
        guard promptMarker == "%" || promptMarker == "#" || promptMarker == "$" else {
            return nil
        }

        let cwdToken = parts[1]
        let command: String?
        if parts.count > 3 {
            command = parts.dropFirst(3).joined(separator: " ")
        } else {
            command = nil
        }
        return (cwdToken: cwdToken, command: command)
    }

    private static func parsedLoosePromptLine(_ line: String) -> PromptLineDetails? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.isEmpty == false else { return nil }
        let lastIndex = min(parts.count - 1, loosePromptMarkerScanTokenLimit)
        guard lastIndex >= 0 else { return nil }

        for index in 0...lastIndex {
            let token = parts[index]

            if promptMarkerTokens.contains(token) {
                guard index > 0,
                      normalizedPromptPathCandidate(parts[index - 1]) != nil else {
                    continue
                }
                let command: String?
                if index + 1 < parts.count {
                    command = parts[(index + 1)...].joined(separator: " ")
                } else {
                    command = nil
                }
                return PromptLineDetails(command: normalizedPromptCommand(command))
            }

            guard token.count > 1,
                  let trailingCharacter = token.last else {
                continue
            }
            let markerToken = String(trailingCharacter)
            guard promptMarkerTokens.contains(markerToken) else {
                continue
            }

            let pathToken = String(token.dropLast())
            guard normalizedPromptPathCandidate(pathToken) != nil else {
                continue
            }
            let command: String?
            if index + 1 < parts.count {
                command = parts[(index + 1)...].joined(separator: " ")
            } else {
                command = nil
            }
            return PromptLineDetails(command: normalizedPromptCommand(command))
        }

        return nil
    }

    // Some users run two-line prompts that print the cwd above a host/user
    // prompt line such as `mac:san-antonio j$`. Keep this matcher intentionally
    // narrow so transcript lines do not get mistaken for prompt state.
    private static func parsedTwoLineHostPromptLine(
        _ line: String,
        previousLine: String?
    ) -> PromptLineDetails? {
        guard previousLineLooksLikeTwoLinePromptDirectory(previousLine) else {
            return nil
        }

        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 2 else {
            return nil
        }
        guard looksLikeTwoLineHostPromptPrefix(parts[0]) else {
            return nil
        }

        if promptMarkerAttachedUserToken(parts[1]) != nil {
            return PromptLineDetails(
                command: normalizedPromptCommand(commandText(in: parts, startingAt: 2))
            )
        }

        guard parts.count >= 3,
              isPromptUserToken(parts[1]),
              parts[2] == "$" else {
            return nil
        }

        return PromptLineDetails(
            command: normalizedPromptCommand(commandText(in: parts, startingAt: 3))
        )
    }

    private static func normalizedPromptCommand(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func normalizedPromptPathCandidate(_ token: String) -> String? {
        var candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else { return nil }

        while let firstScalar = candidate.unicodeScalars.first,
              promptPathWrapperCharacters.contains(firstScalar) {
            candidate.removeFirst()
        }
        while let lastScalar = candidate.unicodeScalars.last,
              promptPathWrapperCharacters.contains(lastScalar)
                || promptPathTrailingPunctuationCharacters.contains(lastScalar) {
            candidate.removeLast()
        }
        guard candidate.isEmpty == false else { return nil }

        if candidate.hasPrefix("/") || candidate.hasPrefix("~") || candidate.hasPrefix("file://") {
            return normalizedPromptPathToken(candidate)
        }
        if let colonIndex = candidate.lastIndex(of: ":") {
            let suffix = String(candidate[candidate.index(after: colonIndex)...])
            if suffix.hasPrefix("/") || suffix.hasPrefix("~") || suffix.hasPrefix("file://") {
                return normalizedPromptPathToken(suffix)
            }
        }

        return nil
    }

    private static func normalizedPromptPathToken(_ token: String) -> String? {
        guard token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("file://") else {
            return nil
        }

        let path: String
        if token.hasPrefix("file://"),
           let url = URL(string: token),
           url.isFileURL {
            path = url.path
        } else {
            path = token
        }

        guard path.isEmpty == false else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func previousLineLooksLikeTwoLinePromptDirectory(_ line: String?) -> Bool {
        guard let line else { return false }
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 1 else {
            return false
        }
        return normalizedPromptPathCandidate(parts[0]) != nil
    }

    private static func looksLikeTwoLineHostPromptPrefix(_ token: String) -> Bool {
        guard token.contains("/") == false else {
            return false
        }

        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return false
        }
        return promptIdentitySegmentIsValid(String(parts[0]))
            && promptIdentitySegmentIsValid(String(parts[1]))
    }

    private static func promptMarkerAttachedUserToken(_ token: String) -> String? {
        guard token.count > 1,
              let trailingCharacter = token.last,
              trailingCharacter == "$" else {
            return nil
        }

        let userToken = String(token.dropLast())
        guard isPromptUserToken(userToken) else {
            return nil
        }
        return userToken
    }

    private static func isPromptUserToken(_ token: String) -> Bool {
        promptIdentitySegmentIsValid(token)
    }

    private static func promptIdentitySegmentIsValid(_ token: String) -> Bool {
        guard token.isEmpty == false,
              token.contains("/") == false else {
            return false
        }

        return token.unicodeScalars.allSatisfy { scalar in
            promptIdentityTokenCharacters.contains(scalar)
        }
    }

    private static func commandText(in parts: [String], startingAt startIndex: Int) -> String? {
        guard startIndex < parts.count else {
            return nil
        }
        return parts[startIndex...].joined(separator: " ")
    }

    private static func collapsedWhitespace(_ line: String) -> String {
        line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Shell-injected launches can prefix the real command with KEY=value pairs.
    // Skip those assignment tokens so prompt classification still sees `codex`
    // / `claude` as the command token.
    private static func leadingCommandToken(in command: String) -> String? {
        command
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first { token in token.contains("=") == false }?
            .lowercased()
    }

    private static func truncatedCommand(_ command: String) -> String {
        String(command.prefix(commandCharacterLimit))
    }

    private struct PromptLineDetails {
        let command: String?
    }

    private enum PromptContext {
        case interactive
        case command(command: String, token: String)
    }

    private struct PromptObservation {
        let context: PromptContext
        let offsetFromBottom: Int
    }

    private static let commandCharacterLimit = 96
    private static let promptScanLineWindow = 16
    private static let recentPromptLineMaxDistanceFromBottom = 5
    private static let loosePromptMarkerScanTokenLimit = 5
    private static let agentLaunchCommandTokens: Set<String> = ["cdx", "codex", "cc", "claude"]
    private static let promptMarkerTokens: Set<String> = ["%", "#", "$", ">"]
    private static let promptPathWrapperCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>")
    private static let promptPathTrailingPunctuationCharacters = CharacterSet(charactersIn: ",;")
    private static let promptIdentityTokenCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))
}
