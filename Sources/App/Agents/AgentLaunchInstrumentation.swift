import RemoteProtocol
import CoreState
import Foundation

struct PreparedAgentLaunchCommand {
    let argv: [String]
    let environment: [String: String]
    let artifacts: PreparedAgentLaunchArtifacts?
    let codexSkillsInjectionResult: CodexSkillsInjectionResult

    init(
        argv: [String],
        environment: [String: String],
        artifacts: PreparedAgentLaunchArtifacts?,
        codexSkillsInjectionResult: CodexSkillsInjectionResult = .notRequested
    ) {
        self.argv = argv
        self.environment = environment
        self.artifacts = artifacts
        self.codexSkillsInjectionResult = codexSkillsInjectionResult
    }
}

enum CodexStatusTrackingSource: Equatable, Sendable {
    case hooks
    case sessionLogFallback(reason: String)

    var code: String {
        switch self {
        case .hooks:
            return "hooks"
        case .sessionLogFallback:
            return "session_log_fallback"
        }
    }

    var fallbackReason: String? {
        switch self {
        case .hooks:
            return nil
        case .sessionLogFallback(let reason):
            return reason
        }
    }
}

enum LaunchArtifactsCleanupPolicy {
    case deleteImmediately
    case retainAfterSessionStop
}

struct PreparedAgentLaunchArtifacts {
    let directory: ManagedAgentLaunchArtifactDirectory
    let codexSessionLogURL: URL?
    let cleanupPolicy: LaunchArtifactsCleanupPolicy

    var directoryURL: URL { directory.directoryURL }
}

enum AgentLaunchInstrumentationError: LocalizedError {
    case agentConfigContentEnvironmentAlreadySet(agent: AgentKind, key: String)
    case invalidClaudeSettingsArgument
    case unsupportedClaudeSettingsFormat
    case missingPiExtensionResource

    var errorDescription: String? {
        switch self {
        case .agentConfigContentEnvironmentAlreadySet(let agent, let key):
            return "\(agent.displayName) launch profile already sets \(key); Toastty will not overwrite it for status instrumentation."
        case .invalidClaudeSettingsArgument:
            return "Claude launch profile has an invalid --settings argument."
        case .unsupportedClaudeSettingsFormat:
            return "Claude settings must decode to a JSON object."
        case .missingPiExtensionResource:
            return "Toastty could not find its bundled Pi extension."
        }
    }
}

enum AgentLaunchInstrumentation {
    nonisolated(unsafe) static var piExtensionPathProviderForTesting: (() -> String?)?

