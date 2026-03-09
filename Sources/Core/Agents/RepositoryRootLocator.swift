import Foundation

public enum RepositoryRootLocator {
    public static func inferRepoRoot(
        from workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let workingDirectory = normalizedWorkingDirectory(workingDirectory) else { return nil }

        var candidateURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        while true {
            let gitURL = candidateURL.appendingPathComponent(".git", isDirectory: false)
            if fileManager.fileExists(atPath: gitURL.path) {
                return candidateURL.path
            }

            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path {
                return nil
            }
            candidateURL = parentURL
        }
    }

    private static func normalizedWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
