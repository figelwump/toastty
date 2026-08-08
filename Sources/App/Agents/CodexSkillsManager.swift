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

/// Typed reason the user skills plugin was not delivered for a launch. User
/// plugin failures never affect shipped delivery; they surface only through
/// this diagnostic.
enum CodexUserSkillsDiagnostic: Equatable, Sendable {
    case populationFailed(String)
    case digestMismatch(String)
    case staleCache(String)
    case cleanupFailed(String)
    case profileUnavailable(String)
    case operationTimedOut
}

enum CodexUserSkillsDeliveryState: Equatable, Sendable {
    case notDelivered
    case delivered(version: String, contentDigest: String)
    case failed(CodexUserSkillsDiagnostic)
}

struct CodexSkillsPreparation: Equatable, Sendable {
    let configuration: CodexSkillsLaunchConfiguration?
    let status: CodexSkillsStatus
    let installedOrUpdated: Bool
    let firstInstallSucceeded: Bool
    /// Outcome of the user-plugin phase. `.notDelivered` for shipped-only
    /// preparations (no snapshot requested or shipped delivery unavailable).
    let userSkills: CodexUserSkillsDeliveryState

    init(
        configuration: CodexSkillsLaunchConfiguration?,
        status: CodexSkillsStatus,
        installedOrUpdated: Bool,
        firstInstallSucceeded: Bool,
        userSkills: CodexUserSkillsDeliveryState = .notDelivered
    ) {
        self.configuration = configuration
        self.status = status
        self.installedOrUpdated = installedOrUpdated
        self.firstInstallSucceeded = firstInstallSucceeded
        self.userSkills = userSkills
    }

    func withUserSkills(_ userSkills: CodexUserSkillsDeliveryState) -> CodexSkillsPreparation {
        CodexSkillsPreparation(
            configuration: configuration,
            status: status,
            installedOrUpdated: installedOrUpdated,
            firstInstallSucceeded: firstInstallSucceeded,
            userSkills: userSkills
        )
    }
}

enum CodexSkillsManagerError: LocalizedError, Equatable {
    case bundledPluginUnavailable
    case bundledMarketplaceUnavailable(String)
    case invalidCodexHome(String)
    case operationTimedOut
    case profileConfigConflict(String)
    case profileConfigChanged(String)
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
        case .profileConfigChanged(let path):
            return "The Codex profile changed while Toastty was updating it at \(path). Toastty preserved the newer contents; try again."
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
    /// The user-plugin phase serializes on its own lock: it guards state
    /// disjoint from the shipped plugin (user cache subtree, user receipt),
    /// so a slow user population can never make a concurrent shipped
    /// preparation wait out its budget on `operationLock` — lock contention
    /// must not feed the shipped failure accounting.
    private static let userOperationLock = NSLock()
    /// The only state both phases write is the profile overlay file; its
    /// read-compare-rewrite is protected by this dedicated, briefly held
    /// lock.
    private static let profileOverlayLock = NSLock()

    private let repairStateLock = NSLock()
    private var pendingRepairHomes = Set<String>()
    private var failureCounts: [String: Int] = [:]

    private let homeDirectoryURL: URL
    /// Toastty-side storage (receipts, legacy staging) follows the resolved
    /// runtime paths so runtime-isolated app instances never write into the
    /// real `~/.toastty`. `homeDirectoryURL` still locates the user's default
    /// `~/.codex`, which is not Toastty state and is never isolated.
    private let toasttyConfigDirectoryURL: URL
    private let agentPluginsDirectoryURL: URL
    private let sourcePluginURLProvider: @Sendable () -> URL?
    private let sourceMarketplaceURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager
    private let pluginClient: any CodexPluginCLIManaging
    private let cacheLock = NSLock()
    private var cachedConfigurations: [String: CachedConfiguration] = [:]

    init(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
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
        toasttyConfigDirectoryURL = runtimePaths.configDirectoryURL
        agentPluginsDirectoryURL = runtimePaths.agentPluginsDirectoryURL
        self.sourcePluginURLProvider = sourcePluginURLProvider
        self.sourceMarketplaceURLProvider = sourceMarketplaceURLProvider
        self.fileManager = fileManager
        self.pluginClient = pluginClient
    }

    var stateRootURL: URL {
        agentPluginsDirectoryURL.appendingPathComponent("codex", isDirectory: true)
    }

    /// Sweep seam: holds both the shipped and user operation locks (in the
    /// same order as `uninstall`) so `ToasttySkillArtifactSweeper`'s Codex
    /// cache-litter pass cannot race an in-flight cache swap in either
    /// plugin phase.
    static func withExclusiveCacheAccess<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        userOperationLock.lock()
        defer { userOperationLock.unlock() }
        return try body()
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

