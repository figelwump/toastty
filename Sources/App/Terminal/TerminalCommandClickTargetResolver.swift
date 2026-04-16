import CoreState
import Foundation

enum TerminalCommandClickTarget: Equatable, Sendable {
    case markdownFile(path: String, placement: WebPanelPlacement)
    case passthrough(URL)
}

enum TerminalCommandClickTargetResolver {
    private static let trailingSentencePunctuation: Set<Character> = [
        ",",
        ".",
        ":",
        ";",
        "!",
        "?",
        "\"",
        "'",
        ")",
        "]",
        "}",
        ">",
    ]

    static func resolve(
        hoveredURL: URL,
        cwd: String?,
        useAlternatePlacement: Bool,
        fileManager: FileManager = .default
    ) -> TerminalCommandClickTarget {
        guard let localFilePath = resolvedLocalFilePath(for: hoveredURL, cwd: cwd),
              let markdownFilePath = normalizedMarkdownFilePath(localFilePath, fileManager: fileManager) else {
            return .passthrough(hoveredURL)
        }

        let placement: WebPanelPlacement = useAlternatePlacement ? .rootRight : .newTab
        return .markdownFile(path: markdownFilePath, placement: placement)
    }

    private static func resolvedLocalFilePath(for hoveredURL: URL, cwd: String?) -> String? {
        if let scheme = hoveredURL.scheme?.lowercased(),
           scheme != "file" {
            return nil
        }

        guard let rawPath = rawPath(for: hoveredURL),
              let normalizedRawPath = WebPanelState.normalizedFilePath(rawPath) else {
            return nil
        }

        let expandedPath = (normalizedRawPath as NSString).expandingTildeInPath
        guard expandedPath.isEmpty == false else {
            return nil
        }

        if expandedPath.hasPrefix("/") {
            return expandedPath
        }

        guard let normalizedCWD = WebPanelState.normalizedFilePath(cwd) else {
            return nil
        }

        return URL(
            fileURLWithPath: expandedPath,
            relativeTo: URL(fileURLWithPath: normalizedCWD, isDirectory: true)
        )
        .standardizedFileURL
        .path
    }

    private static func rawPath(for hoveredURL: URL) -> String? {
        let path = hoveredURL.path
        guard path.isEmpty == false else {
            return nil
        }
        return path
    }

    private static func normalizedMarkdownFilePath(
        _ path: String,
        fileManager: FileManager
    ) -> String? {
        if let exactMatch = normalizedExistingMarkdownFilePath(path, fileManager: fileManager) {
            return exactMatch
        }

        for recoveredPath in trailingPunctuationRecoveryCandidates(for: path) {
            if let recoveredMatch = normalizedExistingMarkdownFilePath(recoveredPath, fileManager: fileManager) {
                return recoveredMatch
            }
        }

        return nil
    }

    private static func normalizedExistingMarkdownFilePath(
        _ path: String,
        fileManager: FileManager
    ) -> String? {
        let resolvedURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path
        guard resolvedPath.isEmpty == false else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue == false else {
            return nil
        }

        guard LocalDocumentClassifier.format(forFilePath: resolvedPath) == .markdown else {
            return nil
        }

        return WebPanelState.normalizedFilePath(resolvedPath)
    }

    private static func trailingPunctuationRecoveryCandidates(for path: String) -> [String] {
        var trimmedPath = path
        var recoveredPaths: [String] = []

        while let trailingCharacter = trimmedPath.last,
              trailingSentencePunctuation.contains(trailingCharacter) {
            trimmedPath.removeLast()
            recoveredPaths.append(trimmedPath)
        }

        return recoveredPaths
    }
}
