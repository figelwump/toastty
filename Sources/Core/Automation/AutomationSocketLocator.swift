import Darwin
import Foundation

struct AutomationSocketDiscoveryRecord: Codable, Equatable, Sendable {
    let socketPath: String
    let processID: Int32
}

public enum AutomationSocketLocator {
    public static func resolveClientSocketPath(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String {
        if let explicitPath = explicitSocketPath(in: environment) {
            return explicitPath
        }

        if let record = readDiscoveryRecord(environment: environment, fileManager: fileManager),
           discoveryRecordIsUsable(
               record,
               fileManager: fileManager,
               processIsAlive: isProcessAlive(processID:)
           ) {
            return record.socketPath
        }

        if let liveSocketPath = latestLiveSocketPath(
            environment: environment,
            fileManager: fileManager,
            processIsAlive: isProcessAlive(processID:)
        ) {
            return liveSocketPath
        }

        return legacySocketPath(environment: environment)
    }

    public static func resolveServerSocketPath(
        environment: [String: String],
        processID: Int32 = getpid()
    ) -> String {
        if let explicitPath = explicitSocketPath(in: environment) {
            return explicitPath
        }

        return socketDirectoryURL(environment: environment)
            .appendingPathComponent("events-v1-\(processID).sock", isDirectory: false)
            .path
    }

    public static func writeDiscoveryRecord(
        socketPath: String,
        processID: Int32,
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws {
        let directoryURL = socketDirectoryURL(environment: environment)
        try AutomationSocketDirectory.prepareSocketDirectory(at: directoryURL, fileManager: fileManager)

        let record = AutomationSocketDiscoveryRecord(socketPath: socketPath, processID: processID)
        let data = try JSONEncoder().encode(record)
        let recordURL = discoveryRecordURL(environment: environment)
        try data.write(to: recordURL, options: [.atomic])
        _ = chmod(recordURL.path, 0o600)
    }

    public static func removeDiscoveryRecordIfOwned(
        socketPath: String,
        processID: Int32,
        environment: [String: String],
        fileManager: FileManager = .default
    ) {
        guard let record = readDiscoveryRecord(environment: environment, fileManager: fileManager),
              record.socketPath == socketPath,
              record.processID == processID else {
            return
        }

        try? fileManager.removeItem(at: discoveryRecordURL(environment: environment))
    }

    static func readDiscoveryRecord(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> AutomationSocketDiscoveryRecord? {
        // A record in a directory another user controls could point anywhere.
        guard AutomationSocketDirectory.isTrustedDirectory(
            atPath: socketDirectoryURL(environment: environment).path
        ) else {
            return nil
        }
        let recordURL = discoveryRecordURL(environment: environment)
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(AutomationSocketDiscoveryRecord.self, from: data) else {
            return nil
        }
        return record
    }

    static func discoveryRecordIsUsable(
        _ record: AutomationSocketDiscoveryRecord,
        fileManager: FileManager = .default,
        processIsAlive: (Int32) -> Bool
    ) -> Bool {
        guard processIsAlive(record.processID) else {
            return false
        }
        return AutomationSocketDirectory.isOwnedByCurrentUser(atPath: record.socketPath) == true
    }

    static func latestLiveSocketPath(
        environment: [String: String],
        fileManager: FileManager = .default,
        processIsAlive: (Int32) -> Bool
    ) -> String? {
        let directoryURL = socketDirectoryURL(environment: environment)
        guard AutomationSocketDirectory.isTrustedDirectory(atPath: directoryURL.path),
              let candidateURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return candidateURLs
            .compactMap { candidateSocketInfo(for: $0, fileManager: fileManager, processIsAlive: processIsAlive) }
            .max(by: { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.path < rhs.path
                }
                return lhs.modifiedAt < rhs.modifiedAt
            })?
            .path
    }

    static func discoveryRecordURL(environment: [String: String]) -> URL {
        socketDirectoryURL(environment: environment)
            .appendingPathComponent(discoveryRecordFilename, isDirectory: false)
    }

    public static func socketDirectoryURL(environment: [String: String]) -> URL {
        #if os(Linux)
        // $XDG_RUNTIME_DIR is already per-user (0700), so no uid suffix.
        if let runtimeDirectory = ToasttyRuntimePaths.linuxXDGRuntimeDirectoryPath(environment: environment) {
            return URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
                .appendingPathComponent("toastty", isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: ToasttyRuntimePaths.socketBaseDirectoryPath(environment: environment), isDirectory: true)
            .appendingPathComponent("toastty-\(getuid())", isDirectory: true)
    }

    static func legacySocketPath(environment: [String: String]) -> String {
        socketDirectoryURL(environment: environment)
            .appendingPathComponent("events-v1.sock", isDirectory: false)
            .path
    }

    private static func explicitSocketPath(in environment: [String: String]) -> String? {
        guard let value = environment[ToasttyLaunchContextEnvironment.socketPathKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private static func candidateSocketInfo(
        for url: URL,
        fileManager: FileManager,
        processIsAlive: (Int32) -> Bool
    ) -> CandidateSocketInfo? {
        let filename = url.lastPathComponent
        guard filename.hasPrefix(socketFilenamePrefix),
              filename.hasSuffix(socketFilenameSuffix) else {
            return nil
        }

        let pidSubstring = filename
            .dropFirst(socketFilenamePrefix.count)
            .dropLast(socketFilenameSuffix.count)
        guard let processID = Int32(pidSubstring),
              processIsAlive(processID),
              AutomationSocketDirectory.isOwnedByCurrentUser(atPath: url.path) == true else {
            return nil
        }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return CandidateSocketInfo(
            path: url.path,
            modifiedAt: resourceValues?.contentModificationDate ?? .distantPast
        )
    }

    private static func isProcessAlive(processID: Int32) -> Bool {
        guard processID > 0 else {
            return false
        }

        if kill(processID, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    private static let discoveryRecordFilename = "current-socket.json"
    private static let socketFilenamePrefix = "events-v1-"
    private static let socketFilenameSuffix = ".sock"

    private struct CandidateSocketInfo: Equatable {
        let path: String
        let modifiedAt: Date
    }
}
