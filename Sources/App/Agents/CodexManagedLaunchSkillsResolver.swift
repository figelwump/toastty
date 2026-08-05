import CoreState
import Foundation

final class CodexProcessPathStore: @unchecked Sendable {
    private let lock = NSLock()
    private let refreshPath: @Sendable () -> String?
    private var path: String?

    init(
        path: String? = nil,
        refreshPath: @escaping @Sendable () -> String? = { nil }
    ) {
        self.path = path
        self.refreshPath = refreshPath
    }

    func update(_ path: String?) {
        lock.withLock {
            self.path = path
        }
    }

    func currentPath() -> String? {
        lock.withLock { path }
    }

    func refresh() -> String? {
        guard let refreshedPath = refreshPath() else {
            return currentPath()
        }
        update(refreshedPath)
        return refreshedPath
    }
}

struct CodexManagedLaunchSkillsDecision: Equatable, Sendable {
    let configuration: CodexSkillsLaunchConfiguration?
    let status: CodexSkillsStatus?
    /// Typed user-plugin outcome for launches that resolved a user snapshot;
    /// nil when the launch path never considered user skills.
    let userSkills: CodexUserSkillsDeliveryState?

    init(
        configuration: CodexSkillsLaunchConfiguration?,
        status: CodexSkillsStatus?,
        userSkills: CodexUserSkillsDeliveryState? = nil
    ) {
        self.configuration = configuration
        self.status = status
        self.userSkills = userSkills
    }
}

protocol CodexManagedLaunchSkillsResolving: AnyObject, Sendable {
    func resolve(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchSkillsDecision
    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) async -> CodexManagedLaunchSkillsDecision
    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchSkillsDecision
    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        userSkillSnapshot: UserSkillPluginSnapshot?
    ) async -> CodexManagedLaunchSkillsDecision
    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        userSkillSnapshot: UserSkillPluginSnapshot?
    ) -> CodexManagedLaunchSkillsDecision
}

extension CodexManagedLaunchSkillsResolving {
    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) async -> CodexManagedLaunchSkillsDecision {
        resolve(request: request, workingDirectory: workingDirectory)
    }

    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchSkillsDecision {
        resolve(request: request, workingDirectory: workingDirectory)
    }

    // Snapshot-parameter defaults forward to the snapshot-free variants so
    // test doubles that only implement those observe the same calls.
    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        userSkillSnapshot _: UserSkillPluginSnapshot?
    ) async -> CodexManagedLaunchSkillsDecision {
        await resolveForManagedLaunch(request: request, workingDirectory: workingDirectory)
    }

    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        userSkillSnapshot _: UserSkillPluginSnapshot?
    ) -> CodexManagedLaunchSkillsDecision {
        resolveForRestoredManagedLaunch(request: request, workingDirectory: workingDirectory)
    }
}

final class CodexManagedLaunchSkillsResolver: CodexManagedLaunchSkillsResolving, @unchecked Sendable {
    private let homeDirectoryURL: URL
    private let fileManager: FileManager
    let manager: CodexSkillsManager
    private let processEnvironment: @Sendable () -> [String: String]
    private let processPathProvider: @Sendable () -> String?
    private let unsupportedLock = NSLock()
    private var unsupportedRuntimeKeys = Set<String>()

    init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default,
        manager: CodexSkillsManager? = nil,
        processEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        processPathProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.fileManager = fileManager
        self.manager = manager ?? CodexSkillsManager(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
        self.processEnvironment = processEnvironment
        self.processPathProvider = processPathProvider
    }

    func resolve(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchSkillsDecision {
        guard request.agent == .codex,
              let runtime = resolveRuntime(request: request, workingDirectory: workingDirectory) else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }
        return CodexManagedLaunchSkillsDecision(
            configuration: manager.cachedLaunchConfiguration(runtime: runtime),
            status: nil
        )
    }

    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) async -> CodexManagedLaunchSkillsDecision {
        await resolveManagedLaunch(
            request: request,
            workingDirectory: workingDirectory
        ) { [manager] runtime in
            try manager.prepareForManagedLaunch(runtime: runtime)
        }
    }

    func resolveForManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        userSkillSnapshot: UserSkillPluginSnapshot?
    ) async -> CodexManagedLaunchSkillsDecision {
        await resolveManagedLaunch(
            request: request,
            workingDirectory: workingDirectory
        ) { [manager] runtime in
            try manager.prepareForManagedLaunch(runtime: runtime, userSnapshot: userSkillSnapshot)
        }
    }

    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchSkillsDecision {
        resolveRestoredManagedLaunch(
            request: request,
            workingDirectory: workingDirectory
        ) { [manager] runtime in
            try manager.prepareForRestoredManagedLaunch(runtime: runtime)
        }
    }

    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        userSkillSnapshot: UserSkillPluginSnapshot?
    ) -> CodexManagedLaunchSkillsDecision {
        resolveRestoredManagedLaunch(
            request: request,
            workingDirectory: workingDirectory
        ) { [manager] runtime in
            try manager.prepareForRestoredManagedLaunch(runtime: runtime, userSnapshot: userSkillSnapshot)
        }
    }
}

