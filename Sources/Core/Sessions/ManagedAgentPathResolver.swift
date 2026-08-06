import Foundation

public enum ManagedAgentPathResolver {
    public static func mergedPath(currentPath: String?, basePath: String?) -> String? {
        let components = mergedPathComponents(currentPath: currentPath, basePath: basePath)
        guard components.isEmpty == false else {
            return nil
        }
        return components.joined(separator: ":")
    }

    public static func resolvedExecutablePath(
        commandName: String,
        currentPath: String?,
        basePath: String?,
        excludedDirectoryPaths: Set<String> = [],
        excludedExecutablePaths: Set<String> = [],
        canonicalPathProvider: (String) -> String? = defaultCanonicalPath(for:),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let pathComponents = mergedPathComponents(currentPath: currentPath, basePath: basePath)
        let canonicalExcludedDirectoryPaths = Set(
            excludedDirectoryPaths.compactMap(canonicalPathProvider)
        )
        let canonicalExcludedExecutablePaths = Set(
            excludedExecutablePaths.compactMap(canonicalPathProvider)
        )

        for directoryPath in pathComponents {
            let candidatePath = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(commandName, isDirectory: false)
                .path
            if isExecutablePathAllowed(
                candidatePath,
                canonicalExcludedDirectoryPaths: canonicalExcludedDirectoryPaths,
                canonicalExcludedExecutablePaths: canonicalExcludedExecutablePaths,
                canonicalPathProvider: canonicalPathProvider,
                isExecutableFile: isExecutableFile
            ) {
                return candidatePath
            }
        }

        return nil
    }

    /// Builds a subprocess-safe PATH from an agent's preferred shell PATH and the
    /// app's inherited fallback. Relative and explicitly excluded directories are
    /// omitted so a private management process cannot resolve Toastty's command
    /// shims or executables relative to its working directory.
    public static func sanitizedMergedPath(
        preferredPath: String?,
        fallbackPath: String?,
        excludedDirectoryPaths: Set<String> = []
    ) -> String? {
        let excludedPaths = Set(excludedDirectoryPaths.compactMap(canonicalAbsolutePath))
        var seenPaths = Set<String>()
        var entries: [String] = []

        for entry in mergedPathComponents(currentPath: preferredPath, basePath: fallbackPath) {
            guard let canonicalPath = canonicalAbsolutePath(entry),
                  excludedPaths.contains(canonicalPath) == false,
                  seenPaths.insert(canonicalPath).inserted else {
                continue
            }
            entries.append(standardizedAbsolutePath(entry))
        }
        guard entries.isEmpty == false else { return nil }
        return entries.joined(separator: ":")
    }

    public static func isExecutablePathAllowed(
        _ executablePath: String,
        excludedDirectoryPaths: Set<String> = [],
        excludedExecutablePaths: Set<String> = [],
        canonicalPathProvider: (String) -> String? = defaultCanonicalPath(for:),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        let canonicalExcludedDirectoryPaths = Set(
            excludedDirectoryPaths.compactMap(canonicalPathProvider)
        )
        let canonicalExcludedExecutablePaths = Set(
            excludedExecutablePaths.compactMap(canonicalPathProvider)
        )

        return isExecutablePathAllowed(
            executablePath,
            canonicalExcludedDirectoryPaths: canonicalExcludedDirectoryPaths,
            canonicalExcludedExecutablePaths: canonicalExcludedExecutablePaths,
            canonicalPathProvider: canonicalPathProvider,
            isExecutableFile: isExecutableFile
        )
    }

    private static func isExecutablePathAllowed(
        _ executablePath: String,
        canonicalExcludedDirectoryPaths: Set<String>,
        canonicalExcludedExecutablePaths: Set<String>,
        canonicalPathProvider: (String) -> String?,
        isExecutableFile: (String) -> Bool
    ) -> Bool {
        let directoryPath = URL(fileURLWithPath: executablePath, isDirectory: false)
            .deletingLastPathComponent()
            .path
        if let canonicalDirectoryPath = canonicalPathProvider(directoryPath),
           canonicalExcludedDirectoryPaths.contains(canonicalDirectoryPath) {
            return false
        }

        if let canonicalExecutablePath = canonicalPathProvider(executablePath),
           canonicalExcludedExecutablePaths.contains(canonicalExecutablePath) {
            return false
        }

        return isExecutableFile(executablePath)
    }

    private static func mergedPathComponents(
        currentPath: String?,
        basePath: String?
    ) -> [String] {
        deduplicatedPathEntries(from: normalizedPathEntries(currentPath) + normalizedPathEntries(basePath))
    }

    private static func normalizedPathEntries(_ path: String?) -> [String] {
        guard let path else {
            return []
        }
        return path
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    private static func deduplicatedPathEntries(from entries: [String]) -> [String] {
        var seenEntries = Set<String>()
        var deduplicatedEntries: [String] = []

        for entry in entries where seenEntries.insert(entry).inserted {
            deduplicatedEntries.append(entry)
        }

        return deduplicatedEntries
    }

    public static func defaultCanonicalPath(for path: String) -> String? {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: false)
            .standardizedFileURL
            .path
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            return nil
        }
        return standardizedPath
    }

    private static func standardizedAbsolutePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func canonicalAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
