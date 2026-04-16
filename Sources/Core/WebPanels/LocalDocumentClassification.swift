import Foundation

// Shared source of truth for local-document format detection and supported
// picker/command-entry extensions.
public enum LocalDocumentClassifier {
    public static let filenameExtensionToFormat: [String: LocalDocumentFormat] = [
        "md": .markdown,
        "markdown": .markdown,
        "mdown": .markdown,
        "mkd": .markdown,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
    ]

    public static let supportedFilenameExtensions: [String] = filenameExtensionToFormat.keys.sorted()

    public static func format(forPathExtension pathExtension: String) -> LocalDocumentFormat? {
        let normalizedExtension = pathExtension.lowercased()
        guard normalizedExtension.isEmpty == false else {
            return nil
        }

        return filenameExtensionToFormat[normalizedExtension]
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
