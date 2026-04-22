import Foundation

struct CommandPaletteFileIndexSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case indexing
        case ready
    }

    let results: [PaletteFileResult]
    let status: Status

    var isIndexing: Bool {
        status == .indexing
    }

    static func indexing(results: [PaletteFileResult]) -> CommandPaletteFileIndexSnapshot {
        CommandPaletteFileIndexSnapshot(results: results, status: .indexing)
    }

    static func ready(results: [PaletteFileResult]) -> CommandPaletteFileIndexSnapshot {
        CommandPaletteFileIndexSnapshot(results: results, status: .ready)
    }
}

protocol CommandPaletteFileIndexing: Sendable {
    func prepareIndex(in scope: PaletteFileSearchScope) async -> CommandPaletteFileIndexSnapshot
    func indexedFiles(in scope: PaletteFileSearchScope) async -> [PaletteFileResult]
}

actor CommandPaletteFileOpenProvider: CommandPaletteFileIndexing {
    typealias ScanScope = @Sendable (String) async -> [PaletteFileResult]

    private struct InFlightIndex {
        let generation: Int
        let task: Task<[PaletteFileResult], Never>
    }

    private struct CacheEntry {
        var generation = 0
        var results: [PaletteFileResult] = []
        var lastIndexedAt: Date?
        var inFlightIndex: InFlightIndex?
    }

    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        "build",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        ".tox",
        ".nox",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".next",
        ".nuxt",
        ".svelte-kit",
        ".turbo",
        ".parcel-cache",
    ]

    private static let skippedGeneratedDirectoryNames: Set<String> = [
        "Derived",
    ]

    private static let skippedGeneratedDirectoryPrefixes: [String] = [
        "Derived-",
        "DerivedData",
    ]

    private let staleAfter: TimeInterval
    private let scanScope: ScanScope
    private var entries: [String: CacheEntry] = [:]

    init(
        staleAfter: TimeInterval = 30,
        scanScope: ScanScope? = nil
    ) {
        self.staleAfter = staleAfter
        self.scanScope = scanScope ?? { rootPath in
            CommandPaletteFileOpenProvider.scanScope(rootPath: rootPath)
        }
    }

    func prepareIndex(in scope: PaletteFileSearchScope) async -> CommandPaletteFileIndexSnapshot {
        let normalizedScopePath = Self.normalizedDirectoryPath(scope.rootPath)
        guard normalizedScopePath.isEmpty == false else {
            return .ready(results: [])
        }

        var entry = entries[normalizedScopePath] ?? CacheEntry()
        if shouldStartIndex(for: entry) {
            entry = startIndex(for: normalizedScopePath, entry: entry)
            entries[normalizedScopePath] = entry
        }

        if entry.inFlightIndex != nil {
            return .indexing(results: entry.results)
        }

        return .ready(results: entry.results)
    }

    func indexedFiles(in scope: PaletteFileSearchScope) async -> [PaletteFileResult] {
        let normalizedScopePath = Self.normalizedDirectoryPath(scope.rootPath)
        guard normalizedScopePath.isEmpty == false else {
            return []
        }

        var entry = entries[normalizedScopePath] ?? CacheEntry()
        if shouldStartIndex(for: entry) {
            entry = startIndex(for: normalizedScopePath, entry: entry)
            entries[normalizedScopePath] = entry
        }

        guard let inFlightIndex = entry.inFlightIndex else {
            return entry.results
        }

        let results = await inFlightIndex.task.value
        commit(results: results, for: normalizedScopePath, generation: inFlightIndex.generation)
        return results
    }

    func cancel() {
        for entry in entries.values {
            entry.inFlightIndex?.task.cancel()
        }
        entries.removeAll()
    }

    private func shouldStartIndex(for entry: CacheEntry) -> Bool {
        if entry.inFlightIndex != nil {
            return false
        }
        guard let lastIndexedAt = entry.lastIndexedAt else {
            return true
        }
        return Date().timeIntervalSince(lastIndexedAt) >= staleAfter
    }

    private func startIndex(for normalizedScopePath: String, entry: CacheEntry) -> CacheEntry {
        var updatedEntry = entry
        let nextGeneration = entry.generation + 1
        updatedEntry.generation = nextGeneration
        updatedEntry.inFlightIndex = InFlightIndex(
            generation: nextGeneration,
            task: Task(priority: .utility) { [scanScope] in
                await scanScope(normalizedScopePath)
            }
        )
        return updatedEntry
    }

    private func commit(results: [PaletteFileResult], for normalizedScopePath: String, generation: Int) {
        guard var entry = entries[normalizedScopePath],
              entry.generation == generation else {
            return
        }

        entry.results = results
        entry.lastIndexedAt = Date()
        entry.inFlightIndex = nil
        entries[normalizedScopePath] = entry
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
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        let supportedExtensions = CommandPaletteFileOpenRouting.supportedPathExtensions
        let supportedExactFileNames = CommandPaletteFileOpenRouting.supportedExactFileNames
        var results: [PaletteFileResult] = []

        while let candidate = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                return []
            }

            let candidatePath = candidate.path
            let resourceValues = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])

            if resourceValues?.isDirectory == true {
                guard let resolvedCandidate = resolvedRelativePath(
                    for: candidatePath,
                    rootPath: rootPath
                ) else {
                    continue
                }

                if shouldSkipDescendants(
                    of: candidate,
                    relativePath: resolvedCandidate.relativePath,
                    resourceValues: resourceValues
                ) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues?.isRegularFile == true else {
                continue
            }

            let fileName = candidate.lastPathComponent
            if fileName.hasPrefix("."),
               supportedExactFileNames.contains(fileName) == false {
                continue
            }

            let pathExtension = candidate.pathExtension.lowercased()
            guard supportedExtensions.contains(pathExtension) || supportedExactFileNames.contains(fileName) else {
                continue
            }

            guard let resolvedCandidate = resolvedRelativePath(
                for: candidatePath,
                rootPath: rootPath
            ),
                  shouldSkipFile(relativePath: resolvedCandidate.relativePath) == false,
                  let destination = CommandPaletteFileOpenRouting.destination(
                      forNormalizedFilePath: resolvedCandidate.filePath
                  ) else {
                continue
            }

            results.append(
                PaletteFileResult(
                    filePath: resolvedCandidate.filePath,
                    fileName: candidate.lastPathComponent,
                    relativePath: resolvedCandidate.relativePath,
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
        relativePath: String,
        resourceValues: URLResourceValues?
    ) -> Bool {
        if resourceValues?.isSymbolicLink == true {
            return true
        }

        let directoryName = directoryURL.lastPathComponent
        if skippedDirectoryNames.contains(directoryName) {
            return true
        }

        let pathComponents = relativePath.split(separator: "/")
        if pathComponents.count >= 2,
           pathComponents[0] == ".yarn",
           (pathComponents[1] == "cache" || pathComponents[1] == "unplugged") {
            return true
        }

        if skippedGeneratedDirectoryNames.contains(directoryName) ||
            skippedGeneratedDirectoryPrefixes.contains(where: { directoryName.hasPrefix($0) }) {
            return true
        }

        return false
    }

    private static func shouldSkipFile(relativePath: String) -> Bool {
        let pathComponents = relativePath.split(separator: "/")
        if pathComponents.count >= 2,
           pathComponents[0] == ".yarn",
           (pathComponents[1] == "cache" || pathComponents[1] == "unplugged") {
            return true
        }

        return false
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

    private static func resolvedRelativePath(
        for candidatePath: String,
        rootPath: String
    ) -> (relativePath: String, filePath: String)? {
        if let relativePath = descendantRelativePath(candidatePath, of: rootPath) {
            return (relativePath, candidatePath)
        }

        let normalizedCandidatePath = normalizedFilePath(candidatePath)
        guard let relativePath = descendantRelativePath(normalizedCandidatePath, of: rootPath) else {
            return nil
        }

        return (relativePath, normalizedCandidatePath)
    }

    private static func descendantRelativePath(_ filePath: String, of rootPath: String) -> String? {
        guard isDescendant(filePath, of: rootPath) else {
            return nil
        }

        return relativePath(for: filePath, rootPath: rootPath)
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        normalizedFilePath(path)
    }

    private static func normalizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
