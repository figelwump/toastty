import Foundation

public struct ToasttyRuntimePaths: Equatable, Sendable {
    public static let environmentKey = "TOASTTY_RUNTIME_HOME"

    private static let configDirectoryName = ".toastty"
    private static let logDirectoryName = "logs"
    private static let runDirectoryName = "run"
    private static let configFileName = "config"
    private static let workspaceLayoutsFileName = "workspace-layout-profiles.json"
    private static let terminalProfilesFileName = "terminal-profiles.toml"
    private static let logFileName = "toastty.log"
    private static let socketFileName = "events-v1.sock"
    private static let runtimeVersionFileName = "runtime-version.txt"
    private static let runtimeVersion = "1"
    private static let instanceFileName = "instance.json"
    private static let defaultsSuitePrefix = "com.GiantThings.toastty.runtime."

    public let runtimeHomeURL: URL?

    private let homeDirectoryPath: String
    private let temporaryDirectoryPath: String

    private init(runtimeHomeURL: URL?, homeDirectoryPath: String, temporaryDirectoryPath: String) {
        self.runtimeHomeURL = runtimeHomeURL
        self.homeDirectoryPath = homeDirectoryPath
        self.temporaryDirectoryPath = temporaryDirectoryPath
    }

    public var isRuntimeHomeEnabled: Bool {
        runtimeHomeURL != nil
    }

    public var configDirectoryURL: URL {
        runtimeHomeURL ?? URL(filePath: homeDirectoryPath)
            .appending(path: Self.configDirectoryName, directoryHint: .isDirectory)
    }

    public var configFileURL: URL {
        configDirectoryURL.appending(path: Self.configFileName, directoryHint: .notDirectory)
    }

    public var workspaceLayoutsFileURL: URL {
        configDirectoryURL.appending(path: Self.workspaceLayoutsFileName, directoryHint: .notDirectory)
    }

    public var terminalProfilesFileURL: URL {
        configDirectoryURL.appending(path: Self.terminalProfilesFileName, directoryHint: .notDirectory)
    }

    public var defaultLogFileURL: URL {
        if let runtimeHomeURL {
            return runtimeHomeURL
                .appending(path: Self.logDirectoryName, directoryHint: .isDirectory)
                .appending(path: Self.logFileName, directoryHint: .notDirectory)
        }

        return URL(filePath: homeDirectoryPath)
            .appending(path: "Library/Logs/Toastty", directoryHint: .isDirectory)
            .appending(path: Self.logFileName, directoryHint: .notDirectory)
    }

    public var automationSocketFileURL: URL? {
        guard let runtimeHomeURL else { return nil }

        let socketDirectoryName = "toastty-runtime-\(Self.stableHashHex(for: runtimeHomeURL.path))"
        return URL(fileURLWithPath: temporaryDirectoryPath, isDirectory: true)
            .appendingPathComponent(socketDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.socketFileName, isDirectory: false)
    }

    public var instanceFileURL: URL? {
        runtimeHomeURL?.appending(path: Self.instanceFileName, directoryHint: .notDirectory)
    }

    public var userDefaultsSuiteName: String? {
        guard let runtimeHomeURL else { return nil }
        return Self.defaultsSuitePrefix + Self.stableHashHex(for: runtimeHomeURL.path)
    }

    public static func resolve(
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ToasttyRuntimePaths {
        ToasttyRuntimePaths(
            runtimeHomeURL: normalizedRuntimeHomeURL(environment: environment),
            homeDirectoryPath: homeDirectoryPath,
            temporaryDirectoryPath: environment["TMPDIR"] ?? NSTemporaryDirectory()
        )
    }

    public func prepare(fileManager: FileManager = .default) throws {
        guard let runtimeHomeURL else { return }

        try fileManager.createDirectory(at: runtimeHomeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: runtimeHomeURL.appending(path: Self.logDirectoryName, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: runtimeHomeURL.appending(path: Self.runDirectoryName, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        if let automationSocketFileURL {
            try fileManager.createDirectory(
                at: automationSocketFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let versionFileURL = runtimeHomeURL.appending(path: Self.runtimeVersionFileName, directoryHint: .notDirectory)
        let expectedContents = Self.runtimeVersion + "\n"
        let existingContents = try? String(contentsOf: versionFileURL, encoding: .utf8)
        if existingContents != expectedContents {
            try expectedContents.write(to: versionFileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func normalizedRuntimeHomeURL(environment: [String: String]) -> URL? {
        guard let rawValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false else {
            return nil
        }

        let expandedPath = (rawValue as NSString).expandingTildeInPath
        return URL(filePath: expandedPath).standardizedFileURL
    }

    private static func stableHashHex(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
