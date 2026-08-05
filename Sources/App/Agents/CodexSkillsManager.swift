import CoreState
import CryptoKit
import Darwin
import Foundation

enum CodexSkillsAvailability: String, Equatable, Sendable {
    case ready
    case notInstalled
    case unrunnable
    case failed
    case unsupported
}

struct CodexSkillsStatus: Equatable, Sendable {
    let availability: CodexSkillsAvailability
    let detail: String
    let bundledVersion: String?
    let installedVersion: String?
    let bundledDigest: String?
    let installedDigest: String?
    let cachePath: String?
    let profileConfigPath: String
    let updatePending: Bool
    let repairPending: Bool
    let hasActiveManagedSession: Bool

    var isReady: Bool {
        availability == .ready && updatePending == false && repairPending == false
    }
}

struct CodexSkillsPreparation: Equatable, Sendable {
    let configuration: CodexSkillsLaunchConfiguration?
    let status: CodexSkillsStatus
    let installedOrUpdated: Bool
    let firstInstallSucceeded: Bool
}

enum CodexSkillsManagerError: LocalizedError, Equatable {
    case bundledPluginUnavailable
    case bundledMarketplaceUnavailable(String)
    case invalidCodexHome(String)
    case operationTimedOut
    case profileConfigConflict(String)
    case ownedStateMismatch(String)
    case pluginInstallMismatch
    case pluginNotInstalled
    case installedPluginMismatch(String)
    case activeSessions
    case copyFailed(String)
    case cacheSwapFailed(String)
    case legacyCleanupFailed(String)
    case uninstallFailed(String)
    case rollbackUnverified(String)

    var errorDescription: String? {
        switch self {
        case .bundledPluginUnavailable:
            return "Toastty could not find its bundled Codex skills plugin."
        case .bundledMarketplaceUnavailable(let path):
            return "Toastty could not find its bundled Codex marketplace at \(path)."
        case .invalidCodexHome(let path):
            return "Codex home must be an absolute path: \(path)"
        case .operationTimedOut:
            return "Codex skills provisioning timed out."
        case .profileConfigConflict(let path):
            return "A Codex profile file Toastty does not own exists at \(path). Toastty preserved it; managed sessions launch without Toastty skills until it is moved or removed."
        case .ownedStateMismatch(let path):
            return "Toastty cannot verify ownership of the Codex skills state at \(path)."
        case .pluginInstallMismatch:
            return "Codex produced an unexpected plugin while populating Toastty skills."
        case .pluginNotInstalled:
            return "The Toastty Codex skills plugin is not installed."
        case .installedPluginMismatch(let path):
            return "The cached Toastty Codex plugin does not match the verified bundle at \(path)."
        case .activeSessions:
            return "Wait for active managed Codex sessions to finish before changing the plugin."
        case .copyFailed(let path):
            return "Toastty could not stage its Codex skills plugin at \(path)."
        case .cacheSwapFailed(let message):
            return "Toastty could not update its Codex plugin cache: \(message)"
        case .legacyCleanupFailed(let message):
            return "Toastty could not clean up its previous Codex skills installation: \(message)"
        case .uninstallFailed(let message):
            return "Toastty could not uninstall its Codex skills: \(message)"
        case .rollbackUnverified(let message):
            return "Toastty could not verify the previous Codex skills version after an update failure: \(message)"
        }
    }
}

struct CodexProcessEnvironment: Equatable, Sendable {
    let codexHomeURL: URL
    let path: String?

    func applying(to inheritedEnvironment: [String: String]) -> [String: String] {
        var environment = inheritedEnvironment
        environment["CODEX_HOME"] = codexHomeURL.path
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.isEmpty == false {
            environment["PATH"] = path
        }
        return environment
    }
}

struct CodexIntegrationRuntime: Equatable, Sendable {
    let executableURL: URL
    let processEnvironment: CodexProcessEnvironment
    let workingDirectoryURL: URL

    init(
        executableURL: URL,
        processEnvironment: CodexProcessEnvironment,
        workingDirectoryURL: URL
    ) {
        self.executableURL = executableURL
        self.processEnvironment = processEnvironment
        self.workingDirectoryURL = workingDirectoryURL
    }

    init(
        executableURL: URL,
        codexHomeURL: URL,
        processPath: String? = nil,
        workingDirectoryURL: URL
    ) {
        self.init(
            executableURL: executableURL,
            processEnvironment: CodexProcessEnvironment(
                codexHomeURL: codexHomeURL,
                path: processPath
            ),
            workingDirectoryURL: workingDirectoryURL
        )
    }

    var codexHomeURL: URL {
        processEnvironment.codexHomeURL
    }
}

enum CodexIntegrationRuntimeLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredProcessPath: String? = nil,
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> CodexIntegrationRuntime {
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let processPath = ManagedAgentPathResolver.sanitizedMergedPath(
            preferredPath: preferredProcessPath,
            fallbackPath: environment["PATH"]
        )
        let searchDirectories = (processPath ?? "")
            .split(separator: ":")
            .map { component in
                URL(fileURLWithPath: String(component), isDirectory: true)
            }
        let executable = ["codex", "cdx"].lazy.compactMap { commandName in
            searchDirectories
                .map { $0.appendingPathComponent(commandName, isDirectory: false) }
                .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
        }.first
        guard let executable else {
            throw CodexPluginCLIError.executableUnavailable("codex or cdx (PATH)")
        }
        let configuredHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome = if let configuredHome, configuredHome.isEmpty == false {
            URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        }
        guard codexHome.path.hasPrefix("/") else {
            throw CodexSkillsManagerError.invalidCodexHome(codexHome.path)
        }
        return CodexIntegrationRuntime(
            executableURL: executable,
            processEnvironment: CodexProcessEnvironment(
                codexHomeURL: codexHome,
                path: processPath
            ),
            workingDirectoryURL: cwd
        )
    }
}

