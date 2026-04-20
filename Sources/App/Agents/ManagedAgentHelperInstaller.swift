import CoreState
import Foundation

struct ManagedAgentHelperPaths: Equatable {
    let cliExecutablePath: String?
    let agentShimExecutablePath: String?
}

final class ManagedAgentHelperInstaller {
    private let runtimePaths: ToasttyRuntimePaths
    private let fileManager: FileManager
    private let cliExecutablePathProvider: @Sendable () -> String?
    private let agentShimExecutablePathProvider: @Sendable () -> String?

    init(
        runtimePaths: ToasttyRuntimePaths,
        fileManager: FileManager = .default,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = ToasttyBundledExecutableLocator.defaultCLIExecutablePath,
        agentShimExecutablePathProvider: @escaping @Sendable () -> String? = ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath
    ) {
        self.runtimePaths = runtimePaths
        self.fileManager = fileManager
        self.cliExecutablePathProvider = cliExecutablePathProvider
        self.agentShimExecutablePathProvider = agentShimExecutablePathProvider
    }

    func resolvePaths() throws -> ManagedAgentHelperPaths {
        let resolvedPaths = ManagedAgentHelperPaths(
            cliExecutablePath: normalizedNonEmpty(cliExecutablePathProvider()),
            agentShimExecutablePath: normalizedNonEmpty(agentShimExecutablePathProvider())
        )
        guard runtimePaths.isRuntimeHomeEnabled else {
            return resolvedPaths
        }

        return ManagedAgentHelperPaths(
            cliExecutablePath: try stageExecutableIfNeeded(
                sourcePath: resolvedPaths.cliExecutablePath,
                stagedFileName: "toastty"
            ) ?? resolvedPaths.cliExecutablePath,
            agentShimExecutablePath: try stageExecutableIfNeeded(
                sourcePath: resolvedPaths.agentShimExecutablePath,
                stagedFileName: "toastty-agent-shim"
            ) ?? resolvedPaths.agentShimExecutablePath
        )
    }

    private func stageExecutableIfNeeded(
        sourcePath: String?,
        stagedFileName: String
    ) throws -> String? {
        guard let sourcePath = normalizedNonEmpty(sourcePath) else {
            return nil
        }
        guard fileManager.isExecutableFile(atPath: sourcePath) else {
            return sourcePath
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let destinationURL = runtimePaths.agentShimDirectoryURL
            .appendingPathComponent(stagedFileName, isDirectory: false)
            .standardizedFileURL
        if sourceURL.path == destinationURL.path {
            return sourceURL.path
        }

        try fileManager.createDirectory(
            at: runtimePaths.agentShimDirectoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = runtimePaths.agentShimDirectoryURL
            .appendingPathComponent(".\(stagedFileName).\(UUID().uuidString).tmp", isDirectory: false)
            .standardizedFileURL
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: temporaryURL.path
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        return destinationURL.path
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
