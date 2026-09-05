import RemoteProtocol
import CoreState
import Darwin
import Foundation

struct ClaudeSkillsLaunchConfiguration: Equatable, Sendable {
    let pluginRootPath: String
    let skillsRootPath: String
    let version: String
    let contentDigest: String
}

enum ClaudeSkillsDeliveryStatus: Equatable, Sendable {
    case providedAtLaunch(ClaudeSkillsLaunchConfiguration)
    case stagesOnNextLaunch(version: String)
    case unavailable(detail: String)
}

protocol ClaudeSkillsBundleManaging: AnyObject, Sendable {
    func existingVerifiedConfiguration() -> ClaudeSkillsLaunchConfiguration?
    func deliveryStatus() async -> ClaudeSkillsDeliveryStatus
    func prepareForManagedLaunch() async -> ClaudeSkillsLaunchConfiguration?
    func prepareForRestoredManagedLaunch() -> ClaudeSkillsLaunchConfiguration?
}

extension ClaudeSkillsBundleManaging {
    func prepareForRestoredManagedLaunch() -> ClaudeSkillsLaunchConfiguration? {
        existingVerifiedConfiguration()
    }
}

/// Stages the shipped agent plugin once and serves every additive skills
/// runtime from it (`AgentKind.usesStagedSkillsTree`): Claude consumes
/// `pluginRootPath` as a `--plugin-dir`, Cursor consumes that same plugin root
/// (including its Cursor hooks), while pi, OpenCode, and MiMo Code consume the
/// plain `skills/<name>/SKILL.md` tree at `skillsRootPath`. The staging root
/// keeps its `claude` component: it is content-addressed and already swept, so
/// the shared payload needs no migration.
final class ClaudeSkillsBundleManager: ClaudeSkillsBundleManaging, @unchecked Sendable {
    private let sourcePluginURLProvider: @Sendable () -> URL?
    private let stagingRootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "dev.toastty.claude-skills-bundle", qos: .userInitiated)

    /// The Toastty-side staging root follows the resolved runtime paths so
    /// runtime-isolated app instances never write into the real `~/.toastty`.
    convenience init(
        sourcePluginURLProvider: @escaping @Sendable () -> URL? = {
            ToasttyAgentPluginBundle.bundledPluginURL()
        },
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default
    ) {
        self.init(
            sourcePluginURLProvider: sourcePluginURLProvider,
            stagingRootURL: runtimePaths.agentPluginsDirectoryURL
                .appendingPathComponent("claude", isDirectory: true),
            fileManager: fileManager
        )
    }

    init(
        sourcePluginURLProvider: @escaping @Sendable () -> URL? = {
            ToasttyAgentPluginBundle.bundledPluginURL()
        },
        stagingRootURL: URL,
        fileManager: FileManager = .default
    ) {
        self.sourcePluginURLProvider = sourcePluginURLProvider
        self.stagingRootURL = stagingRootURL
        self.fileManager = fileManager
    }

    func existingVerifiedConfiguration() -> ClaudeSkillsLaunchConfiguration? {
        do {
            return try existingVerifiedConfigurationThrowing()
        } catch {
            logFailure(error)
            return nil
        }
    }

    func deliveryStatus() async -> ClaudeSkillsDeliveryStatus {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let status: ClaudeSkillsDeliveryStatus
                do {
                    status = try deliveryStatusThrowing()
                } catch {
                    logFailure(error)
                    status = .unavailable(detail: error.localizedDescription)
                }
                continuation.resume(returning: status)
            }
        }
    }

    func prepareForManagedLaunch() async -> ClaudeSkillsLaunchConfiguration? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try prepareForManagedLaunchThrowing())
                } catch {
                    logFailure(error)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func prepareForRestoredManagedLaunch() -> ClaudeSkillsLaunchConfiguration? {
        queue.sync { [self] in
            do {
                return try prepareForManagedLaunchThrowing()
            } catch {
                logFailure(error)
                return nil
            }
        }
    }

    /// Sweep seam: runs `body` on the manager's serial preparation queue so
    /// `ToasttySkillArtifactSweeper` and any in-flight staging or restored
    /// preparation serialize correctly.
    func withExclusiveStagingAccess<T>(_ body: () -> T) -> T {
        queue.sync(execute: body)
    }
}

private extension ClaudeSkillsBundleManager {
    func deliveryStatusThrowing() throws -> ClaudeSkillsDeliveryStatus {
        guard let sourceURL = sourcePluginURLProvider() else {
            throw ClaudeSkillsBundleManagerError.bundledPluginUnavailable
        }
        let source = try ToasttyAgentPluginBundle.read(
            pluginRootURL: sourceURL,
            fileManager: fileManager
        )
        let destination = destinationPluginURL(for: source)
        guard fileManager.fileExists(atPath: destination.path) else {
            return .stagesOnNextLaunch(version: source.version)
        }
        return .providedAtLaunch(
            try verifiedConfiguration(at: destination, expected: source)
        )
    }