/// Delivers the shipped Toastty skills to managed Codex sessions through a
/// profile-based mechanism that never writes to the user's Codex
/// `config.toml`:
///
/// 1. Population (off the launch path): install the bundled plugin into a
///    throwaway `CODEX_HOME` with the real Codex CLI so the cache bytes are
///    canonical, digest-verify them, then atomically swap the produced
///    subtree into the real `$CODEX_HOME/plugins/cache/toastty/toastty/`.
/// 2. A Toastty-owned `$CODEX_HOME/toastty-managed.config.toml` overlay
///    enables the cached plugin for processes launched with
///    `--profile toastty-managed`; ordinary sessions see nothing.
/// 3. A receipt sidecar under `~/.toastty/agent-plugins/codex/` records the
///    verified cache identity so later launches byte-verify without
///    subprocess work.
///
/// See docs/plans/evidence/codex-session-scoped-skills-2026-08-04.md for the
/// capability evidence this mechanism rests on.
final class CodexSkillsManager: @unchecked Sendable {
    static let operationTimeout: TimeInterval = 4
    private static let operationLock = NSLock()

    private let repairStateLock = NSLock()
    private var pendingRepairHomes = Set<String>()
    private var failureCounts: [String: Int] = [:]

    private let homeDirectoryURL: URL
    private let sourcePluginURLProvider: @Sendable () -> URL?
    private let sourceMarketplaceURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager
    private let pluginClient: any CodexPluginCLIManaging
    private let cacheLock = NSLock()
    private var cachedConfigurations: [String: CachedConfiguration] = [:]

