import CoreState
import Foundation

struct CodexManagedLaunchSkillsDecision: Equatable, Sendable {
    let configuration: CodexSkillsLaunchConfiguration?
    let status: CodexSkillsStatus?

    init(
        configuration: CodexSkillsLaunchConfiguration?,
        status: CodexSkillsStatus?
    ) {
        self.configuration = configuration
        self.status = status
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
}

final class CodexManagedLaunchSkillsResolver: CodexManagedLaunchSkillsResolving, @unchecked Sendable {
    private let homeDirectoryURL: URL
    private let fileManager: FileManager
    private let manager: CodexSkillsManager
    private let processEnvironment: @Sendable () -> [String: String]
    private let unsupportedLock = NSLock()
    private var unsupportedRuntimeKeys = Set<String>()

    init(
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        fileManager: FileManager = .default,
        manager: CodexSkillsManager? = nil,
        processEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.fileManager = fileManager
        self.manager = manager ?? CodexSkillsManager(
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
        self.processEnvironment = processEnvironment
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
                do {
                    let preparation = try manager.prepareForManagedLaunch(
                        runtime: runtime
                    )
                    continuation.resume(
                        returning: CodexManagedLaunchSkillsDecision(
                            configuration: preparation.configuration,
                            status: preparation.status
                        )
                    )
                } catch let error as CodexPluginCLIError {
                    if error.isUnsupported {
                        markUnsupported(key)
                    }
                    logFailure(error, runtime: runtime)
                    continuation.resume(
                        returning: CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
                    )
                } catch let error as CodexAppServerClientError {
                    if error.isUnsupported {
                        markUnsupported(key)
                    }
                    logFailure(error, runtime: runtime)
                    continuation.resume(
                        returning: CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
                    )
                } catch {
                    logFailure(error, runtime: runtime)
                    continuation.resume(
                        returning: CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
                    )
                }
            }
        }
    }

    func resolveForRestoredManagedLaunch(
        request: ManagedAgentLaunchRequest,
        workingDirectory: String?
    ) -> CodexManagedLaunchSkillsDecision {
        guard request.agent == .codex,
              let runtime = resolveRuntime(request: request, workingDirectory: workingDirectory) else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }
        let key = runtimeKey(runtime)
        guard unsupportedLock.withLock({ unsupportedRuntimeKeys.contains(key) }) == false else {
            return CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
        }
        do {
            let preparation = try manager.prepareForRestoredManagedLaunch(runtime: runtime)
            return CodexManagedLaunchSkillsDecision(
                configuration: preparation.configuration,
                status: preparation.status
            )
        } catch let error as CodexPluginCLIError {
            if error.isUnsupported { markUnsupported(key) }
            logFailure(error, runtime: runtime)
        } catch let error as CodexAppServerClientError {
            if error.isUnsupported { markUnsupported(key) }
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
