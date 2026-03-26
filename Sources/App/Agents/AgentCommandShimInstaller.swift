import CoreState
import Foundation

struct AgentCommandShimInstallation: Equatable {
    let directoryURL: URL
    let helperPath: String
}

enum AgentCommandShimInstallerError: LocalizedError, Equatable {
    case helperUnavailable(path: String?)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let path):
            if let path {
                return "Toastty could not find its managed agent shim helper at \(path)."
            }
            return "Toastty could not resolve its managed agent shim helper."
        }
    }
}

final class AgentCommandShimInstaller {
    private let runtimePaths: ToasttyRuntimePaths
    private let fileManager: FileManager
    private let helperExecutablePathProvider: @Sendable () -> String?

    init(
        runtimePaths: ToasttyRuntimePaths,
        fileManager: FileManager = .default,
        helperExecutablePathProvider: @escaping @Sendable () -> String? = ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath
    ) {
        self.runtimePaths = runtimePaths
        self.fileManager = fileManager
        self.helperExecutablePathProvider = helperExecutablePathProvider
    }

    func install() throws -> AgentCommandShimInstallation {
        guard let helperPath = normalizedNonEmpty(helperExecutablePathProvider()) else {
            throw AgentCommandShimInstallerError.helperUnavailable(path: nil)
        }
        guard fileManager.isExecutableFile(atPath: helperPath) else {
            throw AgentCommandShimInstallerError.helperUnavailable(path: helperPath)
        }

        let directoryURL = runtimePaths.agentShimDirectoryURL
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        for commandName in ["codex", "claude"] {
            let linkURL = directoryURL.appendingPathComponent(commandName, isDirectory: false)
            if fileManager.fileExists(atPath: linkURL.path) {
                try fileManager.removeItem(at: linkURL)
            }
            try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: helperPath)
        }

        return AgentCommandShimInstallation(
            directoryURL: directoryURL,
            helperPath: helperPath
        )
    }

    static func pathValue(
        prepending directoryPath: String,
        to existingPath: String?
    ) -> String {
        var components = (existingPath ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false && $0 != directoryPath }
        components.insert(directoryPath, at: 0)
        return components.joined(separator: ":")
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
