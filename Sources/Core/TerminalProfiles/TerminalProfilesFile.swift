import Foundation

public struct TerminalProfilesParseError: LocalizedError, Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var errorDescription: String? {
        "terminal-profiles.toml line \(line): \(message)"
    }
}

public enum TerminalProfilesFile {
    private static let configDirectoryName = ".toastty"
    private static let fileName = "terminal-profiles.toml"
    public static let environmentOverrideKey = "TOASTTY_TERMINAL_PROFILES_PATH"

    public static func fileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let overrideURL = overrideFileURL(environment: environment) {
            return overrideURL
        }
        return defaultFileURL(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
    }

    private static func defaultFileURL(
        homeDirectoryPath: String,
        environment: [String: String]
    ) -> URL {
        ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        ).terminalProfilesFileURL
    }

    private static func overrideFileURL(environment: [String: String]) -> URL? {
        guard let rawOverridePath = environment[environmentOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawOverridePath.isEmpty == false else {
            return nil
        }

        let expandedPath = (rawOverridePath as NSString).expandingTildeInPath
        return URL(filePath: expandedPath)
    }

    public static func ensureTemplateExists(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        // External override paths are intended for tests/automation; don't
        // silently create files outside the standard Toastty config location.
        if overrideFileURL(environment: environment) != nil {
            return
        }
        let url = fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
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
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TerminalProfileCatalog {
        let url = fileURL(homeDirectoryPath: homeDirectoryPath, environment: environment)
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return try TerminalProfilesParser.parse(contents: contents)
    }

    public static func templateContents() -> String {
        """
        # Toastty terminal profiles
        #
        # Uncomment and edit profiles below to make them available in Toastty menus.
        # `displayName` is shown in the menu.
        # `badge` is shown as a pill in the terminal panel header. If omitted,
        # Toastty uses `displayName`.
        # `startupCommand` is sent to the pane's login shell when the pane is
        # created or restored.
        # `shortcutKey` (optional) is a single letter or digit that registers
        # ⌘⌥<key> to split right and ⌘⌥⇧<key> to split down with this profile.
        #
        # Toastty sets these environment variables for profiled panes:
        # - TOASTTY_PANEL_ID
        # - TOASTTY_TERMINAL_PROFILE_ID
        # - TOASTTY_LAUNCH_REASON   ("create" or "restore")
        #
        # For multiplexers like zmx/tmux, install Toastty shell integration so
        # the shell inside the session keeps emitting live pane titles and
        # restored zsh/bash panes can reuse pane-local command history.
        # Use Toastty > Install Shell Integration… or see the README.
        #
        # Example: bind each Toastty pane to its own persistent zmx session.
        #
        # [zmx]
        # displayName = "ZMX"
        # badge = "ZMX"
        # startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"
        # shortcutKey = "z"
        """
            + "\n"
    }
}

private enum TerminalProfilesParser {
    private struct PartialProfile {
        var line: Int
        var displayName: String?
        var badge: String?
        var startupCommand: String?
        var shortcutKey: String?
    }

    static func parse(contents: String) throws -> TerminalProfileCatalog {
        let lines = contents.components(separatedBy: .newlines)
        var profiles: [TerminalProfile] = []
        var currentID: String?
        var currentProfile: PartialProfile?
        var seenProfileIDs = Set<String>()
        var seenShortcutKeys = [Character: String]()

        func finalizeCurrentProfile() throws {
            guard let currentID, let currentProfile else { return }
            guard let displayName = normalizedNonEmpty(currentProfile.displayName) else {
                throw TerminalProfilesParseError(
                    line: currentProfile.line,
                    message: "[\(currentID)] is missing displayName"
                )
            }
            guard let startupCommand = normalizedNonEmpty(currentProfile.startupCommand) else {
                throw TerminalProfilesParseError(
                    line: currentProfile.line,
                    message: "[\(currentID)] is missing startupCommand"
                )
            }
            let badgeLabel = normalizedNonEmpty(currentProfile.badge) ?? displayName
            let shortcutKey: Character? = if let raw = normalizedNonEmpty(currentProfile.shortcutKey) {
                try validateShortcutKey(raw, line: currentProfile.line, profileID: currentID, seen: &seenShortcutKeys)
            } else {
                nil
            }
            profiles.append(
                TerminalProfile(
                    id: currentID,
                    displayName: displayName,
                    badgeLabel: badgeLabel,
                    startupCommand: startupCommand,
                    shortcutKey: shortcutKey
                )
            )
        }

        for (index, rawLine) in lines.enumerated() {
            let strippedLine = stripComment(from: rawLine)
            let trimmedLine = strippedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { continue }

            if trimmedLine.hasPrefix("[") {
                guard trimmedLine.hasSuffix("]") else {
                    throw TerminalProfilesParseError(line: index + 1, message: "invalid table header")
                }

                try finalizeCurrentProfile()

                let rawID = String(trimmedLine.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let profileID = validateProfileID(rawID) else {
                    throw TerminalProfilesParseError(
                        line: index + 1,
                        message: "invalid profile ID '\(rawID)'"
                    )
                }
                guard seenProfileIDs.insert(profileID).inserted else {
                    throw TerminalProfilesParseError(
                        line: index + 1,
                        message: "duplicate profile '\(profileID)'"
                    )
                }

                currentID = profileID
                currentProfile = PartialProfile(line: index + 1)
                continue
            }

            guard let currentID else {
                throw TerminalProfilesParseError(
                    line: index + 1,
                    message: "expected [profile-id] table before profile fields"
                )
            }
            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
                throw TerminalProfilesParseError(line: index + 1, message: "expected key = value")
            }

            let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(
                trimmedLine[trimmedLine.index(after: equalsIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )

            switch key {
            case "displayName":
                guard currentProfile?.displayName == nil else {
                    throw TerminalProfilesParseError(
                        line: index + 1,
                        message: "[\(currentID)] has duplicate displayName"
                    )
                }
                currentProfile?.displayName = try decodeString(rawValue, line: index + 1, profileID: currentID, key: key)

            case "badge":
                guard currentProfile?.badge == nil else {
                    throw TerminalProfilesParseError(
                        line: index + 1,
                        message: "[\(currentID)] has duplicate badge"
                    )
                }
                currentProfile?.badge = try decodeString(rawValue, line: index + 1, profileID: currentID, key: key)

            case "startupCommand":
                guard currentProfile?.startupCommand == nil else {
                    throw TerminalProfilesParseError(
                        line: index + 1,
                        message: "[\(currentID)] has duplicate startupCommand"
                    )
                }
                currentProfile?.startupCommand = try decodeString(rawValue, line: index + 1, profileID: currentID, key: key)

            case "shortcutKey":
                guard currentProfile?.shortcutKey == nil else {
                    throw TerminalProfilesParseError(
                        line: index + 1,
                        message: "[\(currentID)] has duplicate shortcutKey"
                    )
                }
                currentProfile?.shortcutKey = try decodeString(rawValue, line: index + 1, profileID: currentID, key: key)

            default:
                throw TerminalProfilesParseError(
                    line: index + 1,
                    message: "[\(currentID)] contains unknown key '\(key)'"
                )
            }
        }

        try finalizeCurrentProfile()
        return TerminalProfileCatalog(profiles: profiles)
    }

    private static func decodeString(
        _ value: String,
        line: Int,
        profileID: String,
        key: String
    ) throws -> String {
        do {
            return try JSONDecoder().decode(String.self, from: Data(value.utf8))
        } catch {
            throw TerminalProfilesParseError(
                line: line,
                message: "[\(profileID)] has invalid \(key)"
            )
        }
    }

    private static func validateProfileID(_ rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard trimmed.hasPrefix("-") == false else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
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
            throw TerminalProfilesParseError(
                line: line,
                message: "[\(profileID)] shortcutKey must be a single letter or digit"
            )
        }
        if let existingID = seen[char] {
            throw TerminalProfilesParseError(
                line: line,
                message: "[\(profileID)] shortcutKey '\(char)' is already used by [\(existingID)]"
            )
        }
        seen[char] = profileID
        return char
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
                isInsideString.toggle()
                result.append(character)
                continue
            }

            if character == "#" && !isInsideString {
                break
            }

            result.append(character)
        }

        return result
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}
