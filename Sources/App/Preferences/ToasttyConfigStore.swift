import CoreState
import Foundation

struct ToasttyConfig: Equatable {
    var terminalFontSizePoints: Double?
}

enum ToasttyConfigStore {
    private static let terminalFontSizeKey = "terminal-font-size"
    private static let configDirectoryName = ".config/toastty"
    private static let configFileName = "config"

    static func load() -> ToasttyConfig {
        guard let contents = try? String(contentsOf: configFileURL(), encoding: .utf8) else {
            return ToasttyConfig(terminalFontSizePoints: nil)
        }
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
        let url = configFileURL()
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
}
