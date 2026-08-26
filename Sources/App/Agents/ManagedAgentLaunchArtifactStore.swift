import CoreState
import Darwin
import Foundation
import RemoteProtocol

enum ManagedAgentLaunchArtifactLifetime: Equatable {
    case session
    case agentProcess
}

enum ManagedAgentLaunchArtifactStorage: Equatable {
    case temporary
    case durable
}

struct ManagedAgentLaunchArtifactDirectory: Equatable {
    let directoryURL: URL
    let ownerRecordURL: URL?
    let lifetime: ManagedAgentLaunchArtifactLifetime
    let storage: ManagedAgentLaunchArtifactStorage
}

enum ManagedAgentOwnerProcessState: Equatable {
    case alive
    case dead
    case unknown
}

/// Owns per-launch files that an agent can revisit after launch. Durable
/// directories live below Toastty's runtime home so macOS cannot purge them as
/// temporary files. Cleanup is deliberately conservative: a directory is
/// removed only after its Toastty session is inactive and its recorded owner
/// PID is proven absent. A live PID is always preserved, even if it may have
/// been reused, because avoiding premature deletion is more important than
/// eager cleanup.
final class ManagedAgentLaunchArtifactStore {
    static let metadataFileName = ".toastty-launch-artifacts.json"
    static let ownerRecordFileName = ".owner-pid"
    static let defaultCleanupGraceInterval: TimeInterval = 10 * 60

    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let ownerProcessStateProvider: @Sendable (Int32) -> ManagedAgentOwnerProcessState
    private let cleanupGraceInterval: TimeInterval