    func prepareForManagedLaunchThrowing() throws -> ClaudeSkillsLaunchConfiguration {
        guard let sourceURL = sourcePluginURLProvider() else {
            throw ClaudeSkillsBundleManagerError.bundledPluginUnavailable
        }
        let source = try ToasttyAgentPluginBundle.read(
            pluginRootURL: sourceURL,
            fileManager: fileManager
        )
        let destination = destinationPluginURL(for: source)
        if fileManager.fileExists(atPath: destination.path) {
            return try verifiedConfiguration(at: destination, expected: source)
        }

        try fileManager.createDirectory(
            at: stagingRootURL,
            withIntermediateDirectories: true
        )
        let temporaryVersionRoot = stagingRootURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryPluginRoot = temporaryVersionRoot.appendingPathComponent("toastty", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryVersionRoot, withIntermediateDirectories: false)
            try fileManager.copyItem(at: source.pluginRootURL, to: temporaryPluginRoot)
            try normalizeScriptPermissions(in: temporaryPluginRoot)
            clearQuarantine(from: temporaryPluginRoot)
            _ = try verifiedConfiguration(at: temporaryPluginRoot, expected: source)

            let destinationVersionRoot = destination.deletingLastPathComponent()
            do {
                try fileManager.moveItem(at: temporaryVersionRoot, to: destinationVersionRoot)
            } catch where fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporaryVersionRoot)
            }
            return try verifiedConfiguration(at: destination, expected: source)
        } catch {
            try? fileManager.removeItem(at: temporaryVersionRoot)
            throw error
        }
    }

    func existingVerifiedConfigurationThrowing() throws -> ClaudeSkillsLaunchConfiguration? {
        guard let sourceURL = sourcePluginURLProvider() else { return nil }
        let source = try ToasttyAgentPluginBundle.read(
            pluginRootURL: sourceURL,
            fileManager: fileManager
        )
        let destination = destinationPluginURL(for: source)
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        return try verifiedConfiguration(at: destination, expected: source)
    }

    func destinationPluginURL(for descriptor: ToasttyAgentPluginDescriptor) -> URL {
        stagingRootURL
            .appendingPathComponent("\(descriptor.version)-\(descriptor.contentDigest)", isDirectory: true)
            .appendingPathComponent("toastty", isDirectory: true)
    }

    func verifiedConfiguration(
        at pluginURL: URL,
        expected: ToasttyAgentPluginDescriptor
    ) throws -> ClaudeSkillsLaunchConfiguration {
        let installed = try ToasttyAgentPluginBundle.read(
            pluginRootURL: pluginURL,
            fileManager: fileManager
        )
        guard installed.name == expected.name,
              installed.version == expected.version,
              installed.contentDigest == expected.contentDigest else {
            throw ClaudeSkillsBundleManagerError.stagedPluginMismatch(pluginURL.path)
        }
        return ClaudeSkillsLaunchConfiguration(
            pluginRootPath: pluginURL.path,
            skillsRootPath: installed.skillsRootURL.path,
            version: installed.version,
            contentDigest: installed.contentDigest
        )
    }

    func normalizeScriptPermissions(in pluginRootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: pluginRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ClaudeSkillsBundleManagerError.copyFailed(pluginRootURL.path)
        }
        for case let url as URL in enumerator {
            let isExecutablePayload = url.pathComponents.contains("scripts")
                || (url.pathComponents.contains("cursor-hooks") && url.pathExtension == "sh")
            guard isExecutablePayload,
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

    func logFailure(_ error: Error) {
        ToasttyLog.warning(
            "Claude skills plugin preparation failed; launching without Toastty skills",
            category: .automation,
            metadata: ["error": error.localizedDescription]
        )
    }
}

enum ClaudeSkillsBundleManagerError: LocalizedError, Equatable {
    case bundledPluginUnavailable
    case copyFailed(String)
    case stagedPluginMismatch(String)

    var errorDescription: String? {
        switch self {
        case .bundledPluginUnavailable:
            return "Toastty could not find its bundled agent plugin."
        case .copyFailed(let path):
            return "Toastty could not copy the Claude skills plugin to \(path)."
        case .stagedPluginMismatch(let path):
            return "The staged Claude skills plugin does not match the bundled plugin at \(path)."
        }
    }
}
