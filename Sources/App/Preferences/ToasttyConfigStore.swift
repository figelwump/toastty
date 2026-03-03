import CoreState
import Foundation

struct ToasttyConfig: Equatable {
    var terminalFontSizePoints: Double?
}

enum ToasttyConfigStore {
    private static let terminalFontSizeKey = "terminal-font-size"
    private static let configDirectoryName = ".toastty"
    private static let legacyConfigDirectoryName = ".config/toastty"
    private static let configFileName = "config"

    static func load() -> ToasttyConfig {
        let primaryURL = configFileURL()
        if let contents = try? String(contentsOf: primaryURL, encoding: .utf8) {
            return parse(contents: contents)
        }

        let legacyURL = legacyConfigFileURL()
        guard let contents = try? String(contentsOf: legacyURL, encoding: .utf8) else {
            return ToasttyConfig(terminalFontSizePoints: nil)
        }

        migrateLegacyConfigIfNeeded(legacyURL: legacyURL, destinationURL: primaryURL)
        return parse(contents: contents)
    }

    static func persistTerminalFontSizePoints(_ points: Double?) {
        let clampedPoints = points.map(AppState.clampedTerminalFontPoints)
        if clampedPoints == nil {
            removeConfigFileIfPresent()
            return
        }

        do {
            let configURL = configFileURL()
            let directoryURL = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let rendered = render(config: ToasttyConfig(terminalFontSizePoints: clampedPoints))
            try rendered.write(to: configURL, atomically: true, encoding: .utf8)
            removeConfigFileIfPresent(at: legacyConfigFileURL())
        } catch {
            ToasttyLog.warning(
                "Failed to persist Toastty config",
                category: .bootstrap,
                metadata: [
                    "path": configFileURL().path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private static func parse(contents: String) -> ToasttyConfig {
        var terminalFontSizePoints: Double?

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }

            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == terminalFontSizeKey else { continue }
            guard let parsed = Double(value) else { continue }
            terminalFontSizePoints = AppState.clampedTerminalFontPoints(parsed)
        }

        return ToasttyConfig(terminalFontSizePoints: terminalFontSizePoints)
    }

    private static func render(config: ToasttyConfig) -> String {
        var lines: [String] = [
            "# Toastty config",
            "# Remove this key to follow Ghostty font-size again.",
        ]

        if let points = config.terminalFontSizePoints {
            lines.append("\(terminalFontSizeKey) = \(format(points: points))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(points: Double) -> String {
        if abs(points.rounded() - points) < AppState.terminalFontComparisonEpsilon {
            return String(Int(points.rounded()))
        }
        return String(format: "%.2f", points)
    }

    private static func removeConfigFileIfPresent() {
        removeConfigFileIfPresent(at: configFileURL())
        removeConfigFileIfPresent(at: legacyConfigFileURL())
    }

    private static func migrateLegacyConfigIfNeeded(legacyURL: URL, destinationURL: URL) {
        guard FileManager.default.fileExists(atPath: destinationURL.path) == false else { return }
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try FileManager.default.moveItem(at: legacyURL, to: destinationURL)
            } catch {
                try FileManager.default.copyItem(at: legacyURL, to: destinationURL)
                removeConfigFileIfPresent(at: legacyURL)
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

    private static func removeConfigFileIfPresent(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
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

    private static func configFileURL() -> URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: configDirectoryName, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }

    private static func legacyConfigFileURL() -> URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: legacyConfigDirectoryName, directoryHint: .isDirectory)
            .appending(path: configFileName, directoryHint: .notDirectory)
    }
}
