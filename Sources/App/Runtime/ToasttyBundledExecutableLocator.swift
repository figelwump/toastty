import Foundation

enum ToasttyBundledExecutableLocator {
    static func defaultCLIExecutablePath() -> String? {
        resolvedExecutablePath(
            candidateNames: ["toastty"],
            fileManager: .default,
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL
        )
    }

    static func defaultAgentShimExecutablePath() -> String? {
        resolvedExecutablePath(
            candidateNames: ["toastty-agent-shim", "toastty_agent_shim"],
            fileManager: .default,
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL
        )
    }

    static func resolvedCLIExecutablePath(
        fileManager: FileManager,
        bundleURL: URL,
        executableURL: URL?
    ) -> String? {
        resolvedExecutablePath(
            candidateNames: ["toastty"],
            fileManager: fileManager,
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    static func resolvedAgentShimExecutablePath(
        fileManager: FileManager,
        bundleURL: URL,
        executableURL: URL?
    ) -> String? {
        resolvedExecutablePath(
            candidateNames: ["toastty-agent-shim", "toastty_agent_shim"],
            fileManager: fileManager,
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    static func executablePathCandidates(
        named executableName: String,
        bundleURL: URL,
        executableURL: URL?
    ) -> [String] {
        executablePathCandidates(
            candidateNames: [executableName],
            bundleURL: bundleURL,
            executableURL: executableURL
        )
    }

    static func executablePathCandidates(
        candidateNames: [String],
        bundleURL: URL,
        executableURL: URL?
    ) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ path: String) {
            guard candidates.contains(path) == false else { return }
            candidates.append(path)
        }

        for executableName in candidateNames {
            appendCandidate(
                bundleURL
                    .appendingPathComponent("Contents/Helpers", isDirectory: true)
                    .appendingPathComponent(executableName, isDirectory: false)
                    .path
            )

            if let executableURL {
                appendCandidate(
                    executableURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(executableName)
                        .path
                )
            }

            appendCandidate(
                bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(executableName)
                    .path
            )
        }

        return candidates
    }

    private static func resolvedExecutablePath(
        candidateNames: [String],
        fileManager: FileManager,
        bundleURL: URL,
        executableURL: URL?
    ) -> String? {
        let candidates = executablePathCandidates(
            candidateNames: candidateNames,
            bundleURL: bundleURL,
            executableURL: executableURL
        )
        return candidates.first(where: { isUsableExecutable(atPath: $0, fileManager: fileManager) }) ?? candidates.first
    }

    private static func isUsableExecutable(
        atPath path: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: path) else {
            return false
        }

        let url = URL(fileURLWithPath: path)
        guard let siblingNames = try? fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) else {
            return false
        }

        return siblingNames.contains(url.lastPathComponent)
    }
}
