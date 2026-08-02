import Foundation

enum CodexIntegrationComponentState: String, Equatable, Sendable {
    case ready
    case needsSetup
    case warning
    case unsupported
    case failed
}

struct CodexIntegrationComponentStatus: Equatable, Sendable {
    let state: CodexIntegrationComponentState
    let detail: String
}

struct CodexIntegrationSetupStatus: Equatable, Sendable {
    let plugin: CodexIntegrationComponentStatus
    let legacySkills: CodexIntegrationComponentStatus
    let globalHooks: CodexIntegrationComponentStatus
    let sessionHooks: CodexIntegrationComponentStatus
    let fallback: CodexIntegrationComponentStatus
    let assessment: CodexSessionIntegrationAssessment?
    let legacySkillConflictPaths: [String]
    let disabledNameTombstones: [String]

    var isReady: Bool {
        plugin.state == .ready
            && legacySkills.state == .ready
            && globalHooks.state == .ready
            && (sessionHooks.state == .ready || sessionHooks.state == .warning)
    }
}

struct CodexIntegrationSetupResult: Equatable, Sendable {
    let status: CodexIntegrationSetupStatus
    let copiedPlugin: Bool
    let marketplaceChanged: Bool
    let pluginChanged: Bool
    let migratedLegacySkillPaths: [String]
}

enum CodexIntegrationManagerError: LocalizedError, Equatable {
    case missingBundledMarketplace(String)
    case invalidCodexHome(String)
    case copyFailed(String)
    case unexpectedPluginName(String)
    case skillDisableVerificationFailed(String)
    case installedSkillSetMismatch(expected: [String], actual: [String])
    case installedSkillEnabled(String)
    case marketplaceMismatch(String)
    case pluginNotInstalled
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledMarketplace(let path):
            return "Toastty's bundled Codex integration is missing at \(path)."
        case .invalidCodexHome(let path):
            return "Codex home must be an absolute path: \(path)"
        case .copyFailed(let path):
            return "Unable to copy the Toastty Codex integration to \(path)."
        case .unexpectedPluginName(let name):
            return "Toastty's bundled Codex plugin has an unexpected name: \(name)."
        case .skillDisableVerificationFailed(let name):
            return "Codex did not persist the disabled state for \(name)."
        case .installedSkillSetMismatch(let expected, let actual):
            return "Installed Toastty skills do not match the bundled manifest (expected: \(expected.joined(separator: ", ")); actual: \(actual.joined(separator: ", ")))."
        case .installedSkillEnabled(let name):
            return "Toastty skill \(name) is still enabled in ordinary Codex sessions."
        case .marketplaceMismatch(let name):
            return "Codex registered the Toastty marketplace as \(name)."
        case .pluginNotInstalled:
            return "The Toastty Codex plugin is not installed."
        case .uninstallFailed(let message):
            return "Unable to uninstall the Toastty Codex integration: \(message)"
        }
    }
}

struct CodexIntegrationRuntime: Equatable, Sendable {
    let executableURL: URL
    let codexHomeURL: URL
    let workingDirectoryURL: URL
}

enum CodexIntegrationRuntimeLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> CodexIntegrationRuntime {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { component in
                let directory = component.isEmpty ? cwd.path : String(component)
                return URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
            }
        guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw CodexAppServerClientError.executableUnavailable("codex (PATH)")
        }
        let codexHomePath = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome = if let codexHomePath, codexHomePath.isEmpty == false {
            URL(fileURLWithPath: codexHomePath, isDirectory: true)
        } else {
            homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        }
        guard codexHome.path.hasPrefix("/") else {
            throw CodexIntegrationManagerError.invalidCodexHome(codexHome.path)
        }
        return CodexIntegrationRuntime(
            executableURL: executable,
            codexHomeURL: codexHome,
            workingDirectoryURL: cwd
        )
    }
}

struct CodexManagedLaunchIntegrationDecision: Equatable, Sendable {
    let configuration: CodexSessionLaunchConfiguration?
    let assessment: CodexSessionIntegrationAssessment?
    let statusTrackingSource: CodexStatusTrackingSource
}

