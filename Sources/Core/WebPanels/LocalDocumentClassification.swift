import Foundation

public enum LocalDocumentSyntaxLanguage: String, Codable, Equatable, Sendable {
    case yaml
    case toml
    case json
    case xml
    case bash
    case swift
    case javascript
    case typescript
    case python
    case go
    case rust
}

public struct LocalDocumentClassification: Equatable, Sendable {
    public let format: LocalDocumentFormat
    public let syntaxLanguage: LocalDocumentSyntaxLanguage?
    public let formatLabel: String

    public init(
        format: LocalDocumentFormat,
        syntaxLanguage: LocalDocumentSyntaxLanguage?,
        formatLabel: String
    ) {
        self.format = format
        self.syntaxLanguage = syntaxLanguage
        self.formatLabel = formatLabel
    }
}

// Shared source of truth for local-document format detection and supported
// picker/command-entry extensions.
public enum LocalDocumentClassifier {
    // Keep grouped text/code families intentionally small. Some extensions like
    // `.jsonc` and `.properties` still share a broad viewer family even when we
    // do not offer specialized syntax highlighting for them yet.
    private static let exactFileNameToClassification: [String: LocalDocumentClassification] = [
        ".gitignore": .init(format: .config, syntaxLanguage: nil, formatLabel: "Git Ignore"),
    ]

    private static let filenameExtensionToClassification: [String: LocalDocumentClassification] = [
        "md": .init(format: .markdown, syntaxLanguage: nil, formatLabel: "Markdown"),
        "markdown": .init(format: .markdown, syntaxLanguage: nil, formatLabel: "Markdown"),
        "mdown": .init(format: .markdown, syntaxLanguage: nil, formatLabel: "Markdown"),
        "mkd": .init(format: .markdown, syntaxLanguage: nil, formatLabel: "Markdown"),
        "yaml": .init(format: .yaml, syntaxLanguage: .yaml, formatLabel: "YAML"),
        "yml": .init(format: .yaml, syntaxLanguage: .yaml, formatLabel: "YAML"),
        "toml": .init(format: .toml, syntaxLanguage: .toml, formatLabel: "TOML"),
        "json": .init(format: .json, syntaxLanguage: .json, formatLabel: "JSON"),
        "jsonc": .init(format: .json, syntaxLanguage: nil, formatLabel: "JSONC"),
        "jsonl": .init(format: .jsonl, syntaxLanguage: .json, formatLabel: "JSON Lines"),
        "ini": .init(format: .config, syntaxLanguage: nil, formatLabel: "Config"),
        "conf": .init(format: .config, syntaxLanguage: nil, formatLabel: "Config"),
        "cfg": .init(format: .config, syntaxLanguage: nil, formatLabel: "Config"),
        "properties": .init(format: .config, syntaxLanguage: nil, formatLabel: "Config"),
        "csv": .init(format: .csv, syntaxLanguage: nil, formatLabel: "CSV"),
        "tsv": .init(format: .tsv, syntaxLanguage: nil, formatLabel: "TSV"),
        "xml": .init(format: .xml, syntaxLanguage: .xml, formatLabel: "XML"),
        "sh": .init(format: .shell, syntaxLanguage: .bash, formatLabel: "Shell Script"),
        "bash": .init(format: .shell, syntaxLanguage: .bash, formatLabel: "Shell Script"),
        "zsh": .init(format: .shell, syntaxLanguage: .bash, formatLabel: "Shell Script"),
        "swift": .init(format: .code, syntaxLanguage: .swift, formatLabel: "Swift"),
        "js": .init(format: .code, syntaxLanguage: .javascript, formatLabel: "JavaScript"),
        "mjs": .init(format: .code, syntaxLanguage: .javascript, formatLabel: "JavaScript"),
        "cjs": .init(format: .code, syntaxLanguage: .javascript, formatLabel: "JavaScript"),
        "jsx": .init(format: .code, syntaxLanguage: .javascript, formatLabel: "JavaScript"),
        "ts": .init(format: .code, syntaxLanguage: .typescript, formatLabel: "TypeScript"),
        "mts": .init(format: .code, syntaxLanguage: .typescript, formatLabel: "TypeScript"),
        "cts": .init(format: .code, syntaxLanguage: .typescript, formatLabel: "TypeScript"),
        "tsx": .init(format: .code, syntaxLanguage: .typescript, formatLabel: "TypeScript"),
        "py": .init(format: .code, syntaxLanguage: .python, formatLabel: "Python"),
        "go": .init(format: .code, syntaxLanguage: .go, formatLabel: "Go"),
        "rs": .init(format: .code, syntaxLanguage: .rust, formatLabel: "Rust"),
    ]

