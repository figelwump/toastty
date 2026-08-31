import CoreState
import Darwin
import Foundation

struct ManagedAgentHelperPaths: Equatable {
    let cliExecutablePath: String?
    let agentShimExecutablePath: String?
}

final class ManagedAgentHelperInstaller {
    static let ownerRecordFileName = ".owner-pid"

    private let runtimePaths: ToasttyRuntimePaths
    private let fileManager: FileManager
    private let cliExecutablePathProvider: @Sendable () -> String?
    private let agentShimExecutablePathProvider: @Sendable () -> String?
    private let processID: Int32
    private let instanceIdentifier: UUID
    private let ownerProcessStateProvider: @Sendable (Int32) -> ManagedAgentOwnerProcessState

    init(
        runtimePaths: ToasttyRuntimePaths,
        fileManager: FileManager = .default,
        cliExecutablePathProvider: @escaping @Sendable () -> String? = ToasttyBundledExecutableLocator.defaultCLIExecutablePath,
        agentShimExecutablePathProvider: @escaping @Sendable () -> String? = ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath,
        processID: Int32 = getpid(),
        instanceIdentifier: UUID = UUID(),
        ownerProcessStateProvider: @escaping @Sendable (Int32) -> ManagedAgentOwnerProcessState =
            ManagedAgentHelperInstaller.ownerProcessState
    ) {
        self.runtimePaths = runtimePaths
        self.fileManager = fileManager
        self.cliExecutablePathProvider = cliExecutablePathProvider
        self.agentShimExecutablePathProvider = agentShimExecutablePathProvider
        self.processID = processID
        self.instanceIdentifier = instanceIdentifier
        self.ownerProcessStateProvider = ownerProcessStateProvider
    }

    func resolvePaths() throws -> ManagedAgentHelperPaths {
        let resolvedPaths = ManagedAgentHelperPaths(
            cliExecutablePath: normalizedNonEmpty(cliExecutablePathProvider()),
            agentShimExecutablePath: normalizedNonEmpty(agentShimExecutablePathProvider())
        )
        guard runtimePaths.isRuntimeHomeEnabled else {
            return resolvedPaths
        }

        try sweepStaleInstanceDirectories()
        let instanceDirectoryURL = try makeInstanceDirectory()
        do {
            let cliExecutablePath = try stageExecutableIfNeeded(
                sourcePath: resolvedPaths.cliExecutablePath,
                stagedFileName: "toastty",
                destinationDirectoryURL: instanceDirectoryURL
            ) ?? resolvedPaths.cliExecutablePath
            let agentShimExecutablePath = try stageExecutableIfNeeded(
                sourcePath: resolvedPaths.agentShimExecutablePath,
                stagedFileName: "toastty-agent-shim",
                destinationDirectoryURL: instanceDirectoryURL
            ) ?? resolvedPaths.agentShimExecutablePath

            // Preserve the runtime-home command surface for interactive use.
            // Managed launches receive the immutable instance paths above.
            _ = try stageExecutableIfNeeded(
                sourcePath: cliExecutablePath,
                stagedFileName: "toastty",
                destinationDirectoryURL: runtimePaths.agentShimDirectoryURL,
                replacesExisting: true
            )
            _ = try stageExecutableIfNeeded(
                sourcePath: agentShimExecutablePath,
                stagedFileName: "toastty-agent-shim",
                destinationDirectoryURL: runtimePaths.agentShimDirectoryURL,
                replacesExisting: true
            )

            return ManagedAgentHelperPaths(
                cliExecutablePath: cliExecutablePath,
                agentShimExecutablePath: agentShimExecutablePath
            )
        } catch {
            try? fileManager.removeItem(at: instanceDirectoryURL)
            throw error
        }
    }

    private func stageExecutableIfNeeded(
        sourcePath: String?,
        stagedFileName: String,
        destinationDirectoryURL: URL,
        replacesExisting: Bool = false
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
        let destinationURL = destinationDirectoryURL
            .appendingPathComponent(stagedFileName, isDirectory: false)
            .standardizedFileURL
        if sourceURL.path == destinationURL.path {
            return sourceURL.path
        }

        try fileManager.createDirectory(
            at: destinationDirectoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationDirectoryURL
            .appendingPathComponent(".\(stagedFileName).\(UUID().uuidString).tmp", isDirectory: false)
            .standardizedFileURL
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: temporaryURL.path
            )
            if replacesExisting {
                guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        return destinationURL.path
    }

    private func makeInstanceDirectory() throws -> URL {
        guard processID > 1 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let rootDirectoryURL = runtimePaths.managedAgentHelperInstancesDirectoryURL
        try prepareOwnedDirectory(rootDirectoryURL)

        let directoryURL = rootDirectoryURL.appendingPathComponent(
            instanceDirectoryName(for: instanceIdentifier),
            isDirectory: true
        )
        guard pathExists(at: directoryURL.path) == false else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try validateOwnedDirectory(directoryURL)
            let ownerRecordURL = directoryURL.appendingPathComponent(Self.ownerRecordFileName)
            try Data("\(processID)\n".utf8).write(to: ownerRecordURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerRecordURL.path)
            return directoryURL
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    private func sweepStaleInstanceDirectories() throws {
        let rootDirectoryURL = runtimePaths.managedAgentHelperInstancesDirectoryURL
        guard pathExists(at: rootDirectoryURL.path) else { return }
        try validateOwnedDirectory(rootDirectoryURL)
        guard let childURLs = try? fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directoryURL in childURLs {
            guard isValidInstanceDirectory(directoryURL, rootDirectoryURL: rootDirectoryURL),
                  let ownerProcessID = validatedOwnerProcessID(in: directoryURL),
                  ownerProcessStateProvider(ownerProcessID) == .dead else {
                continue
            }
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    private func isValidInstanceDirectory(_ directoryURL: URL, rootDirectoryURL: URL) -> Bool {
        guard directoryURL.deletingLastPathComponent().standardizedFileURL == rootDirectoryURL.standardizedFileURL,
              directoryURL.lastPathComponent.hasPrefix("instance-"),
              UUID(uuidString: String(directoryURL.lastPathComponent.dropFirst("instance-".count))) != nil else {
            return false
        }
        return (try? validateOwnedDirectory(directoryURL)) != nil
    }

    private func validatedOwnerProcessID(in directoryURL: URL) -> Int32? {
        let ownerRecordURL = directoryURL.appendingPathComponent(Self.ownerRecordFileName)
        let descriptor = open(ownerRecordURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= 64 else {
            return nil
        }

        let byteCount = Int(info.st_size)
        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress, byteCount)
        }
        guard bytesRead == byteCount,
              let value = String(data: data, encoding: .utf8),
              let processID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              processID > 1 else {
            return nil
        }
        return processID
    }

    private func prepareOwnedDirectory(_ directoryURL: URL) throws {
        if pathExists(at: directoryURL.path) == false {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateOwnedDirectory(directoryURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func validateOwnedDirectory(_ directoryURL: URL) throws {
        var info = stat()
        guard lstat(directoryURL.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func pathExists(at path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func instanceDirectoryName(for identifier: UUID) -> String {
        "instance-\(identifier.uuidString.lowercased())"
    }

    private static func ownerProcessState(_ processID: Int32) -> ManagedAgentOwnerProcessState {
        guard processID > 1 else { return .dead }
        if kill(processID, 0) != 0 {
            return errno == ESRCH ? .dead : .unknown
        }
        return .alive
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}