final class CodexIntegrationManager: @unchecked Sendable {
    static let assessmentTimeout: TimeInterval = 1.5
    private static let operationLock = NSLock()

    private let homeDirectoryURL: URL
    private let sourceMarketplaceURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager
    private let client: CodexAppServerClient
    private let nowProvider: @Sendable () -> Date

    init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        sourceMarketplaceURLProvider: @escaping @Sendable () -> URL? = {
            Bundle.main.resourceURL?.appendingPathComponent("CodexPluginMarketplace", isDirectory: true)
        },
        fileManager: FileManager = .default,
        client: CodexAppServerClient = CodexAppServerClient(),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.sourceMarketplaceURLProvider = sourceMarketplaceURLProvider
        self.fileManager = fileManager
        self.client = client
        self.nowProvider = nowProvider
    }

    var stableMarketplaceURL: URL {
        homeDirectoryURL.appendingPathComponent(".toastty/codex-plugin", isDirectory: true)
    }

    func status(runtime: CodexIntegrationRuntime) -> CodexIntegrationSetupStatus {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        return statusWithLockHeld(runtime: runtime)
    }

    func setup(runtime: CodexIntegrationRuntime) throws -> CodexIntegrationSetupResult {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }

        let sourceURL = try bundledMarketplaceURL()
        let copiedPlugin = try installStableMarketplaceCopy(from: sourceURL)
        let manifest = try copiedManifest()
        let invocation = persistentInvocation(runtime: runtime, timeout: 15)

        // Fail safe: persistent disables must exist before Codex can discover
        // or install the plugin from the new marketplace.
        try persistDisabledSkills(manifest.qualifiedSkillNames, invocation: invocation)

        let registeredName = try client.addMarketplace(
            invocation: invocation,
            source: stableMarketplaceURL.path
        )
        guard registeredName == CodexSessionIntegrationContract.marketplaceName else {
            throw CodexIntegrationManagerError.marketplaceMismatch(registeredName)
        }
        let pluginWasInstalled = try client.installedPluginID(
            invocation: invocation,
            pluginName: manifest.pluginName,
            marketplaceName: registeredName
        ) != nil
        if pluginWasInstalled {
            try client.upgradeMarketplace(invocation: invocation, marketplaceName: registeredName)
        } else {
            try client.installPlugin(
                invocation: invocation,
                pluginName: manifest.pluginName,
                marketplacePath: stableMarketplaceURL
                    .appendingPathComponent(".agents/plugins/marketplace.json", isDirectory: false)
                    .path
            )
        }

        // Reapply after install/update, then verify exact membership and state.
        try persistDisabledSkills(manifest.qualifiedSkillNames, invocation: invocation)
        try verifyOrdinarySkillConfiguration(manifest: manifest, invocation: invocation)

        let migration = try CodexStatusHookInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            codexHomePath: runtime.codexHomeURL.path,
            fileManager: fileManager
        ).prepareSessionIntegrationMigration()
        let legacyMigration = try migrateOwnedLegacySkills(manifest: manifest, codexHomeURL: runtime.codexHomeURL)

        return CodexIntegrationSetupResult(
            status: statusWithLockHeld(runtime: runtime),
            copiedPlugin: copiedPlugin,
            marketplaceChanged: true,
            pluginChanged: pluginWasInstalled == false || copiedPlugin,
            migratedLegacySkillPaths: legacyMigration.migratedPaths
                + (migration.hooksFileChanged ? [migration.status.hooksFileURL.path] : [])
        )
    }

    func uninstall(
        runtime: CodexIntegrationRuntime,
        restoreLegacySkills: Bool
    ) throws -> CodexIntegrationSetupStatus {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        let invocation = persistentInvocation(runtime: runtime, timeout: 15)
        let tombstones = (try? copiedManifest().qualifiedSkillNames) ?? []

        if let pluginID = try client.installedPluginID(
            invocation: invocation,
            pluginName: CodexSessionIntegrationContract.pluginName,
            marketplaceName: CodexSessionIntegrationContract.marketplaceName
        ) {
            try client.uninstallPlugin(invocation: invocation, pluginID: pluginID)
        }
        try client.removeMarketplace(
            invocation: invocation,
            marketplaceName: CodexSessionIntegrationContract.marketplaceName
        )
        _ = try CodexStatusHookInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            codexHomePath: runtime.codexHomeURL.path,
            fileManager: fileManager
        ).prepareSessionIntegrationMigration()

        if restoreLegacySkills {
            try restoreLatestLegacySkillBackup(codexHomeURL: runtime.codexHomeURL)
        }
        if fileManager.fileExists(atPath: stableMarketplaceURL.path) {
            do {
                try fileManager.removeItem(at: stableMarketplaceURL)
            } catch {
                throw CodexIntegrationManagerError.uninstallFailed(error.localizedDescription)
            }
        }
        let status = statusWithLockHeld(runtime: runtime)
        return CodexIntegrationSetupStatus(
            plugin: status.plugin,
            legacySkills: status.legacySkills,
            globalHooks: status.globalHooks,
            sessionHooks: status.sessionHooks,
            fallback: status.fallback,
            assessment: status.assessment,
            legacySkillConflictPaths: status.legacySkillConflictPaths,
            disabledNameTombstones: tombstones.sorted()
        )
    }

    func managedAssessment(
        runtime: CodexIntegrationRuntime
    ) throws -> CodexSessionIntegrationAssessment {
        let manifest = try copiedManifest()
        let hookInstaller = CodexStatusHookInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            codexHomePath: runtime.codexHomeURL.path,
            fileManager: fileManager
        )
        let command = hookInstaller.sessionLaunchForwarderCommand()
        return try client.assess(
            invocation: CodexAppServerInvocation(
                executableURL: runtime.executableURL,
                codexHomeURL: runtime.codexHomeURL,
                workingDirectoryURL: runtime.workingDirectoryURL,
                configOverrides: CodexSessionIntegrationContract.launchOverrides(
                    enabling: manifest.qualifiedSkillNames,
                    forwarderCommand: command
                ),
                timeout: Self.assessmentTimeout
            ),
            expectedSkillNames: manifest.qualifiedSkillNames,
            forwarderCommand: command,
            legacyGlobalHooksPresent: try hookInstaller.legacyGlobalHooksPresent()
        )
    }

    func managedLaunchDecision(
        runtime: CodexIntegrationRuntime
    ) throws -> CodexManagedLaunchIntegrationDecision {
        let manifest = try copiedManifest()
        let hookInstaller = CodexStatusHookInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            codexHomePath: runtime.codexHomeURL.path,
            fileManager: fileManager
        )
        let assessment = try managedAssessment(runtime: runtime)
        guard assessment.canInjectSessionConfiguration else {
            return CodexManagedLaunchIntegrationDecision(
                configuration: nil,
                assessment: assessment,
                statusTrackingSource: .sessionLogFallback(reason: "session_integration_unsupported")
            )
        }
        let configuration = CodexSessionLaunchConfiguration(
            manifest: manifest,
            forwarderCommand: hookInstaller.sessionLaunchForwarderCommand(),
            legacyGlobalHooksPresent: assessment.legacyGlobalHooksPresent
        )
        let source: CodexStatusTrackingSource
        if assessment.legacyGlobalHooksPresent {
            // Presence alone does not prove that a legacy hook is trusted or
            // still executable. Keep fallback ownership until explicit setup
            // removes it; launch instrumentation will suppress duplicate
            // session hooks while the legacy definition remains.
            source = .sessionLogFallback(reason: "legacy_global_hooks_present")
        } else if assessment.canUseSessionIntegrations {
            source = .hooks
        } else {
            source = .sessionLogFallback(reason: "session_hooks_awaiting_trust")
        }
        return CodexManagedLaunchIntegrationDecision(
            configuration: configuration,
            assessment: assessment,
            statusTrackingSource: source
        )
    }
}

