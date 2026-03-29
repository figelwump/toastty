import CoreState
import Darwin
import Foundation

private enum AgentCommandShim {
    static func run(
        arguments: [String],
        environment: [String: String]
    ) -> Int32 {
        guard let commandName = Invocation.commandName(arguments: arguments) else {
            fputs("toastty-agent-shim: unsupported invocation\n", stderr)
            return 64
        }

        guard let realBinaryPath = resolveRealBinaryPath(
            commandName: commandName,
            environment: environment
        ) else {
            ToasttyLog.warning(
                "Managed agent shim could not resolve the real binary path",
                category: .terminal,
                metadata: invocationLogMetadata(
                    commandName: commandName,
                    environment: environment,
                    additional: ["real_binary_path": "none"]
                )
            )
            fputs("\(commandName): command not found\n", stderr)
            return 127
        }

        ToasttyLog.info(
            "Observed managed agent shim invocation",
            category: .terminal,
            metadata: invocationLogMetadata(
                commandName: commandName,
                environment: environment,
                additional: ["real_binary_path": realBinaryPath]
            )
        )

        guard let invocation = Invocation(arguments: arguments) else {
            ToasttyLog.info(
                "Passing through managed agent shim invocation because agent inference failed",
                category: .terminal,
                metadata: invocationLogMetadata(
                    commandName: commandName,
                    environment: environment,
                    additional: [
                        "real_binary_path": realBinaryPath,
                        "reason": "agent_inference_failed",
                    ]
                )
            )
            return spawnAndWait(
                executablePath: realBinaryPath,
                argv: arguments,
                environment: environment
            )
        }

        let passThroughReasons = passThroughReasons(environment: environment)
        if passThroughReasons.isEmpty == false {
            ToasttyLog.info(
                "Passing through managed agent shim invocation without Toastty session management",
                category: .terminal,
                metadata: invocationLogMetadata(
                    commandName: commandName,
                    environment: environment,
                    additional: [
                        "agent": invocation.agent.rawValue,
                        "real_binary_path": realBinaryPath,
                        "reason": passThroughReasons.joined(separator: ","),
                    ]
                )
            )
            return spawnAndWait(
                executablePath: realBinaryPath,
                argv: invocation.argv,
                environment: environment
            )
        }

        guard let cliPath = normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.cliPathKey]),
              let panelIDValue = normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.panelIDKey]),
              let panelID = UUID(uuidString: panelIDValue) else {
            return spawnAndWait(
                executablePath: realBinaryPath,
                argv: invocation.argv,
                environment: environment
            )
        }

        let cwd = normalizedNonEmpty(environment["PWD"]) ?? FileManager.default.currentDirectoryPath
        guard let plan = prepareManagedLaunchPlan(
            cliPath: cliPath,
            request: ManagedAgentLaunchRequest(
                agent: invocation.agent,
                panelID: panelID,
                argv: invocation.argv,
                cwd: cwd
            ),
            environment: environment
        ) else {
            ToasttyLog.warning(
                "Managed agent shim fell back to unmanaged launch after launch planning failed",
                category: .terminal,
                metadata: invocationLogMetadata(
                    commandName: commandName,
                    environment: environment,
                    additional: [
                        "agent": invocation.agent.rawValue,
                        "panel_id": panelID.uuidString,
                        "cwd": cwd,
                        "real_binary_path": realBinaryPath,
                        "reason": "prepare_managed_launch_failed",
                    ]
                )
            )
            return spawnAndWait(
                executablePath: realBinaryPath,
                argv: invocation.argv,
                environment: environment
            )
        }

        ToasttyLog.info(
            "Prepared managed agent shim launch",
            category: .terminal,
            metadata: invocationLogMetadata(
                commandName: commandName,
                environment: environment,
                additional: [
                    "agent": invocation.agent.rawValue,
                    "panel_id": panelID.uuidString,
                    "session_id": plan.sessionID,
                    "cwd": cwd,
                    "repo_root": plan.environment[ToasttyLaunchContextEnvironment.repoRootKey] ?? "none",
                    "real_binary_path": realBinaryPath,
                ]
            )
        )

        var childEnvironment = environment
        childEnvironment.merge(plan.environment) { _, new in new }
        let exitStatus = spawnAndWait(
            executablePath: realBinaryPath,
            argv: plan.argv,
            environment: childEnvironment
        )
        stopSession(
            cliPath: cliPath,
            sessionID: plan.sessionID,
            environment: childEnvironment,
            reason: exitStatus == 0 ? "process_exit" : "process_exit"
        )
        return exitStatus
    }

    private static func passThroughReasons(environment: [String: String]) -> [String] {
        var reasons: [String] = []
        if environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] == "1" {
            reasons.append("managed_agent_shim_bypass")
        }
        if environment[ToasttyLaunchContextEnvironment.sessionIDKey] != nil {
            reasons.append("session_id_present")
        }
        if normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.panelIDKey]) == nil {
            reasons.append("missing_panel_id")
        }
        if normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.cliPathKey]) == nil {
            reasons.append("missing_cli_path")
        }
        return reasons
    }

    private static func resolveRealBinaryPath(
        commandName: String,
        environment: [String: String]
    ) -> String? {
        let pathComponents = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let excludedDirectoryPaths = Set(
            [
                CommandLine.arguments.first.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().path
                },
                Bundle.main.executableURL?.deletingLastPathComponent().path,
            ]
            .compactMap { canonicalPath(for: $0) }
        )
        let currentExecutablePaths = Set(
            [
                CommandLine.arguments.first,
                Bundle.main.executableURL?.path,
            ]
            .compactMap { canonicalPath(for: $0) }
        )

        for directoryPath in pathComponents where directoryPath.isEmpty == false {
            if let canonicalDirectoryPath = canonicalPath(for: directoryPath),
               excludedDirectoryPaths.contains(canonicalDirectoryPath) {
                continue
            }

            let candidatePath = URL(fileURLWithPath: directoryPath, isDirectory: true)
                .appendingPathComponent(commandName, isDirectory: false)
                .path
            if let canonicalCandidatePath = canonicalPath(for: candidatePath),
               currentExecutablePaths.contains(canonicalCandidatePath) {
                continue
            }
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }

        return nil
    }

    private static func prepareManagedLaunchPlan(
        cliPath: String,
        request: ManagedAgentLaunchRequest,
        environment: [String: String]
    ) -> ManagedAgentLaunchPlan? {
        let arguments = managedLaunchArguments(for: request)
        guard let output = runCLI(cliPath: cliPath, arguments: arguments, environment: environment),
              output.exitCode == 0 else {
            return nil
        }

        return try? JSONDecoder().decode(ManagedAgentLaunchPlan.self, from: output.stdout)
    }

    private static func managedLaunchArguments(for request: ManagedAgentLaunchRequest) -> [String] {
        var arguments = [
            "agent",
            "prepare-managed-launch",
            "--agent",
            request.agent.rawValue,
            "--panel",
            request.panelID.uuidString,
        ]
        if let cwd = normalizedNonEmpty(request.cwd) {
            arguments.append("--cwd")
            arguments.append(cwd)
        }
        for argument in request.argv {
            arguments.append("--arg")
            arguments.append(argument)
        }
        return arguments
    }

    private static func stopSession(
        cliPath: String,
        sessionID: String,
        environment: [String: String],
        reason: String
    ) {
        _ = runCLI(
            cliPath: cliPath,
            arguments: [
                "session",
                "stop",
                "--session",
                sessionID,
                "--reason",
                reason,
            ],
            environment: environment
        )
    }

    private static func runCLI(
        cliPath: String,
        arguments: [String],
        environment: [String: String]
    ) -> CLIOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return CLIOutput(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func spawnAndWait(
        executablePath: String,
        argv: [String],
        environment: [String: String]
    ) -> Int32 {
        let spawnedChildPID = spawnProcess(
            executablePath: executablePath,
            argv: argv,
            environment: environment
        )
        guard spawnedChildPID > 0 else {
            return 1
        }

        let previousSIGINT = Darwin.signal(SIGINT, SIG_IGN)
        let previousSIGQUIT = Darwin.signal(SIGQUIT, SIG_IGN)
        defer {
            _ = Darwin.signal(SIGINT, previousSIGINT)
            _ = Darwin.signal(SIGQUIT, previousSIGQUIT)
        }

        var waitStatus: Int32 = 0
        while waitpid(spawnedChildPID, &waitStatus, 0) < 0 {
            if errno == EINTR {
                continue
            }
            return 1
        }

        if childExitedNormally(waitStatus) {
            return childExitCode(waitStatus)
        }
        if childExitedDueToSignal(waitStatus) {
            return 128 + childTerminatingSignal(waitStatus)
        }
        return 1
    }

    private static func spawnProcess(
        executablePath: String,
        argv: [String],
        environment: [String: String]
    ) -> pid_t {
        var pid = pid_t()
        let status = withCStringArray(argv) { argvPointers in
            withCStringArray(environmentStrings(from: environment)) { envPointers in
                posix_spawn(
                    &pid,
                    executablePath,
                    nil,
                    nil,
                    argvPointers,
                    envPointers
                )
            }
        }
        guard status == 0 else {
            return -1
        }
        return pid
    }

    private static func environmentStrings(from environment: [String: String]) -> [String] {
        environment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
    }

    private static func withCStringArray<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        var pointers = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }

    private static func childExitedNormally(_ status: Int32) -> Bool {
        (status & 0x7f) == 0
    }

    private static func childExitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func childExitedDueToSignal(_ status: Int32) -> Bool {
        let signal = status & 0x7f
        return signal != 0 && signal != 0x7f
    }

    private static func childTerminatingSignal(_ status: Int32) -> Int32 {
        status & 0x7f
    }

    private static func invocationLogMetadata(
        commandName: String,
        environment: [String: String],
        additional: [String: String] = [:]
    ) -> [String: String] {
        let shimDirectory = normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey])
        let path = normalizedNonEmpty(environment["PATH"])

        var metadata: [String: String] = [
            "command_name": commandName,
            "panel_id": normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.panelIDKey]) ?? "none",
            "session_id_present": environment[ToasttyLaunchContextEnvironment.sessionIDKey] == nil ? "false" : "true",
            "cli_path_present": normalizedNonEmpty(environment[ToasttyLaunchContextEnvironment.cliPathKey]) == nil ? "false" : "true",
            "agent_shim_directory": shimDirectory ?? "none",
            "path_starts_with_shim_directory": pathStartsWithDirectory(
                path,
                directoryPath: shimDirectory
            ) ? "true" : "false",
            "path_contains_shim_directory": pathContainsDirectory(
                path,
                directoryPath: shimDirectory
            ) ? "true" : "false",
            "path_sample": pathEntriesSample(path),
            "pwd": normalizedNonEmpty(environment["PWD"]) ?? FileManager.default.currentDirectoryPath,
        ]

        for (key, value) in additional {
            metadata[key] = value
        }
        return metadata
    }

    private static func normalizedPathEntries(_ path: String?) -> [String] {
        guard let path else {
            return []
        }
        return path
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    private static func pathEntriesSample(_ path: String?, limit: Int = 4) -> String {
        let entries = normalizedPathEntries(path)
        guard entries.isEmpty == false else {
            return "none"
        }
        return entries.prefix(limit).joined(separator: " | ")
    }

    private static func pathStartsWithDirectory(_ path: String?, directoryPath: String?) -> Bool {
        guard let directoryPath,
              let firstEntry = normalizedPathEntries(path).first else {
            return false
        }
        return firstEntry == directoryPath
    }

    private static func pathContainsDirectory(_ path: String?, directoryPath: String?) -> Bool {
        guard let directoryPath else {
            return false
        }
        return normalizedPathEntries(path).contains(directoryPath)
    }
}

private struct Invocation {
    let commandName: String
    let agent: AgentKind
    let argv: [String]

    init?(arguments: [String]) {
        guard let commandName = Self.commandName(arguments: arguments),
              let agent = ManagedAgentCommandResolver.inferManagedAgent(
                  commandName: commandName,
                  argv: arguments
              ) else {
            return nil
        }
        self.commandName = commandName
        self.agent = agent
        self.argv = arguments
    }

    static func commandName(arguments: [String]) -> String? {
        guard arguments.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: arguments[0]).lastPathComponent
    }
}

private struct CLIOutput {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}

private func canonicalPath(for path: String?) -> String? {
    guard let path = normalizedNonEmpty(path) else {
        return nil
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

exit(
    AgentCommandShim.run(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
)
