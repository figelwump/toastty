import CoreState
import Foundation

protocol CodexManagedLaunchIntegrationResolving: AnyObject, Sendable {
    func resolve(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchIntegrationDecision
    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) async -> CodexManagedLaunchIntegrationDecision
}

extension CodexManagedLaunchIntegrationResolving {
    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) async -> CodexManagedLaunchIntegrationDecision {
        resolve(request: request, workingDirectory: workingDirectory)
    }
}

final class CodexManagedLaunchIntegrationResolver: CodexManagedLaunchIntegrationResolving, @unchecked Sendable {
    private let homeDirectoryURL: URL
    private let fileManager: FileManager
    private let manager: CodexIntegrationManager
    private let processEnvironment: @Sendable () -> [String: String]
    private let timeout: TimeInterval
    private let cacheLock = NSLock()
    private var trustedCache: [CacheKey: CodexManagedLaunchIntegrationDecision] = [:]

    init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default,
        manager: CodexIntegrationManager? = nil,
        processEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        timeout: TimeInterval = CodexIntegrationManager.assessmentTimeout
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.fileManager = fileManager
        self.manager = manager ?? CodexIntegrationManager(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
        self.processEnvironment = processEnvironment
        self.timeout = timeout
    }

    func resolve(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchIntegrationDecision {
        guard request.agent == .codex,
              let runtime = resolveRuntime(request: request, workingDirectory: workingDirectory) else {
            return fallbackDecision(runtime: nil, reason: "codex_executable_unresolved")
        }
        // Workspace restoration still uses the synchronous planner contract.
        // Never run app-server or recursive cache fingerprinting on the main
        // actor for that path; restored sessions safely retain log fallback.
        return fallbackDecision(runtime: runtime, reason: "session_integration_probe_deferred")
    }

    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) async -> CodexManagedLaunchIntegrationDecision {
        guard request.agent == .codex,
              let runtime = resolveRuntime(request: request, workingDirectory: workingDirectory) else {
            return fallbackDecision(runtime: nil, reason: "codex_executable_unresolved")
        }

        return await withCheckedContinuation { continuation in
            let race = CodexManagedLaunchResolutionRace(continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                race.finish(self.assess(runtime: runtime))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [self] in
                race.finish(
                    self.fallbackDecision(
                        runtime: runtime,
                        reason: "session_integration_probe_failed"
                    )
                )
            }
        }
    }

