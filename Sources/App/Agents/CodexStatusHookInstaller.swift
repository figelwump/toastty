import Foundation

enum CodexStatusHookInstallState: String, Equatable, Sendable {
    case notInstalled
    case needsUpdate
    case installed
}

enum CodexStatusHookSetupRequirement: String, Equatable, Sendable {
    case none
    case automaticMaintenance
    case userSetup
}

struct CodexStatusHookInstallStatus: Equatable, Sendable {
    let hooksFileURL: URL
    let forwarderScriptURL: URL
    let state: CodexStatusHookInstallState
    let setupRequirement: CodexStatusHookSetupRequirement

    init(
        hooksFileURL: URL,
        forwarderScriptURL: URL,
        state: CodexStatusHookInstallState,
        setupRequirement: CodexStatusHookSetupRequirement? = nil
    ) {
        self.hooksFileURL = hooksFileURL
        self.forwarderScriptURL = forwarderScriptURL
        self.state = state
        self.setupRequirement = setupRequirement ?? Self.defaultSetupRequirement(for: state)
    }

    var isInstalled: Bool {
        state == .installed
    }

    var requiresLaunchPreflightWarning: Bool {
        setupRequirement == .userSetup
    }

    var needsAutomaticMaintenance: Bool {
        setupRequirement == .automaticMaintenance
    }

    private static func defaultSetupRequirement(
        for state: CodexStatusHookInstallState
    ) -> CodexStatusHookSetupRequirement {
        switch state {
        case .installed:
            return .none
        case .notInstalled, .needsUpdate:
            return .userSetup
        }
    }
}

struct CodexStatusHookInstallResult: Equatable, Sendable {
    let status: CodexStatusHookInstallStatus
    let hooksFileChanged: Bool
    let forwarderScriptChanged: Bool
}

enum CodexStatusHookInstallerError: LocalizedError, Equatable {
    case unsupportedCodexHome(String)
    case hooksFileNotJSONObject(String)
    case unableToReadHooksFile(String)
    case unableToWriteHooksFile(String)
    case unableToWriteForwarder(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCodexHome(let path):
            return "Codex home must be an absolute path: \(path)"
        case .hooksFileNotJSONObject(let path):
            return "Codex hooks file must contain a JSON object: \(path)"
        case .unableToReadHooksFile(let path):
            return "Unable to read Codex hooks file: \(path)"
        case .unableToWriteHooksFile(let path):
            return "Unable to write Codex hooks file: \(path)"
        case .unableToWriteForwarder(let path):
            return "Unable to write Toastty Codex hook forwarder: \(path)"
        }
    }
}

final class CodexStatusHookInstaller {
    private static let installLock = NSLock()
    private static let hookEventNames = CodexSessionIntegrationContract.hookDefinitions.map(\.event.rawValue)
    private static let legacyHookEventNames = [
        "PostToolUse",
    ]
    private let homeDirectoryPath: String
    private let codexHomePath: String?
    private let fileManager: FileManager

    init(
        homeDirectoryPath: String = NSHomeDirectory(),
        codexHomePath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.homeDirectoryPath = homeDirectoryPath
        self.codexHomePath = codexHomePath
        self.fileManager = fileManager
    }

    func installationStatus() throws -> CodexStatusHookInstallStatus {
        let hooksFileURL = try self.hooksFileURL()
        let forwarderScriptURL = forwarderScriptURL()
        let expectedForwarder = Self.forwarderScriptContents(logFilePath: telemetryFailureLogURL().path)
        let expectedCommand = Self.hookCommand(forwarderScriptURL: forwarderScriptURL)

        let hasOwnedHooks: Bool
        if fileManager.fileExists(atPath: hooksFileURL.path) {
            let object = try readHooksJSONObject(from: hooksFileURL)
            hasOwnedHooks = Self.containsOwnedToasttyHooks(in: object, expectedCommand: expectedCommand)
        } else {
            hasOwnedHooks = false
        }
        let hasCurrentForwarder = Self.forwarderScriptIsCurrent(
            at: forwarderScriptURL,
            expectedForwarder: expectedForwarder
        )

        let state: CodexStatusHookInstallState
        let setupRequirement: CodexStatusHookSetupRequirement
        if hasCurrentForwarder, hasOwnedHooks == false {
            state = .installed
            setupRequirement = .none
        } else {
            state = .needsUpdate
            // Refreshing the stable forwarder is always safe. Removing working
            // global hooks waits for explicit Codex integration setup.
            setupRequirement = hasCurrentForwarder ? .userSetup : .automaticMaintenance
        }

        return CodexStatusHookInstallStatus(
            hooksFileURL: hooksFileURL,
            forwarderScriptURL: forwarderScriptURL,
            state: state,
            setupRequirement: setupRequirement
        )
    }

