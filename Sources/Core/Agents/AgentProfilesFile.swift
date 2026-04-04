import Foundation

public struct AgentProfilesParseError: LocalizedError, Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var errorDescription: String? {
        "agents.toml line \(line): \(message)"
    }
}

public enum AgentProfilesFile {
    private static let configDirectoryName = ".toastty"
    private static let fileName = "agents.toml"

    public static func fileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: configDirectoryName, directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    public static func ensureTemplateExists(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory()
    ) throws {
        let url = fileURL(homeDirectoryPath: homeDirectoryPath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = Data(templateContents().utf8)
        do {
            try contents.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        }
    }

    public static func load(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory()
    ) throws -> AgentCatalog {
        let url = fileURL(homeDirectoryPath: homeDirectoryPath)
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return try AgentProfilesParser.parse(contents: contents)
    }

    public static func templateContents() -> String {
        """
        # Toastty agent launch profiles
        #
        # Point your agent to these instructions to set up your agents.toml file:
        # https://github.com/figelwump/toastty/blob/main/docs/running-agents.md
        #
        # Uncomment and edit profiles below to make them available in Toastty UI.
        # After saving, use Toastty > Reload Configuration to pick up new
        # buttons and shortcuts without relaunching.
        #
        # Fields:
        #   displayName  — shown in menus and toolbar buttons.
        #   argv         — the exact command Toastty runs for that profile.
        #   manualCommandNames — (optional) extra executable basenames Toastty
        #                        should shim for typed launches of built-in
        #                        Codex/Claude wrappers. Use basenames only,
        #                        with no paths or spaces.
        #   shortcutKey  — (optional) single letter or digit; registers ⌘⌥<key>.
        #
        # Edit these examples to match your local setup.
        #
        # [codex]
        # displayName = "Codex"
        # argv = ["codex"]
        # manualCommandNames = ["agent-safehouse"]
        # shortcutKey = "c"
        #
        # [claude]
        # displayName = "Claude Code"
        # argv = ["claude"]
        # manualCommandNames = ["run-sandboxed.sh"]
        """
            + "\n"
    }
}

private enum AgentProfilesParser {
    private struct PartialProfile {
        var line: Int
        var displayName: String?
        var argv: [String]?
        var manualCommandNames: [String]?
        var shortcutKey: String?
    }

    static func parse(contents: String) throws -> AgentCatalog {
        let lines = contents.components(separatedBy: .newlines)
        var profiles: [AgentProfile] = []
        var currentID: String?
        var currentProfile: PartialProfile?
        var seenProfileIDs = Set<String>()
        var seenShortcutKeys = [Character: String]()

        func finalizeCurrentProfile() throws {
            guard let currentID, let currentProfile else { return }
            guard let displayName = normalizedNonEmpty(currentProfile.displayName) else {
                throw AgentProfilesParseError(
                    line: currentProfile.line,
                    message: "[\(currentID)] is missing displayName"
                )
            }
            guard let argv = currentProfile.argv, argv.isEmpty == false else {
                throw AgentProfilesParseError(
                    line: currentProfile.line,
                    message: "[\(currentID)] is missing argv"
                )
            }
            let manualCommandNames = try validateManualCommandNames(
                currentProfile.manualCommandNames ?? [],
                line: currentProfile.line,
                profileID: currentID
            )
            let shortcutKey: Character? = if let raw = normalizedNonEmpty(currentProfile.shortcutKey) {
                try validateShortcutKey(raw, line: currentProfile.line, profileID: currentID, seen: &seenShortcutKeys)
            } else {
                nil
            }
            profiles.append(
                AgentProfile(
                    id: currentID,
                    displayName: displayName,
                    argv: argv,
                    manualCommandNames: manualCommandNames,
                    shortcutKey: shortcutKey
                )
            )
        }

        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let strippedLine = stripComment(from: rawLine)
            let trimmedLine = strippedLine.trimmingCharacters(in: .whitespacesAndNewlines)

            defer { lineIndex += 1 }

            guard trimmedLine.isEmpty == false else { continue }

            if trimmedLine.hasPrefix("[") {
                guard trimmedLine.hasSuffix("]") else {
                    throw AgentProfilesParseError(line: lineIndex + 1, message: "invalid table header")
                }

                try finalizeCurrentProfile()

                let header = String(trimmedLine.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let agent = AgentKind(rawValue: header) else {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "invalid agent ID '\(header)'"
                    )
                }
                guard seenProfileIDs.insert(agent.rawValue).inserted else {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "duplicate profile '\(agent.rawValue)'"
                    )
                }

                currentID = agent.rawValue
                currentProfile = PartialProfile(line: lineIndex + 1)
                continue
            }

            guard let currentID else {
                throw AgentProfilesParseError(
                    line: lineIndex + 1,
                    message: "expected [profile-id] table before profile fields"
                )
            }
            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                throw AgentProfilesParseError(line: lineIndex + 1, message: "expected key = value")
            }