private extension CodexIntegrationManager {
    struct LegacyMigrationResult {
        let migratedPaths: [String]
        let conflictPaths: [String]
    }

    func bundledMarketplaceURL() throws -> URL {
        let expected = sourceMarketplaceURLProvider()
            ?? URL(fileURLWithPath: "CodexPluginMarketplace", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expected.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(
                atPath: expected.appendingPathComponent(".agents/plugins/marketplace.json").path
              ),
              fileManager.fileExists(
                atPath: expected.appendingPathComponent("plugins/toastty/.codex-plugin/plugin.json").path
              ) else {
            throw CodexIntegrationManagerError.missingBundledMarketplace(expected.path)
        }
        return expected
    }

    func copiedManifest() throws -> CodexPluginSkillManifest {
        let manifest = try CodexPluginSkillManifestReader.read(
            pluginDirectoryURL: stableMarketplaceURL.appendingPathComponent("plugins/toastty", isDirectory: true),
            fileManager: fileManager
        )
        guard manifest.pluginName == CodexSessionIntegrationContract.pluginName else {
            throw CodexIntegrationManagerError.unexpectedPluginName(manifest.pluginName)
        }
        return manifest
    }

    func installStableMarketplaceCopy(from sourceURL: URL) throws -> Bool {
        let destination = stableMarketplaceURL
        if directoriesAreByteIdentical(sourceURL, destination) {
            return false
        }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".codex-plugin-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CodexIntegrationManagerError.copyFailed(destination.path)
        }
    }

