import Foundation

// Shared source of truth for local-document formats admitted by current entry
// points. YAML and TOML stay excluded until code-mode rendering exists.
public enum LocalDocumentClassifier {
    public static let markdownFilenameExtensions: [String] = [
        "md",
        "markdown",
        "mdown",
        "mkd",
    ]

    public static func format(forPathExtension pathExtension: String) -> LocalDocumentFormat? {
        let normalizedExtension = pathExtension.lowercased()
        guard normalizedExtension.isEmpty == false else {
            return nil
        }

        return markdownFilenameExtensions.contains(normalizedExtension) ? .markdown : nil
    }

    public static func format(forFilePath filePath: String) -> LocalDocumentFormat? {
        guard let normalizedFilePath = WebPanelState.normalizedFilePath(filePath) else {
            return nil
        }

        return format(
            forPathExtension: URL(fileURLWithPath: normalizedFilePath).pathExtension
        )
    }
}
