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
    let installedPath: String?
    let marketplacePath: String
    let updatePending: Bool
    let repairPending: Bool
    let hasActiveManagedSession: Bool
    let disabledNameTombstones: [String]

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
    case marketplaceConflict(String)
    case pluginConflict(String)
    case ownedStateMismatch(String)
    case pluginInstallMismatch
    case pluginNotInstalled
    case installedPluginMismatch(String)
    case ordinarySkillsMismatch(expected: [String], actual: [String])
    case ordinarySkillEnabled(String)
    case activeSessions
    case copyFailed(String)
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
        case .marketplaceConflict(let path):
            return "A marketplace named toastty already exists at \(path). Toastty preserved it."
        case .pluginConflict(let pluginID):
            return "A plugin named toastty is already installed as \(pluginID). Toastty preserved it."
        case .ownedStateMismatch(let path):
            return "Toastty cannot verify ownership of the Codex skills state at \(path)."
        case .pluginInstallMismatch:
            return "Codex installed an unexpected plugin while provisioning Toastty skills."
        case .pluginNotInstalled:
            return "The Toastty Codex skills plugin is not installed."
        case .installedPluginMismatch(let path):
            return "The installed Toastty Codex plugin does not match the verified bundle at \(path)."
        case .ordinarySkillsMismatch(let expected, let actual):
            return "Ordinary Codex reported an unexpected Toastty skill set (expected \(expected); found \(actual))."
        case .ordinarySkillEnabled(let name):
            return "Toastty skill \(name) is enabled in ordinary Codex."
        case .activeSessions:
            return "Wait for active managed Codex sessions to finish before changing the plugin."
        case .copyFailed(let path):
            return "Toastty could not stage its Codex skills plugin at \(path)."
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

final class CodexSkillsManager: @unchecked Sendable {
    static let operationTimeout: TimeInterval = 4
    private static let operationLock = NSLock()
    private static let sharedStateLock = NSLock()
    nonisolated(unsafe) private static var pendingRepairHomes = Set<String>()
    nonisolated(unsafe) private static var failureCounts: [String: Int] = [:]