    func persistDisabledSkills(
        _ names: [String],
        invocation: CodexAppServerInvocation
    ) throws {
        for name in names.sorted() {
            let effectiveEnabled = try client.writeSkillConfig(
                invocation: invocation,
                name: name,
                enabled: false
            )
            guard effectiveEnabled == false else {
                throw CodexIntegrationManagerError.skillDisableVerificationFailed(name)
            }
        }
    }

    func verifyOrdinarySkillConfiguration(
        manifest: CodexPluginSkillManifest,
        invocation: CodexAppServerInvocation
    ) throws {
        let expected = Set(manifest.qualifiedSkillNames)
        let pluginPrefix = "\(CodexSessionIntegrationContract.pluginName):"
        let listed = try client.listSkills(invocation: invocation)
        let installed = Set(listed.map(\.name).filter { $0.hasPrefix(pluginPrefix) })
        guard installed == expected else {
            throw CodexIntegrationManagerError.installedSkillSetMismatch(
                expected: expected.sorted(),
                actual: installed.sorted()
            )
        }
        if let enabled = listed.first(where: { expected.contains($0.name) && $0.enabled }) {
            throw CodexIntegrationManagerError.installedSkillEnabled(enabled.name)
        }
    }

    func statusWithLockHeld(runtime: CodexIntegrationRuntime) -> CodexIntegrationSetupStatus {
        let manifest: CodexPluginSkillManifest
        do {
            manifest = try copiedManifest()
        } catch {
            return CodexIntegrationSetupStatus(
                plugin: .init(state: .needsSetup, detail: "Toastty Codex plugin is not installed."),
                legacySkills: .init(state: .needsSetup, detail: "Legacy skill conflicts have not been checked."),
                globalHooks: globalHookStatus(runtime: runtime),
                sessionHooks: .init(state: .needsSetup, detail: "Session hooks have not been checked."),
                fallback: .init(state: .ready, detail: "Codex will use notify and session-log fallback telemetry."),
                assessment: nil,
                legacySkillConflictPaths: [],
                disabledNameTombstones: []
            )
        }

        let legacy = (try? inspectLegacySkills(manifest: manifest, codexHomeURL: runtime.codexHomeURL))
            ?? LegacyMigrationResult(migratedPaths: [], conflictPaths: [])
        do {
            let ordinary = persistentInvocation(runtime: runtime, timeout: Self.assessmentTimeout)
            try verifyOrdinarySkillConfiguration(manifest: manifest, invocation: ordinary)
            let assessment = try managedAssessment(runtime: runtime)
            let sessionStatus: CodexIntegrationComponentStatus
            if assessment.canInjectSessionConfiguration == false {
                sessionStatus = .init(state: .unsupported, detail: "This Codex version cannot load Toastty's process-scoped skills and hooks.")
            } else if assessment.allSessionHooksTrusted {
                sessionStatus = .init(state: .ready, detail: "All Toastty session hooks are supported and trusted.")
            } else {
                sessionStatus = .init(state: .warning, detail: "Session hooks are waiting for Codex trust. Run /hooks in a managed Codex session.")
            }
            return CodexIntegrationSetupStatus(
                plugin: .init(state: .ready, detail: "Toastty plugin is installed and its skills are disabled in ordinary Codex sessions."),
                legacySkills: legacy.conflictPaths.isEmpty
                    ? .init(state: .ready, detail: "No legacy standalone Toastty skills are exposed globally.")
                    : .init(state: .warning, detail: "Modified or ambiguous legacy skills still appear in ordinary Codex sessions."),
                globalHooks: globalHookStatus(runtime: runtime),
                sessionHooks: sessionStatus,
                fallback: assessment.allSessionHooksTrusted
                    ? .init(state: .ready, detail: "Trusted session hooks provide primary telemetry for the next launch.")
                    : .init(state: .warning, detail: "Notify and session-log fallback remains active until hooks are trusted."),
                assessment: assessment,
                legacySkillConflictPaths: legacy.conflictPaths,
                disabledNameTombstones: []
            )
        } catch let error as CodexAppServerClientError {
            let unsupported = {
                if case .rpcError(_, let code, _) = error { return code == -32601 }
                return false
            }()
            return CodexIntegrationSetupStatus(
                plugin: .init(state: .needsSetup, detail: "Toastty could not verify the installed plugin and disabled skills."),
                legacySkills: legacy.conflictPaths.isEmpty
                    ? .init(state: .ready, detail: "No legacy standalone Toastty skills are exposed globally.")
                    : .init(state: .warning, detail: "Legacy standalone skill conflicts remain."),
                globalHooks: globalHookStatus(runtime: runtime),
                sessionHooks: .init(
                    state: unsupported ? .unsupported : .failed,
                    detail: unsupported ? "This Codex version does not support session integration APIs." : error.localizedDescription
                ),
                fallback: .init(state: .ready, detail: "Codex will launch with notify and session-log fallback telemetry."),
                assessment: nil,
                legacySkillConflictPaths: legacy.conflictPaths,
                disabledNameTombstones: []
            )
        } catch {
            return CodexIntegrationSetupStatus(
                plugin: .init(state: .failed, detail: error.localizedDescription),
                legacySkills: legacy.conflictPaths.isEmpty
                    ? .init(state: .ready, detail: "No legacy standalone Toastty skills are exposed globally.")
                    : .init(state: .warning, detail: "Legacy standalone skill conflicts remain."),
                globalHooks: globalHookStatus(runtime: runtime),
                sessionHooks: .init(state: .failed, detail: "Session integration could not be verified."),
                fallback: .init(state: .ready, detail: "Codex will launch with notify and session-log fallback telemetry."),
                assessment: nil,
                legacySkillConflictPaths: legacy.conflictPaths,
                disabledNameTombstones: []
            )
        }
    }