    /// Whether a pi launch with this argv will actually receive injected
    /// skills, composing the same extension and skills gates `prepare` applies.
    /// The planner consults this so the skills-provisioned notice is never
    /// posted for a launch whose caller explicitly opted out.
    static func piLaunchWillInjectSkills(argv: [String]) -> Bool {
        let commandIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .pi, argv: argv)
        return piLaunchAllowsExtensionInjection(argv: argv, commandIndex: commandIndex)
            && piLaunchAllowsSkillsInjection(argv: argv, commandIndex: commandIndex)
    }

    /// `stagedSkillsIntegration` is the staged shipped-skills payload shared by
    /// every additive runtime, and `deliveredUserSkillsRootPath` is the caller's
    /// runtime-specific projection of the user skills snapshot (Claude and
    /// Cursor consume the plugin root; the other additive runtimes consume the
    /// plain skills tree). Codex takes both through its profile overlay instead.
    static func prepare(
        agent: AgentKind,
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?,
        fileManager: FileManager,
        artifactStore: ManagedAgentLaunchArtifactStore? = nil,
        launchEnvironment: [String: String] = [:],
        codexStatusTrackingSource: CodexStatusTrackingSource = .sessionLogFallback(reason: "default"),
        codexSkillsIntegration: CodexSkillsLaunchConfiguration? = nil,
        stagedSkillsIntegration: ClaudeSkillsLaunchConfiguration? = nil,
        deliveredUserSkillsRootPath: String? = nil
    ) throws -> PreparedAgentLaunchCommand {
        if agent == .claude {
            return try prepareClaudeLaunch(
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                artifactStore: artifactStore,
                skillsIntegration: stagedSkillsIntegration,
                userPluginRootPath: deliveredUserSkillsRootPath
            )
        }

        if agent == .cursor {
            return prepareCursorLaunch(
                argv: argv,
                skillsIntegration: stagedSkillsIntegration,
                userPluginRootPath: deliveredUserSkillsRootPath
            )
        }

        if agent == .codex {
            return try prepareCodexLaunch(
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                fileManager: fileManager,
                artifactStore: artifactStore,
                launchEnvironment: launchEnvironment,
                statusTrackingSource: codexStatusTrackingSource,
                skillsIntegration: codexSkillsIntegration
            )
        }

        if agent == .opencode {
            return try prepareOpenCodeFamilyLaunch(
                runtime: .opencode,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                launchEnvironment: launchEnvironment,
                skillsIntegration: stagedSkillsIntegration,
                userSkillsRootPath: deliveredUserSkillsRootPath
            )
        }

        if agent == .mimocode {
            return try prepareOpenCodeFamilyLaunch(
                runtime: .mimocode,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                launchEnvironment: launchEnvironment,
                skillsIntegration: stagedSkillsIntegration,
                userSkillsRootPath: deliveredUserSkillsRootPath
            )
        }

        if agent == .pi {
            return try preparePiLaunch(
                argv: argv,
                sessionID: sessionID,
                fileManager: fileManager,
                skillsIntegration: stagedSkillsIntegration,
                userSkillsRootPath: deliveredUserSkillsRootPath
            )
        }

        return PreparedAgentLaunchCommand(argv: argv, environment: [:], artifacts: nil)
    }

    /// Cursor's documented `--plugin-dir` flag is repeatable, so Toastty can
    /// add its immutable shipped plugin and the generated user-skills plugin
    /// without rewriting the user's global Cursor hooks or plugin settings.
    /// Injection is deliberately limited to an unambiguous `cursor-agent`
    /// executable; Cursor's generic `agent` alias is too collision-prone to
    /// identify as a managed Cursor launch on its own.
    private static func prepareCursorLaunch(
        argv: [String],
        skillsIntegration: ClaudeSkillsLaunchConfiguration?,
        userPluginRootPath: String?
    ) -> PreparedAgentLaunchCommand {
        guard let insertionIndex = safeCursorPluginExecutableIndex(in: argv) else {
            return PreparedAgentLaunchCommand(argv: argv, environment: [:], artifacts: nil)
        }

        var launchArguments: [String] = []
        var environment: [String: String] = [:]
        if let skillsIntegration {
            launchArguments += ["--plugin-dir", skillsIntegration.pluginRootPath]
            environment[ToasttyLaunchContextEnvironment.skillsRootKey] = skillsIntegration.skillsRootPath
        }
        if let userPluginRootPath = normalizedNonEmptyValue(userPluginRootPath) {
            launchArguments += ["--plugin-dir", userPluginRootPath]
        }

        return PreparedAgentLaunchCommand(
            argv: insertingArguments(
                launchArguments,
                into: argv,
                afterIndex: insertionIndex
            ),
            environment: environment,
            artifacts: nil
        )
    }

    private static func prepareClaudeLaunch(
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?,
        fileManager: FileManager,
        artifactStore: ManagedAgentLaunchArtifactStore?,
        skillsIntegration: ClaudeSkillsLaunchConfiguration?,
        userPluginRootPath: String?
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectory = try makeArtifactsDirectory(
            agent: .claude,
            prefix: "toastty-claude-launch",
            sessionID: sessionID,
            fileManager: fileManager,
            lifetime: .agentProcess,
            artifactStore: artifactStore
        )
        let artifactsDirectoryURL = artifactsDirectory.directoryURL

        do {
            let hookScriptURL = artifactsDirectoryURL.appendingPathComponent("claude-hook.sh", isDirectory: false)
            let telemetryErrorLogURL = telemetryErrorLogURL(in: artifactsDirectoryURL)
            try writeExecutableScript(
                makeTelemetryForwarderScript(
                    cliExecutablePath: cliExecutablePath,
                    source: "claude-hooks",
                    telemetryErrorLogURL: telemetryErrorLogURL,
                    stderrFallbackURL: artifactsDirectoryURL.appendingPathComponent("claude-hook.stderr", isDirectory: false),
                    inputMode: .stdinOrFirstArgument,
                    ownerRecordURL: artifactsDirectory.ownerRecordURL,
                    ownerPIDEnvironmentKey: "CLAUDE_PID"
                ),
                to: hookScriptURL,
                fileManager: fileManager
            )

            let existingSettings = try resolveClaudeSettingsArgument(
                from: argv,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            )
            let mergedSettings = mergeClaudeHooks(
                into: existingSettings.baseSettings,
                command: "/bin/sh \(shellQuote(hookScriptURL.path))"
            )

            let settingsURL = artifactsDirectoryURL.appendingPathComponent("claude-settings.json", isDirectory: false)
            try writeJSONObject(mergedSettings, to: settingsURL, fileManager: fileManager)
            let settingsInsertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(
                for: .claude,
                argv: existingSettings.argvWithoutSettings
            )
            let skillsInsertionIndex = safeClaudeSkillsIntegrationExecutableIndex(
                in: existingSettings.argvWithoutSettings
            )
            var launchArguments = ["--settings", settingsURL.path]
            var environment: [String: String] = [:]
            if let ownerRecordURL = artifactsDirectory.ownerRecordURL {
                environment[ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey] = ownerRecordURL.path
            }
            if let skillsIntegration, skillsInsertionIndex != nil {
                launchArguments += ["--plugin-dir", skillsIntegration.pluginRootPath]
                environment[ToasttyLaunchContextEnvironment.skillsRootKey] = skillsIntegration.skillsRootPath
            }
            // The user plugin snapshot is already immutable and
            // content-addressed, so its root is injected directly (after the
            // shipped plugin, additive with caller-supplied --plugin-dir
            // flags) under the same safe-executable-index gating.
            if let userPluginRootPath = normalizedNonEmptyValue(userPluginRootPath),
               skillsInsertionIndex != nil {
                launchArguments += ["--plugin-dir", userPluginRootPath]
            }

            return PreparedAgentLaunchCommand(
                argv: insertingArguments(
                    launchArguments,
                    into: existingSettings.argvWithoutSettings,
                    afterIndex: skillsInsertionIndex ?? settingsInsertionIndex
                ),
                environment: environment,
                artifacts: PreparedAgentLaunchArtifacts(
                    directory: artifactsDirectory,
                    codexSessionLogURL: nil,
                    // Claude can still invoke hooks after Toastty has already
                    // stopped tracking the managed session.
                    cleanupPolicy: .retainAfterSessionStop
                )
            )
        } catch {
            try? fileManager.removeItem(at: artifactsDirectoryURL)
            throw error
        }
    }

    private static func prepareCodexLaunch(
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        fileManager: FileManager,
        artifactStore: ManagedAgentLaunchArtifactStore?,
        launchEnvironment: [String: String],
        statusTrackingSource: CodexStatusTrackingSource,
        skillsIntegration: CodexSkillsLaunchConfiguration?
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectory = try makeArtifactsDirectory(
            agent: .codex,
            prefix: "toastty-codex-launch",
            sessionID: sessionID,
            fileManager: fileManager,
            lifetime: .agentProcess,
            artifactStore: artifactStore
        )
        let artifactsDirectoryURL = artifactsDirectory.directoryURL

        do {
            let logURL = artifactsDirectoryURL.appendingPathComponent("codex-session.jsonl", isDirectory: false)
            var environment = baselineEnvironment(for: .codex)
            if let ownerRecordURL = artifactsDirectory.ownerRecordURL {
                environment[ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey] = ownerRecordURL.path
            }
            environment["CODEX_TUI_RECORD_SESSION"] = "1"
            environment["CODEX_TUI_SESSION_LOG_PATH"] = logURL.path
            let safeExecutableIndex = safeCodexSkillsExecutableIndex(in: argv)
            let skillsPreparation = prepareCodexSkills(
                argv: argv,
                configuration: skillsIntegration,
                executableIndex: safeExecutableIndex,
                launchEnvironment: launchEnvironment
            )
            if skillsPreparation.result == .injected,
               let skillsIntegration {
                environment[ToasttyLaunchContextEnvironment.skillsRootKey] = skillsIntegration.skillsRootPath
            }

            var preparedArgv = skillsPreparation.argv
            if statusTrackingSource != .hooks {
                let notifyScriptURL = artifactsDirectoryURL.appendingPathComponent("codex-notify.sh", isDirectory: false)
                let telemetryErrorLogURL = telemetryErrorLogURL(in: artifactsDirectoryURL)
                try writeExecutableScript(
                    makeTelemetryForwarderScript(
                        cliExecutablePath: cliExecutablePath,
                        source: "codex-notify",
                        telemetryErrorLogURL: telemetryErrorLogURL,
                        stderrFallbackURL: artifactsDirectoryURL.appendingPathComponent("codex-notify.stderr", isDirectory: false),
                        inputMode: .stdinOrFirstArgument,
                        ownerRecordURL: artifactsDirectory.ownerRecordURL
                    ),
                    to: notifyScriptURL,
                    fileManager: fileManager
                )
                let notifyArray = CodexConfigTOMLSerializer.tomlStringArrayLiteral([
                    "/bin/sh",
                    notifyScriptURL.path,
                ])
                let insertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(
                    for: .codex,
                    argv: preparedArgv
                )
                preparedArgv = insertingArguments(
                    ["-c", "notify=\(notifyArray)"],
                    into: preparedArgv,
                    afterIndex: insertionIndex
                )
            }

            return PreparedAgentLaunchCommand(
                argv: preparedArgv,
                environment: environment,
                artifacts: PreparedAgentLaunchArtifacts(
                    directory: artifactsDirectory,
                    codexSessionLogURL: logURL,
                    cleanupPolicy: artifactStore == nil ? .deleteImmediately : .retainAfterSessionStop
                ),
                codexSkillsInjectionResult: skillsPreparation.result
            )
        } catch {
            try? fileManager.removeItem(at: artifactsDirectoryURL)
            throw error
        }
    }

    private static func prepareOpenCodeFamilyLaunch(
        runtime: OpenCodeFamilyRuntime,
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?,
        fileManager: FileManager,
        launchEnvironment: [String: String],
        skillsIntegration: ClaudeSkillsLaunchConfiguration?,
        userSkillsRootPath: String?
    ) throws -> PreparedAgentLaunchCommand {
        if normalizedNonEmptyValue(launchEnvironment[runtime.configContentEnvironmentKey]) != nil {
            throw AgentLaunchInstrumentationError.agentConfigContentEnvironmentAlreadySet(
                agent: runtime.agent,
                key: runtime.configContentEnvironmentKey
            )
        }

        let artifactsDirectory = try makeArtifactsDirectory(
            agent: runtime.agent,
            prefix: runtime.artifactsDirectoryPrefix,
            sessionID: sessionID,
            fileManager: fileManager,
            lifetime: .session,
            artifactStore: nil
        )
        let artifactsDirectoryURL = artifactsDirectory.directoryURL

        do {
            let pluginURL = artifactsDirectoryURL.appendingPathComponent(runtime.pluginFilename, isDirectory: false)
            let telemetryErrorLogURL = telemetryErrorLogURL(in: artifactsDirectoryURL)
            let runtimeEnvironment = ProcessInfo.processInfo.environment.merging(launchEnvironment) { _, new in new }
            let resumeDirectoryURL = ToasttyRuntimePaths.resolve(environment: runtimeEnvironment)
                .managedAgentResumeDirectoryURL
            let initialRootSessionID = explicitOpenCodeFamilySessionID(
                runtime: runtime,
                argv: argv
            )
            try Data(
                makeOpenCodeFamilyStatusPlugin(
                    cliExecutablePath: cliExecutablePath,
                    source: runtime.eventSource,
                    workingDirectory: workingDirectory,
                    resumeDirectoryURL: resumeDirectoryURL,
                    telemetryErrorLogURL: telemetryErrorLogURL,
                    initialRootSessionID: initialRootSessionID
                ).appending("\n").utf8
            ).write(to: pluginURL, options: .atomic)

            var configContent: [String: Any] = [
                "plugin": [
                    pluginURL.absoluteURL.standardizedFileURL.absoluteString,
                ],
            ]
            var environment: [String: String] = [:]
            // `skills.paths` entries must be plain absolute paths: unlike
            // `plugin`, a `file://` URI silently discovers nothing. The whole
            // object replaces any `skills` the user's own config layers set,
            // so it is emitted only alongside the shipped tree.
            if let skillsIntegration {
                var skillsPaths = [skillsIntegration.skillsRootPath]
                if let userSkillsRootPath = normalizedNonEmptyValue(userSkillsRootPath) {
                    skillsPaths.append(userSkillsRootPath)
                }
                configContent["skills"] = ["paths": skillsPaths]
                environment[ToasttyLaunchContextEnvironment.skillsRootKey] = skillsIntegration.skillsRootPath
            }
            let configData = try JSONSerialization.data(withJSONObject: configContent, options: [.sortedKeys])
            environment[runtime.configContentEnvironmentKey] = String(decoding: configData, as: UTF8.self)

            return PreparedAgentLaunchCommand(
                argv: argv,
                environment: environment,
                artifacts: PreparedAgentLaunchArtifacts(
                    directory: artifactsDirectory,
                    codexSessionLogURL: nil,
                    cleanupPolicy: .deleteImmediately
                )
            )
        } catch {
            try? fileManager.removeItem(at: artifactsDirectoryURL)
            throw error
        }
    }

    private static func preparePiLaunch(
        argv: [String],
        sessionID: String,
        fileManager: FileManager,
        skillsIntegration: ClaudeSkillsLaunchConfiguration?,
        userSkillsRootPath: String?
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectory = try makeArtifactsDirectory(
            agent: .pi,
            prefix: "toastty-pi-launch",
            sessionID: sessionID,
            fileManager: fileManager,
            lifetime: .session,
            artifactStore: nil
        )
        let artifactsDirectoryURL = artifactsDirectory.directoryURL

        let telemetryLogURL = artifactsDirectoryURL.appendingPathComponent("pi-telemetry.jsonl", isDirectory: false)
        var environment = [
            "TOASTTY_PI_TELEMETRY_LOG_PATH": telemetryLogURL.path,
        ]

        let insertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .pi, argv: argv)
        guard piLaunchAllowsExtensionInjection(argv: argv, commandIndex: insertionIndex) else {
            return PreparedAgentLaunchCommand(
                argv: argv,
                environment: environment,
                artifacts: PreparedAgentLaunchArtifacts(
                    directory: artifactsDirectory,
                    codexSessionLogURL: nil,
                    cleanupPolicy: .deleteImmediately
                )
            )
        }

        guard let extensionPath = resolvedPiExtensionPath() else {
            try? fileManager.removeItem(at: artifactsDirectoryURL)
            throw AgentLaunchInstrumentationError.missingPiExtensionResource
        }

        // `--skill` is repeatable and takes the parent directory of
        // `<name>/SKILL.md` folders, so the staged trees are additive with any
        // caller-supplied `--skill`.
        var launchArguments = ["--extension", extensionPath]
        if piLaunchAllowsSkillsInjection(argv: argv, commandIndex: insertionIndex) {
            if let skillsIntegration {
                launchArguments += ["--skill", skillsIntegration.skillsRootPath]
                environment[ToasttyLaunchContextEnvironment.skillsRootKey] = skillsIntegration.skillsRootPath
            }
            if let userSkillsRootPath = normalizedNonEmptyValue(userSkillsRootPath) {
                launchArguments += ["--skill", userSkillsRootPath]
            }
        }

        return PreparedAgentLaunchCommand(
            argv: insertingArguments(
                launchArguments,
                into: argv,
                afterIndex: insertionIndex
            ),
            environment: environment,
            artifacts: PreparedAgentLaunchArtifacts(
                directory: artifactsDirectory,
                codexSessionLogURL: nil,
                cleanupPolicy: .deleteImmediately
            )
        )
    }
}

private extension AgentLaunchInstrumentation {
    enum TelemetryInputMode {
        case none
        case stdinOrFirstArgument
    }

    enum OpenCodeFamilyRuntime {
        case mimocode
        case opencode

        var agent: AgentKind {
            switch self {
            case .mimocode:
                return .mimocode
            case .opencode:
                return .opencode
            }
        }

        var configContentEnvironmentKey: String {
            switch self {
            case .mimocode:
                return "MIMOCODE_CONFIG_CONTENT"
            case .opencode:
                return "OPENCODE_CONFIG_CONTENT"
            }
        }

        var eventSource: String {
            switch self {
            case .mimocode:
                return "mimocode-plugin"
            case .opencode:
                return "opencode-plugin"
            }
        }

        var artifactsDirectoryPrefix: String {
            switch self {
            case .mimocode:
                return "toastty-mimocode-launch"
            case .opencode:
                return "toastty-opencode-launch"
            }
        }

        var pluginFilename: String {
            switch self {
            case .mimocode:
                return "toastty-mimocode-status-plugin.js"
            case .opencode:
                return "toastty-opencode-status-plugin.js"
            }
        }

        var executableBasenames: Set<String> {
            switch self {
            case .mimocode:
                return ["mimo", "mimocode"]
            case .opencode:
                return ["opencode"]
            }
        }
    }