        // Standalone guard, independent of the legacy state file: machines
        // that ran the retired mechanism carry disabled `toastty:*`
        // `[[skills.config]]` entries in the user's config that silently
        // suppress the profile-delivered skills. Idempotent and cheap when
        // the config is clean; the in-memory fast path above skips it, so it
        // runs at most once per process in the steady state.
        neutralizeLegacySkillsConfigEntriesIfNeeded(runtime: runtime)

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
        // Restored launches are typically the first Codex preparation after
        // startup; neutralize retired skills.config suppressions before the
        // fast path can hand out a delivery they would silently disable.
        neutralizeLegacySkillsConfigEntriesIfNeeded(runtime: runtime)
        let fastResult = lockedRestoreFastPath(runtime: runtime, bundled: bundled)
        Self.operationLock.unlock()
        if let fastResult {
            return fastResult
        }
        return try prepareForManagedLaunch(runtime: runtime)
    }

    /// Shipped provisioning followed by the isolated user-plugin phase. The
    /// resolution provenance decides destructiveness: `.empty` (a completed
    /// scan confirmed zero accepted skills) converges earlier user delivery
    /// back to shipped-only; `.unavailable` (timeout, build error,
    /// unverifiable state) leaves delivered user state completely untouched;
    /// `.snapshot` delivers. Any user-plugin error leaves the shipped result
    /// exactly as the resolution-free overload would have produced it, with a
    /// typed diagnostic in `userSkills`, and never touches the shipped
    /// failure circuit breaker.
    func prepareForManagedLaunch(
        runtime: CodexIntegrationRuntime,
        userSkills resolution: UserSkillSnapshotResolution
    ) throws -> CodexSkillsPreparation {
        let shipped = try prepareForManagedLaunch(runtime: runtime)
        let userState = applyUserPluginPhase(
            runtime: runtime,
            resolution: resolution,
            shippedDelivered: shipped.configuration != nil,
            allowPopulation: true
        )
        return shipped.withUserSkills(userState)
    }

    /// Convenience mapping kept for callers/tests that resolve the snapshot
    /// themselves: a snapshot delivers, nil is the confirmed-empty resolution
    /// (destructive convergence).
    func prepareForManagedLaunch(
        runtime: CodexIntegrationRuntime,
        userSnapshot: UserSkillPluginSnapshot?
    ) throws -> CodexSkillsPreparation {
        try prepareForManagedLaunch(
            runtime: runtime,
            userSkills: userSnapshot.map { .snapshot($0) } ?? .empty
        )
    }

    /// Restored variant: the user plugin is byte-verified against the
    /// already-built snapshot only. A stale or unverifiable user cache drops
    /// the user entry from the profile with a typed diagnostic while shipped
    /// restore proceeds; restored preparation never runs user-plugin CLI
    /// population and never enumerates user source packages.
    func prepareForRestoredManagedLaunch(
        runtime: CodexIntegrationRuntime,
        userSkills resolution: UserSkillSnapshotResolution
    ) throws -> CodexSkillsPreparation {
        let shipped = try prepareForRestoredManagedLaunch(runtime: runtime)
        let userState = applyUserPluginPhase(
            runtime: runtime,
            resolution: resolution,
            shippedDelivered: shipped.configuration != nil,
            allowPopulation: false
        )
        return shipped.withUserSkills(userState)
    }

    /// Convenience mapping; see `prepareForManagedLaunch(runtime:userSnapshot:)`.
    func prepareForRestoredManagedLaunch(
        runtime: CodexIntegrationRuntime,
        userSnapshot: UserSkillPluginSnapshot?
    ) throws -> CodexSkillsPreparation {
        try prepareForRestoredManagedLaunch(
            runtime: runtime,
            userSkills: userSnapshot.map { .snapshot($0) } ?? .empty
        )
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
        // Uninstall removes user-plugin state too, so it must exclude a
        // concurrent user phase as well.
        try acquireLock(Self.userOperationLock, until: deadline)
        defer { Self.userOperationLock.unlock() }

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
            let profileURL = profileConfigURL(for: runtime)
            try Self.withProfileOverlayLock {
                try removeManagedProfileContentsForUninstall(at: profileURL)
            }
            let cacheRoot = pluginCacheRootURL(for: runtime)
            if fileManager.fileExists(atPath: cacheRoot.path) {
                try fileManager.removeItem(at: cacheRoot)
            }
            removeDirectoryIfEmpty(cacheRoot.deletingLastPathComponent())
            // The user plugin cache and receipt are Toastty-owned state too.
            try removeUserPluginState(runtime: runtime)
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

    /// Sidecar recording the verified user-plugin cache identity for one
    /// `CODEX_HOME`, kept separate from the shipped receipt so either plugin
    /// can be verified or dropped without touching the other.
    struct UserPluginReceiptRecord: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let pluginName: String
        let cachePath: String
        let installedVersion: String
        /// `ToasttyAgentPluginBundle.contentDigest` of the cached version dir;
        /// equals the snapshot's `pluginContentDigest` when in sync.
        let installedDigest: String
        let sourceDigest: String
        let acceptedPackageNames: [String]
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

    func userReceiptURL(for runtime: CodexIntegrationRuntime) -> URL {
        homeStateURL(for: runtime).appendingPathComponent("user-receipt.json", isDirectory: false)
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
        cacheRootURL(
            runtime: runtime,
            marketplaceName: CodexSkillsContract.marketplaceName,
            pluginName: CodexSkillsContract.pluginName
        )
    }

    func userPluginCacheRootURL(for runtime: CodexIntegrationRuntime) -> URL {
        cacheRootURL(
            runtime: runtime,
            marketplaceName: CodexUserSkillsContract.marketplaceName,
            pluginName: CodexUserSkillsContract.pluginName
        )
    }

    func cacheRootURL(
        runtime: CodexIntegrationRuntime,
        marketplaceName: String,
        pluginName: String
    ) -> URL {
        runtime.codexHomeURL
            .appendingPathComponent("plugins/cache", isDirectory: true)
            .appendingPathComponent(marketplaceName, isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
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

    /// Ensures Toastty's marker and plugin tables while retaining every other
    /// profile setting. A foreign file at the profile path is never
    /// overwritten. By default
    /// the user entry is included exactly while a user receipt points at an
    /// existing cache subtree (the cheap probe); the user-plugin phase can
    /// pass an explicit `includeUserPlugin` decision instead — used to force
    /// a shipped-only overlay when delivered user state exists on disk but
    /// failed byte verification.
    func ensureProfileConfig(
        runtime: CodexIntegrationRuntime,
        includeUserPlugin: Bool? = nil
    ) throws {
        // The overlay is the one file both the shipped phase (under
        // `operationLock`) and the user phase (under `userOperationLock`)
        // rewrite; this briefly-held dedicated lock serializes the
        // read-compare-rewrite across them.
        Self.profileOverlayLock.lock()
        defer { Self.profileOverlayLock.unlock() }
        try checkProfileConfigOwnership(runtime: runtime)
        let url = profileConfigURL(for: runtime)
        let shouldIncludeUserPlugin = includeUserPlugin
            ?? userPluginStateLooksDeliverable(runtime: runtime)
        for _ in 0..<3 {
            let original = try? Data(contentsOf: url)
            let expectedContents: String
            if let original, let existing = String(data: original, encoding: .utf8) {
                expectedContents = CodexManagedProfileConfig.mergedFileContents(
                    preserving: existing,
                    includeUserPlugin: shouldIncludeUserPlugin
                )
            } else {
                expectedContents = CodexManagedProfileConfig.fileContents(
                    includeUserPlugin: shouldIncludeUserPlugin
                )
            }
            let expected = Data(expectedContents.utf8)
            if original == expected { return }
            guard (try? Data(contentsOf: url)) == original else { continue }
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try expected.write(to: url, options: .atomic)
            return
        }
        throw CodexSkillsManagerError.profileConfigChanged(url.path)
    }

    func removeManagedProfileContentsForUninstall(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        for _ in 0..<3 {
            let original = try Data(contentsOf: url)
            guard let contents = String(data: original, encoding: .utf8) else { return }
            guard CodexManagedProfileConfig.isToasttyOwned(contents) else { return }
            let preserved = CodexManagedProfileConfig.removingManagedContents(from: contents)
            guard (try? Data(contentsOf: url)) == original else { continue }
            if preserved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try fileManager.removeItem(at: url)
            } else {
                try Data(preserved.utf8).write(to: url, options: .atomic)
            }
            return
        }
        throw CodexSkillsManagerError.profileConfigChanged(url.path)
    }

    /// Cheap existence-only probe deciding profile contents; full byte
    /// verification stays with the user-plugin phase.
    func userPluginStateLooksDeliverable(runtime: CodexIntegrationRuntime) -> Bool {
        guard let record = readUserReceipt(runtime) else { return false }
        return fileManager.fileExists(atPath: record.cachePath)
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
        try verifySingleVersionCache(cacheRootURL: cacheRoot, recordedCacheURL: recordedCacheURL)
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

    /// Keep the single-version invariant `codex plugin add` maintains.
    func verifySingleVersionCache(cacheRootURL: URL, recordedCacheURL: URL) throws {
        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: cacheRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        guard versionDirectories.count == 1,
              versionDirectories.first.map({ standardizedPath($0.path) })
                  == standardizedPath(recordedCacheURL.path) else {
            throw CodexSkillsManagerError.installedPluginMismatch(cacheRootURL.path)
        }
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
        let produced = try installPluginIntoThrowawayHome(
            marketplaceName: CodexSkillsContract.marketplaceName,
            pluginName: CodexSkillsContract.pluginName,
            selector: CodexSkillsContract.pluginSelector,
            marketplaceSourceURL: stagedMarketplaceURL,
            runtime: runtime,
            stagingRoot: stagingRoot,
            deadline: deadline
        )
        let producedDescriptor = try ToasttyAgentPluginBundle.read(
            pluginRootURL: produced.versionURL,
            fileManager: fileManager
        )
        guard producedDescriptor.version == bundled.version,
              producedDescriptor.contentDigest == bundled.contentDigest else {
            throw CodexSkillsManagerError.installedPluginMismatch(
                "\(produced.installation.installedPath) (expected \(bundled.version)/\(bundled.contentDigest), found \(producedDescriptor.version)/\(producedDescriptor.contentDigest))"
            )
        }
        // The CLI copy may drop helper modes or add quarantine; normalize the
        // Toastty-owned bytes before they reach the real cache. The digest
        // covers file bytes only, so this cannot invalidate verification.
        try normalizeScriptPermissions(in: produced.versionURL)
        clearQuarantine(from: produced.versionURL)
        try checkDeadline(deadline)

        let cacheRoot = pluginCacheRootURL(for: runtime)
        try swapCacheSubtree(
            producedPluginDirURL: produced.pluginDirURL,
            cacheRootURL: cacheRoot
        ) { retiredURL, swapError in
            try self.restoreRetiredCache(
                retiredURL: retiredURL,
                cacheRoot: cacheRoot,
                runtime: runtime,
                bundled: bundled,
                swapError: swapError
            )
        }
        let finalVersionURL = cacheRoot
            .appendingPathComponent(produced.versionURL.lastPathComponent, isDirectory: true)
        return try ToasttyAgentPluginBundle.read(
            pluginRootURL: finalVersionURL,
            fileManager: fileManager
        )
    }

    struct ThrowawayInstallResult {
        let installation: CodexPluginInstallation
        /// `<throwaway>/plugins/cache/<marketplace>/<plugin>` — swapped as a
        /// whole into the real cache.
        let pluginDirURL: URL
        /// The single version directory the CLI produced inside `pluginDirURL`.
        let versionURL: URL
    }

    /// Shared population core: registers `marketplaceSourceURL` and installs
    /// `selector` with the real Codex CLI against a throwaway `CODEX_HOME`
    /// under `stagingRoot`, verifying the CLI reported the expected identity
    /// and produced its cache subtree at the expected location. Content
    /// verification stays with the callers (shipped and user plugins record
    /// different receipt shapes).
    func installPluginIntoThrowawayHome(
        marketplaceName: String,
        pluginName: String,
        selector: String,
        marketplaceSourceURL: URL,
        runtime: CodexIntegrationRuntime,
        stagingRoot: URL,
        deadline: Date
    ) throws -> ThrowawayInstallResult {
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
        let addedMarketplaceName = try pluginClient.addMarketplace(
            runtime: throwawayRuntime,
            sourcePath: marketplaceSourceURL.path,
            deadline: deadline
        )
        guard addedMarketplaceName == marketplaceName else {
            throw CodexSkillsManagerError.pluginInstallMismatch
        }
        let installation = try pluginClient.installPlugin(
            runtime: throwawayRuntime,
            selector: selector,
            deadline: deadline
        )
        guard installation.pluginID == selector,
              installation.name == pluginName,
              installation.marketplaceName == marketplaceName else {
            throw CodexSkillsManagerError.pluginInstallMismatch
        }
        let producedPluginDirURL = throwawayHomeURL
            .appendingPathComponent("plugins/cache", isDirectory: true)
            .appendingPathComponent(marketplaceName, isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        let producedVersionURL = URL(fileURLWithPath: installation.installedPath, isDirectory: true)
        guard standardizedPath(producedVersionURL.deletingLastPathComponent().path)
            == standardizedPath(producedPluginDirURL.path) else {
            throw CodexSkillsManagerError.pluginInstallMismatch
        }
        return ThrowawayInstallResult(
            installation: installation,
            pluginDirURL: producedPluginDirURL,
            versionURL: producedVersionURL
        )
    }

    /// Stage sibling, rename old out, rename new in, remove old — keeping the
    /// plugin directory single-version like `codex plugin add` does. When the
    /// final rename fails after the old subtree was retired,
    /// `restoreRetired` decides how to recover before the swap error is
    /// rethrown.
    func swapCacheSubtree(
        producedPluginDirURL: URL,
        cacheRootURL cacheRoot: URL,
        restoreRetired: (URL, Error) throws -> Void
    ) throws {
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
                try restoreRetired(retiredURL, error)
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

    // MARK: - User plugin phase

    /// Runs after (and fully independently of) shipped provisioning. Every
    /// error is absorbed into a typed `CodexUserSkillsDeliveryState`; nothing
    /// here throws to the caller, increments the shipped failure counters, or
    /// mutates shipped receipts/caches, so shipped delivery is exactly what it
    /// would have been with no user skills.
    func applyUserPluginPhase(
        runtime: CodexIntegrationRuntime,
        resolution: UserSkillSnapshotResolution,
        shippedDelivered: Bool,
        allowPopulation: Bool
    ) -> CodexUserSkillsDeliveryState {
        // Without a shipped configuration no `--profile` flag is injected, so
        // no plugin can reach the session; leave all user state untouched for
        // the next successful shipped launch to reconcile.
        guard shippedDelivered else { return .notDelivered }

        let deadline = Date().addingTimeInterval(Self.operationTimeout)
        do {
            try acquireLock(Self.userOperationLock, until: deadline)
        } catch {
            return .failed(.operationTimedOut)
        }
        defer { Self.userOperationLock.unlock() }

        let snapshot: UserSkillPluginSnapshot
        switch resolution {
        case .empty:
            // A completed scan confirmed the user has no accepted skills:
            // converge user-had-skills → user-has-none.
            do {
                try removeUserPluginState(runtime: runtime)
                try ensureProfileConfig(runtime: runtime)
                return .notDelivered
            } catch {
                return .failed(.cleanupFailed(error.localizedDescription))
            }

        case .unavailable:
            // The resolution could not complete (timeout, build error,
            // unverifiable snapshot store). This must never be conflated with
            // "the user has no skills": delivered files are never deleted. A
            // verified receipt-plus-cache keeps its profile entry and
            // delivers; delivered state that fails byte verification is
            // excluded from the overlay (so unverified bytes never load)
            // while cache and receipt stay on disk for a later definitive
            // resolution to reconcile.
            guard let record = readUserReceipt(runtime) else {
                // Nothing was ever delivered; nothing to exclude.
                return .notDelivered
            }
            guard (try? verifyUserInstalledFiles(runtime: runtime, record: record)) != nil else {
                try? ensureProfileConfig(runtime: runtime, includeUserPlugin: false)
                return .failed(.staleCache(userPluginCacheRootURL(for: runtime).path))
            }
            do {
                try ensureProfileConfig(runtime: runtime)
                return .delivered(
                    version: record.installedVersion,
                    contentDigest: record.installedDigest
                )
            } catch {
                return .failed(.profileUnavailable(error.localizedDescription))
            }

        case .snapshot(let resolved):
            snapshot = resolved
        }

        // Fast path: receipt plus cache bytes already match the snapshot.
        if let record = readUserReceipt(runtime),
           record.installedVersion == snapshot.version,
           record.installedDigest == snapshot.pluginContentDigest,
           record.sourceDigest == snapshot.sourceDigest,
           (try? verifyUserInstalledFiles(runtime: runtime, record: record)) != nil {
            do {
                try ensureProfileConfig(runtime: runtime)
                return .delivered(
                    version: record.installedVersion,
                    contentDigest: record.installedDigest
                )
            } catch {
                return .failed(.profileUnavailable(error.localizedDescription))
            }
        }

        guard allowPopulation else {
            // Restored launches never repopulate; a stale or unverifiable
            // user cache drops the user entry while shipped restore proceeds.
            return dropUserPlugin(
                runtime: runtime,
                diagnostic: .staleCache(userPluginCacheRootURL(for: runtime).path)
            )
        }

        do {
            let record = try populateUserCache(
                runtime: runtime,
                snapshot: snapshot,
                deadline: deadline
            )
            try ensureProfileConfig(runtime: runtime)
            return .delivered(
                version: record.installedVersion,
                contentDigest: record.installedDigest
            )
        } catch {
            return dropUserPlugin(runtime: runtime, diagnostic: userDiagnostic(from: error))
        }
    }

    /// Converges a failed or abandoned user delivery to "no user plugin":
    /// cache subtree and receipt removed, profile rewritten shipped-only.
    func dropUserPlugin(
        runtime: CodexIntegrationRuntime,
        diagnostic: CodexUserSkillsDiagnostic
    ) -> CodexUserSkillsDeliveryState {
        try? removeUserPluginState(runtime: runtime)
        try? ensureProfileConfig(runtime: runtime)
        return .failed(diagnostic)
    }

    func removeUserPluginState(runtime: CodexIntegrationRuntime) throws {
        let cacheRoot = userPluginCacheRootURL(for: runtime)
        if fileManager.fileExists(atPath: cacheRoot.path) {
            try fileManager.removeItem(at: cacheRoot)
        }
        removeDirectoryIfEmpty(cacheRoot.deletingLastPathComponent())
        let receiptURL = userReceiptURL(for: runtime)
        if fileManager.fileExists(atPath: receiptURL.path) {
            try fileManager.removeItem(at: receiptURL)
        }
    }

    /// Same mechanism as the shipped plugin: CLI install into a throwaway
    /// `CODEX_HOME` from the snapshot's marketplace fixture, digest-verify the
    /// produced bytes against `snapshot.pluginContentDigest`, and atomically
    /// swap the subtree into `$CODEX_HOME/plugins/cache/toastty-user/…`.
    func populateUserCache(
        runtime: CodexIntegrationRuntime,
        snapshot: UserSkillPluginSnapshot,
        deadline: Date
    ) throws -> UserPluginReceiptRecord {
        let stagingRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "toastty-codex-user-plugin-populate-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let produced = try installPluginIntoThrowawayHome(
            marketplaceName: CodexUserSkillsContract.marketplaceName,
            pluginName: CodexUserSkillsContract.pluginName,
            selector: CodexUserSkillsContract.pluginSelector,
            marketplaceSourceURL: snapshot.marketplaceRootURL,
            runtime: runtime,
            stagingRoot: stagingRoot,
            deadline: deadline
        )
        guard produced.installation.version == snapshot.version else {
            throw CodexSkillsManagerError.installedPluginMismatch(
                "\(produced.installation.installedPath) (expected version \(snapshot.version), found \(produced.installation.version))"
            )
        }
        let producedDigest = try ToasttyAgentPluginBundle.contentDigest(
            rootURL: produced.versionURL,
            fileManager: fileManager
        )
        guard producedDigest == snapshot.pluginContentDigest else {
            throw CodexSkillsManagerError.installedPluginMismatch(
                "\(produced.installation.installedPath) (expected \(snapshot.pluginContentDigest), found \(producedDigest))"
            )
        }
        // The digest covers bytes only; restore the snapshot's executable
        // modes the CLI copy may have dropped, and clear quarantine.
        try mirrorRegularFilePermissions(from: snapshot.pluginRootURL, to: produced.versionURL)
        clearQuarantine(from: produced.versionURL)
        try checkDeadline(deadline)

        let cacheRoot = userPluginCacheRootURL(for: runtime)
        try swapCacheSubtree(
            producedPluginDirURL: produced.pluginDirURL,
            cacheRootURL: cacheRoot
        ) { [self] retiredURL, _ in
            // Best-effort rollback: put the previous subtree back when
            // possible; otherwise leave the cache absent so the failure path
            // converges to shipped-only delivery.
            if fileManager.fileExists(atPath: cacheRoot.path) {
                try? fileManager.removeItem(at: cacheRoot)
            }
            try? fileManager.moveItem(at: retiredURL, to: cacheRoot)
        }
        let finalVersionURL = cacheRoot.appendingPathComponent(
            produced.versionURL.lastPathComponent,
            isDirectory: true
        )
        let finalDigest = try ToasttyAgentPluginBundle.contentDigest(
            rootURL: finalVersionURL,
            fileManager: fileManager
        )
        guard finalDigest == snapshot.pluginContentDigest else {
            throw CodexSkillsManagerError.installedPluginMismatch(finalVersionURL.path)
        }
        let record = UserPluginReceiptRecord(
            schemaVersion: 1,
            pluginName: CodexUserSkillsContract.pluginName,
            cachePath: finalVersionURL.path,
            installedVersion: snapshot.version,
            installedDigest: finalDigest,
            sourceDigest: snapshot.sourceDigest,
            acceptedPackageNames: snapshot.acceptedPackageNames
        )
        try writeUserReceipt(record, runtime: runtime)
        return record
    }

    /// Pure filesystem byte verification of the user cache against its
    /// receipt; the same single-version and recorded-location invariants as
    /// the shipped plugin, with the generic content digest replacing the
    /// shipped bundle reader (which validates the shipped skill set).
    @discardableResult
    func verifyUserInstalledFiles(
        runtime: CodexIntegrationRuntime,
        record: UserPluginReceiptRecord
    ) throws -> URL {
        guard record.schemaVersion == 1,
              record.pluginName == CodexUserSkillsContract.pluginName else {
            throw CodexSkillsManagerError.ownedStateMismatch(userReceiptURL(for: runtime).path)
        }
        let cacheRoot = userPluginCacheRootURL(for: runtime)
        let recordedCacheURL = URL(fileURLWithPath: record.cachePath, isDirectory: true)
        guard standardizedPath(recordedCacheURL.deletingLastPathComponent().path)
            == standardizedPath(cacheRoot.path) else {
            throw CodexSkillsManagerError.ownedStateMismatch(userReceiptURL(for: runtime).path)
        }
        try verifySingleVersionCache(cacheRootURL: cacheRoot, recordedCacheURL: recordedCacheURL)
        let digest = try ToasttyAgentPluginBundle.contentDigest(
            rootURL: recordedCacheURL,
            fileManager: fileManager
        )
        guard digest == record.installedDigest else {
            throw CodexSkillsManagerError.installedPluginMismatch(record.cachePath)
        }
        return recordedCacheURL
    }

    /// Applies the source tree's executable bits (0755/0644) to the same
    /// relative paths in the destination tree.
    func mirrorRegularFilePermissions(from sourceRootURL: URL, to destinationRootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: sourceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw CodexSkillsManagerError.copyFailed(destinationRootURL.path)
        }
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                continue
            }
            let relativeComponents = url.pathComponents.suffix(enumerator.level)
            var destinationURL = destinationRootURL
            for component in relativeComponents {
                destinationURL.appendPathComponent(component)
            }
            guard fileManager.fileExists(atPath: destinationURL.path) else { continue }
            let permissions = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            let isExecutable = (permissions?.uint16Value ?? 0) & 0o111 != 0
            try fileManager.setAttributes(
                [.posixPermissions: isExecutable ? 0o755 : 0o644],
                ofItemAtPath: destinationURL.path
            )
        }
    }

    func readUserReceipt(_ runtime: CodexIntegrationRuntime) -> UserPluginReceiptRecord? {
        guard let data = try? Data(contentsOf: userReceiptURL(for: runtime)) else { return nil }
        return try? JSONDecoder().decode(UserPluginReceiptRecord.self, from: data)
    }

    func writeUserReceipt(
        _ record: UserPluginReceiptRecord,
        runtime: CodexIntegrationRuntime
    ) throws {
        let url = userReceiptURL(for: runtime)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    func userDiagnostic(from error: Error) -> CodexUserSkillsDiagnostic {
        if let managerError = error as? CodexSkillsManagerError {
            switch managerError {
            case .installedPluginMismatch(let detail):
                return .digestMismatch(detail)
            case .operationTimedOut:
                return .operationTimedOut
            case .profileConfigConflict(let path):
                return .profileUnavailable(path)
            default:
                return .populationFailed(managerError.localizedDescription)
            }
        }
        if let cliError = error as? CodexPluginCLIError, case .timedOut = cliError {
            return .operationTimedOut
        }
        return .populationFailed(error.localizedDescription)
    }

    // MARK: - Legacy skills.config neutralization

    /// The retired branch mechanism disable-unioned `[[skills.config]]`
    /// entries (`name = "toastty:<skill>"`, `enabled = false`) into the
    /// user's main `config.toml` through the Codex app-server. Main-config
    /// skill settings apply under profile overlays (see
    /// docs/plans/evidence/codex-session-scoped-skills-2026-08-04.md), so the
    /// surviving entries silently suppress the profile-delivered shipped
    /// skills forever — confirmed live on a legacy machine. This surgical
    /// direct edit is deliberate: the app-server client was removed and the
    /// architecture test forbids reintroducing it, `codex plugin remove`
    /// never touches `skills.config`, and these blocks are Toastty-authored
    /// artifacts of the removed mechanism — deleting them completes Toastty's
    /// own uninstall. Whole toastty-named blocks are removed (not flipped to
    /// `enabled = true`) so no clutter remains; every other line is preserved
    /// byte-identically. The original file is backed up beside the receipts
    /// under Toastty's own state directory before the first edit, and the
    /// replacement is atomic. Fail-open: any anomaly (unreadable config,
    /// unexpected shape, failed write) leaves the file untouched, logs
    /// through the legacy-cleanup diagnostic pathway, and never blocks
    /// provisioning — shipped delivery proceeds exactly as today, with skills
    /// possibly staying suppressed on that machine until a later repair.
    func neutralizeLegacySkillsConfigEntriesIfNeeded(runtime: CodexIntegrationRuntime) {
        let configURL = runtime.codexHomeURL.appendingPathComponent("config.toml", isDirectory: false)
        guard let originalData = try? Data(contentsOf: configURL) else { return }
        guard let contents = String(data: originalData, encoding: .utf8) else {
            logLegacySkillsConfigAnomaly("config.toml is not valid UTF-8", configURL: configURL)
            return
        }
        // Cheap guard: none of the exact legacy skill names present means
        // nothing to do (the common steady state).
        guard Self.legacyDisabledSkillNames.contains(where: { contents.contains("\"\($0)\"") }) else {
            return
        }
        guard contents.contains("\r") == false else {
            logLegacySkillsConfigAnomaly(
                "config.toml uses unsupported line endings",
                configURL: configURL
            )
            return
        }
        // nil here is benign: a legacy name may appear in a block that is not
        // removable (for example re-enabled by the user) or outside a
        // well-formed block; both are left untouched without noise.
        guard let edited = Self.removingToasttySkillsConfigBlocks(from: contents) else { return }

        let backupURL = homeStateURL(for: runtime).appendingPathComponent(
            "config-backup-\(Self.legacyConfigBackupTimestamp()).toml",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try originalData.write(to: backupURL)
            let permissions = (try? fileManager.attributesOfItem(atPath: configURL.path))?[.posixPermissions]
            try Data(edited.utf8).write(to: configURL, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
            }
            ToasttyLog.info(
                "Removed retired Toastty skills.config entries from the Codex config",
                category: .automation,
                metadata: [
                    "codex_config": configURL.path,
                    "backup": backupURL.path,
                ]
            )
        } catch {
            try? fileManager.removeItem(at: backupURL)
            logLegacySkillsConfigAnomaly(error.localizedDescription, configURL: configURL)
        }
    }

    func logLegacySkillsConfigAnomaly(_ detail: String, configURL: URL) {
        ToasttyLog.warning(
            "Legacy cleanup could not neutralize retired Toastty skills.config entries; shipped skills may stay suppressed until repair",
            category: .automation,
            metadata: [
                "codex_config": configURL.path,
                "error": CodexSkillsManagerError.legacyCleanupFailed(detail).localizedDescription,
            ]
        )
    }

    static func legacyConfigBackupTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// The exact skill names the retired mechanism disable-unioned into the
    /// user's config. Only these — and only while still disabled — are ever
    /// removed; any other `toastty:*` entry (user-authored, re-enabled, or
    /// from a future mechanism) is not Toastty's to touch.
    static let legacyDisabledSkillNames: Set<String> = [
        "toastty:toastty-capabilities",
        "toastty:toastty-open-markdown",
        "toastty:toastty-scratchpad",
        "toastty:worktree-create",
        "toastty:worktree-done",
    ]

    /// Line-based removal (validator-script style, deliberately not a TOML
    /// parser round-trip, which would normalize the file): drops every whole
    /// `[[skills.config]]` array-of-table block whose `name` value is exactly
    /// one of `legacyDisabledSkillNames` AND that still carries
    /// `enabled = false`, together with the blank separator lines inside and
    /// immediately after the block, and keeps every other line — comments,
    /// unrelated or re-enabled `[[skills.config]]` blocks, ordering —
    /// byte-identically. Returns nil when there is nothing to remove or the
    /// shape is not understood (CRLF line endings, legacy names outside a
    /// well-formed block); callers fail open on nil.
    static func removingToasttySkillsConfigBlocks(from contents: String) -> String? {
        guard contents.contains("\r") == false else { return nil }
        let lines = contents.components(separatedBy: "\n")
        // Preserve the trailing newline: a final empty component stays out of
        // every block span.
        let scanCount = lines.last == "" ? lines.count - 1 : lines.count

        var removedIndices = Set<Int>()
        var index = 0
        while index < scanCount {
            guard lines[index].trimmingCharacters(in: .whitespaces) == "[[skills.config]]" else {
                index += 1
                continue
            }
            var span = [index]
            var pendingBlanks: [Int] = []
            var blockName: String?
            var blockIsDisabled = false
            var cursor = index + 1
            while cursor < scanCount {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    pendingBlanks.append(cursor)
                    cursor += 1
                    continue
                }
                // A header starts the next block; a comment is preserved
                // (only real key-value lines belong to the removable span).
                if trimmed.hasPrefix("[") || trimmed.hasPrefix("#") {
                    break
                }
                span.append(contentsOf: pendingBlanks)
                pendingBlanks = []
                span.append(cursor)
                if let name = skillNameAssignmentValue(trimmed) {
                    blockName = name
                }
                if isDisabledAssignment(trimmed) {
                    blockIsDisabled = true
                }
                cursor += 1
            }
            if let blockName,
               legacyDisabledSkillNames.contains(blockName),
               blockIsDisabled {
                removedIndices.formUnion(span)
                // Trailing blank separators disappear with their block.
                removedIndices.formUnion(pendingBlanks)
            }
            index = cursor
        }
        guard removedIndices.isEmpty == false else { return nil }
        return lines.indices
            .filter { removedIndices.contains($0) == false }
            .map { lines[$0] }
            .joined(separator: "\n")
    }

    /// The quoted value of a `name = "…"` assignment with flexible whitespace
    /// around `=`, applied to an already-trimmed line; nil for any other
    /// line.
    static func skillNameAssignmentValue(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("name") else { return nil }
        var rest = Substring(trimmedLine).dropFirst("name".count)
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        guard let closingQuoteIndex = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<closingQuoteIndex])
    }

    /// `enabled = false` with flexible whitespace, optionally followed by a
    /// comment, applied to an already-trimmed line.
    static func isDisabledAssignment(_ trimmedLine: String) -> Bool {
        guard trimmedLine.hasPrefix("enabled") else { return false }
        var rest = Substring(trimmedLine).dropFirst("enabled".count)
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "=" else { return false }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard rest.hasPrefix("false") else { return false }
        let remainder = rest.dropFirst("false".count).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty || remainder.hasPrefix("#")
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

    /// Legacy state only ever existed in the real home; resolving through the
    /// runtime paths keeps isolated runs from touching it (cleanup finds
    /// nothing there).
    var legacyStableMarketplaceURL: URL {
        toasttyConfigDirectoryURL.appendingPathComponent("codex-plugin", isDirectory: true)
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
        try acquireLock(Self.operationLock, until: deadline)
    }

    static func withProfileOverlayLock<T>(_ operation: () throws -> T) rethrows -> T {
        profileOverlayLock.lock()
        defer { profileOverlayLock.unlock() }
        return try operation()
    }

    func acquireLock(_ lock: NSLock, until deadline: Date) throws {
        while lock.try() == false {
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
