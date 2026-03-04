import Foundation

protocol SystemScreenshotLocationResolving: Sendable {
    func resolveScreenshotDirectory() -> URL
}

struct SystemScreenshotLocationResolver: SystemScreenshotLocationResolving {
    private static let screenshotDefaultsSuiteName = "com.apple.screencapture"
    private static let screenshotLocationKey = "location"

    func resolveScreenshotDirectory() -> URL {
        if let configuredPath = UserDefaults(suiteName: Self.screenshotDefaultsSuiteName)?
            .string(forKey: Self.screenshotLocationKey),
           let configuredDirectory = Self.normalizedDirectoryURL(from: configuredPath) {
            return configuredDirectory
        }

        return defaultDesktopDirectoryURL()
    }

    private func defaultDesktopDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Desktop", isDirectory: true)
            .standardizedFileURL
    }

    private static func normalizedDirectoryURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return url.standardizedFileURL
        }

        let expandedPath = (trimmed as NSString).expandingTildeInPath
        guard expandedPath.isEmpty == false else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
    }
}