    func install() throws -> CodexStatusHookInstallResult {
        try prepareSessionIntegrationMigration()
    }

    /// Explicit setup migration: maintain the stable forwarder and remove only
    /// Toastty-owned current or legacy global hook entries. This never adds a
    /// global hook.
    func prepareSessionIntegrationMigration() throws -> CodexStatusHookInstallResult {
        try Self.withInstallLock {
            try prepareSessionIntegrationMigrationWithLockHeld()
        }
    }

    func performAutomaticMaintenanceIfNeeded() throws -> CodexStatusHookInstallResult? {
        let status = try installationStatus()
        guard status.needsAutomaticMaintenance else {
            return nil
        }
        return try maintainForwarder()
    }

    func maintainForwarder() throws -> CodexStatusHookInstallResult {
        try Self.withInstallLock {
            let forwarderScriptURL = forwarderScriptURL()
            let expectedForwarder = Self.forwarderScriptContents(logFilePath: telemetryFailureLogURL().path)
            let changed = try writeForwarderIfNeeded(expectedForwarder, to: forwarderScriptURL)
            return CodexStatusHookInstallResult(
                status: try installationStatus(),
                hooksFileChanged: false,
                forwarderScriptChanged: changed
            )
        }
    }

    func legacyGlobalHooksPresent() throws -> Bool {
        let hooksFileURL = try self.hooksFileURL()
        guard fileManager.fileExists(atPath: hooksFileURL.path) else { return false }
        let object = try readHooksJSONObject(from: hooksFileURL)
        return Self.containsOwnedToasttyHooks(
            in: object,
            expectedCommand: Self.hookCommand(forwarderScriptURL: forwarderScriptURL())
        )
    }

    func sessionLaunchForwarderCommand() -> String {
        Self.hookCommand(forwarderScriptURL: forwarderScriptURL())
    }

    private func prepareSessionIntegrationMigrationWithLockHeld() throws -> CodexStatusHookInstallResult {
        let hooksFileURL = try self.hooksFileURL()
        let forwarderScriptURL = forwarderScriptURL()
        let expectedForwarder = Self.forwarderScriptContents(logFilePath: telemetryFailureLogURL().path)
        let expectedCommand = Self.hookCommand(forwarderScriptURL: forwarderScriptURL)

        let previousHooksObject = try existingHooksJSONObject(from: hooksFileURL)
        let nextHooksObject = Self.removingToasttyHooks(from: previousHooksObject, expectedCommand: expectedCommand)
        let hooksChanged = (nextHooksObject as NSDictionary).isEqual(to: previousHooksObject) == false
        let nextHooksData = try JSONSerialization.data(
            withJSONObject: nextHooksObject,
            options: [.prettyPrinted, .sortedKeys]
        )

        let forwarderChanged = try writeForwarderIfNeeded(expectedForwarder, to: forwarderScriptURL)
        if hooksChanged {
            do {
                try fileManager.createDirectory(
                    at: hooksFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try nextHooksData.write(to: hooksFileURL, options: .atomic)
            } catch {
                throw CodexStatusHookInstallerError.unableToWriteHooksFile(hooksFileURL.path)
            }
        }

        return CodexStatusHookInstallResult(
            status: try installationStatus(),
            hooksFileChanged: hooksChanged,
            forwarderScriptChanged: forwarderChanged
        )
    }

    func uninstall() throws -> CodexStatusHookInstallStatus {
        try prepareSessionIntegrationMigration().status
    }
}

private extension CodexStatusHookInstaller {
    static func withInstallLock<T>(_ operation: () throws -> T) rethrows -> T {
        installLock.lock()
        defer { installLock.unlock() }
        return try operation()
    }

    func hooksFileURL() throws -> URL {
        let codexHome = codexHomePath.flatMap(Self.normalizedNonEmpty) ?? "\(homeDirectoryPath)/.codex"
        guard codexHome.hasPrefix("/") else {
            throw CodexStatusHookInstallerError.unsupportedCodexHome(codexHome)
        }
        return URL(fileURLWithPath: codexHome, isDirectory: true)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    func forwarderScriptURL() -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(".toastty/codex-hooks/forwarder.sh", isDirectory: false)
    }

    func telemetryFailureLogURL() -> URL {
        URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
            .appendingPathComponent(".toastty/codex-hooks/telemetry-failures.log", isDirectory: false)
    }

    func existingHooksJSONObject(from url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        return try readHooksJSONObject(from: url)
    }

    func readHooksJSONObject(from url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexStatusHookInstallerError.unableToReadHooksFile(url.path)
        }
        guard data.isEmpty == false else {
            return [:]
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexStatusHookInstallerError.unableToReadHooksFile(url.path)
        }
        guard let jsonObject = object as? [String: Any] else {
            throw CodexStatusHookInstallerError.hooksFileNotJSONObject(url.path)
        }
        return jsonObject
    }