    static func explicitOpenCodeFamilySessionID(
        runtime: OpenCodeFamilyRuntime,
        argv: [String]
    ) -> String? {
        guard argv.isEmpty == false else { return nil }
        let boundaryIndex = argv.firstIndex(of: "--") ?? argv.endIndex
        let candidates = argv.indices.filter { index in
            guard index < boundaryIndex else { return false }
            let basename = URL(fileURLWithPath: argv[index]).lastPathComponent.lowercased()
            return runtime.executableBasenames.contains(basename)
        }
        guard candidates.count == 1, let executableIndex = candidates.first else { return nil }

        if executableIndex > 0 {
            let wrapperBasename = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
            let supportedWrappers: Set<String> = ["agent-safehouse", "run-sandboxed.sh"]
            guard supportedWrappers.contains(wrapperBasename),
                  ManagedAgentCommandResolver.inferManagedAgent(
                      commandName: argv[0],
                      argv: argv
                  ) == runtime.agent else {
                return nil
            }
        }

        var index = executableIndex + 1
        while index < boundaryIndex {
            let argument = argv[index]
            if argument == "--session" || argument == "-s" {
                guard index + 1 < boundaryIndex else { return nil }
                let value = argv[index + 1]
                guard value.hasPrefix("-") == false else { return nil }
                return normalizedNonEmptyValue(value).map { String($0.prefix(240)) }
            }
            if argument.hasPrefix("--session=") {
                return normalizedNonEmptyValue(String(argument.dropFirst("--session=".count)))
                    .map { String($0.prefix(240)) }
            }
            index += 1
        }
        return nil
    }

    struct ResolvedClaudeSettings {
        let argvWithoutSettings: [String]
        let baseSettings: [String: Any]
    }

    static func makeArtifactsDirectory(
        agent: AgentKind,
        prefix: String,
        sessionID: String,
        fileManager: FileManager,
        lifetime: ManagedAgentLaunchArtifactLifetime,
        artifactStore: ManagedAgentLaunchArtifactStore?
    ) throws -> ManagedAgentLaunchArtifactDirectory {
        if let artifactStore {
            return try artifactStore.makeDirectory(
                agent: agent,
                sessionID: sessionID,
                lifetime: lifetime
            )
        }
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(sessionID)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return ManagedAgentLaunchArtifactDirectory(
            directoryURL: url,
            ownerRecordURL: lifetime == .agentProcess
                ? url.appendingPathComponent(ManagedAgentLaunchArtifactStore.ownerRecordFileName)
                : nil,
            lifetime: lifetime,
            storage: .temporary
        )
    }