    func assess(runtime: CodexIntegrationRuntime) -> CodexManagedLaunchIntegrationDecision {
        let key = cacheKey(for: runtime)
        cacheLock.lock()
        let cached = trustedCache[key]
        cacheLock.unlock()
        if let cached {
            return cached
        }

        let decision: CodexManagedLaunchIntegrationDecision
        do {
            decision = try manager.managedLaunchDecision(runtime: runtime)
        } catch {
            ToasttyLog.warning(
                "Codex session integration assessment failed; using fallback",
                category: .automation,
                metadata: [
                    "codex_executable": runtime.executableURL.path,
                    "codex_home": runtime.codexHomeURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return fallbackDecision(runtime: runtime, reason: "session_integration_probe_failed")
        }
        if decision.assessment?.canUseSessionIntegrations == true {
            cacheLock.lock()
            trustedCache = [key: decision]
            cacheLock.unlock()
        }
        return decision
    }
}

private extension CodexManagedLaunchIntegrationResolver {
    struct CacheKey: Hashable {
        let executablePath: String
        let codexHomePath: String
        let workingDirectoryPath: String
        let executableSignature: Int
        let configSignature: Int
        let projectConfigSignature: Int
        let hookTrustSignature: Int
        let codexStateSignature: Int
        let integrationSignature: Int
    }

    func resolveRuntime(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexIntegrationRuntime? {
        let mergedEnvironment = processEnvironment().merging(request.environment) { _, new in new }
        let executablePath: String?
        if let hint = request.codexCapabilityHint,
           hint.resolvedExecutablePath.hasPrefix("/"),
           ["codex", "cdx"].contains(
                URL(fileURLWithPath: hint.resolvedExecutablePath).lastPathComponent.lowercased()
           ),
           fileManager.isExecutableFile(atPath: hint.resolvedExecutablePath) {
            executablePath = hint.resolvedExecutablePath
        } else {
            executablePath = resolveExecutablePath(
                argv: request.argv,
                workingDirectory: workingDirectory,
                path: mergedEnvironment["PATH"]
            )
        }
        guard let executablePath else { return nil }

        let codexHomePath = request.codexCapabilityHint?.codexHomePath
            ?? normalizedCodexIntegrationText(request.environment["CODEX_HOME"])
            ?? homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true).path
        guard codexHomePath.hasPrefix("/") else { return nil }
        let cwdURL = workingDirectory.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } ?? homeDirectoryURL

        return CodexIntegrationRuntime(
            executableURL: URL(fileURLWithPath: executablePath),
            codexHomeURL: URL(fileURLWithPath: codexHomePath, isDirectory: true),
            workingDirectoryURL: cwdURL
        )
    }

    func resolveExecutablePath(
        argv: [String],
        workingDirectory: String?,
        path: String?
    ) -> String? {
        guard let index = AgentLaunchInstrumentation.safeCodexExecutableIndex(in: argv) else {
            return nil
        }
        if index > 0 {
            let wrapper = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
            guard ["agent-safehouse", "run-sandboxed.sh"].contains(wrapper),
                  ManagedAgentCommandResolver.inferManagedAgent(
                    commandName: argv[0],
                    argv: argv
                  ) == .codex else {
                return nil
            }
        }
        let argument = argv[index]
        if argument.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: argument) ? argument : nil
        }
        if argument.contains("/") {
            guard let workingDirectory else { return nil }
            let candidate = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(argument)
                .standardizedFileURL.path
            return fileManager.isExecutableFile(atPath: candidate) ? candidate : nil
        }
        for directory in (path ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? (workingDirectory ?? fileManager.currentDirectoryPath) : String(directory)
            let candidate = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(argument)
                .standardizedFileURL.path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func fallbackDecision(
        runtime: CodexIntegrationRuntime?,
        reason: String
    ) -> CodexManagedLaunchIntegrationDecision {
        let legacyGlobalHooksPresent: Bool
        if let runtime {
            legacyGlobalHooksPresent = (try? CodexStatusHookInstaller(
                homeDirectoryPath: homeDirectoryURL.path,
                codexHomePath: runtime.codexHomeURL.path,
                fileManager: fileManager
            ).legacyGlobalHooksPresent()) == true
        } else {
            legacyGlobalHooksPresent = false
        }
        return CodexManagedLaunchIntegrationDecision(
            configuration: nil,
            assessment: nil,
            statusTrackingSource: .sessionLogFallback(
                reason: legacyGlobalHooksPresent ? "legacy_global_hooks_unverified" : reason
            )
        )
    }

    func cacheKey(for runtime: CodexIntegrationRuntime) -> CacheKey {
        let stableRoot = homeDirectoryURL.appendingPathComponent(".toastty/codex-plugin", isDirectory: true)
        return CacheKey(
            executablePath: runtime.executableURL.path,
            codexHomePath: runtime.codexHomeURL.path,
            workingDirectoryPath: runtime.workingDirectoryURL.path,
            executableSignature: fileMetadataSignature(runtime.executableURL),
            configSignature: fileContentSignature(runtime.codexHomeURL.appendingPathComponent("config.toml")),
            projectConfigSignature: projectConfigSignature(runtime.workingDirectoryURL),
            hookTrustSignature: fileContentSignature(runtime.codexHomeURL.appendingPathComponent("hooks.json")),
            codexStateSignature: codexStateSignature(runtime.codexHomeURL),
            integrationSignature: directorySignature(stableRoot)
        )
    }

    func projectConfigSignature(_ workingDirectoryURL: URL) -> Int {
        var directory = workingDirectoryURL.standardizedFileURL
        var hasher = Hasher()
        while true {
            let configURL = directory.appendingPathComponent(".codex/config.toml", isDirectory: false)
            hasher.combine(configURL.path)
            hasher.combine(fileContentSignature(configURL))
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return hasher.finalize()
    }

    func codexStateSignature(_ codexHomeURL: URL) -> Int {
        var hasher = Hasher()
        hasher.combine(fileMetadataSignature(codexHomeURL.appendingPathComponent("state_5.sqlite")))
        hasher.combine(fileMetadataSignature(codexHomeURL.appendingPathComponent("sqlite/state_5.sqlite")))
        hasher.combine(directoryMetadataSignature(codexHomeURL.appendingPathComponent("plugins", isDirectory: true)))
        return hasher.finalize()
    }

    func fileMetadataSignature(_ url: URL) -> Int {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
        var hasher = Hasher()
        hasher.combine((attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0)
        hasher.combine((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        hasher.combine((attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        hasher.combine((attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0)
        return hasher.finalize()
    }

    func fileContentSignature(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.hashValue
    }

    func directorySignature(_ root: URL) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }
        let files = enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
        var hasher = Hasher()
        for file in files {
            hasher.combine(String(file.path.dropFirst(root.path.count)))
            hasher.combine(fileContentSignature(file))
        }
        return hasher.finalize()
    }

    func directoryMetadataSignature(_ root: URL) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return 0 }
        let entries = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(String(entry.path.dropFirst(root.path.count)))
            hasher.combine(fileMetadataSignature(entry))
        }
        return hasher.finalize()
    }
}

private final class CodexManagedLaunchResolutionRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private func normalizedCodexIntegrationText(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.isEmpty == false else {
        return nil
    }
    return value
}