    private let homeDirectoryURL: URL
    private let sourcePluginURLProvider: @Sendable () -> URL?
    private let sourceMarketplaceURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager
    private let pluginClient: any CodexPluginCLIManaging
    private let skillClient: any CodexSkillsConfiguring
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
        pluginClient: any CodexPluginCLIManaging = CodexPluginCLIClient(),
        skillClient: any CodexSkillsConfiguring = CodexAppServerClient()
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.sourcePluginURLProvider = sourcePluginURLProvider
        self.sourceMarketplaceURLProvider = sourceMarketplaceURLProvider
        self.fileManager = fileManager
        self.pluginClient = pluginClient
        self.skillClient = skillClient
    }

    var stableMarketplaceURL: URL {
        homeDirectoryURL.appendingPathComponent(".toastty/codex-plugin", isDirectory: true)
    }

    var stateRootURL: URL {
        homeDirectoryURL.appendingPathComponent(".toastty/agent-plugins/codex", isDirectory: true)
    }

    func cachedLaunchConfiguration(runtime: CodexIntegrationRuntime) -> CodexSkillsLaunchConfiguration? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedConfigurations[runtimeKey(runtime)]?.configuration
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
           let cached = cachedEntry(runtime: runtime),
           cached.verificationLevel == .full,
           cached.fingerprint == fingerprint(runtime: runtime, bundled: bundled, record: readOwnershipRecord(runtime)) {
            if cached.record.installedDigest == bundled.contentDigest {
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
        }

        try acquireOperationLock(until: deadline)
        defer { Self.operationLock.unlock() }

        let oldRecord = readOwnershipRecord(runtime)
        let oldVerified = try? verifyExisting(
            runtime: runtime,
            bundled: bundled,
            record: oldRecord,
            deadline: deadline,
            requireBundledDigest: false
        )
        if let oldVerified,
           oldVerified.record.installedDigest == bundled.contentDigest,
           pendingRepair(for: runtime) == false {
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
                oldRecord: oldRecord,
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
            if let managerError = error as? CodexSkillsManagerError,
               case .rollbackUnverified = managerError {
                clearCachedConfiguration(runtime)
                throw error
            }
            if let oldVerified {
                cache(oldVerified, runtime: runtime, bundled: bundled)
                return CodexSkillsPreparation(
                    configuration: oldVerified.configuration,
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

    /// Restored sessions must select the bundled version before their resume command is
    /// submitted. Reuse a current byte-verified install without subprocess work; otherwise
    /// perform the same bounded, fail-open provisioning as a new managed launch.
    func prepareForRestoredManagedLaunch(
        runtime: CodexIntegrationRuntime
    ) throws -> CodexSkillsPreparation {
        // A restored pane may be prepared after files changed within this app process.
        // Never let an earlier cache entry override the disk verification below.
        clearCachedConfiguration(runtime)
        let bundled = try bundledDescriptor()
        if pendingRepair(for: runtime) == false,
           let record = readOwnershipRecord(runtime),
           record.installedDigest == bundled.contentDigest,
           let verified = try? verifyInstalledFiles(
               runtime: runtime,
               bundled: bundled,
               record: record,
               requireBundledDigest: true
           ) {
            cache(
                verified,
                runtime: runtime,
                bundled: bundled,
                verificationLevel: .installedFiles
            )
            return CodexSkillsPreparation(
                configuration: verified.configuration,
                status: readyStatus(bundled: bundled, record: record, runtime: runtime),
                installedOrUpdated: false,
                firstInstallSucceeded: false
            )
        }
        return try prepareForManagedLaunch(runtime: runtime)
    }

    func status(
        runtime: CodexIntegrationRuntime,
        hasActiveManagedCodexSession: Bool
    ) -> CodexSkillsStatus {
        let deadline = Date().addingTimeInterval(Self.operationTimeout)
        do {
            let bundled = try bundledDescriptor()
            guard let record = readOwnershipRecord(runtime) else {
                return CodexSkillsStatus(
                    availability: .notInstalled,
                    detail: "Toastty skills will be added automatically on the next managed Codex launch.",
                    bundledVersion: bundled.version,
                    installedVersion: nil,
                    bundledDigest: bundled.contentDigest,
                    installedDigest: nil,
                    installedPath: nil,
                    marketplacePath: marketplaceURL(for: runtime).path,
                    updatePending: false,
                    repairPending: pendingRepair(for: runtime),
                    hasActiveManagedSession: hasActiveManagedCodexSession,
                    disabledNameTombstones: CodexSkillsContract.retiredQualifiedSkillNames
                )
            }
            let verified = try verifyExisting(
                runtime: runtime,
                bundled: bundled,
                record: record,
                deadline: deadline,
                requireBundledDigest: false
            )
            cache(verified, runtime: runtime, bundled: bundled)
            return readyStatus(
                bundled: bundled,
                record: verified.record,
                runtime: runtime,
                hasActiveManagedCodexSession: hasActiveManagedCodexSession
            )
        } catch let error as CodexPluginCLIError where error.isUnsupported {
            return unsupportedStatus(runtime: runtime, detail: error.localizedDescription)
        } catch let error as CodexPluginCLIError where error.isRuntimeUnavailable {
            return unrunnableStatus(runtime: runtime, detail: error.localizedDescription)
        } catch let error as CodexAppServerClientError where error.isUnsupported {
            return unsupportedStatus(runtime: runtime, detail: error.localizedDescription)
        } catch {
            return CodexSkillsStatus(
                availability: .failed,
                detail: error.localizedDescription,
                bundledVersion: (try? bundledDescriptor().version),
                installedVersion: readOwnershipRecord(runtime)?.installedVersion,
                bundledDigest: (try? bundledDescriptor().contentDigest),
                installedDigest: readOwnershipRecord(runtime)?.installedDigest,
                installedPath: readOwnershipRecord(runtime)?.installedPath,
                marketplacePath: marketplaceURL(for: runtime).path,
                updatePending: false,
                repairPending: pendingRepair(for: runtime),
                hasActiveManagedSession: hasActiveManagedCodexSession,
                disabledNameTombstones: CodexSkillsContract.retiredQualifiedSkillNames
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

        let marketplaceURL = marketplaceURL(for: runtime)
        let ownershipStateURL = ownershipStateURL(for: runtime)
        guard let record = readOwnershipRecord(runtime),
              standardizedPath(record.marketplacePath) == standardizedPath(marketplaceURL.path) else {
            throw CodexSkillsManagerError.ownedStateMismatch(ownershipStateURL.path)
        }
        let bundled = try bundledDescriptor()
        _ = try verifyExisting(
            runtime: runtime,
            bundled: bundled,
            record: record,
            deadline: deadline,
            requireBundledDigest: false,
            requireExclusiveMarketplace: true
        )
        try pluginClient.removePlugin(
            runtime: runtime,
            selector: pluginSelector,
            deadline: deadline
        )
        try pluginClient.removeMarketplace(
            runtime: runtime,
            name: CodexSkillsContract.marketplaceName,
            deadline: deadline
        )

        do {
            if fileManager.fileExists(atPath: marketplaceURL.path) {
                try fileManager.removeItem(at: marketplaceURL)
            }
            if fileManager.fileExists(atPath: ownershipStateURL.path) {
                try fileManager.removeItem(at: ownershipStateURL)
            }
            try removeStagedVersionsIfUnused()
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
    struct OwnershipRecord: Codable, Equatable, Sendable {
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
        let record: OwnershipRecord
    }

    struct CachedConfiguration {
        enum VerificationLevel {
            case installedFiles
            case full
        }

        let configuration: CodexSkillsLaunchConfiguration
        let record: OwnershipRecord
        let fingerprint: String
        let verificationLevel: VerificationLevel
    }

    var versionsRootURL: URL {
        stateRootURL.appendingPathComponent("versions", isDirectory: true)
    }

    func ownershipStateURL(for runtime: CodexIntegrationRuntime) -> URL {
        stateRootURL
            .appendingPathComponent("homes", isDirectory: true)
            .appendingPathComponent(homeKey(runtime.codexHomeURL.path), isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func marketplaceURL(for runtime: CodexIntegrationRuntime) -> URL {
        let defaultCodexHome = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        if standardizedPath(runtime.codexHomeURL.path) == standardizedPath(defaultCodexHome.path) {
            return stableMarketplaceURL
        }
        return ownershipStateURL(for: runtime)
            .deletingLastPathComponent()
            .appendingPathComponent("marketplace", isDirectory: true)
    }

    func homeKey(_ path: String) -> String {
        SHA256.hash(data: Data(standardizedPath(path).utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var pluginSelector: String {
        "\(CodexSkillsContract.pluginName)@\(CodexSkillsContract.marketplaceName)"
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

    func provision(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        oldRecord: OwnershipRecord?,
        deadline: Date
    ) throws -> VerifiedInstallation {
        try checkDeadline(deadline)
        let marketplaceURL = marketplaceURL(for: runtime)
        let marketplaces = try pluginClient.listMarketplaces(runtime: runtime, deadline: deadline)
        let existingMarketplace = marketplaces.first {
            $0.name == CodexSkillsContract.marketplaceName
        }
        if let existingMarketplace,
           marketplaceMatches(existingMarketplace, expectedURL: marketplaceURL) == false {
            throw CodexSkillsManagerError.marketplaceConflict(existingMarketplace.rootPath)
        }
        let existingPlugins = try pluginClient.listInstalledPlugins(
            runtime: runtime,
            deadline: deadline
        )
        if let conflict = existingPlugins.first(where: {
            $0.name == CodexSkillsContract.pluginName && $0.pluginID != pluginSelector
        }) {
            throw CodexSkillsManagerError.pluginConflict(conflict.pluginID)
        }
        let disabledNames = Set(
            (oldRecord?.skillNames ?? []).map { "\(CodexSkillsContract.pluginName):\($0)" }
                + bundled.qualifiedSkillNames
                + CodexSkillsContract.retiredQualifiedSkillNames
        )
        try persistDisabledSkills(
            disabledNames.sorted(),
            runtime: runtime,
            deadline: deadline
        )

        let stagedPluginURL = try stageImmutablePlugin(bundled)
        let previousLink = try currentStablePluginLinkDestination(marketplaceURL: marketplaceURL)
        var addedMarketplace = false
        do {
            try stageStableMarketplace(
                pluginURL: stagedPluginURL,
                marketplaceURL: marketplaceURL,
                allowExistingOwnedLayout: isOwnedMarketplaceLayout(marketplaceURL: marketplaceURL)
            )
            if existingMarketplace == nil {
                let name = try pluginClient.addMarketplace(
                    runtime: runtime,
                    sourcePath: marketplaceURL.path,
                    deadline: deadline
                )
                guard name == CodexSkillsContract.marketplaceName else {
                    throw CodexSkillsManagerError.marketplaceConflict(name)
                }
                addedMarketplace = true
            }

            let installation = try pluginClient.installPlugin(
                runtime: runtime,
                selector: pluginSelector,
                deadline: deadline
            )
            guard installation.pluginID == pluginSelector,
                  installation.name == CodexSkillsContract.pluginName,
                  installation.marketplaceName == CodexSkillsContract.marketplaceName else {
                throw CodexSkillsManagerError.pluginInstallMismatch
            }
            try persistDisabledSkills(
                disabledNames.sorted(),
                runtime: runtime,
                deadline: deadline
            )
            let installed = try ToasttyAgentPluginBundle.read(
                pluginRootURL: URL(fileURLWithPath: installation.installedPath, isDirectory: true),
                fileManager: fileManager
            )
            guard installed.version == bundled.version,
                  installed.contentDigest == bundled.contentDigest else {
                throw CodexSkillsManagerError.installedPluginMismatch(
                    "\(installation.installedPath) (expected \(bundled.version)/\(bundled.contentDigest), found \(installed.version)/\(installed.contentDigest))"
                )
            }
            try verifyOrdinarySkills(
                expectedNames: bundled.qualifiedSkillNames,
                runtime: runtime,
                deadline: deadline
            )
            let record = OwnershipRecord(
                schemaVersion: 1,
                marketplaceName: CodexSkillsContract.marketplaceName,
                marketplacePath: marketplaceURL.path,
                installedPath: installation.installedPath,
                installedVersion: installed.version,
                installedDigest: installed.contentDigest,
                skillNames: installed.skillNames
            )
            try writeOwnershipRecord(record, runtime: runtime)
            return VerifiedInstallation(
                configuration: launchConfiguration(descriptor: installed),
                record: record
            )
        } catch {
            let updateError = error
            if let previousLink {
                try? replaceStablePluginLink(
                    with: URL(fileURLWithPath: previousLink),
                    marketplaceURL: marketplaceURL
                )
            } else {
                try? removeStableMarketplaceIfUnowned(
                    runtime: runtime,
                    marketplaceURL: marketplaceURL
                )
            }
            if addedMarketplace {
                try? pluginClient.removeMarketplace(
                    runtime: runtime,
                    name: CodexSkillsContract.marketplaceName,
                    deadline: deadline
                )
            }
            if let oldRecord {
                do {
                    _ = try verifyExisting(
                        runtime: runtime,
                        bundled: bundled,
                        record: oldRecord,
                        deadline: deadline,
                        requireBundledDigest: false
                    )
                } catch {
                    throw CodexSkillsManagerError.rollbackUnverified(
                        "\(updateError.localizedDescription) Rollback check: \(error.localizedDescription)"
                    )
                }
            }
            throw updateError
        }
    }

    func verifyExisting(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        record: OwnershipRecord?,
        deadline: Date,
        requireBundledDigest: Bool,
        requireExclusiveMarketplace: Bool = false
    ) throws -> VerifiedInstallation {
        let verified = try verifyInstalledFiles(
            runtime: runtime,
            bundled: bundled,
            record: record,
            requireBundledDigest: requireBundledDigest
        )
        let record = verified.record
        let marketplaces = try pluginClient.listMarketplaces(runtime: runtime, deadline: deadline)
        guard let marketplace = marketplaces.first(where: { $0.name == CodexSkillsContract.marketplaceName }) else {
            throw CodexSkillsManagerError.pluginNotInstalled
        }
        guard marketplaceMatches(marketplace, expectedURL: marketplaceURL(for: runtime)) else {
            throw CodexSkillsManagerError.marketplaceConflict(marketplace.rootPath)
        }
        let plugins = try pluginClient.listInstalledPlugins(runtime: runtime, deadline: deadline)
        if requireExclusiveMarketplace,
           plugins.contains(where: {
               $0.marketplaceName == CodexSkillsContract.marketplaceName
                   && $0.pluginID != pluginSelector
           }) {
            throw CodexSkillsManagerError.uninstallFailed(
                "The Toastty marketplace has other installed plugins, so Toastty preserved it."
            )
        }
        guard let plugin = plugins.first(where: { $0.pluginID == pluginSelector }),
              plugin.name == CodexSkillsContract.pluginName,
              plugin.marketplaceName == CodexSkillsContract.marketplaceName else {
            throw CodexSkillsManagerError.pluginNotInstalled
        }
        guard plugin.version == record.installedVersion else {
            throw CodexSkillsManagerError.installedPluginMismatch(record.installedPath)
        }
        try verifyOrdinarySkills(
            expectedNames: verified.configuration.qualifiedSkillNames,
            runtime: runtime,
            deadline: deadline
        )
        return verified
    }

    func verifyInstalledFiles(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        record: OwnershipRecord?,
        requireBundledDigest: Bool
    ) throws -> VerifiedInstallation {
        guard let record else { throw CodexSkillsManagerError.pluginNotInstalled }
        guard record.schemaVersion == 1,
              record.marketplaceName == CodexSkillsContract.marketplaceName,
              standardizedPath(record.marketplacePath) == standardizedPath(marketplaceURL(for: runtime).path) else {
            throw CodexSkillsManagerError.ownedStateMismatch(ownershipStateURL(for: runtime).path)
        }
        guard isOwnedMarketplaceLayout(marketplaceURL: marketplaceURL(for: runtime)) else {
            throw CodexSkillsManagerError.ownedStateMismatch(marketplaceURL(for: runtime).path)
        }
        let installed = try ToasttyAgentPluginBundle.read(
            pluginRootURL: URL(fileURLWithPath: record.installedPath, isDirectory: true),
            fileManager: fileManager
        )
        guard installed.version == record.installedVersion,
              installed.contentDigest == record.installedDigest,
              installed.skillNames == record.skillNames else {
            throw CodexSkillsManagerError.installedPluginMismatch(record.installedPath)
        }
        if requireBundledDigest, installed.contentDigest != bundled.contentDigest {
            throw CodexSkillsManagerError.installedPluginMismatch(record.installedPath)
        }
        return VerifiedInstallation(
            configuration: launchConfiguration(descriptor: installed),
            record: record
        )
    }

    func persistDisabledSkills(
        _ names: [String],
        runtime: CodexIntegrationRuntime,
        deadline: Date
    ) throws {
        try skillClient.writeSkillConfigs(
            invocation: invocation(runtime: runtime, deadline: deadline),
            states: names.map { CodexSkillState(name: $0, enabled: false) }
        )
    }

    func verifyOrdinarySkills(
        expectedNames: [String],
        runtime: CodexIntegrationRuntime,
        deadline: Date
    ) throws {
        let expected = Set(expectedNames)
        let pluginPrefix = "\(CodexSkillsContract.pluginName):"
        let listed = try skillClient.listSkills(
            invocation: invocation(runtime: runtime, deadline: deadline)
        )
        let toasttySkills = listed.filter { $0.name.hasPrefix(pluginPrefix) }
        let actual = Set(toasttySkills.map(\.name))
        guard actual == expected else {
            throw CodexSkillsManagerError.ordinarySkillsMismatch(
                expected: expected.sorted(),
                actual: actual.sorted()
            )
        }
        if let enabled = toasttySkills.first(where: { $0.enabled }) {
            throw CodexSkillsManagerError.ordinarySkillEnabled(enabled.name)
        }
    }

    func invocation(
        runtime: CodexIntegrationRuntime,
        deadline: Date
    ) throws -> CodexAppServerInvocation {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CodexSkillsManagerError.operationTimedOut }
        return CodexAppServerInvocation(
            executableURL: runtime.executableURL,
            processEnvironment: runtime.processEnvironment,
            workingDirectoryURL: runtime.workingDirectoryURL,
            configOverrides: [],
            timeout: remaining
        )
    }

    func stageImmutablePlugin(_ bundled: ToasttyAgentPluginDescriptor) throws -> URL {
        let versionRoot = versionsRootURL.appendingPathComponent(
            "\(bundled.version)-\(bundled.contentDigest)",
            isDirectory: true
        )
        let destination = versionRoot.appendingPathComponent("toastty", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try ToasttyAgentPluginBundle.read(
                pluginRootURL: destination,
                fileManager: fileManager
            )
            guard existing.contentDigest == bundled.contentDigest else {
                throw CodexSkillsManagerError.copyFailed(destination.path)
            }
            return destination
        }

        try fileManager.createDirectory(at: versionsRootURL, withIntermediateDirectories: true)
        let temporaryRoot = versionsRootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryPlugin = temporaryRoot.appendingPathComponent("toastty", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
            try fileManager.copyItem(at: bundled.pluginRootURL, to: temporaryPlugin)
            try normalizeScriptPermissions(in: temporaryPlugin)
            clearQuarantine(from: temporaryPlugin)
            let copied = try ToasttyAgentPluginBundle.read(
                pluginRootURL: temporaryPlugin,
                fileManager: fileManager
            )
            guard copied.contentDigest == bundled.contentDigest else {
                throw CodexSkillsManagerError.copyFailed(destination.path)
            }
            do {
                try fileManager.moveItem(at: temporaryRoot, to: versionRoot)
            } catch where fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporaryRoot)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: temporaryRoot)
            throw error
        }
    }

    func stageStableMarketplace(
        pluginURL: URL,
        marketplaceURL: URL,
        allowExistingOwnedLayout: Bool
    ) throws {
        if fileManager.fileExists(atPath: marketplaceURL.path),
           allowExistingOwnedLayout == false,
           isOwnedMarketplaceLayout(marketplaceURL: marketplaceURL) == false {
            throw CodexSkillsManagerError.ownedStateMismatch(marketplaceURL.path)
        }
        let destinationManifest = marketplaceURL.appendingPathComponent(
            ".agents/plugins/marketplace.json",
            isDirectory: false
        )
        let sourceManifest = try bundledMarketplaceManifestURL()
        try fileManager.createDirectory(
            at: destinationManifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceData = try Data(contentsOf: sourceManifest)
        if (try? Data(contentsOf: destinationManifest)) != sourceData {
            try sourceData.write(to: destinationManifest, options: .atomic)
        }
        try fileManager.createDirectory(
            at: marketplaceURL.appendingPathComponent("plugins", isDirectory: true),
            withIntermediateDirectories: true
        )
        try replaceStablePluginLink(with: pluginURL, marketplaceURL: marketplaceURL)
    }

    func replaceStablePluginLink(with destination: URL, marketplaceURL: URL) throws {
        let pluginsRoot = marketplaceURL.appendingPathComponent("plugins", isDirectory: true)
        try fileManager.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
        let link = pluginsRoot.appendingPathComponent("toastty", isDirectory: true)
        let temporary = pluginsRoot.appendingPathComponent(".toastty-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: temporary, withDestinationURL: destination)
        let result = temporary.path.withCString { sourcePointer in
            link.path.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }
        guard result == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CodexSkillsManagerError.copyFailed(link.path)
        }
    }

    func currentStablePluginLinkDestination(marketplaceURL: URL) throws -> String? {
        let link = marketplaceURL.appendingPathComponent("plugins/toastty", isDirectory: true)
        guard fileManager.fileExists(atPath: link.path) else { return nil }
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink == true else {
            throw CodexSkillsManagerError.ownedStateMismatch(link.path)
        }
        return try fileManager.destinationOfSymbolicLink(atPath: link.path)
    }

    func isOwnedMarketplaceLayout(marketplaceURL: URL) -> Bool {
        let manifest = marketplaceURL.appendingPathComponent(
            ".agents/plugins/marketplace.json"
        )
        guard let data = try? Data(contentsOf: manifest),
              let expectedManifestURL = try? bundledMarketplaceManifestURL(),
              let expectedData = try? Data(contentsOf: expectedManifestURL),
              data == expectedData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] as? String == CodexSkillsContract.marketplaceName else {
            return false
        }
        let link = marketplaceURL.appendingPathComponent("plugins/toastty")
        guard (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let destinationURL = URL(
            fileURLWithPath: destination,
            relativeTo: link.deletingLastPathComponent()
        ).standardizedFileURL
        let versionsPath = standardizedPath(versionsRootURL.path) + "/"
        return standardizedPath(destinationURL.path).hasPrefix(versionsPath)
            && (try? ToasttyAgentPluginBundle.read(
                pluginRootURL: destinationURL,
                fileManager: fileManager
            )) != nil
    }

    func marketplaceMatches(
        _ marketplace: CodexPluginMarketplace,
        expectedURL: URL
    ) -> Bool {
        guard standardizedPath(marketplace.rootPath) == standardizedPath(expectedURL.path),
              let sourcePath = marketplace.sourcePath else {
            return false
        }
        return standardizedPath(sourcePath) == standardizedPath(expectedURL.path)
    }

    func removeStableMarketplaceIfUnowned(
        runtime: CodexIntegrationRuntime,
        marketplaceURL: URL
    ) throws {
        guard readOwnershipRecord(runtime) == nil,
              isOwnedMarketplaceLayout(marketplaceURL: marketplaceURL) else { return }
        try fileManager.removeItem(at: marketplaceURL)
    }

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

    func launchConfiguration(
        descriptor: ToasttyAgentPluginDescriptor
    ) -> CodexSkillsLaunchConfiguration {
        CodexSkillsLaunchConfiguration(
            qualifiedSkillNames: descriptor.qualifiedSkillNames,
            skillsRootPath: descriptor.skillsRootURL.path,
            version: descriptor.version,
            contentDigest: descriptor.contentDigest
        )
    }

    func readOwnershipRecord(_ runtime: CodexIntegrationRuntime) -> OwnershipRecord? {
        guard let data = try? Data(contentsOf: ownershipStateURL(for: runtime)) else { return nil }
        return try? JSONDecoder().decode(OwnershipRecord.self, from: data)
    }

    func writeOwnershipRecord(
        _ record: OwnershipRecord,
        runtime: CodexIntegrationRuntime
    ) throws {
        let url = ownershipStateURL(for: runtime)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    func readyStatus(
        bundled: ToasttyAgentPluginDescriptor,
        record: OwnershipRecord,
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
            installedPath: record.installedPath,
            marketplacePath: marketplaceURL(for: runtime).path,
            updatePending: updatePending,
            repairPending: repairPending,
            hasActiveManagedSession: hasActiveManagedCodexSession,
            disabledNameTombstones: CodexSkillsContract.retiredQualifiedSkillNames
        )
    }

    func failedStatus(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        detail: String
    ) -> CodexSkillsStatus {
        let record = readOwnershipRecord(runtime)
        return CodexSkillsStatus(
            availability: .failed,
            detail: detail,
            bundledVersion: bundled.version,
            installedVersion: record?.installedVersion,
            bundledDigest: bundled.contentDigest,
            installedDigest: record?.installedDigest,
            installedPath: record?.installedPath,
            marketplacePath: marketplaceURL(for: runtime).path,
            updatePending: record?.installedDigest != bundled.contentDigest,
            repairPending: pendingRepair(for: runtime),
            hasActiveManagedSession: false,
            disabledNameTombstones: CodexSkillsContract.retiredQualifiedSkillNames
        )
    }

    func unsupportedStatus(
        runtime: CodexIntegrationRuntime,
        detail: String
    ) -> CodexSkillsStatus {
        CodexSkillsStatus(
            availability: .unsupported,
            detail: detail,
            bundledVersion: try? bundledDescriptor().version,
            installedVersion: readOwnershipRecord(runtime)?.installedVersion,
            bundledDigest: try? bundledDescriptor().contentDigest,
            installedDigest: readOwnershipRecord(runtime)?.installedDigest,
            installedPath: readOwnershipRecord(runtime)?.installedPath,
            marketplacePath: marketplaceURL(for: runtime).path,
            updatePending: false,
            repairPending: pendingRepair(for: runtime),
            hasActiveManagedSession: false,
            disabledNameTombstones: CodexSkillsContract.retiredQualifiedSkillNames
        )
    }

    func unrunnableStatus(
        runtime: CodexIntegrationRuntime,
        detail: String
    ) -> CodexSkillsStatus {
        CodexSkillsStatus(
            availability: .unrunnable,
            detail: detail,
            bundledVersion: try? bundledDescriptor().version,
            installedVersion: readOwnershipRecord(runtime)?.installedVersion,
            bundledDigest: try? bundledDescriptor().contentDigest,
            installedDigest: readOwnershipRecord(runtime)?.installedDigest,
            installedPath: readOwnershipRecord(runtime)?.installedPath,
            marketplacePath: marketplaceURL(for: runtime).path,
            updatePending: false,
            repairPending: pendingRepair(for: runtime),
            hasActiveManagedSession: false,
            disabledNameTombstones: CodexSkillsContract.retiredQualifiedSkillNames
        )
    }

    func cache(
        _ verified: VerifiedInstallation,
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor,
        verificationLevel: CachedConfiguration.VerificationLevel = .full
    ) {
        let entry = CachedConfiguration(
            configuration: verified.configuration,
            record: verified.record,
            fingerprint: fingerprint(runtime: runtime, bundled: bundled, record: verified.record),
            verificationLevel: verificationLevel
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
        record: OwnershipRecord?
    ) -> String {
        [
            runtimeKey(runtime),
            metadataSignature(runtime.executableURL),
            dataSignature(runtime.codexHomeURL.appendingPathComponent("config.toml")),
            bundled.contentDigest,
            dataSignature(ownershipStateURL(for: runtime)),
            record.map { metadataSignature(URL(fileURLWithPath: $0.installedPath)) } ?? "none",
        ].joined(separator: "|")
    }

    func failureSignature(
        runtime: CodexIntegrationRuntime,
        bundled: ToasttyAgentPluginDescriptor
    ) -> String {
        [
            runtimeKey(runtime),
            metadataSignature(runtime.executableURL),
            dataSignature(runtime.codexHomeURL.appendingPathComponent("config.toml")),
            bundled.contentDigest,
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

    func removeStagedVersionsIfUnused() throws {
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
        if fileManager.fileExists(atPath: versionsRootURL.path) {
            try fileManager.removeItem(at: versionsRootURL)
        }
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
        Self.sharedStateLock.lock()
        defer { Self.sharedStateLock.unlock() }
        return Self.pendingRepairHomes.contains(path)
    }

    func markPendingRepair(for runtime: CodexIntegrationRuntime) {
        Self.sharedStateLock.lock()
        Self.pendingRepairHomes.insert(runtime.codexHomeURL.path)
        Self.sharedStateLock.unlock()
    }

    func clearPendingRepair(for runtime: CodexIntegrationRuntime) {
        Self.sharedStateLock.lock()
        Self.pendingRepairHomes.remove(runtime.codexHomeURL.path)
        Self.sharedStateLock.unlock()
    }

    func failureCount(for signature: String) -> Int {
        Self.sharedStateLock.lock()
        defer { Self.sharedStateLock.unlock() }
        return Self.failureCounts[signature] ?? 0
    }

    func incrementFailure(for signature: String) {
        Self.sharedStateLock.lock()
        Self.failureCounts[signature, default: 0] += 1
        Self.sharedStateLock.unlock()
    }

    func clearFailure(for signature: String) {
        Self.sharedStateLock.lock()
        Self.failureCounts.removeValue(forKey: signature)
        Self.sharedStateLock.unlock()
    }

    func clearFailuresForRuntime(_ runtime: CodexIntegrationRuntime) {
        let prefix = runtimeKey(runtime)
        Self.sharedStateLock.lock()
        Self.failureCounts = Self.failureCounts.filter { $0.key.hasPrefix(prefix) == false }
        Self.sharedStateLock.unlock()
    }
}

extension Notification.Name {
    static let toasttyManagedAgentSkillsProvisioned = Notification.Name(
        "dev.toastty.managed-agent-skills-provisioned"
    )
}