    private static let fallbackClassificationByFormat: [LocalDocumentFormat: LocalDocumentClassification] = [
        .markdown: .init(format: .markdown, syntaxLanguage: nil, formatLabel: "Markdown"),
        .yaml: .init(format: .yaml, syntaxLanguage: .yaml, formatLabel: "YAML"),
        .toml: .init(format: .toml, syntaxLanguage: .toml, formatLabel: "TOML"),
        .json: .init(format: .json, syntaxLanguage: .json, formatLabel: "JSON"),
        .jsonl: .init(format: .jsonl, syntaxLanguage: .json, formatLabel: "JSON Lines"),
        .config: .init(format: .config, syntaxLanguage: nil, formatLabel: "Config"),
        .csv: .init(format: .csv, syntaxLanguage: nil, formatLabel: "CSV"),
        .tsv: .init(format: .tsv, syntaxLanguage: nil, formatLabel: "TSV"),
        .xml: .init(format: .xml, syntaxLanguage: .xml, formatLabel: "XML"),
        .shell: .init(format: .shell, syntaxLanguage: .bash, formatLabel: "Shell Script"),
        .code: .init(format: .code, syntaxLanguage: nil, formatLabel: "Code"),
    ]

    public static let filenameExtensionToFormat: [String: LocalDocumentFormat] =
        filenameExtensionToClassification.mapValues(\.format)

    public static let supportedFilenameExtensions: [String] =
        filenameExtensionToClassification.keys.sorted()

    public static let supportedExactFileNames: [String] =
        exactFileNameToClassification.keys.sorted()

    public static func classification(forPathExtension pathExtension: String) -> LocalDocumentClassification? {
        let normalizedExtension = pathExtension.lowercased()
        guard normalizedExtension.isEmpty == false else {
            return nil
        }

        return filenameExtensionToClassification[normalizedExtension]
    }

    public static func classification(forFilePath filePath: String) -> LocalDocumentClassification? {
        guard let normalizedFilePath = WebPanelState.normalizedFilePath(filePath) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: normalizedFilePath)
        if let directClassification = classification(forFileName: fileURL.lastPathComponent) {
            return directClassification
        }

        // Only the filename itself participates in `path:line` recovery.
        // Directory components may legally contain colons and should not
        // affect the file's classification.
        return classificationForColonSuffixedFileName(fileURL.lastPathComponent)
    }

    private static func classificationForColonSuffixedFileName(
        _ fileName: String
    ) -> LocalDocumentClassification? {
        var candidateFileName = fileName
        while let separatorIndex = candidateFileName.lastIndex(of: ":") {
            candidateFileName.removeSubrange(separatorIndex...)
            if let classification = classification(forFileName: candidateFileName) {
                return classification
            }
        }

        return nil
    }

    private static func classification(
        forFileName fileName: String
    ) -> LocalDocumentClassification? {
        if let directClassification = exactFileNameToClassification[fileName] {
            return directClassification
        }

        let pathExtension = (fileName as NSString).pathExtension
        return classification(forPathExtension: pathExtension)
    }

    public static func classification(
        format: LocalDocumentFormat,
        filePath: String? = nil
    ) -> LocalDocumentClassification {
        if let filePath,
           let classification = classification(forFilePath: filePath) {
            return classification
        }

        return fallbackClassificationByFormat[format] ?? .init(
            format: format,
            syntaxLanguage: nil,
            formatLabel: "Code"
        )
    }

    public static func format(forPathExtension pathExtension: String) -> LocalDocumentFormat? {
        classification(forPathExtension: pathExtension)?.format
    }

    public static func format(forFilePath filePath: String) -> LocalDocumentFormat? {
        classification(forFilePath: filePath)?.format
    }
}
