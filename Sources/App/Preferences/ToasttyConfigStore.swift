import CoreState
import Foundation

struct ToasttyConfig: Equatable {
    var terminalFontSizePoints: Double?
    var defaultTerminalProfileID: String?
}

enum ToasttyConfigStore {
    private static let terminalFontSizeKey = "terminal-font-size"
    private static let defaultTerminalProfileKey = "default-terminal-profile"
    private static let configDirectoryName = ".toastty"
    private static let legacyConfigDirectoryName = ".config/toastty"
    private static let configFileName = "config"

    static func load(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> ToasttyConfig {
        let primaryURL = configFileURL(homeDirectoryPath: homeDirectoryPath)
        if let contents = try? String(contentsOf: primaryURL, encoding: .utf8) {
            return parse(contents: contents)
        }

        let legacyURL = legacyConfigFileURL(homeDirectoryPath: homeDirectoryPath)
        guard let contents = try? String(contentsOf: legacyURL, encoding: .utf8) else {
            return ToasttyConfig()
        }

        migrateLegacyConfigIfNeeded(
            legacyURL: legacyURL,
            destinationURL: primaryURL,
            fileManager: fileManager
        )
        return parse(contents: contents)
    }

    static func ensureTemplateExists(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory()
    ) throws {
        let configURL = configFileURL(homeDirectoryPath: homeDirectoryPath)
        let legacyURL = legacyConfigFileURL(homeDirectoryPath: homeDirectoryPath)
        guard fileManager.fileExists(atPath: configURL.path) == false,
              fileManager.fileExists(atPath: legacyURL.path) == false else {
            return
        }

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = Data(render(config: ToasttyConfig()).utf8)
        do {
            try contents.write(to: configURL, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        }
    }

    private static func parse(contents: String) -> ToasttyConfig {
        var config = ToasttyConfig()

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = stripComment(from: String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }

            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case terminalFontSizeKey:
                guard let parsed = Double(value) else { continue }
                config.terminalFontSizePoints = AppState.clampedTerminalFontPoints(parsed)

            case defaultTerminalProfileKey:
                guard let parsed = parseString(value) else { continue }
                config.defaultTerminalProfileID = AppState.normalizedTerminalProfileID(parsed)

            default:
                continue
            }
        }

        return config
    }

    private static func render(config: ToasttyConfig) -> String {
        var lines: [String] = [
            "# Toastty config",
            "# terminal-font-size sets the default font size baseline for Toastty.",
            "# UI font adjustments are persisted separately and override this value",
            "# until you choose Reset Terminal Font.",
            "# Set default-terminal-profile to a profile ID from",
            "# ~/.toastty/terminal-profiles.toml to use that profile for new terminals,",
            "# including ordinary split shortcuts like Cmd+D and Cmd+Shift+D.",
            "# Existing terminals keep their current profiles.",
            "# Example:",
            "# terminal-font-size = 13",
            "# default-terminal-profile = \"zmx\"",
        ]

        if config.terminalFontSizePoints != nil || config.defaultTerminalProfileID != nil {
            lines.append("")
        }

        if let defaultTerminalProfileID = config.defaultTerminalProfileID {
            lines.append("\(defaultTerminalProfileKey) = \(encodeString(defaultTerminalProfileID))")
        }

        if let points = config.terminalFontSizePoints {
            lines.append("\(terminalFontSizeKey) = \(format(points: points))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseString<S: StringProtocol>(_ rawValue: S) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return try? JSONDecoder().decode(String.self, from: Data(trimmed.utf8))
        }

        return trimmed
    }

    private static func encodeString(_ value: String) -> String {
        guard let encodedData = try? JSONEncoder().encode(value),
              let encoded = String(data: encodedData, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return encoded
    }

    private static func format(points: Double) -> String {
        if abs(points.rounded() - points) < AppState.terminalFontComparisonEpsilon {
            return String(Int(points.rounded()))
        }
        return String(format: "%.2f", points)
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

    private static func migrateLegacyConfigIfNeeded(
        legacyURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: destinationURL.path) == false else { return }
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.moveItem(at: legacyURL, to: destinationURL)
            } catch {
                try fileManager.copyItem(at: legacyURL, to: destinationURL)
                removeConfigFileIfPresent(at: legacyURL, fileManager: fileManager)
            }
            ToasttyLog.info(
                "Migrated Toastty config to ~/.toastty",
                category: .bootstrap,
                metadata: [
                    "path": destinationURL.path,
                    "legacy_path": legacyURL.path,
                ]
            )
        } catch {
            ToasttyLog.warning(
                "Failed to migrate legacy Toastty config",
                category: .bootstrap,
                metadata: [
                    "path": destinationURL.path,
                    "legacy_path": legacyURL.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private static func removeConfigFileIfPresent(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            ToasttyLog.warning(
                "Failed to remove Toastty config file",
                category: .bootstrap,
                metadata: [
                    "path": url.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    static func configFileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: configDirectoryName, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }

    private static func legacyConfigFileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: legacyConfigDirectoryName, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }
}
