import CoreState
import Foundation

enum TerminalCommandClickTarget: Equatable, Sendable {
    case localDocumentFile(path: String, placement: WebPanelPlacement)
    case localDirectory(path: String)
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
        guard let localFilePath = resolvedLocalFilePath(for: hoveredURL, cwd: cwd) else {
            return .passthrough(hoveredURL)
        }

        if let localDocumentFilePath = normalizedLocalDocumentFilePath(localFilePath, fileManager: fileManager) {
            let placement: WebPanelPlacement = useAlternatePlacement ? .rootRight : .newTab
            return .localDocumentFile(path: localDocumentFilePath, placement: placement)
        }

        if let localDirectoryPath = normalizedLocalDirectoryPath(localFilePath, fileManager: fileManager) {
            return .localDirectory(path: localDirectoryPath)
        }

        return .passthrough(hoveredURL)
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

    private static func normalizedLocalDocumentFilePath(
        _ path: String,
        fileManager: FileManager
    ) -> String? {
        normalizedRecoveredPath(
            for: path,
            fileManager: fileManager,
            exactMatcher: normalizedExistingLocalDocumentFilePath
        )
    }

    private static func normalizedExistingLocalDocumentFilePath(
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

        guard LocalDocumentClassifier.format(forFilePath: resolvedPath) != nil else {
            return nil
        }

        return WebPanelState.normalizedFilePath(resolvedPath)
    }

    private static func normalizedLocalDirectoryPath(
        _ path: String,
        fileManager: FileManager
    ) -> String? {
        normalizedRecoveredPath(
            for: path,
            fileManager: fileManager,
            exactMatcher: normalizedExistingLocalDirectoryPath
        )
    }

    private static func normalizedExistingLocalDirectoryPath(
        _ path: String,
        fileManager: FileManager
    ) -> String? {
        let standardizedURL = URL(fileURLWithPath: path).standardizedFileURL
        let standardizedPath = standardizedURL.path
        guard standardizedPath.isEmpty == false else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return WebPanelState.normalizedFilePath(standardizedPath)
        }

        let resolvedPath = standardizedURL.resolvingSymlinksInPath().path
        guard resolvedPath != standardizedPath else {
            return nil
        }

        if fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // Preserve the clicked directory path so the spawned shell starts
            // from the same user-visible location even when existence checks
            // have to follow a symlink target.
            return WebPanelState.normalizedFilePath(standardizedPath)
        }

        return nil
    }

    private static func normalizedRecoveredPath(
        for path: String,
        fileManager: FileManager,
        exactMatcher: (String, FileManager) -> String?
    ) -> String? {
        if let exactMatch = exactMatcher(path, fileManager) {
            return exactMatch
        }

        for recoveredPath in trailingPunctuationRecoveryCandidates(for: path) {
            if let recoveredMatch = exactMatcher(recoveredPath, fileManager) {
                return recoveredMatch
            }
        }

        return nil
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