    func writeForwarderIfNeeded(_ contents: String, to url: URL) throws -> Bool {
        let data = Data(contents.appending("\n").utf8)
        if let currentData = try? Data(contentsOf: url), currentData == data {
            return false
        }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            throw CodexStatusHookInstallerError.unableToWriteForwarder(url.path)
        }
    }

    static func containsOwnedToasttyHooks(
        in object: [String: Any],
        expectedCommand: String
    ) -> Bool {
        guard let hooks = object["hooks"] as? [String: Any] else {
            return false
        }

        return (hookEventNames + legacyHookEventNames).contains { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                return false
            }
            return groups.contains { group in
                guard let hookEntries = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return hookEntries.contains {
                    isOwnedToasttyHook($0, expectedCommand: expectedCommand)
                }
            }
        }
    }

    static func removingToasttyHooks(
        from object: [String: Any],
        expectedCommand: String
    ) -> [String: Any] {
        var nextObject = object
        guard var hooks = nextObject["hooks"] as? [String: Any] else {
            return nextObject
        }

        for eventName in hookEventNames + legacyHookEventNames {
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                continue
            }
            let filteredGroups = groups.compactMap { group -> [String: Any]? in
                guard let hookEntries = group["hooks"] as? [[String: Any]] else {
                    return group
                }
                let filteredHookEntries = hookEntries.filter {
                    isOwnedToasttyHook($0, expectedCommand: expectedCommand) == false
                }
                guard filteredHookEntries.isEmpty == false else {
                    return nil
                }
                var nextGroup = group
                nextGroup["hooks"] = filteredHookEntries
                return nextGroup
            }
            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = filteredGroups
            }
        }

        nextObject["hooks"] = hooks
        return nextObject
    }

    static func isOwnedToasttyHook(_ hook: [String: Any], expectedCommand: String) -> Bool {
        guard let command = hook["command"] as? String else {
            return false
        }
        return command == expectedCommand
    }

    static func forwarderScriptIsCurrent(
        at url: URL,
        expectedForwarder: String
    ) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            return false
        }
        return String(data: data, encoding: .utf8) == expectedForwarder.appending("\n")
    }

    static func hookCommand(forwarderScriptURL: URL) -> String {
        "/bin/sh \(shellQuote(forwarderScriptURL.path))"
    }

    static func forwarderScriptContents(logFilePath: String) -> String {
        let logDirectoryPath = URL(fileURLWithPath: logFilePath).deletingLastPathComponent().path
        return [
            "#!/bin/sh",
            "if [ -z \"${TOASTTY_SESSION_ID:-}\" ] || [ -z \"${TOASTTY_PANEL_ID:-}\" ] || [ -z \"${TOASTTY_SOCKET_PATH:-}\" ] || [ -z \"${TOASTTY_CLI_PATH:-}\" ]; then",
            "  cat >/dev/null",
            "  exit 0",
            "fi",
            "log_dir=\(shellQuote(logDirectoryPath))",
            "log_file=\(shellQuote(logFilePath))",
            "mkdir -p \"$log_dir\" 2>/dev/null || :",
            "stderr_file=\"$(mktemp \"$log_dir/codex-hook-stderr.XXXXXX\" 2>/dev/null)\"",
            "if [ -z \"$stderr_file\" ]; then",
            "  stderr_file=\"$log_dir/codex-hook.stderr\"",
            "fi",
            "rm -f \"$stderr_file\"",
            "if cat | \"$TOASTTY_CLI_PATH\" --socket-path \"$TOASTTY_SOCKET_PATH\" session ingest-agent-event --source codex-hooks --session \"$TOASTTY_SESSION_ID\" --panel \"$TOASTTY_PANEL_ID\" >/dev/null 2>\"$stderr_file\"; then",
            "  rm -f \"$stderr_file\"",
            "  exit 0",
            "fi",
            "status=$?",
            "timestamp=\"$(date -u +\"%Y-%m-%dT%H:%M:%SZ\" 2>/dev/null || date)\"",
            "{",
            "  printf '[%s] source=codex-hooks exit_code=%s socket_path=%s session_id=%s panel_id=%s\\n' \"$timestamp\" \"$status\" \"${TOASTTY_SOCKET_PATH:-<unset>}\" \"${TOASTTY_SESSION_ID:-<unset>}\" \"${TOASTTY_PANEL_ID:-<unset>}\"",
            "  if [ -s \"$stderr_file\" ]; then",
            "    sed 's/^/stderr: /' \"$stderr_file\"",
            "  else",
            "    printf 'stderr: <empty>\\n'",
            "  fi",
            "} >> \"$log_file\"",
            "rm -f \"$stderr_file\"",
            "exit 0",
        ].joined(separator: "\n")
    }

    static func shellQuote(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