private extension CodexManagedLaunchSkillsResolver {
    func resolveManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        prepare: @escaping @Sendable (CodexIntegrationRuntime) throws -> CodexSkillsPreparation
    ) async -> CodexManagedLaunchSkillsDecision {
        guard request.agent == .codex,
              let runtime = resolveRuntime(request: request, workingDirectory: workingDirectory) else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }
        let key = runtimeKey(runtime)
        let unsupported = unsupportedLock.withLock {
            unsupportedRuntimeKeys.contains(key)
        }
        guard unsupported == false else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(
                    returning: decision(
                        preparing: prepare,
                        runtime: runtime,
                        unsupportedKey: key
                    )
                )
            }
        }
    }

    func resolveRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?,
        prepare: (CodexIntegrationRuntime) throws -> CodexSkillsPreparation
    ) -> CodexManagedLaunchSkillsDecision {
        guard request.agent == .codex,
              let runtime = resolveRuntime(request: request, workingDirectory: workingDirectory) else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }
        let key = runtimeKey(runtime)
        guard unsupportedLock.withLock({ unsupportedRuntimeKeys.contains(key) }) == false else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }
        return decision(preparing: prepare, runtime: runtime, unsupportedKey: key)
    }

    func decision(
        preparing prepare: (CodexIntegrationRuntime) throws -> CodexSkillsPreparation,
        runtime: CodexIntegrationRuntime,
        unsupportedKey key: String
    ) -> CodexManagedLaunchSkillsDecision {
        do {
            let preparation = try prepare(runtime)
            return CodexManagedLaunchSkillsDecision(
                configuration: preparation.configuration,
                status: preparation.status,
                userSkills: preparation.userSkills
            )
        } catch let error as CodexPluginCLIError {
            if error.isUnsupported {
                markUnsupported(key)
            }
            logFailure(error, runtime: runtime)
        } catch {
            logFailure(error, runtime: runtime)
        }
        return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
    }
}

private extension CodexManagedLaunchSkillsResolver {
    func resolveRuntime(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexIntegrationRuntime? {
        let inheritedEnvironment = processEnvironment()
        let requestShimDirectoryPath = normalizedText(
            request.environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey]
        )
        let requestProcessPath = requestShimDirectoryPath == nil
            ? nil
            : normalizedText(request.environment["PATH"])
        let preferredProcessPath = request.codexCapabilityHint?.processPath
            ?? requestProcessPath
            ?? processPathProvider()
        let processPath = ManagedAgentPathResolver.sanitizedMergedPath(
            preferredPath: preferredProcessPath,
            fallbackPath: inheritedEnvironment["PATH"],
            excludedDirectoryPaths: Set(
                [requestShimDirectoryPath].compactMap { $0 }
            )
        )
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
                path: processPath
            )
        }
        guard let executablePath else { return nil }

        let codexHomePath = request.codexCapabilityHint?.codexHomePath
            ?? normalizedText(request.environment["CODEX_HOME"])
            ?? homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true).path
        guard codexHomePath.hasPrefix("/") else { return nil }
        let cwdURL = workingDirectory.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } ?? homeDirectoryURL

        return CodexIntegrationRuntime(
            executableURL: URL(fileURLWithPath: executablePath),
            processEnvironment: CodexProcessEnvironment(
                codexHomeURL: URL(fileURLWithPath: codexHomePath, isDirectory: true),
                path: processPath
            ),
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
            let base = directory.isEmpty
                ? (workingDirectory ?? fileManager.currentDirectoryPath)
                : String(directory)
            let candidate = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(argument)
                .standardizedFileURL.path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func runtimeKey(_ runtime: CodexIntegrationRuntime) -> String {
        let metadata: String
        if let attributes = try? fileManager.attributesOfItem(atPath: runtime.executableURL.path) {
            metadata = [
                (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "0",
                (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "0",
                (attributes[.size] as? NSNumber)?.stringValue ?? "0",
                String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
            ].joined(separator: ":")
        } else {
            metadata = "missing"
        }
        return "\(runtime.executableURL.path)|\(metadata)|\(runtime.codexHomeURL.standardizedFileURL.path)"
    }

    func markUnsupported(_ key: String) {
        unsupportedLock.lock()
        unsupportedRuntimeKeys.insert(key)
        unsupportedLock.unlock()
    }

    func logFailure(_ error: Error, runtime: CodexIntegrationRuntime) {
        ToasttyLog.warning(
            "Codex skills provisioning failed; launching without Toastty skills",
            category: .automation,
            metadata: [
                "codex_executable": runtime.executableURL.path,
                "codex_home": runtime.codexHomeURL.path,
                "error": error.localizedDescription,
            ]
        )
    }

    func normalizedText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }
}
