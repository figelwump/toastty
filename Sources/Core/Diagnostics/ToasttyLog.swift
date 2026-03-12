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
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ToasttyLogConfiguration {
        let enabled = !truthy(environment["TOASTTY_LOG_DISABLE"])
        let minimumLevel = parseLogLevel(environment["TOASTTY_LOG_LEVEL"]) ?? .info
        let mirrorToStderr = truthy(environment["TOASTTY_LOG_STDERR"])

        let filePath: String?
        if let rawPath = environment["TOASTTY_LOG_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           rawPath.isEmpty == false,
           rawPath.lowercased() != "none" {
            filePath = rawPath
        } else if truthy(environment["TOASTTY_LOG_TO_FILE"]) {
            filePath = defaultLogPath()
        } else if environment["TOASTTY_LOG_FILE"] == nil {
            filePath = defaultLogPath()
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

    private static func defaultLogPath() -> String {
        let fileManager = FileManager.default
        if let libraryDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            return libraryDirectory
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Toastty", isDirectory: true)
                .appendingPathComponent("toastty.log", isDirectory: false)
                .path
        }

        return URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Logs/Toastty", directoryHint: .isDirectory)
            .appending(path: "toastty.log", directoryHint: .notDirectory)
            .path
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
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

private final class ToasttyLogWriter: @unchecked Sendable {
    private let configuration: ToasttyLogConfiguration
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let formatter = ISO8601DateFormatter()

    init(configuration: ToasttyLogConfiguration) {
        self.configuration = configuration
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if configuration.enabled {
            fileHandle = Self.openLogFileIfConfigured(configuration)
        }
    }

    func configurationSummary() -> [String: String] {
        [
            "enabled": configuration.enabled ? "true" : "false",
            "minimum_level": configuration.minimumLevel.rawValue,
            "file_path": configuration.filePath ?? "",
            "stderr": configuration.mirrorToStderr ? "true" : "false",
        ]
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

        if fileHandle == nil {
            fileHandle = Self.openLogFileIfConfigured(configuration)
        }
        if let handle = fileHandle {
            do {
                if #available(macOS 10.15.4, *) {
                    try handle.write(contentsOf: lineData)
                } else {
                    handle.write(lineData)
                }
            } catch {
                self.fileHandle = nil
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

    private static func openLogFileIfConfigured(_ configuration: ToasttyLogConfiguration) -> FileHandle? {
        guard let filePath = configuration.filePath else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: filePath)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rotateIfOversized(fileURL: fileURL, maxBytes: configuration.maxFileSizeBytes)
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            return handle
        } catch {
            return nil
        }
    }

    private static func rotateIfOversized(fileURL: URL, maxBytes: UInt64) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > maxBytes else {
            return
        }

        let archivedURL = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        if FileManager.default.fileExists(atPath: archivedURL.path) {
            try FileManager.default.removeItem(at: archivedURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: archivedURL)
    }
}
