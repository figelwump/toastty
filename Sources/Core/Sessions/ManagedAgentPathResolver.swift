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
            if let canonicalDirectoryPath = canonicalPathProvider(directoryPath),
               canonicalExcludedDirectoryPaths.contains(canonicalDirectoryPath) {
                continue
            }

            let candidatePath = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(commandName, isDirectory: false)
                .path
            if let canonicalCandidatePath = canonicalPathProvider(candidatePath),
               canonicalExcludedExecutablePaths.contains(canonicalCandidatePath) {
                continue
            }
            if isExecutableFile(candidatePath) {
                return candidatePath
            }
        }

        return nil
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
}
