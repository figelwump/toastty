import Darwin
import Foundation

public enum ToasttyLogLevel: String, CaseIterable, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug:
            return 10
        case .info:
            return 20
        case .warning:
            return 30
        case .error:
            return 40
        }
    }

    public static func < (lhs: ToasttyLogLevel, rhs: ToasttyLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ToasttyLogCategory: String, Sendable {
    case app
    case bootstrap
    case store
    case reducer
    case terminal
    case ghostty
    case input
    case automation
    case state
    case notifications
}

public struct ToasttyLogConfiguration: Sendable, Equatable {
    public let enabled: Bool
    public let minimumLevel: ToasttyLogLevel
    public let filePath: String?
    public let mirrorToStderr: Bool
    public let maxFileSizeBytes: UInt64

    public init(
        enabled: Bool,
        minimumLevel: ToasttyLogLevel,
        filePath: String?,
        mirrorToStderr: Bool,
        maxFileSizeBytes: UInt64 = 5_000_000
    ) {
        self.enabled = enabled
        self.minimumLevel = minimumLevel
        self.filePath = filePath
        self.mirrorToStderr = mirrorToStderr
        self.maxFileSizeBytes = maxFileSizeBytes
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> ToasttyLogConfiguration {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryPath,
            environment: environment
        )
        let enabled = !truthy(environment["TOASTTY_LOG_DISABLE"])
        let minimumLevel = parseLogLevel(environment["TOASTTY_LOG_LEVEL"]) ?? .info
        let mirrorToStderr = truthy(environment["TOASTTY_LOG_STDERR"])

        let filePath: String?
        let rawLogFilePath = environment["TOASTTY_LOG_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawPath = rawLogFilePath,
           rawPath.isEmpty == false,
           rawPath.lowercased() != "none" {
            filePath = rawPath
        } else if truthy(environment["TOASTTY_LOG_TO_FILE"]) {
            filePath = runtimePaths.defaultLogFileURL.path
        } else if environment["TOASTTY_LOG_FILE"] == nil,
                  isRunningUnderXCTest(environment) == false {
            filePath = runtimePaths.defaultLogFileURL.path
        } else {
            filePath = nil
        }

        return ToasttyLogConfiguration(
            enabled: enabled,
            minimumLevel: minimumLevel,
            filePath: filePath,
            mirrorToStderr: mirrorToStderr
        )
    }

    private static func parseLogLevel(_ value: String?) -> ToasttyLogLevel? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return ToasttyLogLevel(rawValue: normalized)
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }

    private static func isRunningUnderXCTest(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil
    }
}

public enum ToasttyLog {
    private static let writer = ToasttyLogWriter(configuration: .fromEnvironment())

    public static func configurationSummary() -> [String: String] {
        writer.configurationSummary()
    }

    public static func debug(
        _ message: @autoclosure () -> String,
        category: ToasttyLogCategory = .app,
        metadata: @autoclosure () -> [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        log(.debug, message: message, category: category, metadata: metadata, file: file, line: line)
    }

    public static func info(
        _ message: @autoclosure () -> String,
        category: ToasttyLogCategory = .app,
        metadata: @autoclosure () -> [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        log(.info, message: message, category: category, metadata: metadata, file: file, line: line)
    }

    public static func warning(
        _ message: @autoclosure () -> String,
        category: ToasttyLogCategory = .app,
        metadata: @autoclosure () -> [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        log(.warning, message: message, category: category, metadata: metadata, file: file, line: line)
    }

    public static func error(
        _ message: @autoclosure () -> String,
        category: ToasttyLogCategory = .app,
        metadata: @autoclosure () -> [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        log(.error, message: message, category: category, metadata: metadata, file: file, line: line)
    }

    private static func log(
        _ level: ToasttyLogLevel,
        message: () -> String,
        category: ToasttyLogCategory,
        metadata: () -> [String: String],
        file: StaticString,
        line: UInt
    ) {
        guard writer.shouldWrite(level) else { return }
        writer.write(
            level: level,
            category: category,
            message: message(),
            metadata: metadata(),
            source: "\(file):\(line)"
        )
    }
}

final class ToasttyLogWriter: @unchecked Sendable {
    private let configuration: ToasttyLogConfiguration
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var rotationLockDescriptor: Int32 = -1
    private var didReportFileSinkFailure = false
    private let formatter = ISO8601DateFormatter()

    init(configuration: ToasttyLogConfiguration) {
        self.configuration = configuration
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit {
        try? fileHandle?.close()
        if rotationLockDescriptor >= 0 {
            Darwin.close(rotationLockDescriptor)
        }
    }

    func configurationSummary() -> [String: String] {
        let runtimePaths = ToasttyRuntimePaths.resolve()
        var summary = [
            "enabled": configuration.enabled ? "true" : "false",
            "minimum_level": configuration.minimumLevel.rawValue,
            "file_path": configuration.filePath ?? "",
            "stderr": configuration.mirrorToStderr ? "true" : "false",
            "runtime_home": runtimePaths.runtimeHomeURL?.path ?? "",
        ]
        if let defaultsSuiteName = runtimePaths.userDefaultsSuiteName {
            summary["defaults_suite"] = defaultsSuiteName
        }
        return summary
    }

    func shouldWrite(_ level: ToasttyLogLevel) -> Bool {
        configuration.enabled && level >= configuration.minimumLevel
    }

    func write(
        level: ToasttyLogLevel,
        category: ToasttyLogCategory,
        message: String,
        metadata: [String: String],
        source: String
    ) {
        guard configuration.enabled else { return }
        guard level >= configuration.minimumLevel else { return }

        let timestamp: String
        lock.lock()
        timestamp = formatter.string(from: Date())
        lock.unlock()

        var payload: [String: Any] = [
            "timestamp": timestamp,
            "level": level.rawValue,
            "category": category.rawValue,
            "message": message,
            "source": source,
        ]
        if metadata.isEmpty == false {
            payload["metadata"] = metadata
        }

        let line = Self.serialize(payload: payload)
        guard let lineData = "\(line)\n".data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        prepareFileHandleForWrite(incomingByteCount: UInt64(lineData.count))
        if let handle = fileHandle {
            do {
                if #available(macOS 10.15.4, *) {
                    try handle.write(contentsOf: lineData)
                } else {
                    handle.write(lineData)
                }
            } catch {
                closeFileHandle()
                reportFileSinkFailureOnce("write_failed")
            }
        }

        if configuration.mirrorToStderr,
           let stderrData = "\(line)\n".data(using: .utf8) {
            FileHandle.standardError.write(stderrData)
        }
    }

    private static func serialize(payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"level\":\"error\",\"category\":\"state\",\"message\":\"failed to serialize log payload\"}"
        }
        return line
    }

    private func prepareFileHandleForWrite(incomingByteCount: UInt64) {
        guard let filePath = configuration.filePath else { return }
        let fileURL = URL(fileURLWithPath: filePath)

        do {
            try reopenFileHandleIfNeeded(fileURL: fileURL)
        } catch {
            closeFileHandle()
            reportFileSinkFailureOnce("open_failed")
            return
        }

        guard shouldRotate(
            fileURL: fileURL,
            incomingByteCount: incomingByteCount,
            maxBytes: configuration.maxFileSizeBytes
        ) else {
            return
        }

        let rotationResult = withRotationLock(fileURL: fileURL) {
            rotateIfStillNeeded(fileURL: fileURL, incomingByteCount: incomingByteCount)
        }
        switch rotationResult {
        case .acquired:
            return
        case .contended:
            // Rotation is already in progress elsewhere. Keep logging and let
            // the next record retry; an identity check first avoids retaining
            // a handle that the competing writer already moved.
            try? reopenFileHandleIfNeeded(fileURL: fileURL)
        case .unavailable:
            // A broken or unwritable lock path must not permit unbounded log
            // growth. Fall back to the pre-coordination behavior under this
            // process's NSLock; rotation remains best-effort across processes.
            rotateIfStillNeeded(fileURL: fileURL, incomingByteCount: incomingByteCount)
        }
    }

    private func rotateIfStillNeeded(fileURL: URL, incomingByteCount: UInt64) {
        do {
            // A competing writer may have rotated while this writer was
            // acquiring the lock. Rebind and recheck before replacing the
            // one retained archive.
            try reopenFileHandleIfNeeded(fileURL: fileURL)
            guard shouldRotate(
                fileURL: fileURL,
                incomingByteCount: incomingByteCount,
                maxBytes: configuration.maxFileSizeBytes
            ) else {
                return
            }
            closeFileHandle()
            try Self.rotate(fileURL: fileURL)
            try reopenFileHandleIfNeeded(fileURL: fileURL)
        } catch {
            closeFileHandle()
            reportFileSinkFailureOnce("rotation_failed")
            try? reopenFileHandleIfNeeded(fileURL: fileURL)
        }
    }

    private func reopenFileHandleIfNeeded(fileURL: URL) throws {
        if let handle = fileHandle,
           let handleIdentity = Self.fileIdentity(descriptor: handle.fileDescriptor),
           let pathIdentity = Self.fileIdentity(path: fileURL.path),
           handleIdentity == pathIdentity {
            return
        }
        closeFileHandle()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = Self.openFile(
            path: fileURL.path,
            flags: O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ToasttyLogFileError.openFailed
        }
        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func shouldRotate(
        fileURL: URL,
        incomingByteCount: UInt64,
        maxBytes: UInt64
    ) -> Bool {
        guard let fileSize = Self.fileSize(path: fileURL.path), fileSize > 0 else {
            // Always accept one record into an empty file, even when that
            // single record is larger than the configured limit.
            return false
        }
        let (projectedSize, overflowed) = fileSize.addingReportingOverflow(incomingByteCount)
        return overflowed || projectedSize > maxBytes
    }

    private static func rotate(fileURL: URL) throws {
        let archivedURL = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        let result = fileURL.path.withCString { currentPath in
            archivedURL.path.withCString { archivedPath in
                Darwin.rename(currentPath, archivedPath)
            }
        }
        guard result != 0 else { return }
        let errorCode = errno
        if errorCode == ENOENT {
            return
        }
        throw ToasttyLogFileError.rotationFailed(errorCode)
    }

    private func withRotationLock(fileURL: URL, _ body: () -> Void) -> RotationLockResult {
        if rotationLockDescriptor < 0 {
            let lockURL = fileURL.appendingPathExtension("lock")
            rotationLockDescriptor = Self.openFile(
                path: lockURL.path,
                flags: O_RDWR | O_CREAT | O_CLOEXEC
            )
            guard rotationLockDescriptor >= 0 else {
                reportFileSinkFailureOnce("rotation_lock_unavailable")
                return .unavailable
            }
        }

        guard Darwin.lockf(rotationLockDescriptor, F_TLOCK, 0) == 0 else {
            let errorCode = errno
            if errorCode == EACCES || errorCode == EAGAIN {
                return .contended
            }
            Darwin.close(rotationLockDescriptor)
            rotationLockDescriptor = -1
            reportFileSinkFailureOnce("rotation_lock_failed")
            return .unavailable
        }
        // lockf ownership is process-scoped; the surrounding NSLock is what
        // serializes this process, while lockf coordinates sibling processes.
        defer { _ = Darwin.lockf(rotationLockDescriptor, F_ULOCK, 0) }
        body()
        return .acquired
    }

    private func closeFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func reportFileSinkFailureOnce(_ reason: String) {
        guard didReportFileSinkFailure == false else { return }
        didReportFileSinkFailure = true
        let message = "Toastty file logging issue (\(reason)); later records will retry.\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }

    private struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    private static func fileIdentity(descriptor: Int32) -> FileIdentity? {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func fileIdentity(path: String) -> FileIdentity? {
        var info = stat()
        let result = path.withCString { Darwin.fstatat(AT_FDCWD, $0, &info, 0) }
        guard result == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func fileSize(path: String) -> UInt64? {
        var info = stat()
        let result = path.withCString { Darwin.fstatat(AT_FDCWD, $0, &info, 0) }
        guard result == 0 else { return nil }
        return UInt64(max(0, info.st_size))
    }

    private static func openFile(path: String, flags: Int32) -> Int32 {
        path.withCString { Darwin.open($0, flags, S_IRUSR | S_IWUSR) }
    }

    private enum ToasttyLogFileError: Error {
        case openFailed
        case rotationFailed(Int32)
    }

    private enum RotationLockResult {
        case acquired
        case contended
        case unavailable
    }
}
