import Foundation

/// What to run for one Codex process that the host talks to as an
/// app-server, and the conversation settings that the same launch gives a
/// terminal session on its command line. Made from the launch plan that a
/// terminal launch types, so the process gets the same configuration,
/// skills, model and working directory.
///
/// `codex app-server` takes configuration values (`-c`) and feature
/// switches, and none of the options of the terminal program. The model, the
/// sandbox and the approval policy go into the request that starts the
/// conversation. An option with no place in either is refused with its
/// name: the session would otherwise run with settings that the profile
/// does not state.
public enum CodexAppServerLaunch {
    public enum LaunchError: Error, Equatable, LocalizedError {
        case emptyCommand
        /// The planned command does not name Codex where Toastty can see it,
        /// such as a shell helper.
        case commandNotFound
        /// The profile's arguments ask for something that a session without
        /// a terminal cannot give.
        case unsupportedArgument(String)

        public var errorDescription: String? {
            switch self {
            case .emptyCommand:
                "The agent profile has no command."
            case .commandNotFound:
                "Toastty cannot find the Codex command in the agent profile's command, so it cannot run Codex without a terminal."
            case .unsupportedArgument(let argument):
                "The agent profile passes \(argument) to Codex. A session that Toastty runs without a terminal cannot use it: "
                    + "it takes configuration values (-c), the model, the sandbox and the approval policy only."
            }
        }
    }

    /// Variables that make Codex bill an API key in place of the plan
    /// sign-in.
    public static let apiKeyKeys: Set<String> = ["OPENAI_API_KEY", "CODEX_API_KEY"]

    /// - Parameters:
    ///   - plannedArguments: the launch plan's `argv`: the profile's command
    ///     with the profile, model and configuration arguments in place, and
    ///     with `resume <ID>` when the plan goes on with a conversation.
    ///   - managedProfile: the name of the profile file that the host adds
    ///     to a terminal launch, and the plugins which that file turns on.
    ///     The app-server reads no profile file, so the plugins are turned
    ///     on with a configuration value. Any other profile is refused.
    ///   - baseEnvironment: the app's own environment.
    ///   - terminalEnvironment: what a terminal of the panel gets on top of
    ///     that: Toastty's socket, CLI and `PATH`.
    ///   - plannedEnvironment: the launch plan's environment.
    public static func make(
        plannedArguments: [String],
        managedProfile: (name: String, pluginSelectors: [String])?,
        baseEnvironment: [String: String],
        terminalEnvironment: [String: String],
        plannedEnvironment: [String: String],
        directory: String
    ) throws -> (launch: AgentProcessLaunch, settings: CodexAppServerSession.ThreadSettings) {
        guard plannedArguments.isEmpty == false else { throw LaunchError.emptyCommand }
        let commandIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .codex, argv: plannedArguments)
        guard ManagedAgentCommandResolver.inferManagedAgent(
            commandName: plannedArguments[commandIndex],
            argv: [plannedArguments[commandIndex]]
        ) == .codex else {
            throw LaunchError.commandNotFound
        }
        // A wrapper before the command, such as `env`, can set a variable
        // for it. That would bring back a key that is removed below.
        for argument in plannedArguments.prefix(commandIndex) {
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if argument.contains("="), apiKeyKeys.contains(name) {
                throw LaunchError.unsupportedArgument("\(name)=…")
            }
        }

        var settings = CodexAppServerSession.ThreadSettings(directory: directory)
        var serverOptions: [String] = []
        let options = Array(plannedArguments.dropFirst(commandIndex + 1))
        var index = 0
        /// The value of an option: the next argument, or the text after `=`.
        func value(of option: String, attached: String?) throws -> String {
            if let attached {
                guard attached.isEmpty == false else { throw LaunchError.unsupportedArgument(option) }
                return attached
            }
            index += 1
            guard index < options.count, options[index].isEmpty == false else {
                throw LaunchError.unsupportedArgument(option)
            }
            return options[index]
        }
        while index < options.count {
            let argument = options[index]
            let name: String
            let attached: String?
            if argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                attached = String(argument[argument.index(after: equals)...])
            } else {
                name = argument
                attached = nil
            }
            switch name {
            case "-c", "--config":
                serverOptions += ["-c", try value(of: name, attached: attached)]
            case "--enable", "--disable":
                serverOptions += [name, try value(of: name, attached: attached)]
            case "--strict-config" where attached == nil:
                serverOptions.append(name)
            case "-m", "--model":
                settings.model = try value(of: name, attached: attached)
            case "-s", "--sandbox":
                settings.sandbox = try value(of: name, attached: attached)
            case "-a", "--ask-for-approval":
                settings.approvalPolicy = try value(of: name, attached: attached)
            case "--dangerously-bypass-approvals-and-sandbox" where attached == nil, "--yolo" where attached == nil:
                settings.approvalPolicy = "never"
                settings.sandbox = "danger-full-access"
            case "-p", "--profile":
                let profile = try value(of: name, attached: attached)
                guard let managedProfile, profile == managedProfile.name else {
                    throw LaunchError.unsupportedArgument("--profile \(profile)")
                }
                if managedProfile.pluginSelectors.isEmpty == false {
                    let entries = managedProfile.pluginSelectors
                        .map { "\(tomlString($0))={enabled=true}" }
                        .joined(separator: ",")
                    serverOptions += ["-c", "plugins={\(entries)}"]
                }
            case "--no-alt-screen" where attached == nil:
                // Only the terminal program has a screen.
                break
            case "resume" where settings.resumeThreadID == nil && index + 1 < options.count
                && options[index + 1].isEmpty == false && options[index + 1].hasPrefix("-") == false:
                // The terminal program's command to go on with a
                // conversation, as a planned resume has it.
                index += 1
                settings.resumeThreadID = options[index]
            default:
                throw LaunchError.unsupportedArgument(argument.hasPrefix("-") ? name : "the argument \"\(argument)\"")
            }
            index += 1
        }

        var environment = baseEnvironment
        environment.merge(terminalEnvironment) { _, new in new }
        environment.merge(plannedEnvironment) { _, new in new }
        for key in apiKeyKeys {
            environment.removeValue(forKey: key)
        }
        // The command is found on PATH, where Toastty's own launcher for
        // agent commands comes first. This launch is already planned.
        environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = "1"
        return (
            AgentProcessLaunch(
                executablePath: "/usr/bin/env",
                arguments: Array(plannedArguments.prefix(commandIndex + 1)) + ["app-server"] + serverOptions,
                environment: environment,
                directory: directory
            ),
            settings
        )
    }

    /// A TOML basic string.
    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