    static func resolveClaudeSettingsArgument(
        from argv: [String],
        workingDirectory: String?,
        fileManager: FileManager
    ) throws -> ResolvedClaudeSettings {
        var strippedArgv: [String] = []
        var settingsValue: String?
        var index = 0

        while index < argv.count {
            let argument = argv[index]

            if argument == "--settings" {
                guard index + 1 < argv.count else {
                    throw AgentLaunchInstrumentationError.invalidClaudeSettingsArgument
                }
                settingsValue = argv[index + 1]
                index += 2
                continue
            }

            if argument.hasPrefix("--settings=") {
                settingsValue = String(argument.dropFirst("--settings=".count))
                index += 1
                continue
            }

            strippedArgv.append(argument)
            index += 1
        }

        guard let settingsValue = normalizedNonEmptyValue(settingsValue) else {
            return ResolvedClaudeSettings(argvWithoutSettings: strippedArgv, baseSettings: [:])
        }

        let decodedObject: Any
        if settingsValue.hasPrefix("{") {
            decodedObject = try JSONSerialization.jsonObject(with: Data(settingsValue.utf8))
        } else {
            let resolvedURL = resolveSettingsFileURL(settingsValue, workingDirectory: workingDirectory)
            decodedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: resolvedURL))
        }

        guard let baseSettings = decodedObject as? [String: Any] else {
            throw AgentLaunchInstrumentationError.unsupportedClaudeSettingsFormat
        }

        return ResolvedClaudeSettings(argvWithoutSettings: strippedArgv, baseSettings: baseSettings)
    }

    static func resolveSettingsFileURL(_ path: String, workingDirectory: String?) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }

        let basePath = normalizedNonEmptyValue(workingDirectory) ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent(expandedPath, isDirectory: false)
    }

    static func mergeClaudeHooks(
        into baseSettings: [String: Any],
        command: String
    ) -> [String: Any] {
        var mergedSettings = baseSettings
        let commandHook: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                ],
            ],
        ]
        let wildcardCommandHook: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                ],
            ],
        ]
        let agentPostToolUseCommandHook: [String: Any] = [
            "matcher": "Agent",
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                ],
            ],
        ]
        let taskPostToolUseCommandHook: [String: Any] = [
            "matcher": "Task",
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                ],
            ],
        ]

        let questionCommandHook: [String: Any] = [
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": command]],
        ]
        // The response runner waits at most five minutes. Give it time to
        // release the host lease before Claude cancels the command itself.
        let permissionCommandHook: [String: Any] = [
            "matcher": "*",
            "hooks": [["type": "command", "command": command, "timeout": 310]],
        ]

        var hooks = mergedSettings["hooks"] as? [String: Any] ?? [:]
        appendClaudeHookEntry(commandHook, to: "SessionStart", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "UserPromptSubmit", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "Stop", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "SessionEnd", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "SubagentStart", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "SubagentStop", in: &hooks)
        appendClaudeHookEntry(agentPostToolUseCommandHook, to: "PostToolUse", in: &hooks)
        appendClaudeHookEntry(taskPostToolUseCommandHook, to: "PostToolUse", in: &hooks)
        appendClaudeHookEntry(questionCommandHook, to: "PostToolUse", in: &hooks)
        appendClaudeHookEntry(questionCommandHook, to: "PostToolUseFailure", in: &hooks)
        appendClaudeHookEntry(wildcardCommandHook, to: "PreToolUse", in: &hooks)
        appendClaudeHookEntry(permissionCommandHook, to: "PermissionRequest", in: &hooks)
        // Keep both PermissionRequest and Notification coverage. Claude surfaces
        // some approval/input pauses as notifications (for example
        // permission_prompt / elicitation_dialog), and the runtime store
        // already suppresses repeated actionable transitions with the same kind.
        appendClaudeHookEntry(wildcardCommandHook, to: "Notification", in: &hooks)
        mergedSettings["hooks"] = hooks

        return mergedSettings
    }

    static func appendClaudeHookEntry(
        _ entry: [String: Any],
        to eventName: String,
        in hooks: inout [String: Any]
    ) {
        var entries = hooks[eventName] as? [[String: Any]] ?? []
        entries.append(entry)
        hooks[eventName] = entries
    }

    static func writeExecutableScript(
        _ script: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try Data(script.appending("\n").utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func writeJSONObject(
        _ object: [String: Any],
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func telemetryErrorLogURL(in artifactsDirectoryURL: URL) -> URL {
        artifactsDirectoryURL.appendingPathComponent("telemetry-failures.log", isDirectory: false)
    }

    static func makeOpenCodeFamilyStatusPlugin(
        cliExecutablePath: String,
        source: String,
        workingDirectory: String?,
        resumeDirectoryURL: URL,
        telemetryErrorLogURL: URL,
        initialRootSessionID: String?
    ) -> String {
        let cliLiteral = jsonStringLiteral(cliExecutablePath)
        let sourceLiteral = jsonStringLiteral(source)
        let workingDirectoryLiteral = jsonStringLiteral(normalizedNonEmptyValue(workingDirectory) ?? "")
        let resumeDirectoryLiteral = jsonStringLiteral(resumeDirectoryURL.path)
        let logLiteral = jsonStringLiteral(telemetryErrorLogURL.path)
        let initialRootSessionLiteral = jsonStringLiteral(initialRootSessionID ?? "")

        return """
        export async function ToasttyOpenCodeFamilyStatusPlugin(pluginInput) {
          const cliPath = \(cliLiteral);
          const source = \(sourceLiteral);
          const launchWorkingDirectory = \(workingDirectoryLiteral);
          const resumeDirectoryPath = \(resumeDirectoryLiteral);
          const logPath = \(logLiteral);
          let rootNativeSessionID = \(initialRootSessionLiteral);
          let rootSessionIdentityObserved = false;
          const isMiMoCode = source === "mimocode-plugin";
          const providerClient = objectValue(pluginInput).client;
          let queue = Promise.resolve();
          let lastFinalText = "";
          let lastCompletedTextCandidate = "";
          let lastForwardedStatusKey = "";
          let lastForwardedFinalText = "";
          let suppressWorkingUntil = 0;
          let blankWorkingSuppressUntil = 0;
          let questionApprovalResolvedUntil = 0;
          let mimoTurnClosed = false;
          const terminalWorkingSuppressMs = 2000;
          const blankWorkingSuppressMs = 750;
          const questionApprovalResolvedSuppressMs = 2000;
          let pendingOpenCodeFinalTimer;
          const openCodeFinalQuietMs = 250;
          const nativeSessionIDLimit = 240;
          const pendingStatusKeys = new Set();
          const pendingFinalTexts = new Set();
          const pendingNativeSessionKeys = new Set();
          const forwardedNativeSessionKeys = new Set();
          const childActivities = new Map();
          const finishedChildIDs = new Set();
          const finishedChildIDLimit = 256;
          const recognizedReasoningEfforts = new Set([
            "off", "none", "minimal", "low", "medium", "high", "xhigh", "max",
          ]);
          let conversationSnapshotCounter = 0;
          let currentConversationSnapshotID = "";
          let currentTurnID = "";
          let promptOpenEmittedForTurn = false;
          let conversationRecordCounter = 0;
          const forwardedConversationSnapshotKeys = new Set();

          function envValue(name) {
            const value = process.env[name];
            return typeof value === "string" && value.trim() ? value : "";
          }

          function objectValue(value) {
            return value && typeof value === "object" ? value : {};
          }

          function stringValue(value, limit) {
            let string = "";
            if (typeof value === "string") {
              string = value;
            } else if (typeof value === "number" || typeof value === "boolean") {
              string = String(value);
            }
            const collapsed = string.split(/\\s+/).filter(Boolean).join(" ");
            if (!collapsed) return "";
            if (!limit || collapsed.length <= limit) return collapsed;
            return `${collapsed.slice(0, Math.max(0, limit - 3))}...`;
          }

          function transcriptText(value, limit = 32768) {
            if (typeof value !== "string") return "";
            const trimmed = value.trim();
            return trimmed.slice(0, limit);
          }

          function partsText(parts) {
            if (!Array.isArray(parts)) return "";
            return transcriptText(parts
              .filter((part) => {
                const type = stringValue(objectValue(part).type, 40).toLowerCase();
                return type === "text" || type === "output_text";
              })
              .map((part) => transcriptText(objectValue(part).text))
              .filter(Boolean)
              .join("\\n"));
          }

          function recordID(prefix, value) {
            const stable = stringValue(value, 500);
            if (stable) return `${prefix}:${stable}`;
            conversationRecordCounter += 1;
            return `${prefix}:${conversationRecordCounter}`;
          }

          function conversationBatch(records, options = {}) {
            if (!rootNativeSessionID) return;
            if (!currentConversationSnapshotID) {
              conversationSnapshotCounter += 1;
              currentConversationSnapshotID = `${source}:${rootNativeSessionID}:${conversationSnapshotCounter}`;
            }
            return {
              type: "toastty.conversation.batch",
              properties: {
                nativeSessionID: rootNativeSessionID,
                snapshotID: currentConversationSnapshotID,
                reset: options.reset === true,
                timestamp: new Date().toISOString(),
                records: Array.isArray(records) ? records : [],
              },
            };
          }

          function enqueueConversation(records, options) {
            const event = conversationBatch(records, options);
            if (!event) return queue;
            queue = queue
              .then(() => forward(event))
              .catch((error) => appendFailure("conversation_forward_exception", event.type, errorText(error)));
            return queue;
          }

          async function forwardConversationRecords(records, reset) {
            const chunks = [];
            let chunk = [];
            let size = 0;
            for (const record of records) {
              const recordSize = JSON.stringify(record).length;
              if (chunk.length && (chunk.length >= 256 || size + recordSize > 45000)) {
                chunks.push(chunk);
                chunk = [];
                size = 0;
              }
              chunk.push(record);
              size += recordSize;
            }
            if (chunk.length || chunks.length === 0) chunks.push(chunk);
            for (let index = 0; index < chunks.length; index += 1) {
              const event = conversationBatch(chunks[index], { reset: reset && index === 0 });
              if (event) await forward(event);
            }
          }

          function messageRecords(infoValue, partsValue, live) {
            const info = objectValue(infoValue);
            const role = stringValue(info.role, 40).toLowerCase();
            const messageID = stringValue(info.id, 500)
              || stringValue(info.messageID, 500)
              || stringValue(info.messageId, 500);
            const text = partsText(partsValue) || transcriptText(info.text) || transcriptText(info.content);
            if (!text || (role !== "user" && role !== "assistant")) return [];
            const timestamp = objectValue(info.time).created || info.createdAt || new Date().toISOString();
            return [{
              kind: role === "user" ? "user_message" : "assistant_message",
              eventID: recordID(`${role}-message`, messageID || stableHashHex(text, 2166136261)),
              timestamp,
              turnID: currentTurnID || undefined,
              text,
              phase: role === "assistant" ? "final" : undefined,
              live,
            }];
          }

          async function forwardConversationSnapshot(key) {
            if (forwardedConversationSnapshotKeys.has(key)) return;
            forwardedConversationSnapshotKeys.add(key);
            conversationSnapshotCounter += 1;
            currentConversationSnapshotID = `${source}:${rootNativeSessionID}:${conversationSnapshotCounter}`;
            let records = [];
            try {
              if (providerClient && providerClient.session && typeof providerClient.session.messages === "function") {
                const response = await providerClient.session.messages({
                  path: { id: rootNativeSessionID },
                  query: launchWorkingDirectory ? { directory: launchWorkingDirectory } : {},
                });
                const messages = Array.isArray(objectValue(response).data)
                  ? objectValue(response).data
                  : (Array.isArray(response) ? response : []);
                for (const message of messages) {
                  const object = objectValue(message);
                  records.push(...messageRecords(object.info || object.message, object.parts, false));
                }
              }
            } catch (error) {
              await appendFailure("conversation_snapshot_exception", "toastty.conversation.batch", errorText(error));
            }
            await forwardConversationRecords(records, true);
          }

          function startConversationTurn(input, output) {
            const outputObject = objectValue(output);
            const inputObject = objectValue(input);
            const info = objectValue(outputObject.message || outputObject.info || inputObject.message || inputObject.info);
            const messageID = stringValue(info.id, 500) || stringValue(inputObject.messageID, 500);
            currentTurnID = messageID || recordID("turn", "");
            promptOpenEmittedForTurn = false;
            const records = [{
              kind: "turn_started",
              eventID: recordID("turn-start", currentTurnID),
              timestamp: new Date().toISOString(),
              turnID: currentTurnID,
              live: true,
            }];
            records.push(...messageRecords(
              { ...info, role: stringValue(info.role, 40) || "user" },
              outputObject.parts || inputObject.parts,
              true
            ));
            enqueueConversation(records);
          }

          function finishConversationTurn(outcome = "completed") {
            if (promptOpenEmittedForTurn) return;
            promptOpenEmittedForTurn = true;
            enqueueConversation([{
              kind: outcome === "completed" ? "prompt_open" : (outcome === "aborted" ? "turn_aborted" : "turn_failed"),
              eventID: recordID("turn-end", currentTurnID || nowMilliseconds()),
              timestamp: new Date().toISOString(),
              turnID: currentTurnID || undefined,
              live: true,
            }]);
          }

          function normalizeProviderEvent(input) {
            const candidate = input && typeof input === "object" && "event" in input ? input.event : input;
            if (!candidate || typeof candidate !== "object") return;
            if (typeof candidate.type !== "string" || !candidate.type) return;
            const properties = candidate.properties && typeof candidate.properties === "object"
              ? candidate.properties
              : {};
            const event = { type: candidate.type, properties };
            if (typeof candidate.id === "string" && candidate.id) event.id = candidate.id;
            return event;
          }

          function sessionIDFrom(value) {
            const object = objectValue(value);
            const direct = stringValue(object.sessionID, nativeSessionIDLimit)
              || stringValue(object.sessionId, nativeSessionIDLimit)
              || stringValue(object.session_id, nativeSessionIDLimit)
              || stringValue(objectValue(object.session).id, nativeSessionIDLimit);
            if (direct) return direct;
            const event = normalizeProviderEvent(value);
            const properties = objectValue(event && event.properties);
            return stringValue(properties.sessionID, nativeSessionIDLimit)
              || stringValue(properties.sessionId, nativeSessionIDLimit)
              || stringValue(properties.session_id, nativeSessionIDLimit)
              || stringValue(objectValue(properties.session).id, nativeSessionIDLimit);
          }

          function claimRootSessionID(input) {
            const observedSessionID = sessionIDFrom(input);
            if (!observedSessionID) return rootNativeSessionID;
            if (!rootSessionIdentityObserved) {
              rootNativeSessionID = observedSessionID;
              rootSessionIdentityObserved = true;
            }
            return rootNativeSessionID;
          }

          function claimRootFromProviderEvent(event) {
            if (rootSessionIdentityObserved || !event || event.type !== "session.created") return;
            const info = objectValue(objectValue(event.properties).info);
            const parentID = stringValue(info.parentID, nativeSessionIDLimit)
              || stringValue(info.parentId, nativeSessionIDLimit);
            if (parentID) return;
            const observedSessionID = stringValue(info.id, nativeSessionIDLimit);
            if (!observedSessionID) return;
            rootNativeSessionID = observedSessionID;
            rootSessionIdentityObserved = true;
          }

          function isRootInput(input) {
            if (!rootNativeSessionID) return false;
            const nativeSessionID = sessionIDFrom(input);
            return !nativeSessionID || nativeSessionID === rootNativeSessionID;
          }

          function providerEventSessionID(event) {
            const properties = objectValue(event && event.properties);
            const info = objectValue(properties.info);
            return stringValue(properties.sessionID, nativeSessionIDLimit)
              || stringValue(properties.sessionId, nativeSessionIDLimit)
              || stringValue(properties.session_id, nativeSessionIDLimit)
              || stringValue(info.sessionID, nativeSessionIDLimit)
              || stringValue(info.sessionId, nativeSessionIDLimit)
              || stringValue(info.session_id, nativeSessionIDLimit)
              || ((event && (event.type === "session.created" || event.type === "session.updated" || event.type === "session.deleted"))
                ? stringValue(info.id, nativeSessionIDLimit)
                : "");
          }

          function normalizedReasoningEffort(value) {
            const effort = stringValue(value, 80).toLowerCase();
            return recognizedReasoningEfforts.has(effort) ? effort : "";
          }

          function executionProfileFrom(value) {
            const info = objectValue(value);
            const model = objectValue(info.model);
            const providerID = stringValue(info.providerID, 100)
              || stringValue(info.providerId, 100)
              || stringValue(model.providerID, 100)
              || stringValue(model.providerId, 100);
            const modelID = stringValue(info.modelID, 160)
              || stringValue(info.modelId, 160)
              || stringValue(model.modelID, 160)
              || stringValue(model.modelId, 160)
              || stringValue(model.id, 160);
            let modelIdentifier = modelID;
            if (providerID && modelID && !modelID.startsWith(`${providerID}/`)) {
              modelIdentifier = stringValue(`${providerID}/${modelID}`, 200);
            }
            const reasoningEffort = normalizedReasoningEffort(info.variant || model.variant);
            return { modelIdentifier, reasoningEffort };
          }

          function executionProfileKey(profile) {
            return [profile.modelIdentifier || "", profile.reasoningEffort || ""].join("|");
          }

          function backgroundActivityEvent(phase, activityID, activity) {
            const properties = {
              phase,
              activityID,
              kind: "subagent",
            };
            if (activity && activity.displayName) properties.displayName = activity.displayName;
            if (activity && activity.profile.modelIdentifier) {
              properties.modelIdentifier = activity.profile.modelIdentifier;
            }
            if (activity && activity.profile.reasoningEffort) {
              properties.reasoningEffort = activity.profile.reasoningEffort;
            }
            return { type: "toastty.background_activity", properties };
          }

          function startOrUpdateChild(info) {
            if (!rootNativeSessionID) return;
            const parentID = stringValue(info.parentID, nativeSessionIDLimit)
              || stringValue(info.parentId, nativeSessionIDLimit);
            if (parentID !== rootNativeSessionID) return;
            const activityID = stringValue(info.id, nativeSessionIDLimit);
            if (!activityID || finishedChildIDs.has(activityID)) return;
            const existing = childActivities.get(activityID);
            const profile = executionProfileFrom(info);
            const mergedProfile = {
              modelIdentifier: profile.modelIdentifier || (existing && existing.profile.modelIdentifier) || "",
              reasoningEffort: profile.reasoningEffort || (existing && existing.profile.reasoningEffort) || "",
            };
            const activity = {
              displayName: stringValue(info.agent, 120) || (existing && existing.displayName) || "Sub-agent",
              profile: mergedProfile,
            };
            const key = [activity.displayName, executionProfileKey(activity.profile)].join("|");
            if (existing && existing.forwardedKey === key) return;
            activity.forwardedKey = key;
            childActivities.set(activityID, activity);
            fire(backgroundActivityEvent("start", activityID, activity));
          }

          function updateChildProfile(info) {
            const activityID = stringValue(info.sessionID, nativeSessionIDLimit)
              || stringValue(info.sessionId, nativeSessionIDLimit)
              || stringValue(info.session_id, nativeSessionIDLimit);
            if (finishedChildIDs.has(activityID)) return;
            const existing = childActivities.get(activityID);
            if (!existing) return;
            const profile = executionProfileFrom(info);
            const mergedProfile = {
              modelIdentifier: profile.modelIdentifier || existing.profile.modelIdentifier || "",
              reasoningEffort: profile.reasoningEffort || existing.profile.reasoningEffort || "",
            };
            const key = [existing.displayName, executionProfileKey(mergedProfile)].join("|");
            if (key === existing.forwardedKey) return;
            const activity = { ...existing, profile: mergedProfile, forwardedKey: key };
            childActivities.set(activityID, activity);
            fire(backgroundActivityEvent("start", activityID, activity));
          }

          function finishChild(activityID) {
            const existing = childActivities.get(activityID);
            if (!existing) return;
            childActivities.delete(activityID);
            finishedChildIDs.add(activityID);
            if (finishedChildIDs.size > finishedChildIDLimit) {
              finishedChildIDs.delete(finishedChildIDs.values().next().value);
            }
            fire(backgroundActivityEvent("finish", activityID));
          }

          function finishAllChildren() {
            for (const activityID of Array.from(childActivities.keys())) finishChild(activityID);
          }

          function isTerminalProviderEvent(event) {
            if (!event) return false;
            if (event.type === "session.idle" || event.type === "session.error" || event.type === "session.deleted") return true;
            if (event.type !== "session.status") return false;
            const statusType = stringValue(objectValue(objectValue(event.properties).status).type, 80);
            return statusType === "idle" || statusType === "error";
          }

          function handleChildProviderEvent(event) {
            if (!event) return;
            const properties = objectValue(event.properties);
            const info = objectValue(properties.info);
            switch (event.type) {
              case "session.created":
              case "session.updated":
                startOrUpdateChild(info);
                return;
              case "message.updated":
                updateChildProfile(info);
                return;
              case "session.status":
              case "session.idle":
              case "session.error":
              case "session.deleted": {
                const activityID = providerEventSessionID(event);
                if (isTerminalProviderEvent(event)) finishChild(activityID);
                return;
              }
              default:
                return;
            }
          }

          function stableHashHex(value, seed) {
            let hash = seed >>> 0;
            for (let index = 0; index < value.length; index += 1) {
              hash ^= value.charCodeAt(index);
              hash = Math.imul(hash, 16777619);
            }
            return (hash >>> 0).toString(16).padStart(8, "0");
          }

          function nativeSessionFilename(nativeSessionID, cwd) {
            const key = `${source}\\0${nativeSessionID}\\0${cwd}`;
            return `${source}-${stableHashHex(key, 2166136261)}${stableHashHex(key, 16777619)}.json`;
          }

          async function writeNativeSessionMarker(event) {
            const fs = await import("node:fs/promises");
            const path = await import("node:path");
            const properties = objectValue(event.properties);
            await fs.mkdir(resumeDirectoryPath, { recursive: true });
            const markerPath = path.join(
              resumeDirectoryPath,
              nativeSessionFilename(properties.nativeSessionID, properties.cwd)
            );
            const marker = {
              source,
              version: 1,
              capturedAt: new Date().toISOString(),
            };
            await fs.writeFile(markerPath, `${JSON.stringify(marker, null, 2)}\\n`, "utf8");
            event.properties = { ...properties, sessionFilePath: markerPath };
            return event;
          }

          function nativeSessionEvent(input) {
            if (!resumeDirectoryPath) return;
            const nativeSessionID = sessionIDFrom(input);
            if (!nativeSessionID) return;
            const cwd = launchWorkingDirectory || envValue("TOASTTY_CWD") || process.cwd();
            const normalizedCWD = stringValue(cwd, 4096);
            if (!normalizedCWD) return;
            return {
              type: "toastty.native_session",
              properties: {
                nativeSessionID,
                cwd: normalizedCWD,
              },
            };
          }

          function toasttyStatus(kind, summary, detail) {
            const properties = { kind, summary };
            const normalizedDetail = stringValue(detail, 240);
            if (normalizedDetail) properties.detail = normalizedDetail;
            return { type: "toastty.status", properties };
          }

          function toasttyFinal(text) {
            const normalizedText = stringValue(text, 240);
            if (!normalizedText) return toasttyStatus("ready", "Ready");
            lastFinalText = normalizedText;
            return { type: "toastty.final", properties: { text: normalizedText } };
          }

          function nowMilliseconds() {
            const milliseconds = typeof Date.now === "function" ? Date.now() : new Date().getTime();
            return Number.isFinite(milliseconds) ? milliseconds : 0;
          }

          function resetTurnState() {
            suppressWorkingUntil = 0;
            lastFinalText = "";
            lastCompletedTextCandidate = "";
            blankWorkingSuppressUntil = 0;
            questionApprovalResolvedUntil = 0;
            mimoTurnClosed = false;
            clearPendingOpenCodeFinal();
          }

          function rememberFinalTextCandidate(input, output) {
            const text = finalTextFrom(input, output);
            if (text) lastCompletedTextCandidate = text;
            return text;
          }

          function clearPendingOpenCodeFinal() {
            if (pendingOpenCodeFinalTimer) {
              clearTimeout(pendingOpenCodeFinalTimer);
              pendingOpenCodeFinalTimer = undefined;
            }
          }

          function scheduleOpenCodeFinal(text) {
            const normalizedText = stringValue(text, 240);
            if (!normalizedText) return;
            clearPendingOpenCodeFinal();
            pendingOpenCodeFinalTimer = setTimeout(() => {
              pendingOpenCodeFinalTimer = undefined;
              flush(toasttyFinal(normalizedText));
            }, openCodeFinalQuietMs);
          }

          function statusKind(event) {
            if (!event || event.type !== "toastty.status") return "";
            return stringValue(objectValue(event.properties).kind, 80);
          }

          function isWorkingStatus(event) {
            return statusKind(event) === "working";
          }

          function workingStatusDetail(event) {
            if (!event || event.type !== "toastty.status") return "";
            return stringValue(objectValue(event.properties).detail, 240);
          }

          function isGenericOpenCodeWorkingStatus(event) {
            const detail = workingStatusDetail(event);
            return !detail || detail === "Writing response";
          }

          function isTerminalStatus(event) {
            if (!event) return false;
            if (event.type === "toastty.final") return true;
            const kind = statusKind(event);
            return kind === "ready" || kind === "idle" || kind === "error";
          }

          function shouldSuppressGenericOpenCodeWorkingAfterTextComplete(event) {
            if (isMiMoCode || !isWorkingStatus(event) || !lastCompletedTextCandidate) return false;
            if (!isGenericOpenCodeWorkingStatus(event)) return false;
            if (pendingOpenCodeFinalTimer) {
              clearPendingOpenCodeFinal();
              lastCompletedTextCandidate = "";
            }
            return true;
          }

          function shouldSuppressGenericMiMoWorkingAfterTurnClosed(event) {
            return isMiMoCode
              && mimoTurnClosed
              && isWorkingStatus(event)
              && isGenericOpenCodeWorkingStatus(event);
          }

          function shouldSuppressBlankWorkingAfterVisibleDetail(event) {
            if (!isWorkingStatus(event) || workingStatusDetail(event)) return false;
            if (!blankWorkingSuppressUntil) return false;
            const now = nowMilliseconds();
            if (!now || now > blankWorkingSuppressUntil) {
              blankWorkingSuppressUntil = 0;
              return false;
            }
            return true;
          }

          function shouldSuppressWorkingAfterTerminal(event) {
            if (!isWorkingStatus(event) || !suppressWorkingUntil) return false;
            const now = nowMilliseconds();
            if (!now) {
              suppressWorkingUntil = 0;
              return false;
            }
            if (now <= suppressWorkingUntil) return true;
            suppressWorkingUntil = 0;
            return false;
          }

          function noteAcceptedEventState(event, options) {
            if (isTerminalStatus(event)) {
              blankWorkingSuppressUntil = 0;
              questionApprovalResolvedUntil = 0;
            }
            if (event.type === "toastty.final") {
              lastForwardedStatusKey = "";
            }
            if (isMiMoCode && options.suppressFollowingWorking && isTerminalStatus(event)) {
              mimoTurnClosed = true;
            }
            if (options.suppressFollowingWorking && isTerminalStatus(event)) {
              suppressWorkingUntil = nowMilliseconds() + terminalWorkingSuppressMs;
            } else if (isWorkingStatus(event)) {
              suppressWorkingUntil = 0;
              const detail = workingStatusDetail(event);
              if (detail) {
                const now = nowMilliseconds();
                blankWorkingSuppressUntil = now ? now + blankWorkingSuppressMs : 0;
              }
              if (!isMiMoCode && (pendingOpenCodeFinalTimer || !isGenericOpenCodeWorkingStatus(event))) {
                clearPendingOpenCodeFinal();
                lastCompletedTextCandidate = "";
              }
              lastFinalText = "";
            }
          }

          function displayToolName(toolName) {
            const raw = stringValue(toolName, 80);
            if (!raw) return "Tool";
            return raw
              .split(/[_-]+/)
              .filter(Boolean)
              .map((component) => component.slice(0, 1).toUpperCase() + component.slice(1))
              .join(" ");
          }

          function isQuestionToolName(toolName) {
            return stringValue(toolName, 80).toLowerCase() === "question";
          }

          function questionApprovalStatus() {
            return toasttyStatus("needs_approval", "Needs approval", permissionDetail({}));
          }

          function questionResolvedStatus() {
            const now = nowMilliseconds();
            questionApprovalResolvedUntil = now ? now + questionApprovalResolvedSuppressMs : 0;
            return toasttyStatus("working", "Working", "Approval resolved");
          }

          function shouldSuppressQuestionApprovalAfterResolution() {
            if (!questionApprovalResolvedUntil) return false;
            const now = nowMilliseconds();
            if (!now || now > questionApprovalResolvedUntil) {
              questionApprovalResolvedUntil = 0;
              return false;
            }
            return true;
          }

          function firstToolName(value) {
            if (typeof value === "string") return stringValue(value, 80);
            const object = objectValue(value);
            return stringValue(object.name, 80)
              || stringValue(object.tool, 80)
              || stringValue(object.id, 80)
              || stringValue(object.callID, 80);
          }

          function commandPreview(metadata) {
            const command = stringValue(metadata.command, 120);
            if (command) return command;
            return stringValue(objectValue(metadata.input).command, 120);
          }

          function permissionDetail(properties) {
            const metadata = objectValue(properties.metadata);
            const description = stringValue(metadata.description, 160);
            if (description) return description;

            const command = commandPreview(metadata);
            if (command) return `Approve ${command}`;

            const metadataTool = stringValue(metadata.tool, 80);
            if (metadataTool) return `Approve ${displayToolName(metadataTool)}`;

            if (Array.isArray(metadata.tools) && metadata.tools.length > 0) {
              if (metadata.tools.length === 1) {
                const tool = firstToolName(metadata.tools[0]);
                if (tool) return `Approve ${displayToolName(tool)}`;
              }
              return `Approve ${metadata.tools.length} tools`;
            }

            const permission = stringValue(properties.permission, 80);
            if (permission) {
              const firstPattern = Array.isArray(properties.patterns)
                ? stringValue(properties.patterns.find((pattern) => stringValue(pattern, 80)), 80)
                : "";
              return firstPattern ? `Approve ${permission} ${firstPattern}` : `Approve ${permission}`;
            }

            return "Agent is waiting for approval";
          }

          function errorDetail(value) {
            if (!value) return "";
            if (typeof value === "string") return stringValue(value, 240);
            const object = objectValue(value);
            return stringValue(object.message, 240)
              || errorDetail(object.data)
              || errorDetail(object.cause)
              || stringValue(object.name, 240);
          }

          function toolNameFromInput(input) {
            const object = objectValue(input);
            return stringValue(object.tool, 80)
              || stringValue(object.name, 80)
              || stringValue(object.id, 80)
              || stringValue(object.callID, 80);
          }

          function toolAfterDetail(input, output) {
            const title = stringValue(objectValue(output).title, 160);
            if (title) return title;
            return `${displayToolName(toolNameFromInput(input))} completed`;
          }

          function messagePartToolName(properties) {
            const part = objectValue(properties.part);
            return stringValue(part.tool, 80)
              || stringValue(part.name, 80)
              || stringValue(properties.tool, 80)
              || stringValue(properties.name, 80);
          }

          function messagePartStateStatus(properties) {
            const part = objectValue(properties.part);
            const state = objectValue(part.state);
            return stringValue(state.status, 80)
              || stringValue(part.status, 80)
              || stringValue(properties.status, 80);
          }

          function isResolvedQuestionPart(properties) {
            switch (messagePartStateStatus(properties).toLowerCase()) {
              case "complete":
              case "completed":
              case "done":
              case "success":
              case "resolved":
              case "accepted":
              case "rejected":
              case "canceled":
              case "cancelled":
              case "error":
              case "failed":
              case "failure":
                return true;
              default:
                return false;
            }
          }

          function messagePartDetail(properties) {
            const part = objectValue(properties.part);
            const partType = stringValue(part.type, 80) || stringValue(properties.type, 80);
            const tool = messagePartToolName(properties);
            if (isQuestionToolName(tool)) return "";
            if (tool || partType === "tool") return `Using ${displayToolName(tool)}`;
            if (partType === "reasoning" || partType === "thinking") return "Reasoning";
            if (partType === "text" || stringValue(part.text, 1) || stringValue(properties.text, 1)) return "Writing response";
            return "";
          }

          function messagePartStatus(properties) {
            const tool = messagePartToolName(properties);
            if (isQuestionToolName(tool)) {
              if (isResolvedQuestionPart(properties)) return questionResolvedStatus();
              if (shouldSuppressQuestionApprovalAfterResolution()) return;
              return questionApprovalStatus();
            }
            const detail = messagePartDetail(properties);
            return detail ? toasttyStatus("working", "Working", detail) : undefined;
          }

          function finalTextFrom(input, output) {
            const inputObject = objectValue(input);
            const outputObject = objectValue(output);
            return stringValue(outputObject.text, 240)
              || stringValue(outputObject.finalText, 240)
              || stringValue(inputObject.finalText, 240)
              || stringValue(inputObject.text, 240);
          }

          function transcriptFromMessageValue(value) {
            const object = objectValue(value);
            const message = objectValue(object.message);
            return partsText(object.parts)
              || partsText(message.parts)
              || transcriptText(object.content)
              || transcriptText(object.text)
              || transcriptText(object.finalText)
              || transcriptText(message.content)
              || transcriptText(message.text);
          }

          function assistantTranscriptFrom(input, output) {
            const inputObject = objectValue(input);
            const outputObject = objectValue(output);
            const direct = transcriptText(outputObject.text)
              || transcriptText(outputObject.finalText)
              || transcriptText(inputObject.finalText);
            if (direct) return direct;

            for (const container of [outputObject, inputObject]) {
              for (const key of ["trajectory", "messages"]) {
                const records = Array.isArray(container[key]) ? container[key] : [];
                for (let index = records.length - 1; index >= 0; index -= 1) {
                  const record = objectValue(records[index]);
                  const info = objectValue(record.info || record.message);
                  const role = stringValue(record.role, 40).toLowerCase()
                    || stringValue(record.type, 40).toLowerCase()
                    || stringValue(info.role, 40).toLowerCase();
                  if (role !== "assistant" && role !== "model") continue;
                  const text = transcriptFromMessageValue(record)
                    || transcriptFromMessageValue(info);
                  if (text) return text;
                }
              }
            }
            return "";
          }

          function enqueueAssistantTranscript(input, output) {
            const transcript = assistantTranscriptFrom(input, output);
            if (!transcript) return "";
            const inputObject = objectValue(input);
            const outputObject = objectValue(output);
            const messageID = stringValue(outputObject.messageID, 500)
              || stringValue(outputObject.messageId, 500)
              || stringValue(inputObject.messageID, 500)
              || stringValue(inputObject.messageId, 500)
              || stableHashHex(transcript, 2166136261);
            enqueueConversation([{
              kind: "assistant_message",
              eventID: recordID("assistant-message", messageID),
              timestamp: new Date().toISOString(),
              turnID: currentTurnID || undefined,
              text: transcript,
              phase: "final",
              live: true,
            }]);
            return transcript;
          }

          function enqueueUserTranscript(input) {
            const object = objectValue(input);
            const message = objectValue(object.message);
            const text = transcriptText(object.query)
              || transcriptText(object.prompt)
              || transcriptText(object.userQuery)
              || transcriptFromMessageValue(message);
            if (!text) return;
            const messageID = stringValue(object.messageID, 500)
              || stringValue(object.messageId, 500)
              || stringValue(message.id, 500)
              || stableHashHex(text, 2166136261);
            enqueueConversation([{
              kind: "user_message",
              eventID: recordID("user-message", messageID),
              timestamp: new Date().toISOString(),
              turnID: currentTurnID || undefined,
              text,
              live: true,
            }]);
          }

          function statusFromProviderEvent(event) {
            if (!event) return;
            const properties = objectValue(event.properties);

            switch (event.type) {
              case "session.status": {
                const status = objectValue(properties.status);
                const statusType = stringValue(status.type, 80);
                if (statusType === "busy") return toasttyStatus("working", "Working", status.message);
                if (statusType === "retry") return toasttyStatus("working", "Retrying", status.message);
                if (statusType === "idle") {
                  if (!isMiMoCode && lastCompletedTextCandidate) {
                    scheduleOpenCodeFinal(lastCompletedTextCandidate);
                    return;
                  }
                  return toasttyStatus("ready", "Ready", lastFinalText);
                }
                return;
              }

              case "session.idle":
                if (!isMiMoCode && lastCompletedTextCandidate) {
                  scheduleOpenCodeFinal(lastCompletedTextCandidate);
                  return;
                }
                return toasttyStatus("ready", "Ready", lastFinalText);

              case "session.error":
                return toasttyStatus("error", "Error", errorDetail(properties.error) || properties.message);

              case "permission.asked":
              case "permission.v2.asked":
                return toasttyStatus("needs_approval", "Needs approval", permissionDetail(properties));

              case "permission.replied":
              case "permission.v2.replied":
                return toasttyStatus("working", "Working", "Approval resolved");

              case "message.part.delta":
              case "message.part.updated": {
                return messagePartStatus(properties);
              }

              default:
                return;
            }
          }

          function errorText(error) {
            if (!error) return "";
            if (typeof error === "string") return error;
            if (error.stack) return String(error.stack);
            if (error.message) return String(error.message);
            return String(error);
          }

          async function appendFailure(reason, eventType, details) {
            try {
              const fs = await import("node:fs/promises");
              const timestamp = new Date().toISOString();
              const socketPath = envValue("TOASTTY_SOCKET_PATH") || "<unset>";
              const sessionID = envValue("TOASTTY_SESSION_ID") || "<unset>";
              const panelID = envValue("TOASTTY_PANEL_ID") || "<unset>";
              const lines = [
                `[${timestamp}] source=${source} reason=${reason} event_type=${eventType || "<unknown>"} socket_path=${socketPath} session_id=${sessionID} panel_id=${panelID}`,
              ];
              const trimmed = String(details || "").slice(0, 4096).trim();
              if (trimmed) {
                for (const line of trimmed.split("\\n")) lines.push(`stderr: ${line}`);
              }
              await fs.appendFile(logPath, `${lines.join("\\n")}\\n`);
            } catch {
              // Telemetry must never break the provider process.
            }
          }

          async function runToasttyCLI(args, payload) {
            if (typeof Bun !== "undefined" && Bun.spawn) {
              const child = Bun.spawn([cliPath, ...args], {
                stdin: "pipe",
                stdout: "ignore",
                stderr: "pipe",
                env: process.env,
              });
              child.stdin.write(payload);
              child.stdin.end();
              const stderr = await new Response(child.stderr).text();
              const exitCode = await child.exited;
              return { exitCode, stderr };
            }

            const childProcess = await import("node:child_process");
            return await new Promise((resolve) => {
              const child = childProcess.spawn(cliPath, args, {
                stdio: ["pipe", "ignore", "pipe"],
                env: process.env,
              });
              let stderr = "";
              child.stderr.on("data", (chunk) => {
                stderr += chunk.toString();
              });
              child.on("error", (error) => {
                resolve({ exitCode: 1, stderr: errorText(error) });
              });
              child.on("close", (code) => {
                resolve({ exitCode: code ?? 1, stderr });
              });
              child.stdin.end(payload);
            });
          }

          async function forward(event) {
            const sessionID = envValue("TOASTTY_SESSION_ID");
            const panelID = envValue("TOASTTY_PANEL_ID");
            const socketPath = envValue("TOASTTY_SOCKET_PATH");
            if (!sessionID || !panelID || !socketPath || !cliPath) {
              await appendFailure("missing_environment", event.type, "");
              return false;
            }

            const args = [
              "--socket-path",
              socketPath,
              "session",
              "ingest-agent-event",
              "--source",
              source,
              "--session",
              sessionID,
              "--panel",
              panelID,
            ];
            const result = await runToasttyCLI(args, JSON.stringify(event));
            if (result.exitCode !== 0) {
              await appendFailure(`exit_code_${result.exitCode}`, event.type, result.stderr);
              return false;
            }
            return true;
          }

          function recordNativeSession(input) {
            if (!isRootInput(input)) return queue;
            const event = nativeSessionEvent(input);
            if (!event) return queue;
            const properties = objectValue(event.properties);
            const key = [
              stringValue(properties.nativeSessionID, nativeSessionIDLimit),
              stringValue(properties.cwd, 4096),
            ].join("|");
            if (forwardedNativeSessionKeys.has(key) || pendingNativeSessionKeys.has(key)) return queue;
            pendingNativeSessionKeys.add(key);
            queue = queue
              .then(async () => {
                const markerEvent = await writeNativeSessionMarker(event);
                const forwarded = await forward(markerEvent);
                if (forwarded) {
                  forwardedNativeSessionKeys.add(key);
                  await forwardConversationSnapshot(key);
                }
              })
              .catch((error) => appendFailure("native_session_exception", event.type, errorText(error)))
              .finally(() => {
                pendingNativeSessionKeys.delete(key);
              });
            return queue;
          }

          function enqueue(event, options = {}) {
            if (!event) return queue;
            if (shouldSuppressWorkingAfterTerminal(event)) return queue;
            if (shouldSuppressGenericOpenCodeWorkingAfterTextComplete(event)) return queue;
            if (shouldSuppressGenericMiMoWorkingAfterTurnClosed(event)) return queue;
            if (shouldSuppressBlankWorkingAfterVisibleDetail(event)) return queue;
            if (!isMiMoCode && isWorkingStatus(event) && !isGenericOpenCodeWorkingStatus(event)) {
              clearPendingOpenCodeFinal();
              lastCompletedTextCandidate = "";
            }
            let statusKey = "";
            let finalText = "";
            if (event.type === "toastty.status") {
              const properties = objectValue(event.properties);
              statusKey = [
                stringValue(properties.kind, 80),
                stringValue(properties.summary, 80),
                stringValue(properties.detail, 240),
              ].join("|");
              if (statusKey === lastForwardedStatusKey || pendingStatusKeys.has(statusKey)) return queue;
              pendingStatusKeys.add(statusKey);
            } else if (event.type === "toastty.final") {
              finalText = stringValue(objectValue(event.properties).text, 240);
              if (finalText && (finalText === lastForwardedFinalText || pendingFinalTexts.has(finalText))) return queue;
              if (finalText) pendingFinalTexts.add(finalText);
            }
            noteAcceptedEventState(event, options);
            queue = queue
              .then(async () => {
                const forwarded = await forward(event);
                if (forwarded && statusKey) lastForwardedStatusKey = statusKey;
                if (forwarded && finalText) lastForwardedFinalText = finalText;
              })
              .catch((error) => appendFailure("forward_exception", event.type, errorText(error)))
              .finally(() => {
                if (statusKey) pendingStatusKeys.delete(statusKey);
                if (finalText) pendingFinalTexts.delete(finalText);
              });
            return queue;
          }

          function fire(event, options) {
            enqueue(event, options);
          }

          function flush(event, options) {
            return enqueue(event, options);
          }

          function hookFailure(hookName, error) {
            queue = queue
              .then(() => appendFailure("hook_exception", hookName, errorText(error)))
              .catch(() => {});
          }

          const hooks = {
            event(input) {
              try {
                const providerEvent = normalizeProviderEvent(input);
                claimRootFromProviderEvent(providerEvent);
                handleChildProviderEvent(providerEvent);
                const eventSessionID = providerEventSessionID(providerEvent);
                const terminalEvent = isTerminalProviderEvent(providerEvent);
                if (!rootNativeSessionID || (eventSessionID && eventSessionID !== rootNativeSessionID)) return;
                if (!eventSessionID && !terminalEvent) return;
                recordNativeSession(input);
                if (terminalEvent) finishAllChildren();
                fire(statusFromProviderEvent(providerEvent));
                if (terminalEvent) {
                  finishConversationTurn(providerEvent.type === "session.error" ? "failed" : "completed");
                }
              } catch (error) {
                hookFailure("event", error);
              }
            },

            "chat.message"(input, output) {
              try {
                claimRootSessionID(input);
                recordNativeSession(input);
                if (isRootInput(input)) startConversationTurn(input, output);
              } catch (error) {
                hookFailure("chat.message", error);
              }
            },

            "permission.ask"(input) {
              try {
                claimRootSessionID(input);
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                fire(toasttyStatus("needs_approval", "Needs approval", permissionDetail(objectValue(input))));
                const properties = objectValue(input);
                const approvalID = stringValue(properties.id, 500)
                  || stringValue(properties.permissionID, 500)
                  || stringValue(properties.permissionId, 500);
                enqueueConversation([{
                  kind: "interaction_presented",
                  eventID: recordID("interaction", approvalID),
                  timestamp: new Date().toISOString(),
                  turnID: currentTurnID || undefined,
                  interactionKind: "permission",
                  providerApprovalID: approvalID || undefined,
                  prompt: permissionDetail(properties),
                  live: true,
                }]);
              } catch (error) {
                hookFailure("permission.ask", error);
              }
            },

            "tool.execute.before"(input) {
              try {
                claimRootSessionID(input);
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                const toolName = toolNameFromInput(input);
                fire(isQuestionToolName(toolName)
                  ? questionApprovalStatus()
                  : toasttyStatus("working", "Working", `Using ${displayToolName(toolName)}`));
                const inputObject = objectValue(input);
                const callID = stringValue(inputObject.callID, 500)
                  || stringValue(inputObject.callId, 500)
                  || recordID("tool-call", "");
                enqueueConversation([{
                  kind: "tool_started",
                  eventID: recordID("tool-start", callID),
                  timestamp: new Date().toISOString(),
                  turnID: currentTurnID || undefined,
                  callID,
                  toolName: toolName || "Tool",
                  detail: commandPreview(inputObject) || undefined,
                  live: true,
                }]);
              } catch (error) {
                hookFailure("tool.execute.before", error);
              }
            },

            "tool.execute.after"(input, output) {
              try {
                claimRootSessionID(input);
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                fire(isQuestionToolName(toolNameFromInput(input))
                  ? questionResolvedStatus()
                  : toasttyStatus("working", "Working", toolAfterDetail(input, output)));
                const inputObject = objectValue(input);
                const outputObject = objectValue(output);
                const callID = stringValue(inputObject.callID, 500)
                  || stringValue(inputObject.callId, 500)
                  || stringValue(outputObject.callID, 500)
                  || stringValue(outputObject.callId, 500);
                if (callID) {
                  enqueueConversation([{
                    kind: "tool_finished",
                    eventID: recordID("tool-finish", callID),
                    timestamp: new Date().toISOString(),
                    turnID: currentTurnID || undefined,
                    callID,
                    toolName: toolNameFromInput(input) || undefined,
                    outcome: outputObject.error ? "failed" : "succeeded",
                    detail: toolAfterDetail(input, output),
                    live: true,
                  }]);
                }
              } catch (error) {
                hookFailure("tool.execute.after", error);
              }
            },

            "experimental.text.complete"(input, output) {
              try {
                claimRootSessionID(input);
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                rememberFinalTextCandidate(input, output);
                enqueueAssistantTranscript(input, output);
                if (!isMiMoCode) return;
              } catch (error) {
                hookFailure("experimental.text.complete", error);
              }
            },
          };

          if (isMiMoCode) {
            hooks["session.pre"] = function () {
              try {
                const input = arguments[0];
                claimRootSessionID(input);
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                resetTurnState();
                currentTurnID = recordID("mimo-turn", "");
                promptOpenEmittedForTurn = false;
                enqueueConversation([{
                  kind: "turn_started",
                  eventID: recordID("turn-start", currentTurnID),
                  timestamp: new Date().toISOString(),
                  turnID: currentTurnID,
                  live: true,
                }]);
                fire(toasttyStatus("working", "Working", "Starting"));
              } catch (error) {
                hookFailure("session.pre", error);
              }
            };

            hooks["session.userQuery.pre"] = function () {
              try {
                const input = arguments[0];
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                resetTurnState();
                enqueueUserTranscript(input);
                fire(toasttyStatus("working", "Working", "Running query"));
              } catch (error) {
                hookFailure("session.userQuery.pre", error);
              }
            };

            hooks["session.userQuery.post"] = function (input, output) {
              try {
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                const detail = errorDetail(objectValue(input).error) || errorDetail(objectValue(output).error);
                if (detail) {
                  finishConversationTurn("failed");
                  return flush(toasttyStatus("error", "Error", detail), { suppressFollowingWorking: true });
                }
                enqueueAssistantTranscript(input, output);
                const text = rememberFinalTextCandidate(input, output);
                if (text) {
                  return flush(toasttyFinal(text), { suppressFollowingWorking: true });
                }
              } catch (error) {
                hookFailure("session.userQuery.post", error);
              }
            };

            hooks["session.post"] = function (input, output) {
              try {
                if (!isRootInput(input)) return;
                recordNativeSession(input);
                finishAllChildren();
                const detail = errorDetail(objectValue(input).error) || errorDetail(objectValue(output).error);
                if (detail) {
                  finishConversationTurn("failed");
                  return flush(toasttyStatus("error", "Error", detail), { suppressFollowingWorking: true });
                }
                enqueueAssistantTranscript(input, output);
                finishConversationTurn(stringValue(objectValue(input).outcome, 40) === "cancelled" ? "aborted" : "completed");
                return flush(toasttyFinal(finalTextFrom(input, output) || lastCompletedTextCandidate), { suppressFollowingWorking: true });
              } catch (error) {
                hookFailure("session.post", error);
              }
            };
          }

          return hooks;
        }
        """
    }

    static func makeTelemetryForwarderScript(
        cliExecutablePath: String,
        source: String,
        telemetryErrorLogURL: URL,
        stderrFallbackURL: URL,
        inputMode: TelemetryInputMode,
        ownerRecordURL: URL? = nil,
        ownerPIDEnvironmentKey: String? = nil
    ) -> String {
        let stderrTemplateURL = stderrFallbackURL.deletingLastPathComponent()
            .appendingPathComponent("telemetry-stderr.XXXXXX", isDirectory: false)
        let respondsToQuestions = source == "claude-hooks"
        let responseFlag = respondsToQuestions ? " --respond-to-questions" : ""
        let stdoutRedirect = respondsToQuestions ? "" : " >/dev/null"
        let cliCommand = "\(shellQuote(cliExecutablePath)) session ingest-agent-event --source \(source)\(responseFlag)"
        let commandInvocationLines: [String]

        switch inputMode {
        case .none:
            commandInvocationLines = [
                "if \(cliCommand)\(stdoutRedirect) 2>\"$stderr_file\"; then",
                "  :",
                "else",
                "  status=$?",
                "  append_telemetry_failure \"$status\"",
                "fi",
            ]

        case .stdinOrFirstArgument:
            commandInvocationLines = [
                "if [ -n \"$1\" ]; then",
                "  printf '%s' \"$1\"",
                "else",
                "  cat",
                "fi | \(cliCommand)\(stdoutRedirect) 2>\"$stderr_file\"",
                "status=$?",
                "if [ \"$status\" -ne 0 ]; then",
                "  append_telemetry_failure \"$status\"",
                "fi",
            ]
        }

        return (
            [
                "#!/bin/sh",
                "umask 077",
            ] + ownerRecordScriptLines(
                ownerRecordURL: ownerRecordURL,
                ownerPIDEnvironmentKey: ownerPIDEnvironmentKey
            ) + [
                "log_file=\(shellQuote(telemetryErrorLogURL.path))",
                "stderr_file=\"$(mktemp \(shellQuote(stderrTemplateURL.path)) 2>/dev/null)\"",
                "if [ -z \"$stderr_file\" ]; then",
                "  stderr_file=\(shellQuote(stderrFallbackURL.path))",
                "fi",
                "rm -f \"$stderr_file\"",
                "",
                "append_telemetry_failure() {",
                "  status=\"$1\"",
                "  timestamp=\"$(date -u +\"%Y-%m-%dT%H:%M:%SZ\" 2>/dev/null || date)\"",
                "  {",
                "    printf '[%s] source=%s exit_code=%s socket_path=%s session_id=%s panel_id=%s\\n' \"$timestamp\" \(shellQuote(source)) \"$status\" \"${TOASTTY_SOCKET_PATH:-<unset>}\" \"${TOASTTY_SESSION_ID:-<unset>}\" \"${TOASTTY_PANEL_ID:-<unset>}\"",
                "    if [ -s \"$stderr_file\" ]; then",
                "      sed 's/^/stderr: /' \"$stderr_file\"",
                "    else",
                "      printf 'stderr: <empty>\\n'",
                "    fi",
                "  } >> \"$log_file\"",
                "}",
                "",
            ] + commandInvocationLines + [
                "rm -f \"$stderr_file\"",
                "exit 0",
            ]
        ).joined(separator: "\n")
    }

    static func ownerRecordScriptLines(
        ownerRecordURL: URL?,
        ownerPIDEnvironmentKey: String?
    ) -> [String] {
        guard let ownerRecordURL else { return [] }
        let ownerPIDExpression = ownerPIDEnvironmentKey.map { "${\($0):-$PPID}" } ?? "$PPID"
        return [
            "owner_file=\(shellQuote(ownerRecordURL.path))",
            "owner_pid=\"\(ownerPIDExpression)\"",
            "case \"$owner_pid\" in",
            "  ''|*[!0-9]*) : ;;",
            "  *)",
            "    owner_tmp=\"$owner_file.tmp.$$\"",
            "    if printf '%s\\n' \"$owner_pid\" > \"$owner_tmp\" 2>/dev/null; then",
            "      chmod 600 \"$owner_tmp\" 2>/dev/null || :",
            "      mv -f \"$owner_tmp\" \"$owner_file\" 2>/dev/null || rm -f \"$owner_tmp\"",
            "    fi",
            "    ;;",
            "esac",
        ]
    }

    static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }

    static func shellQuote(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    static func insertingArguments(
        _ arguments: [String],
        into argv: [String],
        afterIndex: Int
    ) -> [String] {
        guard argv.isEmpty == false else {
            return arguments
        }
        let boundedIndex = min(max(afterIndex, 0), argv.count - 1)
        return Array(argv.prefix(boundedIndex + 1))
            + arguments
            + Array(argv.dropFirst(boundedIndex + 1))
    }

    private struct CodexSkillsPreparation {
        let argv: [String]
        let result: CodexSkillsInjectionResult
    }

    /// Injects `--profile toastty-managed` after the resolved Codex
    /// executable. The profile flag cannot repeat (hard Codex CLI error), so a
    /// caller-supplied profile is a refusal, and the flag only makes sense
    /// against the `CODEX_HOME` whose overlay and plugin cache Toastty
    /// populated, so a caller-replaced home is also a refusal. All refusals
    /// fail open: Codex launches without Toastty skills.
    private static func prepareCodexSkills(
        argv: [String],
        configuration: CodexSkillsLaunchConfiguration?,
        executableIndex: Int?,
        launchEnvironment: [String: String]
    ) -> CodexSkillsPreparation {
        guard let configuration else {
            return CodexSkillsPreparation(
                argv: argv,
                result: .notRequested
            )
        }
        guard let insertionIndex = executableIndex else {
            return CodexSkillsPreparation(
                argv: argv,
                result: .refused(reason: "opaque_or_unsafe_codex_argv")
            )
        }
        guard containsCallerProfileFlag(in: argv, after: insertionIndex) == false else {
            return CodexSkillsPreparation(
                argv: argv,
                result: .refused(reason: "caller_profile_flag")
            )
        }
        guard codexHomeMatchesConfiguration(
            launchEnvironment: launchEnvironment,
            configuration: configuration
        ) else {
            return CodexSkillsPreparation(
                argv: argv,
                result: .refused(reason: "codex_home_replaced")
            )
        }

        return CodexSkillsPreparation(
            argv: insertingArguments(
                ["--profile", CodexSkillsContract.profileName],
                into: argv,
                afterIndex: insertionIndex
            ),
            result: .injected
        )
    }

    static func piLaunchAllowsExtensionInjection(argv: [String], commandIndex: Int) -> Bool {
        let startIndex = min(max(commandIndex + 1, 0), argv.count)
        for argument in argv.dropFirst(startIndex) {
            if argument == "--" {
                return true
            }
            if argument == "--no-extensions" || argument == "-ne" {
                return false
            }
        }
        return true
    }

    /// pi parses argv as one flat left-to-right scan with no end-of-flags
    /// boundary — a literal `--` is an unknown-option hard error Toastty never
    /// inserts — so a caller opt-out counts wherever it sits after the resolved
    /// command. `--no-skills` only suppresses pi's own discovery roots, but
    /// Toastty honors it as an explicit "no injected skills" request, mirroring
    /// the `--no-extensions` precedent.
    static func piLaunchAllowsSkillsInjection(argv: [String], commandIndex: Int) -> Bool {
        let startIndex = min(max(commandIndex + 1, 0), argv.count)
        for argument in argv.dropFirst(startIndex) {
            if argument == "--no-skills" || argument == "-ns" {
                return false
            }
        }
        return true
    }

    static func resolvedPiExtensionPath() -> String? {
        if let path = piExtensionPathProviderForTesting?(),
           normalizedNonEmptyValue(path) != nil {
            return path
        }

        let resourceName = "toastty-pi-extension"
        let resourceExtension = "js"
        let subdirectory = "AgentExtensions"
        let bundles: [Bundle] = [
            .main,
            Bundle(for: AgentLaunchInstrumentationBundleMarker.self),
        ]
        for bundle in bundles {
            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
                return url.path
            }
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: subdirectory
            ) {
                return url.path
            }
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AgentExtensions/\(resourceName).\(resourceExtension)")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL.path
        }

        return nil
    }

    static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private final class AgentLaunchInstrumentationBundleMarker {}

extension AgentLaunchInstrumentation {
    static func safeCodexExecutableIndex(in argv: [String]) -> Int? {
        guard argv.isEmpty == false else { return nil }
        let boundaryIndex = argv.firstIndex(of: "--") ?? argv.endIndex
        let candidates = argv.indices.filter { index in
            guard index < boundaryIndex else { return false }
            let basename = URL(fileURLWithPath: argv[index]).lastPathComponent.lowercased()
            return basename == "codex" || basename == "cdx"
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private static func safeCodexSkillsExecutableIndex(in argv: [String]) -> Int? {
        guard let executableIndex = safeCodexExecutableIndex(in: argv) else { return nil }
        guard executableIndex > 0 else { return executableIndex }

        // These wrappers are the explicit prefix contracts documented and
        // exercised by Toastty. A visible `codex` token inside an arbitrary
        // prefix is not enough evidence that it is the executed subcommand.
        let wrapperBasename = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
        let supportedWrappers: Set<String> = ["agent-safehouse", "run-sandboxed.sh"]
        guard supportedWrappers.contains(wrapperBasename),
              ManagedAgentCommandResolver.inferManagedAgent(
                  commandName: argv[0],
                  argv: argv
              ) == .codex else {
            return nil
        }
        return executableIndex
    }

    private static func safeClaudeSkillsIntegrationExecutableIndex(in argv: [String]) -> Int? {
        guard argv.isEmpty == false else { return nil }
        let boundaryIndex = argv.firstIndex(of: "--") ?? argv.endIndex
        let candidates = argv.indices.filter { index in
            guard index < boundaryIndex else { return false }
            let basename = URL(fileURLWithPath: argv[index]).lastPathComponent.lowercased()
            return basename == "claude" || basename == "cc"
        }
        guard candidates.count == 1, let executableIndex = candidates.first else { return nil }
        guard executableIndex > 0 else { return executableIndex }

        let wrapperBasename = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
        let supportedWrappers: Set<String> = ["agent-safehouse", "run-sandboxed.sh"]
        guard supportedWrappers.contains(wrapperBasename),
              ManagedAgentCommandResolver.inferManagedAgent(
                  commandName: argv[0],
                  argv: argv
              ) == .claude else {
            return nil
        }
        return executableIndex
    }

    private static func safeCursorPluginExecutableIndex(in argv: [String]) -> Int? {
        guard argv.isEmpty == false else { return nil }
        if URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased() == "cursor-agent" {
            return 0
        }
        let boundaryIndex = argv.firstIndex(of: "--") ?? argv.endIndex
        let candidates = argv.indices.filter { index in
            guard index < boundaryIndex else { return false }
            let basename = URL(fileURLWithPath: argv[index]).lastPathComponent.lowercased()
            return basename == "cursor-agent"
        }
        guard candidates.count == 1, let executableIndex = candidates.first else { return nil }
        guard executableIndex > 0 else { return executableIndex }

        let wrapperBasename = URL(fileURLWithPath: argv[0]).lastPathComponent.lowercased()
        let supportedWrappers: Set<String> = ["agent-safehouse", "run-sandboxed.sh"]
        guard supportedWrappers.contains(wrapperBasename),
              ManagedAgentCommandResolver.inferManagedAgent(
                  commandName: argv[0],
                  argv: argv
              ) == .cursor else {
            return nil
        }
        return executableIndex
    }

    /// `--profile` cannot repeat, so any caller-supplied profile flag between
    /// the Codex executable and a `--` terminator refuses injection. Covers
    /// the long form, the `-p` short form, `=`-attached variants, and the
    /// clap attached short form (`-pfoo`). Any other `-p*` token is treated as
    /// a profile flag too: over-matching only skips skills (fail-open), while
    /// under-matching would double the flag and hard-fail the Codex launch.
    private static func containsCallerProfileFlag(
        in argv: [String],
        after executableIndex: Int
    ) -> Bool {
        let boundaryIndex = argv[(executableIndex + 1)...].firstIndex(of: "--") ?? argv.endIndex
        for argument in argv[(executableIndex + 1)..<boundaryIndex] {
            if argument == "--profile"
                || argument.hasPrefix("--profile=")
                || argument.hasPrefix("-p") {
                return true
            }
        }
        return false
    }

    /// `configuration.codexHomePath` is the home the resolver actually
    /// provisioned for this launch (capability hint, request environment, or
    /// the default home). The launch environment is often empty for Codex
    /// (the shell's real `CODEX_HOME` travels in the capability hint), so
    /// only an explicit `CODEX_HOME` here can contradict the provisioned
    /// home and refuse injection.
    private static func codexHomeMatchesConfiguration(
        launchEnvironment: [String: String],
        configuration: CodexSkillsLaunchConfiguration
    ) -> Bool {
        guard let explicitHomePath = normalizedNonEmptyValue(launchEnvironment["CODEX_HOME"]) else {
            return true
        }
        return standardizedFilePath(explicitHomePath)
            == standardizedFilePath(configuration.codexHomePath)
    }

    private static func standardizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func baselineEnvironment(for agent: AgentKind) -> [String: String] {
        guard agent == .codex else {
            return [:]
        }

        return [
            "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT": "1",
        ]
    }

    // Internal test seam for validating Codex config escaping behavior directly.
    static func tomlStringArrayLiteralForTesting(_ values: [String]) -> String {
        CodexConfigTOMLSerializer.tomlStringArrayLiteral(values)
    }

    // Internal test seam for validating TOML basic string escaping directly.
    static func tomlBasicStringLiteralForTesting(_ value: String) -> String {
        CodexConfigTOMLSerializer.tomlBasicStringLiteral(value)
    }
}
