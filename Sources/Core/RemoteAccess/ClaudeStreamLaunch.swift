import Foundation

/// What to run for one Claude Code process that the host talks to in
/// stream-json: the command, its arguments and its environment. Made from the
/// same launch plan that a terminal launch types, so the process gets the
/// same settings, hooks, skills, model and working directory.
public enum ClaudeStreamLaunch {
    public enum LaunchError: Error, Equatable, LocalizedError {
        case emptyCommand
        /// The profile's arguments ask for a mode that cannot hold the
        /// coordinator's conversation.
        case unsupportedArgument(String)

        public var errorDescription: String? {
            switch self {
            case .emptyCommand:
                "The agent profile has no command."
            case .unsupportedArgument(let argument):
                "The agent profile passes \(argument) to Claude Code. A session that Toastty runs without a terminal cannot use it: "
                    + "it needs the Claude plan sign-in, hooks and skills, and its own input and output format."
            }
        }
    }

    /// The arguments that put Claude Code in print mode with one JSON object
    /// on each line, in both directions. `--replay-user-messages` makes
    /// Claude write each message of the host back when it takes it.
    /// `--permission-prompt-tool stdio` sends each permission request to the
    /// host and waits for the answer.
    public static let streamArguments = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--replay-user-messages",
        "--permission-prompt-tool", "stdio",
    ]

    /// Arguments of a profile that this launch cannot keep. `--bare` reads
    /// no plan sign-in, hooks or skills. The others change the format of
    /// the lines or name a different conversation.
    static let refusedArguments: Set<String> = [
        "--bare", "--safe-mode", "-p", "--print", "--input-format", "--output-format",
        "--permission-prompt-tool", "--permission-prompts", "--no-session-persistence",
        "--resume", "-r", "--continue", "-c", "--session-id", "--bg", "--background",
    ]

    /// Variables that mark a process as started inside another Claude Code
    /// session. The app has them only when a developer started it from one.
    static let nestedSessionKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_CHILD_NOTES_DIR", "CLAUDE_PID",
    ]

    /// Variables that make Claude Code bill an API key. In print mode a key
    /// in the environment wins over the plan sign-in.
    public static let apiKeyKeys: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    /// - Parameters:
    ///   - plannedArguments: the launch plan's `argv`: the profile's command
    ///     with the settings, plugin, model and effort arguments in place.
    ///   - resumeNativeSessionID: Claude's ID of the conversation to go on
    ///     with, or `nil` for a new one. A plan that was made for this
    ///     resume has `--resume` with the ID already.
    ///   - baseEnvironment: the app's own environment.
    ///   - terminalEnvironment: what a terminal of the panel gets on top of
    ///     that: Toastty's socket, CLI and `PATH`.
    ///   - plannedEnvironment: the launch plan's environment.
    public static func make(
        plannedArguments: [String],
        resumeNativeSessionID: String?,
        baseEnvironment: [String: String],
        terminalEnvironment: [String: String],
        plannedEnvironment: [String: String],
        directory: String
    ) throws -> AgentProcessLaunch {
        guard plannedArguments.isEmpty == false else { throw LaunchError.emptyCommand }
        let commandIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .claude, argv: plannedArguments)
        // A wrapper before the command, such as `env`, can set a variable
        // for it. That would bring back a key that is removed below.
        for argument in plannedArguments.prefix(commandIndex) {
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if argument.contains("="), apiKeyKeys.contains(name) {
                throw LaunchError.unsupportedArgument("\(name)=…")
            }
        }
        let options = Array(plannedArguments.dropFirst(commandIndex + 1).prefix { $0 != "--" })
        var planResumes = false
        for (index, option) in options.enumerated() {
            let name = option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? option
            if name == "--resume", let resumeNativeSessionID,
               option == "--resume=\(resumeNativeSessionID)"
                || (option == "--resume" && index + 1 < options.count && options[index + 1] == resumeNativeSessionID) {
                planResumes = true
                continue
            }
            if refusedArguments.contains(name) {
                throw LaunchError.unsupportedArgument(name)
            }
        }
        var arguments = plannedArguments
        var inserted = streamArguments
        if let resumeNativeSessionID, planResumes == false {
            inserted += ["--resume", resumeNativeSessionID]
        }
        arguments.insert(contentsOf: inserted, at: commandIndex + 1)

        var environment = baseEnvironment.filter { key, _ in
            nestedSessionKeys.contains(key) == false && apiKeyKeys.contains(key) == false
        }
        environment.merge(terminalEnvironment) { _, new in new }
        environment.merge(plannedEnvironment) { _, new in new }
        for key in apiKeyKeys {
            environment.removeValue(forKey: key)
        }
        // The command is found on PATH, where Toastty's own launcher for
        // agent commands comes first. This launch is already planned.
        environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = "1"
        return AgentProcessLaunch(
            executablePath: "/usr/bin/env",
            arguments: arguments,
            environment: environment,
            directory: directory
        )
    }
}