    init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        sourcePluginURLProvider: @escaping @Sendable () -> URL? = {
            ToasttyAgentPluginBundle.bundledPluginURL()
        },
        sourceMarketplaceURLProvider: @escaping @Sendable () -> URL? = {
            Bundle.main.resourceURL?
                .appendingPathComponent("ToasttyAgentPluginBundle", isDirectory: true)
        },
        fileManager: FileManager = .default,
        pluginClient: any CodexPluginCLIManaging = CodexPluginCLIClient()
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.sourcePluginURLProvider = sourcePluginURLProvider
        self.sourceMarketplaceURLProvider = sourceMarketplaceURLProvider
        self.fileManager = fileManager
        self.pluginClient = pluginClient
    }

    var stateRootURL: URL {
        homeDirectoryURL.appendingPathComponent(".toastty/agent-plugins/codex", isDirectory: true)
    }

    func cachedLaunchConfiguration(runtime: CodexIntegrationRuntime) -> CodexSkillsLaunchConfiguration? {
        cacheLock.lock()
        let entry = cachedConfigurations[runtimeKey(runtime)]
        cacheLock.unlock()
        guard let entry else { return nil }
        // Cheap existence guard: another manager instance may have
        // uninstalled or replaced the on-disk state since this entry was
        // verified. Anything deeper stays with the prepare paths.
        guard fileManager.fileExists(atPath: receiptURL(for: runtime).path),
              fileManager.fileExists(atPath: profileConfigURL(for: runtime).path),
              fileManager.fileExists(atPath: entry.configuration.skillsRootPath) else {
            return nil
        }
        return entry.configuration
    }

    func prepareForManagedLaunch(
        runtime: CodexIntegrationRuntime
    ) throws -> CodexSkillsPreparation {
        let deadline = Date().addingTimeInterval(Self.operationTimeout)
        let bundled = try bundledDescriptor()
        let signature = failureSignature(runtime: runtime, bundled: bundled)
        if failureCount(for: signature) >= 2, pendingRepair(for: runtime) == false {
            return CodexSkillsPreparation(
                configuration: nil,
                status: failedStatus(
                    runtime: runtime,
                    bundled: bundled,
                    detail: "Automatic repair is paused after repeated failures. Choose Repair to try again."
                ),
                installedOrUpdated: false,
                firstInstallSucceeded: false
            )
        }

        if pendingRepair(for: runtime) == false,
           legacyStateFileExists(runtime) == false,
           let cached = cachedEntry(runtime: runtime),
           cached.fingerprint == fingerprint(runtime: runtime, bundled: bundled, record: readReceipt(runtime)),
           cached.record.installedDigest == bundled.contentDigest {
            return CodexSkillsPreparation(
                configuration: cached.configuration,
                status: readyStatus(
                    bundled: bundled,
                    record: cached.record,
                    runtime: runtime
                ),
                installedOrUpdated: false,
                firstInstallSucceeded: false
            )
        }

        try acquireOperationLock(until: deadline)
        defer { Self.operationLock.unlock() }

        let oldRecord = readReceipt(runtime)
        let oldVerified = try? verifyInstalledFiles(
            runtime: runtime,
            bundled: bundled,
            record: oldRecord,
            requireBundledDigest: false
        )
        if let oldVerified,
           oldVerified.record.installedDigest == bundled.contentDigest,
           pendingRepair(for: runtime) == false,
           legacyStateFileExists(runtime) == false {
            do {
                try ensureProfileConfig(runtime: runtime)
            } catch let error as CodexSkillsManagerError {
                if case .profileConfigConflict = error {
                    incrementFailure(for: signature)
                    return conflictPreparation(runtime: runtime, bundled: bundled, error: error)
                }
                throw error
            }
            cache(oldVerified, runtime: runtime, bundled: bundled)
            clearFailure(for: signature)
            return CodexSkillsPreparation(
                configuration: oldVerified.configuration,
                status: readyStatus(
                    bundled: bundled,
                    record: oldVerified.record,
                    runtime: runtime
                ),
                installedOrUpdated: false,
                firstInstallSucceeded: false
            )
        }

        do {
            let wasFirstInstall = oldRecord == nil
            let prepared = try provision(
                runtime: runtime,
                bundled: bundled,
                oldVerified: oldVerified,
                deadline: deadline
            )
            clearPendingRepair(for: runtime)
            clearFailure(for: signature)
            cache(prepared, runtime: runtime, bundled: bundled)
            return CodexSkillsPreparation(
                configuration: prepared.configuration,
                status: readyStatus(
                    bundled: bundled,
                    record: prepared.record,
                    runtime: runtime
                ),
                installedOrUpdated: true,
                firstInstallSucceeded: wasFirstInstall
            )
        } catch {
            incrementFailure(for: signature)
            if let managerError = error as? CodexSkillsManagerError {
                if case .rollbackUnverified = managerError {
                    clearCachedConfiguration(runtime)
                    throw error
                }
                if case .profileConfigConflict = managerError {
                    return conflictPreparation(runtime: runtime, bundled: bundled, error: managerError)
                }
            }
            // Stale-skills fallback: refresh failed but a verified older cache
            // still exists. Re-verify from disk because provisioning may have
            // touched the cache before failing.
            if oldVerified != nil,
               let stillVerified = try? verifyInstalledFiles(
                   runtime: runtime,
                   bundled: bundled,
                   record: readReceipt(runtime),
                   requireBundledDigest: false
               ),
               (try? ensureProfileConfig(runtime: runtime)) != nil {
                cache(stillVerified, runtime: runtime, bundled: bundled)
                return CodexSkillsPreparation(
                    configuration: stillVerified.configuration,
                    status: failedStatus(
                        runtime: runtime,
                        bundled: bundled,
                        detail: "Toastty could not update its skills. Managed sessions will keep using the previous verified version. \(error.localizedDescription)"
                    ),
                    installedOrUpdated: false,
                    firstInstallSucceeded: false
                )
            }
            throw error
        }
    }

    /// Restored sessions must select the bundled version before their resume
    /// command is submitted. Restore ladder: (1) receipt plus cache digest
    /// matching the bundle is reused with pure filesystem checks; (2) any
    /// mismatch runs the same bounded population as a new managed launch;
    /// (3) a failed refresh falls back to a verified older cache with a
    /// stale-skills status; (4) nothing usable fails open without skills.
    func prepareForRestoredManagedLaunch(
        runtime: CodexIntegrationRuntime
    ) throws -> CodexSkillsPreparation {
        // A restored pane may be prepared after files changed within this app
        // process. Never let an earlier cache entry override the disk
        // verification below.
        clearCachedConfiguration(runtime)
        let bundled = try bundledDescriptor()
        // The fast path verifies and may rewrite the profile overlay, so it
        // must hold the same operation lock as provisioning and uninstall;
        // otherwise a racing uninstall could see its deleted overlay
        // recreated.
        try acquireOperationLock(until: Date().addingTimeInterval(Self.operationTimeout))
        let fastResult = lockedRestoreFastPath(runtime: runtime, bundled: bundled)
        Self.operationLock.unlock()
        if let fastResult {
            return fastResult
        }
        return try prepareForManagedLaunch(runtime: runtime)
    }

    /// Restore-ladder branch 1, executed under the operation lock. Returns
    /// nil when the current install cannot be reused as-is and the bounded
    /// provisioning path should run instead.
    private func lockedRestoreFastPath(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor
    ) -> CodexSkillsPreparation? {
        guard pendingRepair(for: runtime) == false,
              legacyStateFileExists(runtime) == false,
              let record = readReceipt(runtime),
              record.installedDigest == bundled.contentDigest,
              let verified = try? verifyInstalledFiles(
                  runtime: runtime,
                  bundled: bundled,
                  record: record,
                  requireBundledDigest: true
              ) else {
            return nil
        }
        do {
            try ensureProfileConfig(runtime: runtime)
        } catch let error as CodexSkillsManagerError where isProfileConflict(error) {
            incrementFailure(for: failureSignature(runtime: runtime, bundled: bundled))
            return conflictPreparation(runtime: runtime, bundled: bundled, error: error)
        } catch {
            return nil
        }
        cache(verified, runtime: runtime, bundled: bundled)
        return CodexSkillsPreparation(
            configuration: verified.configuration,
            status: readyStatus(bundled: bundled, record: record, runtime: runtime),
            installedOrUpdated: false,
            firstInstallSucceeded: false
        )
    }

    func status(
        runtime: CodexIntegrationRuntime,
        hasActiveManagedCodexSession: Bool
    ) -> CodexSkillsStatus {
        do {
            let bundled = try bundledDescriptor()
            guard let record = readReceipt(runtime) else {
                return CodexSkillsStatus(
                    availability: .notInstalled,
                    detail: "Toastty skills will be added automatically on the next managed Codex launch.",
                    bundledVersion: bundled.version,
                    installedVersion: nil,
                    bundledDigest: bundled.contentDigest,
                    installedDigest: nil,
                    cachePath: nil,
                    profileConfigPath: profileConfigURL(for: runtime).path,
                    updatePending: false,
                    repairPending: pendingRepair(for: runtime),
                    hasActiveManagedSession: hasActiveManagedCodexSession
                )
            }
            let verified = try verifyInstalledFiles(
                runtime: runtime,
                bundled: bundled,
                record: record,
                requireBundledDigest: false
            )
            try checkProfileConfigOwnership(runtime: runtime)
            cache(verified, runtime: runtime, bundled: bundled)
            return readyStatus(
                bundled: bundled,
                record: verified.record,
                runtime: runtime,
                hasActiveManagedCodexSession: hasActiveManagedCodexSession
            )
        } catch {
            return CodexSkillsStatus(
                availability: .failed,
                detail: error.localizedDescription,
                bundledVersion: (try? bundledDescriptor().version),
                installedVersion: readReceipt(runtime)?.installedVersion,
                bundledDigest: (try? bundledDescriptor().contentDigest),
                installedDigest: readReceipt(runtime)?.installedDigest,
                cachePath: readReceipt(runtime)?.cachePath,
                profileConfigPath: profileConfigURL(for: runtime).path,
                updatePending: false,
                repairPending: pendingRepair(for: runtime),
                hasActiveManagedSession: hasActiveManagedCodexSession
            )
        }
    }

    func repair(runtime: CodexIntegrationRuntime) throws -> CodexSkillsStatus {
        markPendingRepair(for: runtime)
        clearFailuresForRuntime(runtime)
        return try prepareForManagedLaunch(runtime: runtime).status
    }

    func uninstall(
        runtime: CodexIntegrationRuntime,
        hasActiveManagedCodexSession: Bool
    ) throws -> CodexSkillsStatus {
        guard hasActiveManagedCodexSession == false else {
            throw CodexSkillsManagerError.activeSessions
        }
        let deadline = Date().addingTimeInterval(Self.operationTimeout)
        try acquireOperationLock(until: deadline)
        defer { Self.operationLock.unlock() }

        let receiptURL = receiptURL(for: runtime)
        guard let record = readReceipt(runtime) else {
            throw CodexSkillsManagerError.ownedStateMismatch(receiptURL.path)
        }
        let bundled = try bundledDescriptor()
        _ = try verifyInstalledFiles(
            runtime: runtime,
            bundled: bundled,
            record: record,
            requireBundledDigest: false
        )

        do {
            let cacheRoot = pluginCacheRootURL(for: runtime)
            if fileManager.fileExists(atPath: cacheRoot.path) {
                try fileManager.removeItem(at: cacheRoot)
            }
            removeDirectoryIfEmpty(cacheRoot.deletingLastPathComponent())
            let profileURL = profileConfigURL(for: runtime)
            if let contents = try? String(contentsOf: profileURL, encoding: .utf8),
               CodexManagedProfileConfig.isToasttyOwned(contents) {
                try fileManager.removeItem(at: profileURL)
            }
            if fileManager.fileExists(atPath: receiptURL.path) {
                try fileManager.removeItem(at: receiptURL)
            }
            removeDirectoryIfEmpty(receiptURL.deletingLastPathComponent())
        } catch {
            throw CodexSkillsManagerError.uninstallFailed(error.localizedDescription)
        }
        cacheLock.lock()
        cachedConfigurations.removeValue(forKey: runtimeKey(runtime))
        cacheLock.unlock()
        clearPendingRepair(for: runtime)
        return status(runtime: runtime, hasActiveManagedCodexSession: false)
    }
}