    func globalHookStatus(runtime: CodexIntegrationRuntime) -> CodexIntegrationComponentStatus {
        do {
            let installer = CodexStatusHookInstaller(
                homeDirectoryPath: homeDirectoryURL.path,
                codexHomePath: runtime.codexHomeURL.path,
                fileManager: fileManager
            )
            if try installer.legacyGlobalHooksPresent() {
                return .init(state: .needsSetup, detail: "Legacy global Toastty hooks still need removal.")
            }
            return .init(state: .ready, detail: "Legacy global Toastty hooks are removed.")
        } catch {
            return .init(state: .failed, detail: error.localizedDescription)
        }
    }

    func persistentInvocation(
        runtime: CodexIntegrationRuntime,
        timeout: TimeInterval
    ) -> CodexAppServerInvocation {
        CodexAppServerInvocation(
            executableURL: runtime.executableURL,
            codexHomeURL: runtime.codexHomeURL,
            workingDirectoryURL: runtime.workingDirectoryURL,
            configOverrides: [],
            timeout: timeout
        )
    }

    func inspectLegacySkills(
        manifest: CodexPluginSkillManifest,
        codexHomeURL: URL
    ) throws -> LegacyMigrationResult {
        var owned: [String] = []
        var conflicts: [String] = []
        for root in legacySkillRoots(codexHomeURL: codexHomeURL) {
            for skillName in manifest.skillNames {
                let candidate = root.appendingPathComponent(skillName, isDirectory: true)
                guard fileManager.fileExists(atPath: candidate.path) else { continue }
                let canonical = manifest.skillsRootURL.appendingPathComponent(skillName, isDirectory: true)
                if directoriesAreByteIdentical(candidate.resolvingSymlinksInPath(), canonical) {
                    owned.append(candidate.path)
                } else {
                    conflicts.append(candidate.path)
                }
            }
        }
        return LegacyMigrationResult(migratedPaths: owned.sorted(), conflictPaths: conflicts.sorted())
    }

