import Foundation

// Shared source of truth for local-document format detection and supported
// picker/command-entry extensions.
public enum LocalDocumentClassifier {
    // Keep grouped text/code families intentionally small. Some extensions like
    // `.jsonc` and `.properties` still share a broad viewer family even when we
    // do not offer specialized syntax highlighting for them yet.
    public static let filenameExtensionToFormat: [String: LocalDocumentFormat] = [
        "md": .markdown,
        "markdown": .markdown,
        "mdown": .markdown,
        "mkd": .markdown,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "json": .json,
        "jsonc": .json,
        "jsonl": .jsonl,
        "ini": .config,
        "conf": .config,
        "cfg": .config,
        "properties": .config,
        "csv": .csv,
        "tsv": .tsv,
        "xml": .xml,
        "sh": .shell,
        "bash": .shell,
        "zsh": .shell,
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

        let fileURL = URL(fileURLWithPath: normalizedFilePath)
        if let directFormat = format(forPathExtension: fileURL.pathExtension) {
            return directFormat
        }

        return formatForColonSuffixedFileName(fileURL.lastPathComponent)
    }

    private static func formatForColonSuffixedFileName(_ fileName: String) -> LocalDocumentFormat? {
        var candidateFileName = fileName
        while let separatorIndex = candidateFileName.lastIndex(of: ":") {
            candidateFileName.removeSubrange(separatorIndex...)
            if let format = format(
                forPathExtension: URL(fileURLWithPath: candidateFileName).pathExtension
            ) {
                return format
            }
        }

        return nil
    }
}