private extension CodexSkillsManager {
    /// Sidecar recording the verified cache identity for one `CODEX_HOME`.
    struct ReceiptRecord: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let profileName: String
        let cachePath: String
        let installedVersion: String
        let installedDigest: String
        let skillNames: [String]
        let codexExecutablePath: String
        let codexExecutableSignature: String
    }

    /// Ownership record written by the retired marketplace-install mechanism.
    /// Only decoded during the one-shot legacy cleanup.
    struct LegacyOwnershipRecord: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let marketplaceName: String
        let marketplacePath: String
        let installedPath: String
        let installedVersion: String
        let installedDigest: String
        let skillNames: [String]
    }

    struct VerifiedInstallation {
        let configuration: CodexSkillsLaunchConfiguration
        let record: ReceiptRecord
    }

    struct CachedConfiguration {
        let configuration: CodexSkillsLaunchConfiguration
        let record: ReceiptRecord
        let fingerprint: String
    }

    func homeStateURL(for runtime: CodexIntegrationRuntime) -> URL {
        stateRootURL
            .appendingPathComponent("homes", isDirectory: true)
            .appendingPathComponent(homeKey(runtime.codexHomeURL.path), isDirectory: true)
    }

    func receiptURL(for runtime: CodexIntegrationRuntime) -> URL {
        homeStateURL(for: runtime).appendingPathComponent("receipt.json", isDirectory: false)
    }

    func profileConfigURL(for runtime: CodexIntegrationRuntime) -> URL {
        runtime.codexHomeURL.appendingPathComponent(
            CodexSkillsContract.profileConfigFileName,
            isDirectory: false
        )
    }

    /// `$CODEX_HOME/plugins/cache/<marketplace>/<plugin>` — the single-version
    /// plugin directory Toastty swaps atomically.
    func pluginCacheRootURL(for runtime: CodexIntegrationRuntime) -> URL {
        runtime.codexHomeURL
            .appendingPathComponent("plugins/cache", isDirectory: true)
            .appendingPathComponent(CodexSkillsContract.marketplaceName, isDirectory: true)
            .appendingPathComponent(CodexSkillsContract.pluginName, isDirectory: true)
    }

    func homeKey(_ path: String) -> String {
        SHA256.hash(data: Data(standardizedPath(path).utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func bundledDescriptor() throws -> ToasttyAgentPluginDescriptor {
        guard let source = sourcePluginURLProvider() else {
            throw CodexSkillsManagerError.bundledPluginUnavailable
        }
        return try ToasttyAgentPluginBundle.read(
            pluginRootURL: source,
            fileManager: fileManager
        )
    }

    func bundledMarketplaceManifestURL() throws -> URL {
        let root = sourceMarketplaceURLProvider()
            ?? URL(fileURLWithPath: "ToasttyAgentPluginBundle", isDirectory: true)
        let url = root.appendingPathComponent(
            ".agents/plugins/marketplace.json",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexSkillsManagerError.bundledMarketplaceUnavailable(url.path)
        }
        return url
    }

    func isProfileConflict(_ error: CodexSkillsManagerError) -> Bool {
        if case .profileConfigConflict = error { return true }
        return false
    }

    // MARK: - Profile overlay

    /// Throws when a foreign file occupies the Toastty profile path. Never
    /// writes.
    func checkProfileConfigOwnership(runtime: CodexIntegrationRuntime) throws {
        let url = profileConfigURL(for: runtime)
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              CodexManagedProfileConfig.isToasttyOwned(contents) else {
            throw CodexSkillsManagerError.profileConfigConflict(url.path)
        }
    }

    /// Writes the canonical Toastty overlay when it is missing or drifted.
    /// A foreign file at the profile path is never overwritten.
    func ensureProfileConfig(runtime: CodexIntegrationRuntime) throws {
        try checkProfileConfigOwnership(runtime: runtime)
        let url = profileConfigURL(for: runtime)
        let expected = Data(CodexManagedProfileConfig.fileContents.utf8)
        if (try? Data(contentsOf: url)) == expected { return }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try expected.write(to: url, options: .atomic)
    }

    // MARK: - Verification

    func verifyInstalledFiles(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        record: ReceiptRecord?,
        requireBundledDigest: Bool
    ) throws -> VerifiedInstallation {
        guard let record else { throw CodexSkillsManagerError.pluginNotInstalled }
        guard record.schemaVersion == 1,
              record.profileName == CodexSkillsContract.profileName else {
            throw CodexSkillsManagerError.ownedStateMismatch(receiptURL(for: runtime).path)
        }
        let cacheRoot = pluginCacheRootURL(for: runtime)
        let recordedCacheURL = URL(fileURLWithPath: record.cachePath, isDirectory: true)
        guard standardizedPath(recordedCacheURL.deletingLastPathComponent().path)
            == standardizedPath(cacheRoot.path) else {
            throw CodexSkillsManagerError.ownedStateMismatch(receiptURL(for: runtime).path)
        }
        // Keep the single-version invariant `codex plugin add` maintains.
        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        guard versionDirectories.count == 1,
              versionDirectories.first.map({ standardizedPath($0.path) })
                  == standardizedPath(recordedCacheURL.path) else {
            throw CodexSkillsManagerError.installedPluginMismatch(cacheRoot.path)
        }
        let installed = try ToasttyAgentPluginBundle.read(
            pluginRootURL: recordedCacheURL,
            fileManager: fileManager
        )
        guard installed.version == record.installedVersion,
              installed.contentDigest == record.installedDigest,
              installed.skillNames == record.skillNames else {
            throw CodexSkillsManagerError.installedPluginMismatch(record.cachePath)
        }
        if requireBundledDigest, installed.contentDigest != bundled.contentDigest {
            throw CodexSkillsManagerError.installedPluginMismatch(record.cachePath)
        }
        return VerifiedInstallation(
            configuration: launchConfiguration(runtime: runtime, descriptor: installed),
            record: record
        )
    }

    // MARK: - Provisioning

    func provision(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        oldVerified: VerifiedInstallation?,
        deadline: Date
    ) throws -> VerifiedInstallation {
        try checkDeadline(deadline)
        // Fail fast on a foreign profile file before any subprocess work.
        try checkProfileConfigOwnership(runtime: runtime)
        if legacyStateFileExists(runtime) {
            try performLegacyCleanup(runtime: runtime, deadline: deadline)
        }

        let installed = try populateCache(
            runtime: runtime,
            bundled: bundled,
            oldVerified: oldVerified,
            deadline: deadline
        )
        let record = ReceiptRecord(
            schemaVersion: 1,
            profileName: CodexSkillsContract.profileName,
            cachePath: installed.pluginRootURL.path,
            installedVersion: installed.version,
            installedDigest: installed.contentDigest,
            skillNames: installed.skillNames,
            codexExecutablePath: runtime.executableURL.path,
            codexExecutableSignature: metadataSignature(runtime.executableURL)
        )
        try writeReceipt(record, runtime: runtime)
        try ensureProfileConfig(runtime: runtime)
        return VerifiedInstallation(
            configuration: launchConfiguration(runtime: runtime, descriptor: installed),
            record: record
        )
    }

    /// Installs the bundled plugin through the real Codex CLI in a throwaway
    /// `CODEX_HOME` so the cache bytes are canonical, verifies them against
    /// the bundle, and atomically swaps the produced subtree into the real
    /// cache.
    func populateCache(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        oldVerified: VerifiedInstallation?,
        deadline: Date
    ) throws -> ToasttyAgentPluginDescriptor {
        let stagingRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-codex-plugin-populate-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        // Stage the marketplace fixture inside the throwaway root.
        let stagedMarketplaceURL = stagingRoot.appendingPathComponent("marketplace", isDirectory: true)
        let stagedManifestURL = stagedMarketplaceURL.appendingPathComponent(
            ".agents/plugins/marketplace.json",
            isDirectory: false
        )
        let stagedPluginURL = stagedMarketplaceURL.appendingPathComponent(
            "plugins/\(CodexSkillsContract.pluginName)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: stagedManifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: bundledMarketplaceManifestURL(), to: stagedManifestURL)
            try fileManager.createDirectory(
                at: stagedPluginURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: bundled.pluginRootURL, to: stagedPluginURL)
            try normalizeScriptPermissions(in: stagedPluginURL)
            clearQuarantine(from: stagedPluginURL)
        } catch let error as CodexSkillsManagerError {
            throw error
        } catch {
            throw CodexSkillsManagerError.copyFailed(stagedPluginURL.path)
        }
        let staged = try ToasttyAgentPluginBundle.read(
            pluginRootURL: stagedPluginURL,
            fileManager: fileManager
        )
        guard staged.contentDigest == bundled.contentDigest else {
            throw CodexSkillsManagerError.copyFailed(stagedPluginURL.path)
        }
        try checkDeadline(deadline)

        // Install through the CLI against the throwaway home.
        let throwawayHomeURL = stagingRoot.appendingPathComponent("codex-home", isDirectory: true)
        try fileManager.createDirectory(at: throwawayHomeURL, withIntermediateDirectories: true)
        let throwawayRuntime = CodexIntegrationRuntime(
            executableURL: runtime.executableURL,
            processEnvironment: CodexProcessEnvironment(
                codexHomeURL: throwawayHomeURL,
                path: runtime.processEnvironment.path
            ),
            workingDirectoryURL: stagingRoot
        )
        let marketplaceName = try pluginClient.addMarketplace(
            runtime: throwawayRuntime,
            sourcePath: stagedMarketplaceURL.path,
            deadline: deadline
        )
        guard marketplaceName == CodexSkillsContract.marketplaceName else {
            throw CodexSkillsManagerError.pluginInstallMismatch
        }
        let installation = try pluginClient.installPlugin(
            runtime: throwawayRuntime,
            selector: CodexSkillsContract.pluginSelector,
            deadline: deadline
        )
        guard installation.pluginID == CodexSkillsContract.pluginSelector,
              installation.name == CodexSkillsContract.pluginName,
              installation.marketplaceName == CodexSkillsContract.marketplaceName else {
            throw CodexSkillsManagerError.pluginInstallMismatch
        }
        let producedPluginDirURL = throwawayHomeURL
            .appendingPathComponent("plugins/cache", isDirectory: true)
            .appendingPathComponent(CodexSkillsContract.marketplaceName, isDirectory: true)
            .appendingPathComponent(CodexSkillsContract.pluginName, isDirectory: true)
        let producedVersionURL = URL(fileURLWithPath: installation.installedPath, isDirectory: true)
        guard standardizedPath(producedVersionURL.deletingLastPathComponent().path)
            == standardizedPath(producedPluginDirURL.path) else {
            throw CodexSkillsManagerError.pluginInstallMismatch
        }
        let produced = try ToasttyAgentPluginBundle.read(
            pluginRootURL: producedVersionURL,
            fileManager: fileManager
        )
        guard produced.version == bundled.version,
              produced.contentDigest == bundled.contentDigest else {
            throw CodexSkillsManagerError.installedPluginMismatch(
                "\(installation.installedPath) (expected \(bundled.version)/\(bundled.contentDigest), found \(produced.version)/\(produced.contentDigest))"
            )
        }
        // The CLI copy may drop helper modes or add quarantine; normalize the
        // Toastty-owned bytes before they reach the real cache. The digest
        // covers file bytes only, so this cannot invalidate verification.
        try normalizeScriptPermissions(in: producedVersionURL)
        clearQuarantine(from: producedVersionURL)
        try checkDeadline(deadline)

        try swapCacheSubtree(
            producedPluginDirURL: producedPluginDirURL,
            runtime: runtime,
            bundled: bundled,
            oldVerified: oldVerified
        )
        let finalVersionURL = pluginCacheRootURL(for: runtime)
            .appendingPathComponent(producedVersionURL.lastPathComponent, isDirectory: true)
        return try ToasttyAgentPluginBundle.read(
            pluginRootURL: finalVersionURL,
            fileManager: fileManager
        )
    }

    /// Stage sibling, rename old out, rename new in, remove old — keeping the
    /// plugin directory single-version like `codex plugin add` does.
    func swapCacheSubtree(
        producedPluginDirURL: URL,
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        oldVerified: VerifiedInstallation?
    ) throws {
        let cacheRoot = pluginCacheRootURL(for: runtime)
        let parent = cacheRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagingURL = parent.appendingPathComponent(".toastty-staging-\(UUID().uuidString)", isDirectory: true)
        let retiredURL = parent.appendingPathComponent(".toastty-old-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: producedPluginDirURL, to: stagingURL)
        } catch {
            // The throwaway home may sit on another volume; fall back to a copy.
            do {
                try fileManager.copyItem(at: producedPluginDirURL, to: stagingURL)
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw CodexSkillsManagerError.cacheSwapFailed(error.localizedDescription)
            }
        }

        var retiredOld = false
        do {
            if fileManager.fileExists(atPath: cacheRoot.path) {
                try fileManager.moveItem(at: cacheRoot, to: retiredURL)
                retiredOld = true
            }
            try fileManager.moveItem(at: stagingURL, to: cacheRoot)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if retiredOld {
                try restoreRetiredCache(
                    retiredURL: retiredURL,
                    cacheRoot: cacheRoot,
                    runtime: runtime,
                    bundled: bundled,
                    swapError: error
                )
            }
            throw CodexSkillsManagerError.cacheSwapFailed(error.localizedDescription)
        }
        if retiredOld {
            try? fileManager.removeItem(at: retiredURL)
        }
    }

    func restoreRetiredCache(
        retiredURL: URL,
        cacheRoot: URL,
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        swapError: Error
    ) throws {
        do {
            if fileManager.fileExists(atPath: cacheRoot.path) {
                try fileManager.removeItem(at: cacheRoot)
            }
            try fileManager.moveItem(at: retiredURL, to: cacheRoot)
            _ = try verifyInstalledFiles(
                runtime: runtime,
                bundled: bundled,
                record: readReceipt(runtime),
                requireBundledDigest: false
            )
        } catch {
            throw CodexSkillsManagerError.rollbackUnverified(
                "\(swapError.localizedDescription) Rollback check: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Legacy cleanup

    /// One-shot migration for machines provisioned by the retired mechanism
    /// (user-config marketplace registration, CLI-installed plugin,
    /// `~/.toastty/codex-plugin` staging, `state.json`). The stale
    /// `skills.config` disabled entries in the user's config are deliberately
    /// left alone: missing-skill tombstones are proven tolerated, and never
    /// touching the user's config is the point of the new mechanism.
    func performLegacyCleanup(
        runtime: CodexIntegrationRuntime,
        deadline: Date
    ) throws {
        let legacyStateURL = legacyStateURL(for: runtime)
        let legacyRecord = (try? Data(contentsOf: legacyStateURL))
            .flatMap { try? JSONDecoder().decode(LegacyOwnershipRecord.self, from: $0) }
        // An undecodable state file still attempts the ownership-checked CLI
        // deregistration against the computed default marketplace identity so
        // the user-config registration is not orphaned.
        let expectedMarketplacePath = legacyRecord?.marketplacePath
            ?? legacyMarketplaceURL(for: runtime).path

        do {
            let marketplaces = try pluginClient.listMarketplaces(runtime: runtime, deadline: deadline)
            if let marketplace = marketplaces.first(where: { $0.name == CodexSkillsContract.marketplaceName }),
               standardizedPath(marketplace.rootPath) == standardizedPath(expectedMarketplacePath) {
                let plugins = try pluginClient.listInstalledPlugins(runtime: runtime, deadline: deadline)
                if plugins.contains(where: { $0.pluginID == CodexSkillsContract.pluginSelector }) {
                    try pluginClient.removePlugin(
                        runtime: runtime,
                        selector: CodexSkillsContract.pluginSelector,
                        deadline: deadline
                    )
                }
                let hasForeignDependent = plugins.contains {
                    $0.marketplaceName == CodexSkillsContract.marketplaceName
                        && $0.pluginID != CodexSkillsContract.pluginSelector
                }
                if hasForeignDependent == false {
                    try pluginClient.removeMarketplace(
                        runtime: runtime,
                        name: CodexSkillsContract.marketplaceName,
                        deadline: deadline
                    )
                }
            }
        } catch let error as CodexPluginCLIError where error.isUnsupported {
            // A Codex without plugin management cannot be holding the legacy
            // registration; continue with filesystem cleanup.
        } catch let error where isRetryableLegacyCLIFailure(error) {
            // The CLI could not run at all (missing executable, spawn
            // failure, 126/127, timeout). Leave every piece of legacy state
            // in place — including state.json — so a later launch with a
            // working CLI retries the deregistration, and let provisioning
            // proceed regardless.
            return
        } catch {
            throw CodexSkillsManagerError.legacyCleanupFailed(error.localizedDescription)
        }

        do {
            let legacyMarketplaceURL = legacyMarketplaceURL(for: runtime)
            if fileManager.fileExists(atPath: legacyMarketplaceURL.path) {
                try fileManager.removeItem(at: legacyMarketplaceURL)
            }
            if fileManager.fileExists(atPath: legacyStateURL.path) {
                try fileManager.removeItem(at: legacyStateURL)
            }
            try removeLegacyVersionsIfUnused()
        } catch {
            throw CodexSkillsManagerError.legacyCleanupFailed(error.localizedDescription)
        }
    }

    /// CLI failures that mean "Codex could not run right now" rather than
    /// "the deregistration was rejected"; these defer legacy cleanup instead
    /// of counting toward the failure circuit breaker.
    func isRetryableLegacyCLIFailure(_ error: Error) -> Bool {
        guard let cliError = error as? CodexPluginCLIError else { return false }
        switch cliError {
        case .executableUnavailable, .launchFailed, .timedOut:
            return true
        case .commandFailed:
            return cliError.isRuntimeUnavailable
        case .malformedJSON:
            return false
        }
    }

    var legacyStableMarketplaceURL: URL {
        homeDirectoryURL.appendingPathComponent(".toastty/codex-plugin", isDirectory: true)
    }

    var legacyVersionsRootURL: URL {
        stateRootURL.appendingPathComponent("versions", isDirectory: true)
    }

    func legacyStateURL(for runtime: CodexIntegrationRuntime) -> URL {
        homeStateURL(for: runtime).appendingPathComponent("state.json", isDirectory: false)
    }

    func legacyStateFileExists(_ runtime: CodexIntegrationRuntime) -> Bool {
        fileManager.fileExists(atPath: legacyStateURL(for: runtime).path)
    }

    func legacyMarketplaceURL(for runtime: CodexIntegrationRuntime) -> URL {
        let defaultCodexHome = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        if standardizedPath(runtime.codexHomeURL.path) == standardizedPath(defaultCodexHome.path) {
            return legacyStableMarketplaceURL
        }
        return homeStateURL(for: runtime).appendingPathComponent("marketplace", isDirectory: true)
    }

    func removeLegacyVersionsIfUnused() throws {
        let homesRoot = stateRootURL.appendingPathComponent("homes", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: homesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "state.json" {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    return
                }
            }
        }
        if fileManager.fileExists(atPath: legacyVersionsRootURL.path) {
            try fileManager.removeItem(at: legacyVersionsRootURL)
        }
    }

    // MARK: - Staged-copy normalization

    func normalizeScriptPermissions(in pluginRootURL: URL) throws {
        let skills = pluginRootURL.appendingPathComponent("skills", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: skills,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw CodexSkillsManagerError.copyFailed(pluginRootURL.path)
        }
        for case let url as URL in enumerator {
            guard url.pathComponents.contains("scripts"),
                  (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                continue
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func clearQuarantine(from pluginRootURL: URL) {
        removeQuarantineAttribute(at: pluginRootURL)
        guard let enumerator = fileManager.enumerator(
            at: pluginRootURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            removeQuarantineAttribute(at: url)
        }
    }

    func removeQuarantineAttribute(at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            "com.apple.quarantine".withCString { attribute in
                _ = Darwin.removexattr(path, attribute, 0)
            }
        }
    }

    // MARK: - Records, statuses, caching

    func launchConfiguration(
        runtime: CodexIntegrationRuntime,
        descriptor: ToasttyAgentPluginDescriptor
    ) -> CodexSkillsLaunchConfiguration {
        CodexSkillsLaunchConfiguration(
            profileName: CodexSkillsContract.profileName,
            codexHomePath: runtime.codexHomeURL.path,
            skillsRootPath: descriptor.skillsRootURL.path,
            version: descriptor.version,
            contentDigest: descriptor.contentDigest
        )
    }

    func readReceipt(_ runtime: CodexIntegrationRuntime) -> ReceiptRecord? {
        guard let data = try? Data(contentsOf: receiptURL(for: runtime)) else { return nil }
        return try? JSONDecoder().decode(ReceiptRecord.self, from: data)
    }

    func writeReceipt(
        _ record: ReceiptRecord,
        runtime: CodexIntegrationRuntime
    ) throws {
        let url = receiptURL(for: runtime)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    func conflictPreparation(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        error: CodexSkillsManagerError
    ) -> CodexSkillsPreparation {
        CodexSkillsPreparation(
            configuration: nil,
            status: failedStatus(
                runtime: runtime,
                bundled: bundled,
                detail: error.localizedDescription
            ),
            installedOrUpdated: false,
            firstInstallSucceeded: false
        )
    }

    func readyStatus(
        bundled: ToasttyAgentPluginDescriptor,
        record: ReceiptRecord,
        runtime: CodexIntegrationRuntime,
        hasActiveManagedCodexSession: Bool = false
    ) -> CodexSkillsStatus {
        let updatePending = record.installedDigest != bundled.contentDigest
        let repairPending = pendingRepair(for: runtime)
        let detail: String
        if repairPending {
            detail = "A repair will run before the next managed Codex launch."
        } else if updatePending {
            detail = "A Toastty skills update will be installed before the next managed Codex launch."
        } else {
            detail = "Toastty's four skills are ready for managed Codex sessions."
        }
        return CodexSkillsStatus(
            availability: .ready,
            detail: detail,
            bundledVersion: bundled.version,
            installedVersion: record.installedVersion,
            bundledDigest: bundled.contentDigest,
            installedDigest: record.installedDigest,
            cachePath: record.cachePath,
            profileConfigPath: profileConfigURL(for: runtime).path,
            updatePending: updatePending,
            repairPending: repairPending,
            hasActiveManagedSession: hasActiveManagedCodexSession
        )
    }

    func failedStatus(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        detail: String
    ) -> CodexSkillsStatus {
        let record = readReceipt(runtime)
        return CodexSkillsStatus(
            availability: .failed,
            detail: detail,
            bundledVersion: bundled.version,
            installedVersion: record?.installedVersion,
            bundledDigest: bundled.contentDigest,
            installedDigest: record?.installedDigest,
            cachePath: record?.cachePath,
            profileConfigPath: profileConfigURL(for: runtime).path,
            updatePending: record?.installedDigest != bundled.contentDigest,
            repairPending: pendingRepair(for: runtime),
            hasActiveManagedSession: false
        )
    }

    func cache(
        _ verified: VerifiedInstallation,
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor
    ) {
        let entry = CachedConfiguration(
            configuration: verified.configuration,
            record: verified.record,
            fingerprint: fingerprint(runtime: runtime, bundled: bundled, record: verified.record)
        )
        cacheLock.lock()
        cachedConfigurations[runtimeKey(runtime)] = entry
        cacheLock.unlock()
    }

    func cachedEntry(runtime: CodexIntegrationRuntime) -> CachedConfiguration? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedConfigurations[runtimeKey(runtime)]
    }

    func clearCachedConfiguration(_ runtime: CodexIntegrationRuntime) {
        cacheLock.lock()
        cachedConfigurations.removeValue(forKey: runtimeKey(runtime))
        cacheLock.unlock()
    }

    func fingerprint(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        record: ReceiptRecord?
    ) -> String {
        [
            runtimeKey(runtime),
            metadataSignature(runtime.executableURL),
            bundled.contentDigest,
            dataSignature(receiptURL(for: runtime)),
            dataSignature(profileConfigURL(for: runtime)),
            record.map { metadataSignature(URL(fileURLWithPath: $0.cachePath)) } ?? "none",
        ].joined(separator: "|")
    }

    func failureSignature(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor
    ) -> String {
        [
            runtimeKey(runtime),
            metadataSignature(runtime.executableURL),
            bundled.contentDigest,
            dataSignature(profileConfigURL(for: runtime)),
        ].joined(separator: "|")
    }

    func runtimeKey(_ runtime: CodexIntegrationRuntime) -> String {
        "\(runtime.executableURL.path)|\(runtime.codexHomeURL.path)"
    }

    func metadataSignature(_ url: URL) -> String {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return "missing"
        }
        return [
            (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "0",
            (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "0",
            (attributes[.size] as? NSNumber)?.stringValue ?? "0",
            String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
        ].joined(separator: ":")
    }

    func dataSignature(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "missing" }
        return String(data.hashValue)
    }

    func removeDirectoryIfEmpty(_ url: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ), contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func acquireOperationLock(until deadline: Date) throws {
        while Self.operationLock.try() == false {
            try checkDeadline(deadline)
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func checkDeadline(_ deadline: Date) throws {
        guard Date() < deadline else {
            throw CodexSkillsManagerError.operationTimedOut
        }
    }

    func pendingRepair(for runtime: CodexIntegrationRuntime) -> Bool {
        pendingRepair(forHomePath: runtime.codexHomeURL.path)
    }

    func pendingRepair(forHomePath path: String) -> Bool {
        repairStateLock.lock()
        defer { repairStateLock.unlock() }
        return pendingRepairHomes.contains(path)
    }

    func markPendingRepair(for runtime: CodexIntegrationRuntime) {
        repairStateLock.lock()
        pendingRepairHomes.insert(runtime.codexHomeURL.path)
        repairStateLock.unlock()
    }

    func clearPendingRepair(for runtime: CodexIntegrationRuntime) {
        repairStateLock.lock()
        pendingRepairHomes.remove(runtime.codexHomeURL.path)
        repairStateLock.unlock()
    }

    func failureCount(for signature: String) -> Int {
        repairStateLock.lock()
        defer { repairStateLock.unlock() }
        return failureCounts[signature] ?? 0
    }

    func incrementFailure(for signature: String) {
        repairStateLock.lock()
        failureCounts[signature, default: 0] += 1
        repairStateLock.unlock()
    }

    func clearFailure(for signature: String) {
        repairStateLock.lock()
        failureCounts.removeValue(forKey: signature)
        repairStateLock.unlock()
    }

    func clearFailuresForRuntime(_ runtime: CodexIntegrationRuntime) {
        let prefix = runtimeKey(runtime)
        repairStateLock.lock()
        failureCounts = failureCounts.filter { $0.key.hasPrefix(prefix) == false }
        repairStateLock.unlock()
    }
}