    func migrateOwnedLegacySkills(
        manifest: CodexPluginSkillManifest,
        codexHomeURL: URL
    ) throws -> LegacyMigrationResult {
        let inspection = try inspectLegacySkills(manifest: manifest, codexHomeURL: codexHomeURL)
        guard inspection.migratedPaths.isEmpty == false else { return inspection }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = homeDirectoryURL
            .appendingPathComponent(".toastty/legacy-codex-skills-backup", isDirectory: true)
            .appendingPathComponent(
                "\(formatter.string(from: nowProvider()))-\(UUID().uuidString)",
                isDirectory: true
            )
        var moved: [String] = []
        for path in inspection.migratedPaths {
            let source = URL(fileURLWithPath: path, isDirectory: true)
            let rootLabel = source.deletingLastPathComponent().path == codexHomeURL.appendingPathComponent("skills").path
                ? "codex-home" : "agents-home"
            let destination = backup
                .appendingPathComponent(rootLabel, isDirectory: true)
                .appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            moved.append(path)
        }
        return LegacyMigrationResult(migratedPaths: moved, conflictPaths: inspection.conflictPaths)
    }

    func restoreLatestLegacySkillBackup(codexHomeURL: URL) throws {
        let backupsRoot = homeDirectoryURL.appendingPathComponent(".toastty/legacy-codex-skills-backup", isDirectory: true)
        guard let latest = try? fileManager.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else {
            return
        }
        let mappings = [
            ("codex-home", codexHomeURL.appendingPathComponent("skills", isDirectory: true)),
            ("agents-home", homeDirectoryURL.appendingPathComponent(".agents/skills", isDirectory: true)),
        ]
        for (label, destinationRoot) in mappings {
            let sourceRoot = latest.appendingPathComponent(label, isDirectory: true)
            guard let items = try? fileManager.contentsOfDirectory(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            for source in items {
                let destination = destinationRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                guard fileManager.fileExists(atPath: destination.path) == false else { continue }
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    func legacySkillRoots(codexHomeURL: URL) -> [URL] {
        [
            codexHomeURL.appendingPathComponent("skills", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".agents/skills", isDirectory: true),
        ]
    }

    func directoriesAreByteIdentical(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsFiles = relativeRegularFilePaths(in: lhs),
              let rhsFiles = relativeRegularFilePaths(in: rhs),
              lhsFiles == rhsFiles else {
            return false
        }
        return lhsFiles.allSatisfy { relativePath in
            let lhsURL = lhs.appendingPathComponent(relativePath)
            let rhsURL = rhs.appendingPathComponent(relativePath)
            let lhsData = try? Data(contentsOf: lhsURL)
            let rhsData = try? Data(contentsOf: rhsURL)
            let lhsMode = (try? fileManager.attributesOfItem(atPath: lhsURL.path)[.posixPermissions]) as? NSNumber
            let rhsMode = (try? fileManager.attributesOfItem(atPath: rhsURL.path)[.posixPermissions]) as? NSNumber
            return lhsData != nil && lhsData == rhsData && lhsMode == rhsMode
        }
    }

    func relativeRegularFilePaths(in root: URL) -> [String]? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }
        let rootPrefix = root.standardizedFileURL.path.appending("/")
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return nil }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else { return nil }
            paths.append(String(path.dropFirst(rootPrefix.count)))
        }
        return paths.sorted()
    }
}
