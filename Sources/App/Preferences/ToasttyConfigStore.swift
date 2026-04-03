import CoreState
import Foundation

struct ToasttyConfig: Equatable {
    var terminalFontSizePoints: Double?
    var defaultTerminalProfileID: String?
    var enableAgentCommandShims = true
    var urlRoutingPreferences = URLRoutingPreferences()
}

enum ToasttyConfigStore {
    private static let terminalFontSizeKey = "terminal-font-size"
    private static let defaultTerminalProfileKey = "default-terminal-profile"
    private static let enableAgentCommandShimsKey = "enable-agent-command-shims"
    private static let urlOpeningDestinationKey = "url-opening-destination"
    private static let urlOpeningBrowserPlacementKey = "url-opening-browser-placement"
    private static let configDirectoryName = ".toastty"
    private static let legacyConfigDirectoryName = ".config/toastty"
    private static let configFileName = "config"
    private static let configReferenceFileName = "config-reference"

    static func load(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ToasttyConfig {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        let primaryURL = configFileURL(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        if let contents = try? String(contentsOf: primaryURL, encoding: .utf8) {
            return parse(contents: contents)
        }

        guard runtimePaths.isRuntimeHomeEnabled == false else {
            return ToasttyConfig()
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
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        let configURL = configFileURL(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        let legacyURL = legacyConfigFileURL(homeDirectoryPath: homeDirectoryPath)
        guard fileManager.fileExists(atPath: configURL.path) == false else {
            return
        }
        guard runtimePaths.isRuntimeHomeEnabled || fileManager.fileExists(atPath: legacyURL.path) == false else {
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

    /// Writes (or overwrites) the reference config file with the full commented
    /// template so users can see every supported option. Called on every launch.
    static func writeConfigReference(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let referenceURL = configReferenceFileURL(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        try fileManager.createDirectory(
            at: referenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = Data(render(config: ToasttyConfig()).utf8)
        try contents.write(to: referenceURL)
    }

    static func configReferenceFileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        return runtimePaths.configDirectoryURL
            .appending(path: configReferenceFileName, directoryHint: .notDirectory)
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

            case enableAgentCommandShimsKey:
                guard let parsed = parseBool(value) else { continue }
                config.enableAgentCommandShims = parsed

            case urlOpeningDestinationKey:
                guard let parsedValue = parseString(value),
                      let parsed = URLOpenDestination(rawValue: parsedValue) else { continue }
                config.urlRoutingPreferences.destination = parsed

            case urlOpeningBrowserPlacementKey:
                guard let parsedValue = parseString(value),
                      let parsed = URLBrowserOpenPlacement(rawValue: parsedValue) else { continue }
                config.urlRoutingPreferences.browserPlacement = parsed

            default:
                continue
            }
        }

        return config
    }

    private static func render(config: ToasttyConfig) -> String {
        var lines: [String] = [
            "# Toastty config",
            "",
            "# terminal-font-size sets the default font size baseline for Toastty.",
            "# Window-local UI font adjustments are persisted with each window layout",
            "# until you choose Reset Terminal Font for that window.",
            "# terminal-font-size = 13",
            "",
            "# default-terminal-profile uses a profile ID from",
            "# terminal-profiles.toml for new terminals only,",
            "# including ordinary split shortcuts like Cmd+D and Cmd+Shift+D.",
            "# Existing terminals keep their current profiles.",
            "# default-terminal-profile = \"zmx\"",
            "",
            "# enable-agent-command-shims controls whether Toastty prepends",
            "# managed codex/claude wrappers into terminal PATH so manual",
            "# invocations report session status automatically.",
            "# Set this to false if you do not want Toastty intercepting",
            "# those commands in Toastty terminals.",
            "# enable-agent-command-shims = false",
            "",
            "# url-opening-destination controls where Toastty opens app-owned",
            "# web URLs such as Toastty Help links.",
            "# Supported values: toastty-browser, system-browser.",
            "# The default is toastty-browser.",
            "# url-opening-destination = toastty-browser",
            "",
            "# url-opening-browser-placement controls how Toastty places those",
            "# internally opened browser panels.",
            "# Supported values: rootRight, newTab.",
            "# The default is newTab.",
            "# url-opening-browser-placement = newTab",
        ]

        if config.terminalFontSizePoints != nil
            || config.defaultTerminalProfileID != nil
            || config.enableAgentCommandShims == false
            || config.urlRoutingPreferences != URLRoutingPreferences() {
            lines.append("")
        }

        if let defaultTerminalProfileID = config.defaultTerminalProfileID {
            lines.append("\(defaultTerminalProfileKey) = \(encodeString(defaultTerminalProfileID))")
        }

        if let points = config.terminalFontSizePoints {
            lines.append("\(terminalFontSizeKey) = \(format(points: points))")
        }

        if config.enableAgentCommandShims == false {
            lines.append("\(enableAgentCommandShimsKey) = false")
        }

        if config.urlRoutingPreferences.destination != .toasttyBrowser {
            lines.append(
                "\(urlOpeningDestinationKey) = \(config.urlRoutingPreferences.destination.rawValue)"
            )
        }

        if config.urlRoutingPreferences.browserPlacement != .newTab {
            lines.append(
                "\(urlOpeningBrowserPlacementKey) = \(config.urlRoutingPreferences.browserPlacement.rawValue)"
            )
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

    private static func parseBool<S: StringProtocol>(_ rawValue: S) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
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

    static func configFileURL(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        ).configFileURL
    }

    private static func legacyConfigFileURL(homeDirectoryPath: String = NSHomeDirectory()) -> URL {
        URL(filePath: homeDirectoryPath)
            .appending(path: legacyConfigDirectoryName, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }
}