    init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        ownerProcessStateProvider: @escaping @Sendable (Int32) -> ManagedAgentOwnerProcessState =
            ManagedAgentLaunchArtifactStore.ownerProcessState,
        cleanupGraceInterval: TimeInterval = ManagedAgentLaunchArtifactStore.defaultCleanupGraceInterval
    ) {
        self.rootDirectoryURL = runtimePaths.managedAgentLaunchArtifactsDirectoryURL
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.ownerProcessStateProvider = ownerProcessStateProvider
        self.cleanupGraceInterval = cleanupGraceInterval
    }

    init(
        rootDirectoryURL: URL,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        ownerProcessStateProvider: @escaping @Sendable (Int32) -> ManagedAgentOwnerProcessState =
            ManagedAgentLaunchArtifactStore.ownerProcessState,
        cleanupGraceInterval: TimeInterval = ManagedAgentLaunchArtifactStore.defaultCleanupGraceInterval
    ) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.ownerProcessStateProvider = ownerProcessStateProvider
        self.cleanupGraceInterval = cleanupGraceInterval
    }

    func makeDirectory(
        agent: AgentKind,
        sessionID: String,
        lifetime: ManagedAgentLaunchArtifactLifetime
    ) throws -> ManagedAgentLaunchArtifactDirectory {
        guard lifetime == .agentProcess else {
            return ManagedAgentLaunchArtifactDirectory(
                directoryURL: try makeTemporaryDirectory(agent: agent, sessionID: sessionID),
                ownerRecordURL: nil,
                lifetime: lifetime,
                storage: .temporary
            )
        }

        do {
            return try makeDurableDirectory(agent: agent, sessionID: sessionID)
        } catch {
            ToasttyLog.warning(
                "Falling back to temporary managed-agent launch artifacts",
                category: .automation,
                metadata: [
                    "agent": agent.rawValue,
                    "session_id": sessionID,
                    "error": error.localizedDescription,
                ]
            )
            let directoryURL = try makeTemporaryDirectory(agent: agent, sessionID: sessionID)
            return ManagedAgentLaunchArtifactDirectory(
                directoryURL: directoryURL,
                ownerRecordURL: directoryURL.appendingPathComponent(Self.ownerRecordFileName),
                lifetime: lifetime,
                storage: .temporary
            )
        }
    }

    /// Removes a launch that was prepared but never dispatched. This is the
    /// only forced cleanup path; normal session-stop cleanup always uses
    /// `sweep(activeSessionIDs:)` and process-liveness proof.
    func removeAbandoned(_ artifacts: ManagedAgentLaunchArtifactDirectory) {
        switch artifacts.storage {
        case .temporary:
            try? fileManager.removeItem(at: artifacts.directoryURL)
        case .durable:
            guard let metadata = validatedMetadata(for: artifacts.directoryURL),
                  metadata.sessionID == sessionID(fromDirectoryName: artifacts.directoryURL.lastPathComponent) else {
                return
            }
            try? fileManager.removeItem(at: artifacts.directoryURL)
        }
    }

    func sweep(activeSessionIDs: Set<String>) {
        guard validateExistingRootDirectory() else { return }
        guard let childURLs = try? fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = nowProvider()
        for directoryURL in childURLs {
            guard let metadata = validatedMetadata(for: directoryURL),
                  activeSessionIDs.contains(metadata.sessionID) == false,
                  let owner = validatedOwnerRecord(in: directoryURL),
                  now.timeIntervalSince(owner.observedAt) >= cleanupGraceInterval else {
                continue
            }

            switch ownerProcessStateProvider(owner.processID) {
            case .dead:
                try? fileManager.removeItem(at: directoryURL)
            case .alive, .unknown:
                continue
            }
        }
    }

    private func makeDurableDirectory(
        agent: AgentKind,
        sessionID: String
    ) throws -> ManagedAgentLaunchArtifactDirectory {
        guard UUID(uuidString: sessionID) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try prepareOwnedDirectory(rootDirectoryURL)

        let directoryURL = rootDirectoryURL.appendingPathComponent(
            directoryName(agent: agent, sessionID: sessionID),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: directoryURL.path) == false else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try validateOwnedDirectory(directoryURL)
            let metadata = Metadata(
                schemaVersion: 1,
                sessionID: sessionID,
                agent: agent.rawValue,
                createdAt: nowProvider()
            )
            let metadataURL = directoryURL.appendingPathComponent(Self.metadataFileName)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
            return ManagedAgentLaunchArtifactDirectory(
                directoryURL: directoryURL,
                ownerRecordURL: directoryURL.appendingPathComponent(Self.ownerRecordFileName),
                lifetime: .agentProcess,
                storage: .durable
            )
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    private func makeTemporaryDirectory(agent: AgentKind, sessionID: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-\(agent.rawValue)-launch-\(sessionID)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func prepareOwnedDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) == false {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateOwnedDirectory(url)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validateExistingRootDirectory() -> Bool {
        guard fileManager.fileExists(atPath: rootDirectoryURL.path) else { return false }
        return (try? validateOwnedDirectory(rootDirectoryURL)) != nil
    }

    private func validateOwnedDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func validatedMetadata(for directoryURL: URL) -> Metadata? {
        guard directoryURL.deletingLastPathComponent().standardizedFileURL == rootDirectoryURL,
              (try? validateOwnedDirectory(directoryURL)) != nil,
              let expectedSessionID = sessionID(fromDirectoryName: directoryURL.lastPathComponent),
              let file = readOwnedRegularFile(
                at: directoryURL.appendingPathComponent(Self.metadataFileName),
                maximumByteCount: 16 * 1024
              ),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: file.data),
              metadata.schemaVersion == 1,
              metadata.sessionID == expectedSessionID,
              directoryURL.lastPathComponent == directoryName(agentName: metadata.agent, sessionID: metadata.sessionID) else {
            return nil
        }
        return metadata
    }

    private func validatedOwnerRecord(in directoryURL: URL) -> OwnerRecord? {
        let ownerURL = directoryURL.appendingPathComponent(Self.ownerRecordFileName)
        guard let file = readOwnedRegularFile(at: ownerURL, maximumByteCount: 64),
              let value = String(data: file.data, encoding: .utf8),
              let processID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              processID > 1 else {
            return nil
        }
        return OwnerRecord(processID: processID, observedAt: file.modificationDate)
    }

    private func readOwnedRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) -> (data: Data, modificationDate: Date)? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= off_t(maximumByteCount) else {
            return nil
        }

        let byteCount = Int(info.st_size)
        var data = Data(count: byteCount)
        if byteCount > 0 {
            let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, baseAddress, byteCount)
            }
            guard bytesRead == byteCount else { return nil }
        }
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return (data, modificationDate)
    }

    private func directoryName(agent: AgentKind, sessionID: String) -> String {
        directoryName(agentName: agent.rawValue, sessionID: sessionID)
    }

    private func directoryName(agentName: String, sessionID: String) -> String {
        "toastty-\(agentName)-launch-\(sessionID)"
    }

    private func sessionID(fromDirectoryName name: String) -> String? {
        for agent in [AgentKind.claude, .codex] {
            let prefix = "toastty-\(agent.rawValue)-launch-"
            guard name.hasPrefix(prefix) else { continue }
            let sessionID = String(name.dropFirst(prefix.count))
            return UUID(uuidString: sessionID) == nil ? nil : sessionID
        }
        return nil
    }

    private static func ownerProcessState(_ processID: Int32) -> ManagedAgentOwnerProcessState {
        guard processID > 1 else { return .dead }
        if kill(processID, 0) != 0 {
            return errno == ESRCH ? .dead : .unknown
        }
        return .alive
    }
}

private extension ManagedAgentLaunchArtifactStore {
    struct Metadata: Codable {
        let schemaVersion: Int
        let sessionID: String
        let agent: String
        let createdAt: Date
    }

    struct OwnerRecord {
        let processID: Int32
        let observedAt: Date
    }
}
