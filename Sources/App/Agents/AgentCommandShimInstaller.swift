import CoreState
import Darwin
import Foundation

struct AgentCommandShimInstallation: Equatable {
    let directoryURL: URL
    let helperPath: String
}

enum AgentCommandShimInstallerError: LocalizedError, Equatable {
    case helperUnavailable(path: String?)
    case managedCommandConflict(path: String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let path):
            if let path {
                return "Toastty could not find its managed agent shim helper at \(path)."
            }
            return "Toastty could not resolve its managed agent shim helper."
        case .managedCommandConflict(let path):
            return "Toastty will not overwrite an existing non-symlink agent command at \(path)."
        }
    }
}

final class AgentCommandShimInstaller {
    private static let defaultManagedCommandNames: Set<String> = ["codex", "claude"]
    private static let managedCommandsManifestFileName = ".toastty-managed-agent-commands.json"

    private let runtimePaths: ToasttyRuntimePaths
    private let fileManager: FileManager
    private let helperExecutablePathProvider: @Sendable () -> String?
    private let managedCommandNames: Set<String>

    init(
        runtimePaths: ToasttyRuntimePaths,
        fileManager: FileManager = .default,
        managedCommandNames: Set<String> = AgentCommandShimInstaller.defaultManagedCommandNames,
        helperExecutablePathProvider: @escaping @Sendable () -> String? = ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath
    ) {
        self.runtimePaths = runtimePaths
        self.fileManager = fileManager
        self.managedCommandNames = managedCommandNames
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
        try removeManagedLinks(
            named: previouslyInstalledManagedCommandNames(in: directoryURL)
                .subtracting(managedCommandNames),
            from: directoryURL
        )

        for commandName in managedCommandNames.sorted() {
            let linkURL = directoryURL.appendingPathComponent(commandName, isDirectory: false)
            let pathStatus = Self.pathStatus(at: linkURL.path)
            if pathStatus.exists {
                guard pathStatus.isSymlink else {
                    throw AgentCommandShimInstallerError.managedCommandConflict(path: linkURL.path)
                }
                try fileManager.removeItem(at: linkURL)
            }
            try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: helperPath)
        }
        try writeManagedCommandsManifest(in: directoryURL, commandNames: managedCommandNames)

        return AgentCommandShimInstallation(
            directoryURL: directoryURL,
            helperPath: helperPath
        )
    }

    func syncInstallation(enabled: Bool) throws -> AgentCommandShimInstallation? {
        if enabled {
            return try install()
        }

        try removeInstallationIfPresent()
        return nil
    }

    func removeInstallationIfPresent() throws {
        let directoryURL = runtimePaths.agentShimDirectoryURL
        let commandNamesToRemove = managedCommandNames
            .union(previouslyInstalledManagedCommandNames(in: directoryURL))
        try removeManagedLinks(named: commandNamesToRemove, from: directoryURL)
        try? fileManager.removeItem(at: managedCommandsManifestURL(in: directoryURL))

        guard let remainingEntries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ), remainingEntries.isEmpty else {
            return
        }

        try? fileManager.removeItem(at: directoryURL)
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

    private static func pathStatus(at path: String) -> (exists: Bool, isSymlink: Bool) {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else {
            return (false, false)
        }
        return (true, (statBuffer.st_mode & S_IFMT) == S_IFLNK)
    }

    private func managedCommandsManifestURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(Self.managedCommandsManifestFileName, isDirectory: false)
    }

    private func previouslyInstalledManagedCommandNames(in directoryURL: URL) -> Set<String> {
        let manifestURL = managedCommandsManifestURL(in: directoryURL)
        guard let data = try? Data(contentsOf: manifestURL),
              let commandNames = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(commandNames.compactMap(normalizedNonEmpty))
    }

    private func writeManagedCommandsManifest(in directoryURL: URL, commandNames: Set<String>) throws {
        let manifestURL = managedCommandsManifestURL(in: directoryURL)
        let encodedCommandNames = Array(commandNames).sorted()
        let data = try JSONEncoder().encode(encodedCommandNames)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func removeManagedLinks(named commandNames: Set<String>, from directoryURL: URL) throws {
        for commandName in commandNames.sorted() {
            let linkURL = directoryURL.appendingPathComponent(commandName, isDirectory: false)
            if Self.pathStatus(at: linkURL.path).isSymlink {
                try fileManager.removeItem(at: linkURL)
            }
        }
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