            let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            var rawValue = String(
                trimmedLine[trimmedLine.index(after: equalsIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )

            if key == "argv" || key == "manualCommandNames" {
                while collectionBalance(in: rawValue) > 0 {
                    lineIndex += 1
                    guard lineIndex < lines.count else {
                        throw AgentProfilesParseError(
                            line: lineIndex,
                            message: "unterminated \(key) array"
                        )
                    }
                    let continuation = stripComment(from: lines[lineIndex])
                    rawValue.append("\n")
                    rawValue.append(contentsOf: continuation)
                }
            }

            switch key {
            case "displayName":
                guard currentProfile?.displayName == nil else {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has duplicate displayName"
                    )
                }
                do {
                    currentProfile?.displayName = try decodeJSONString(rawValue)
                } catch {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has invalid displayName"
                    )
                }

            case "argv":
                guard currentProfile?.argv == nil else {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has duplicate argv"
                    )
                }
                do {
                    let argv = try decodeJSONArray(rawValue)
                    guard argv.allSatisfy({ normalizedNonEmpty($0) != nil }) else {
                        throw AgentProfilesParseError(
                            line: lineIndex + 1,
                            message: "[\(currentID)] argv entries must be non-empty"
                        )
                    }
                    currentProfile?.argv = argv
                } catch let error as AgentProfilesParseError {
                    throw error
                } catch {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has invalid argv"
                    )
                }

            case "manualCommandNames":
                guard currentProfile?.manualCommandNames == nil else {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has duplicate manualCommandNames"
                    )
                }
                do {
                    currentProfile?.manualCommandNames = try decodeJSONArray(rawValue)
                } catch {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has invalid manualCommandNames"
                    )
                }

            case "shortcutKey":
                guard currentProfile?.shortcutKey == nil else {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has duplicate shortcutKey"
                    )
                }
                do {
                    currentProfile?.shortcutKey = try decodeJSONString(rawValue)
                } catch {
                    throw AgentProfilesParseError(
                        line: lineIndex + 1,
                        message: "[\(currentID)] has invalid shortcutKey"
                    )
                }

            default:
                throw AgentProfilesParseError(
                    line: lineIndex + 1,
                    message: "[\(currentID)] contains unknown key '\(key)'"
                )
            }
        }

        try finalizeCurrentProfile()
        return AgentCatalog(profiles: profiles)
    }

    private static func decodeJSONString(_ value: String) throws -> String {
        try JSONDecoder().decode(String.self, from: Data(value.utf8))
    }

    private static func decodeJSONArray(_ value: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }

    private static func stripComment(from line: String) -> String {
        var result = ""
        var isInsideString = false
        var isEscaping = false

        for character in line {
            if isEscaping {
                result.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                result.append(character)
                if isInsideString {
                    isEscaping = true
                }
                continue
            }

            if character == "\"" {
                result.append(character)
                isInsideString.toggle()
                continue
            }

            if character == "#" && isInsideString == false {
                break
            }

            result.append(character)
        }

        return result
    }

    private static func collectionBalance(in value: String) -> Int {
        var balance = 0
        var isInsideString = false
        var isEscaping = false

        for character in value {
            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" && isInsideString {
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            guard isInsideString == false else { continue }
            if character == "[" {
                balance += 1
            } else if character == "]" {
                balance -= 1
            }
        }

        return balance
    }

    private static func validateShortcutKey(
        _ raw: String,
        line: Int,
        profileID: String,
        seen: inout [Character: String]
    ) throws -> Character {
        let lowered = raw.lowercased()
        guard lowered.count == 1, let char = lowered.first,
              char.isASCII && (char.isLetter || char.isNumber) else {
            throw AgentProfilesParseError(
                line: line,
                message: "[\(profileID)] shortcutKey must be a single letter or digit"
            )
        }
        if let existingID = seen[char] {
            throw AgentProfilesParseError(
                line: line,
                message: "[\(profileID)] shortcutKey '\(char)' is already used by [\(existingID)]"
            )
        }
        seen[char] = profileID
        return char
    }

    private static func validateManualCommandNames(
        _ rawNames: [String],
        line: Int,
        profileID: String
    ) throws -> [String] {
        guard profileID == AgentKind.codex.rawValue || profileID == AgentKind.claude.rawValue else {
            guard rawNames.isEmpty else {
                throw AgentProfilesParseError(
                    line: line,
                    message: "[\(profileID)] manualCommandNames is supported only for [codex] and [claude]"
                )
            }
            return []
        }

        var validatedNames: [String] = []
        var seenNames = Set<String>()

        for rawName in rawNames {
            guard let trimmedName = normalizedNonEmpty(rawName) else {
                throw AgentProfilesParseError(
                    line: line,
                    message: "[\(profileID)] manualCommandNames entries must be non-empty"
                )
            }
            guard trimmedName.contains("/") == false, trimmedName.contains("\\") == false else {
                throw AgentProfilesParseError(
                    line: line,
                    message: "[\(profileID)] manualCommandNames entries must be executable basenames, not paths"
                )
            }
            guard trimmedName.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw AgentProfilesParseError(
                    line: line,
                    message: "[\(profileID)] manualCommandNames entries must not contain whitespace"
                )
            }
            let normalizedName = trimmedName.lowercased()
            guard normalizedName != AgentKind.codex.rawValue,
                  normalizedName != AgentKind.claude.rawValue else {
                throw AgentProfilesParseError(
                    line: line,
                    message: "[\(profileID)] manualCommandNames must not include built-in agent commands"
                )
            }

            let duplicateKey = normalizedName
            guard seenNames.insert(duplicateKey).inserted else {
                throw AgentProfilesParseError(
                    line: line,
                    message: "[\(profileID)] manualCommandNames contains duplicate entry '\(trimmedName)'"
                )
            }

            validatedNames.append(trimmedName)
        }

        return validatedNames
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
