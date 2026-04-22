import CoreState
import Foundation

enum LocalFileLinkResolver {
    struct LocalDocumentTarget: Equatable {
        let path: String
        let lineNumber: Int?
    }

    private struct ParsedTrailingLineNumberPath: Equatable {
        let path: String
        let lineNumber: Int
    }

    private static let minimumRecoveredMalformedComponentLength = 3
    private static let maximumNestedRelativeChildRecoveryEntries = 2_000
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

    static func resolvedLocalDocumentTarget(
        for url: URL,
        cwd: String? = nil,
        fileManager: FileManager = .default
    ) -> LocalDocumentTarget? {
        guard let localFilePath = resolvedLocalFilePath(for: url, cwd: cwd) else {
            return nil
        }

        for candidate in recoveredPathCandidates(for: localFilePath, fileManager: fileManager) {
            if let exactPath = normalizedExistingLocalDocumentFilePath(candidate, fileManager: fileManager) {
                return LocalDocumentTarget(path: exactPath, lineNumber: nil)
            }

            if let recoveredPath = nestedRelativeChildLocalDocumentFilePath(
                for: candidate,
                cwd: cwd,
                fileManager: fileManager
            ) {
                return LocalDocumentTarget(path: recoveredPath, lineNumber: nil)
            }

            guard let parsedPath = parsedTrailingLineNumberPath(candidate) else {
                continue
            }

            if let resolvedPath = normalizedExistingLocalDocumentFilePath(
                parsedPath.path,
                fileManager: fileManager
            ) {
                return LocalDocumentTarget(path: resolvedPath, lineNumber: parsedPath.lineNumber)
            }

            if let recoveredPath = nestedRelativeChildLocalDocumentFilePath(
                for: parsedPath.path,
                cwd: cwd,
                fileManager: fileManager
            ) {
                return LocalDocumentTarget(path: recoveredPath, lineNumber: parsedPath.lineNumber)
            }
        }

        return nil
    }

    static func looksLikeSupportedLocalDocumentTarget(
        for url: URL,
        cwd: String? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        if let scheme = url.scheme?.lowercased(),
           scheme != "file" {
            return false
        }

        guard let path = rawPath(for: url),
              let normalizedPath = WebPanelState.normalizedFilePath(path) else {
            return false
        }

        let expandedPath = (normalizedPath as NSString).expandingTildeInPath
        guard expandedPath.isEmpty == false else {
            return false
        }

        let localFilePath = resolvedLocalFilePath(for: url, cwd: cwd) ?? expandedPath
        for candidate in recoveredPathCandidates(for: localFilePath, fileManager: fileManager) {
            if isSupportedLocalDocumentIntent(forCandidatePath: candidate, fileManager: fileManager) {
                return true
            }
        }

        return false
    }

    static func normalizedLocalDirectoryPath(
        for url: URL,
        cwd: String? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        guard let localFilePath = resolvedLocalFilePath(for: url, cwd: cwd) else {
            return nil
        }

        return normalizedRecoveredPath(
            for: localFilePath,
            fileManager: fileManager,
            exactMatcher: normalizedExistingLocalDirectoryPath
        )
    }

    private static func resolvedLocalFilePath(for url: URL, cwd: String?) -> String? {
        if let scheme = url.scheme?.lowercased(),
           scheme != "file" {
            return nil
        }

        guard let rawPath = rawPath(for: url),
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

    private static func rawPath(for url: URL) -> String? {
        let path = url.path
        guard path.isEmpty == false else {
            return nil
        }
        return path
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

    private static func existingNonDirectoryPath(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        let standardizedURL = URL(fileURLWithPath: path).standardizedFileURL
        let standardizedPath = standardizedURL.path
        guard standardizedPath.isEmpty == false else {
            return false
        }

        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory),
           isDirectory.boolValue == false {
            return true
        }

        let resolvedPath = standardizedURL.resolvingSymlinksInPath().path
        guard resolvedPath != standardizedPath else {
            return false
        }

        if fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
           isDirectory.boolValue == false {
            return true
        }

        return false
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

    private static func trailingNumericSuffixBasePath(_ path: String) -> String? {
        guard let separatorIndex = path.lastIndex(of: ":") else {
            return nil
        }

        let basePath = String(path[..<separatorIndex])
        let suffix = String(path[path.index(after: separatorIndex)...])
        guard basePath.isEmpty == false,
              suffix.isEmpty == false,
              suffix.allSatisfy(\.isNumber) else {
            return nil
        }

        return basePath
    }

    private static func isSupportedLocalDocumentIntent(
        forCandidatePath candidatePath: String,
        fileManager: FileManager
    ) -> Bool {
        let basePath: String
        if LocalDocumentClassifier.format(forFilePath: candidatePath) != nil {
            basePath = candidatePath
        } else if let parsedBasePath = trailingNumericSuffixBasePath(candidatePath),
                  LocalDocumentClassifier.format(forFilePath: parsedBasePath) != nil {
            basePath = parsedBasePath
        } else {
            return false
        }

        guard basePath.hasPrefix("/") else {
            return true
        }

        if normalizedExistingLocalDirectoryPath(basePath, fileManager: fileManager) != nil {
            return false
        }

        if normalizedExistingLocalDocumentFilePath(basePath, fileManager: fileManager) != nil {
            return true
        }

        if existingNonDirectoryPath(basePath, fileManager: fileManager) {
            return false
        }

        return true
    }

    private static func nestedRelativeChildLocalDocumentFilePath(
        for candidatePath: String,
        cwd: String?,
        fileManager: FileManager
    ) -> String? {
        guard let normalizedCWD = WebPanelState.normalizedFilePath(cwd) else {
            return nil
        }

        let standardizedPath = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        guard isPath(standardizedPath, within: normalizedCWD) else {
            return nil
        }

        let parentURL = URL(fileURLWithPath: standardizedPath)
            .deletingLastPathComponent()
            .standardizedFileURL
        let parentPath = parentURL.path
        guard isPath(parentPath, within: normalizedCWD) else {
            return nil
        }

        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parentPath, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            return nil
        }

        let targetBasename = URL(fileURLWithPath: standardizedPath).lastPathComponent
        guard targetBasename.isEmpty == false else {
            return nil
        }

        guard let enumerator = fileManager.enumerator(
            at: parentURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var visitedEntryCount = 0
        var matchedPath: String?

        for case let candidateURL as URL in enumerator {
            visitedEntryCount += 1
            guard visitedEntryCount <= maximumNestedRelativeChildRecoveryEntries else {
                return nil
            }

            guard candidateURL.lastPathComponent == targetBasename else {
                continue
            }

            guard let normalizedCandidatePath = normalizedExistingLocalDocumentFilePath(
                candidateURL.path,
                fileManager: fileManager
            ) else {
                continue
            }

            if let matchedPath, matchedPath != normalizedCandidatePath {
                return nil
            }
            matchedPath = normalizedCandidatePath
        }

        return matchedPath
    }

    private static func isPath(_ path: String, within root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
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
