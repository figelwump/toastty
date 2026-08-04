import CoreState
import Darwin
import Foundation

struct ClaudeSkillsLaunchConfiguration: Equatable, Sendable {
    let pluginRootPath: String
    let skillsRootPath: String
    let version: String
    let contentDigest: String
}

protocol ClaudeSkillsBundleManaging: AnyObject, Sendable {
    func existingVerifiedConfiguration() -> ClaudeSkillsLaunchConfiguration?
    func prepareForManagedLaunch() async -> ClaudeSkillsLaunchConfiguration?
    func prepareForRestoredManagedLaunch() -> ClaudeSkillsLaunchConfiguration?
}

extension ClaudeSkillsBundleManaging {
    func prepareForRestoredManagedLaunch() -> ClaudeSkillsLaunchConfiguration? {
        existingVerifiedConfiguration()
    }
}

final class ClaudeSkillsBundleManager: ClaudeSkillsBundleManaging, @unchecked Sendable {
    private let sourcePluginURLProvider: @Sendable () -> URL?
    private let stagingRootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "dev.toastty.claude-skills-bundle", qos: .userInitiated)

    init(
        sourcePluginURLProvider: @escaping @Sendable () -> URL? = {
            ToasttyAgentPluginBundle.bundledPluginURL()
        },
        stagingRootURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".toastty/agent-plugins/claude", isDirectory: true),
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
}

private extension ClaudeSkillsBundleManager {
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
        let skillsRootURL = pluginRootURL.appendingPathComponent("skills", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: skillsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw ClaudeSkillsBundleManagerError.copyFailed(pluginRootURL.path)
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
