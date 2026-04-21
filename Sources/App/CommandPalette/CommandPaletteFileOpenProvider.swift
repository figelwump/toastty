import Foundation

actor CommandPaletteFileOpenProvider {
    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        "Derived",
        "build",
        "node_modules",
    ]

    private var cachedScopePath: String?
    private var cachedResults: [PaletteFileResult]?
    private var indexingTask: Task<[PaletteFileResult], Never>?

    func indexedFiles(in scope: PaletteFileSearchScope) async -> [PaletteFileResult] {
        let normalizedScopePath = Self.normalizedDirectoryPath(scope.rootPath)
        guard normalizedScopePath.isEmpty == false else {
            return []
        }

        if cachedScopePath == normalizedScopePath, let cachedResults {
            return cachedResults
        }

        if cachedScopePath != normalizedScopePath {
            indexingTask?.cancel()
            cachedScopePath = normalizedScopePath
            cachedResults = nil
            indexingTask = Task(priority: .utility) {
                Self.scanScope(rootPath: normalizedScopePath)
            }
        }

        guard let indexingTask else {
            return []
        }

        let results = await indexingTask.value
        if cachedScopePath == normalizedScopePath {
            cachedResults = results
        }
        return results
    }

    func cancel() {
        indexingTask?.cancel()
        indexingTask = nil
        cachedScopePath = nil
        cachedResults = nil
    }

    private static func scanScope(rootPath: String) -> [PaletteFileResult] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let supportedExtensions = CommandPaletteFileOpenRouting.supportedPathExtensions
        var results: [PaletteFileResult] = []

        while let candidate = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                return []
            }

            let resourceValues = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])

            if resourceValues?.isDirectory == true {
                if shouldSkipDescendants(of: candidate, resourceValues: resourceValues) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues?.isRegularFile == true else {
                continue
            }

            let pathExtension = candidate.pathExtension.lowercased()
            guard supportedExtensions.contains(pathExtension) else {
                continue
            }

            let normalizedFilePath = normalizedFilePath(candidate.path)
            guard isDescendant(normalizedFilePath, of: rootPath),
                  let destination = CommandPaletteFileOpenRouting.destination(
                      forNormalizedFilePath: normalizedFilePath
                  ) else {
                continue
            }

            results.append(
                PaletteFileResult(
                    filePath: normalizedFilePath,
                    fileName: candidate.lastPathComponent,
                    relativePath: relativePath(for: normalizedFilePath, rootPath: rootPath),
                    destination: destination
                )
            )
        }

        return results.sorted {
            if $0.fileName != $1.fileName {
                return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
            }
            return $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func shouldSkipDescendants(
        of directoryURL: URL,
        resourceValues: URLResourceValues?
    ) -> Bool {
        if skippedDirectoryNames.contains(directoryURL.lastPathComponent) {
            return true
        }

        return resourceValues?.isSymbolicLink == true
    }

    private static func relativePath(for filePath: String, rootPath: String) -> String {
        guard filePath != rootPath else {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }

        return URL(fileURLWithPath: filePath).lastPathComponent
    }

    private static func isDescendant(_ filePath: String, of rootPath: String) -> Bool {
        filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        normalizedFilePath(path)
    }

    private static func normalizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
