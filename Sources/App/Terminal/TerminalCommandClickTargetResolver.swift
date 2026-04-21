import CoreState
import Foundation

enum TerminalCommandClickTarget: Equatable, Sendable {
    case localDocumentFile(path: String, lineNumber: Int?, placement: WebPanelPlacement)
    case localDirectory(path: String)
    case passthrough(URL)
}

enum TerminalCommandClickTargetResolver {
    private struct LocalDocumentFileTarget: Equatable {
        let path: String
        let lineNumber: Int?
    }

    private struct ParsedTrailingLineNumberPath: Equatable {
        let path: String
        let lineNumber: Int
    }

    private static let minimumRecoveredMalformedComponentLength = 3
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

        if let localDocumentTarget = resolvedLocalDocumentFileTarget(localFilePath, fileManager: fileManager) {
            let placement: WebPanelPlacement = useAlternatePlacement ? .rootRight : .newTab
            return .localDocumentFile(
                path: localDocumentTarget.path,
                lineNumber: localDocumentTarget.lineNumber,
                placement: placement
            )
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

    private static func resolvedLocalDocumentFileTarget(
        _ path: String,
        fileManager: FileManager
    ) -> LocalDocumentFileTarget? {
        for candidate in recoveredPathCandidates(for: path, fileManager: fileManager) {
            if let exactPath = normalizedExistingLocalDocumentFilePath(candidate, fileManager: fileManager) {
                return LocalDocumentFileTarget(path: exactPath, lineNumber: nil)
            }

            guard let parsedPath = parsedTrailingLineNumberPath(candidate),
                  let resolvedPath = normalizedExistingLocalDocumentFilePath(
                      parsedPath.path,
                      fileManager: fileManager
                  ) else {
                continue
            }

            return LocalDocumentFileTarget(path: resolvedPath, lineNumber: parsedPath.lineNumber)
        }

        return nil
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

    private static func recoveredPathCandidates(
        for path: String,
        fileManager: FileManager
    ) -> [String] {
        var seen: Set<String> = []
        var candidates: [String] = []

        func appendCandidate(_ candidate: String) {
            guard seen.insert(candidate).inserted else {
                return
            }
            candidates.append(candidate)
        }

        appendCandidate(path)
        for candidate in trailingPunctuationRecoveryCandidates(for: path) {
            appendCandidate(candidate)
        }
        for candidate in malformedAbsolutePathRecoveryCandidates(for: path, fileManager: fileManager) {
            appendCandidate(candidate)
        }

        return candidates
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

        for recoveredPath in malformedAbsolutePathRecoveryCandidates(for: path, fileManager: fileManager) {
            if let recoveredMatch = exactMatcher(recoveredPath, fileManager) {
                return recoveredMatch
            }
        }

        return nil
    }

    private static func parsedTrailingLineNumberPath(_ path: String) -> ParsedTrailingLineNumberPath? {
        guard let separatorIndex = path.lastIndex(of: ":") else {
            return nil
        }

        let basePath = String(path[..<separatorIndex])
        let lineNumberText = String(path[path.index(after: separatorIndex)...])
        guard basePath.isEmpty == false,
              lineNumberText.isEmpty == false,
              lineNumberText.allSatisfy(\.isNumber),
              let lineNumber = Int(lineNumberText),
              lineNumber > 0 else {
            return nil
        }

        return ParsedTrailingLineNumberPath(path: basePath, lineNumber: lineNumber)
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

    private static func malformedAbsolutePathRecoveryCandidates(
        for path: String,
        fileManager: FileManager
    ) -> [String] {
        guard path.hasPrefix("/") else {
            return []
        }

        let pathComponents = (path as NSString).pathComponents
        guard pathComponents.count > 1 else {
            return []
        }

        var existingParentPath = "/"
        let components = Array(pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            let candidateURL = URL(fileURLWithPath: existingParentPath, isDirectory: true)
                .appendingPathComponent(component, isDirectory: false)
                .standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory) else {
                return malformedAbsoluteChildRecoveryCandidates(
                    under: existingParentPath,
                    malformedComponent: component
                )
            }

            if isDirectory.boolValue {
                existingParentPath = candidateURL.path
                continue
            }

            // Exact file targets are handled before recovery. If a regular file
            // appears before the end of the malformed path, do not guess.
            if index < components.index(before: components.endIndex) {
                return []
            }
        }

        return []
    }

    private static func malformedAbsoluteChildRecoveryCandidates(
        under parentPath: String,
        malformedComponent: String
    ) -> [String] {
        guard malformedComponent.isEmpty == false else {
            return []
        }

        let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
        var trimmedComponent = malformedComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        while let whitespaceIndex = trimmedComponent.lastIndex(where: \.isWhitespace) {
            let candidateComponent = String(trimmedComponent[..<whitespaceIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidateComponent.count >= minimumRecoveredMalformedComponentLength else {
                break
            }

            let candidatePath = parentURL
                .appendingPathComponent(candidateComponent, isDirectory: false)
                .standardizedFileURL
                .path
            if candidates.contains(candidatePath) == false {
                candidates.append(candidatePath)
            }
            trimmedComponent = candidateComponent
        }

        return candidates
    }
}
