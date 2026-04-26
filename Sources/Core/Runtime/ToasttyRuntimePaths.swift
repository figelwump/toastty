import Foundation

public enum ToasttyRuntimeHomeStrategy: String, Equatable, Sendable {
    case userHome = "user-home"
    case explicitRuntimeHome = "explicit-runtime-home"
    case worktreeDerived = "worktree-derived"
}

public struct ToasttyRuntimePaths: Equatable, Sendable {
    public static let environmentKey = "TOASTTY_RUNTIME_HOME"
    public static let worktreeRootEnvironmentKey = "TOASTTY_DEV_WORKTREE_ROOT"

    private static let configDirectoryName = ".toastty"
    private static let logDirectoryName = "logs"
    private static let runDirectoryName = "run"
    private static let historyDirectoryName = "history"
    private static let paneHistoryDirectoryName = "panes"
    private static let paneJournalDirectoryName = "pane-journals"
    private static let scratchpadDocumentsDirectoryName = "scratchpad-documents"
    private static let artifactsDirectoryName = "artifacts"
    private static let devRunsDirectoryName = "dev-runs"
    private static let worktreeRuntimePrefix = "worktree-"
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
    public let runtimeHomeStrategy: ToasttyRuntimeHomeStrategy
    public let worktreeRootURL: URL?
    public let runtimeLabel: String?

    private let homeDirectoryPath: String
    private let temporaryDirectoryPath: String

    private init(
        runtimeHomeURL: URL?,
        runtimeHomeStrategy: ToasttyRuntimeHomeStrategy,
        worktreeRootURL: URL?,
        runtimeLabel: String?,
        homeDirectoryPath: String,
        temporaryDirectoryPath: String
    ) {
        self.runtimeHomeURL = runtimeHomeURL
        self.runtimeHomeStrategy = runtimeHomeStrategy
        self.worktreeRootURL = worktreeRootURL
        self.runtimeLabel = runtimeLabel
        self.homeDirectoryPath = homeDirectoryPath
        self.temporaryDirectoryPath = temporaryDirectoryPath
    }

    public var isRuntimeHomeEnabled: Bool {
        runtimeHomeStrategy != .userHome
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

    public var agentShimDirectoryURL: URL {
        if let runtimeHomeURL {
            return runtimeHomeURL.appending(path: "bin", directoryHint: .isDirectory)
        }

        return URL(filePath: homeDirectoryPath)
            .appending(path: Self.configDirectoryName, directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
    }

    public var paneHistoryDirectoryURL: URL {
        configDirectoryURL
            .appending(path: Self.historyDirectoryName, directoryHint: .isDirectory)
            .appending(path: Self.paneHistoryDirectoryName, directoryHint: .isDirectory)
    }

    public func paneHistoryFileURL(for panelID: UUID) -> URL {
        paneHistoryDirectoryURL.appending(
            path: "\(panelID.uuidString).history",
            directoryHint: .notDirectory
        )
    }

    public var paneJournalDirectoryURL: URL {
        configDirectoryURL
            .appending(path: Self.historyDirectoryName, directoryHint: .isDirectory)
            .appending(path: Self.paneJournalDirectoryName, directoryHint: .isDirectory)
    }

    public func paneJournalFileURL(for panelID: UUID) -> URL {
        paneJournalDirectoryURL.appending(
            path: "\(panelID.uuidString).journal",
            directoryHint: .notDirectory
        )
    }

    public var scratchpadDocumentsDirectoryURL: URL {
        configDirectoryURL.appending(
            path: Self.scratchpadDocumentsDirectoryName,
            directoryHint: .isDirectory
        )
    }

    public func scratchpadDocumentFileURL(for documentID: UUID) -> URL {
        scratchpadDocumentsDirectoryURL.appending(
            path: "\(documentID.uuidString).json",
            directoryHint: .notDirectory
        )
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
        let explicitRuntimeHomeURL = normalizedRuntimeHomeURL(environment: environment)
        let worktreeRootURL = normalizedWorktreeRootURL(environment: environment)
        let runtimeLabel = worktreeRootURL.map(Self.runtimeLabel(for:))
        let runtimeHomeStrategy: ToasttyRuntimeHomeStrategy
        let runtimeHomeURL: URL?

        if let explicitRuntimeHomeURL {
            runtimeHomeStrategy = .explicitRuntimeHome
            runtimeHomeURL = explicitRuntimeHomeURL
        } else if let worktreeRootURL, let runtimeLabel {
            runtimeHomeStrategy = .worktreeDerived
            runtimeHomeURL = derivedRuntimeHomeURL(worktreeRootURL: worktreeRootURL, runtimeLabel: runtimeLabel)
        } else {
            runtimeHomeStrategy = .userHome
            runtimeHomeURL = nil
        }

        return ToasttyRuntimePaths(
            runtimeHomeURL: runtimeHomeURL,
            runtimeHomeStrategy: runtimeHomeStrategy,
            worktreeRootURL: worktreeRootURL,
            runtimeLabel: runtimeHomeStrategy == .worktreeDerived ? runtimeLabel : nil,
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
        try fileManager.createDirectory(
            at: agentShimDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: paneHistoryDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: paneJournalDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: scratchpadDocumentsDirectoryURL,
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

    private static func normalizedWorktreeRootURL(environment: [String: String]) -> URL? {
        guard let rawValue = environment[worktreeRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false else {
            return nil
        }

        let expandedPath = (rawValue as NSString).expandingTildeInPath
        return URL(filePath: expandedPath).standardizedFileURL
    }

    private static func derivedRuntimeHomeURL(worktreeRootURL: URL, runtimeLabel: String) -> URL {
        worktreeRootURL
            .appending(path: artifactsDirectoryName, directoryHint: .isDirectory)
            .appending(path: devRunsDirectoryName, directoryHint: .isDirectory)
            .appending(path: worktreeRuntimePrefix + runtimeLabel, directoryHint: .isDirectory)
            .appending(path: "runtime-home", directoryHint: .isDirectory)
    }

    private static func runtimeLabel(for worktreeRootURL: URL) -> String {
        let basename = sanitizedLabelComponent(worktreeRootURL.lastPathComponent)
        let shortHash = String(stableHashHex(for: worktreeRootURL.path).prefix(8))
        return "\(basename)-\(shortHash)"
    }

    private static func sanitizedLabelComponent(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let mapped = folded.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "worktree" : collapsed
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
