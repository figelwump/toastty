import CoreState
import Foundation
import RemoteProtocol

/// Applies action-local provider selections to a configured launch argv while
/// leaving profile defaults untouched when no selection was requested.
enum AgentLaunchArgumentOverrideAdapter {
    /// Structured forks deliberately accept only the small interactive flag
    /// surface below. Unknown commands and positional prompts can change the
    /// meaning of a provider fork, so callers must supply those separately.
    static func applyingConversationOptions(
        forkRecord: ManagedAgentResumeRecord?,
        cwd: String?,
        additionalDirectories: [String],
        to argv: [String],
        agent: AgentKind,
        profileID: String
    ) throws -> [String] {
        guard forkRecord != nil || !additionalDirectories.isEmpty else { return argv }
        guard agent == .codex || agent == .claude else {
            throw AgentLaunchError.launchOverrideUnsupported(
                parameter: forkRecord == nil ? "additionalDirectories" : "forkFromSessionID",
                profileID: profileID
            )
        }
        let editor = try ProviderArgvEditor(argv: argv, agent: agent, profileID: profileID)
        try editor.validateConversationOptions()
        var arguments = additionalDirectories.flatMap { ["--add-dir", $0] }
        if let forkRecord {
            guard let cwd else {
                throw AgentLaunchError.invalidLaunchOverride(parameter: "forkFromSessionID", message: "an explicit cwd is required")
            }
            if agent == .codex {
                arguments = ["fork", forkRecord.nativeSessionID, "-C", cwd] + arguments
            } else {
                // Claude accepts an absolute transcript path, avoiding its
                // current-project session lookup when the child changes cwd.
                arguments = ["--resume", forkRecord.sessionFilePath, "--fork-session", "--system-prompt-snapshot", "off"] + arguments
            }
        }
        return editor.inserting(arguments)
    }

    static let modelSupportedAgents: [AgentKind] = [
        .codex,
        .claude,
        .cursor,
        .opencode,
        .mimocode,
        .pi,
    ]

    static let reasoningEffortSupportedAgents: [AgentKind] = [
        .codex,
        .claude,
        .pi,
    ]

    static func applying(
        model: String?,
        reasoningEffort: String?,
        to configuredArgv: [String],
        agent: AgentKind,
        profileID: String
    ) throws -> [String] {
        guard model != nil || reasoningEffort != nil else {
            return configuredArgv
        }

        if model != nil, modelSupportedAgents.contains(agent) == false {
            throw AgentLaunchError.launchOverrideUnsupported(
                parameter: "model",
                profileID: profileID
            )
        }
        if reasoningEffort != nil, reasoningEffortSupportedAgents.contains(agent) == false {
            throw AgentLaunchError.launchOverrideUnsupported(
                parameter: "reasoningEffort",
                profileID: profileID
            )
        }

        let validatedModel = try validatedValue(model, parameter: "model")
        let validatedReasoningEffort = try validatedValue(
            reasoningEffort,
            parameter: "reasoningEffort"
        )
        var editor = try ProviderArgvEditor(
            argv: configuredArgv,
            agent: agent,
            profileID: profileID
        )

        switch agent {
        case .codex:
            if validatedModel != nil {
                try editor.removeValueFlags(
                    longName: "--model",
                    shortName: "-m",
                    parameter: "model"
                )
                try editor.removeCodexConfigAssignments(
                    key: "model",
                    parameter: "model"
                )
            }
            if validatedReasoningEffort != nil {
                try editor.removeCodexConfigAssignments(
                    key: "model_reasoning_effort",
                    parameter: "reasoningEffort"
                )
            }
            var arguments: [String] = []
            if let validatedModel {
                arguments += ["--model", validatedModel]
            }
            if let validatedReasoningEffort {
                arguments += [
                    "--config",
                    "model_reasoning_effort=\(CodexConfigTOMLSerializer.tomlBasicStringLiteral(validatedReasoningEffort))",
                ]
            }
            return editor.inserting(arguments)

        case .claude:
            if validatedModel != nil {
                try editor.removeValueFlags(
                    longName: "--model",
                    shortName: nil,
                    parameter: "model"
                )
            }
            if validatedReasoningEffort != nil {
                try editor.removeValueFlags(
                    longName: "--effort",
                    shortName: nil,
                    parameter: "reasoningEffort"
                )
            }
            var arguments: [String] = []
            if let validatedModel {
                arguments += ["--model", validatedModel]
            }
            if let validatedReasoningEffort {
                arguments += ["--effort", validatedReasoningEffort]
            }
            return editor.inserting(arguments)

        case .cursor:
            if validatedModel != nil {
                try editor.removeValueFlags(
                    longName: "--model",
                    shortName: nil,
                    parameter: "model"
                )
            }
            return editor.inserting(validatedModel.map { ["--model", $0] } ?? [])

        case .opencode, .mimocode:
            if validatedModel != nil {
                try editor.removeValueFlags(
                    longName: "--model",
                    shortName: "-m",
                    parameter: "model"
                )
            }
            return editor.inserting(validatedModel.map { ["--model", $0] } ?? [])

        case .pi:
            if validatedModel != nil {
                try editor.removeValueFlags(
                    longName: "--model",
                    shortName: nil,
                    parameter: "model"
                )
            }
            if validatedReasoningEffort != nil {
                try editor.removeValueFlags(
                    longName: "--thinking",
                    shortName: nil,
                    parameter: "reasoningEffort"
                )
            }
            var arguments: [String] = []
            if let validatedModel {
                arguments += ["--model", validatedModel]
            }
            if let validatedReasoningEffort {
                arguments += ["--thinking", validatedReasoningEffort]
            }
            return editor.inserting(arguments)

        default:
            // Support checks above reject every requested override for other
            // providers before an editor can reach this branch.
            return configuredArgv
        }
    }

    private static func validatedValue(
        _ value: String?,
        parameter: String
    ) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw AgentLaunchError.invalidLaunchOverride(
                parameter: parameter,
                message: "value must not be blank"
            )
        }
        guard value.utf8.count <= maximumValueUTF8Count else {
            throw AgentLaunchError.invalidLaunchOverride(
                parameter: parameter,
                message: "value exceeds \(maximumValueUTF8Count) UTF-8 bytes"
            )
        }
        guard trimmed.hasPrefix("-") == false else {
            throw AgentLaunchError.invalidLaunchOverride(
                parameter: parameter,
                message: "value must not start with '-'"
            )
        }
        guard value.unicodeScalars.allSatisfy({
            CharacterSet.controlCharacters.contains($0) == false
        }) else {
            throw AgentLaunchError.invalidLaunchOverride(
                parameter: parameter,
                message: "control characters are not supported"
            )
        }
        return value
    }

    private static let maximumValueUTF8Count = 256
}

private struct ProviderArgvEditor {
    private var argv: [String]
    private let agent: AgentKind
    private let profileID: String
    private let executableIndex: Int
    private var providerArgumentsEndIndex: Int

    init(argv: [String], agent: AgentKind, profileID: String) throws {
        self.argv = argv
        self.agent = agent
        self.profileID = profileID

        let boundaryIndex = agent == .pi
            ? argv.endIndex
            : (argv.firstIndex(of: "--") ?? argv.endIndex)
        let executableBasenames = Self.executableBasenames(for: agent)
        let directExecutableIndex = argv.indices.first.flatMap { index in
            executableBasenames.contains(Self.basename(argv[index])) ? index : nil
        }
        let wrapper = argv.first.map(Self.basename)
        let wrappedExecutableIndex: Int? = wrapper.flatMap { wrapper -> Int? in
            guard Self.supportedWrapperBasenames.contains(wrapper) else { return nil }
            return Self.wrappedCommandIndex(argv: argv, boundaryIndex: boundaryIndex)
        }
        guard let executableIndex = directExecutableIndex ?? wrappedExecutableIndex,
              executableBasenames.contains(Self.basename(argv[executableIndex])) else {
            throw AgentLaunchError.unsafeLaunchOverrideArgv(
                profileID: profileID,
                message: "could not resolve an unambiguous \(agent.displayName) executable boundary"
            )
        }
        if executableIndex > 0 {
            guard let wrapper,
                  ManagedAgentCommandResolver.inferManagedAgent(
                      commandName: argv[0],
                      argv: argv
                  ) == agent else {
                throw AgentLaunchError.unsafeLaunchOverrideArgv(
                    profileID: profileID,
                    message: "wrapper '\(wrapper)' does not expose an unambiguous provider command boundary"
                )
            }
        }
        if agent == .pi, argv[(executableIndex + 1)...].contains("--") {
            throw AgentLaunchError.unsafeLaunchOverrideArgv(
                profileID: profileID,
                message: "Pi argv contains an unsupported '--' option boundary"
            )
        }

        self.executableIndex = executableIndex
        self.providerArgumentsEndIndex = boundaryIndex
    }

    mutating func removeValueFlags(
        longName: String,
        shortName: String?,
        parameter: String
    ) throws {
        var removalRanges: [Range<Int>] = []
        var index = executableIndex + 1
        while index < providerArgumentsEndIndex {
            let argument = argv[index]
            if argument == longName || argument == shortName {
                guard index + 1 < providerArgumentsEndIndex,
                      argv[index + 1].hasPrefix("-") == false else {
                    throw unsafeFlagError(argument, parameter: parameter)
                }
                removalRanges.append(index..<(index + 2))
                index += 2
                continue
            }
            if argument.hasPrefix("\(longName)=") {
                guard argument.count > longName.count + 1 else {
                    throw unsafeFlagError(argument, parameter: parameter)
                }
                removalRanges.append(index..<(index + 1))
                index += 1
                continue
            }
            if let shortName, argument.hasPrefix("\(shortName)=") {
                guard argument.count > shortName.count + 1 else {
                    throw unsafeFlagError(argument, parameter: parameter)
                }
                removalRanges.append(index..<(index + 1))
                index += 1
                continue
            }
            if let shortName,
               argument.hasPrefix(shortName),
               argument != shortName {
                throw AgentLaunchError.unsafeLaunchOverrideArgv(
                    profileID: profileID,
                    message: "ambiguous attached \(shortName) argument while replacing \(parameter)"
                )
            }
            index += 1
        }
        remove(removalRanges)
    }

    func validateConversationOptions() throws {
        func unsafe(_ message: String) -> AgentLaunchError {
            .unsafeLaunchOverrideArgv(profileID: profileID, message: message)
        }
        // A wrapper may change cwd or inject provider arguments internally.
        guard executableIndex == 0 else {
            throw unsafe("wrapper '\(Self.basename(argv[0]))' is not supported with structured conversation options")
        }
        guard providerArgumentsEndIndex == argv.endIndex else {
            throw unsafe("an existing '--' argument boundary is not supported with structured conversation options; supply the prompt through initialPrompt")
        }
        let valueFlags: Set<String> = agent == .codex
            ? ["--model", "-m", "--config", "-c", "--sandbox", "-s", "--ask-for-approval", "-a", "--profile", "-p", "--add-dir", "--enable", "--disable"]
            : ["--model", "--effort", "--permission-mode", "--add-dir", "--settings", "--setting-sources", "--allowedTools", "--disallowedTools", "--append-system-prompt", "--system-prompt"]
        let switches: Set<String> = agent == .codex
            ? ["--full-auto", "--approve-for-me", "--strict-config", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--no-alt-screen", "--search"]
            : ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"]
        var index = executableIndex + 1
        while index < argv.endIndex {
            let argument = argv[index]
            if switches.contains(argument) { index += 1; continue }
            if valueFlags.contains(argument) {
                guard index + 1 < argv.endIndex, !argv[index + 1].isEmpty,
                      !argv[index + 1].hasPrefix("-") else {
                    throw unsafe("\(argument) requires a non-empty value that does not start with '-'")
                }
                index += 2
                continue
            }
            let flagName = String(argument.prefix(while: { $0 != "=" }))
            if let equals = argument.firstIndex(of: "="), valueFlags.contains(flagName) {
                if !argument[argument.index(after: equals)...].isEmpty {
                    index += 1
                    continue
                }
                throw unsafe("\(flagName) requires a non-empty value")
            }
            if argument.hasPrefix("-") {
                throw unsafe("\(flagName) is not supported with structured conversation options")
            }
            throw unsafe("positional argument at argv index \(index) is not supported with structured conversation options; supply the prompt through initialPrompt")
        }
    }

    mutating func removeCodexConfigAssignments(
        key: String,
        parameter: String
    ) throws {
        var removalRanges: [Range<Int>] = []
        var index = executableIndex + 1
        while index < providerArgumentsEndIndex {
            let argument = argv[index]
            let assignment: String
            let removalRange: Range<Int>

            if argument == "--config" || argument == "-c" {
                guard index + 1 < providerArgumentsEndIndex,
                      argv[index + 1].hasPrefix("-") == false else {
                    throw unsafeFlagError(argument, parameter: parameter)
                }
                assignment = argv[index + 1]
                removalRange = index..<(index + 2)
                index += 2
            } else if argument.hasPrefix("--config=") {
                assignment = String(argument.dropFirst("--config=".count))
                removalRange = index..<(index + 1)
                index += 1
            } else if argument.hasPrefix("-c=") {
                assignment = String(argument.dropFirst("-c=".count))
                removalRange = index..<(index + 1)
                index += 1
            } else if argument.hasPrefix("-c"), argument != "-c" {
                throw AgentLaunchError.unsafeLaunchOverrideArgv(
                    profileID: profileID,
                    message: "ambiguous attached -c argument while replacing \(parameter)"
                )
            } else {
                index += 1
                continue
            }

            guard let equalsIndex = assignment.firstIndex(of: "=") else {
                throw AgentLaunchError.unsafeLaunchOverrideArgv(
                    profileID: profileID,
                    message: "Codex config argument must use key=value syntax"
                )
            }
            let rawAssignmentKey = assignment[..<equalsIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let assignmentValue = assignment[assignment.index(after: equalsIndex)...]
            guard rawAssignmentKey.isEmpty == false, assignmentValue.isEmpty == false else {
                throw AgentLaunchError.unsafeLaunchOverrideArgv(
                    profileID: profileID,
                    message: "Codex config argument must contain a non-empty key and value"
                )
            }
            let assignmentKey = try normalizedCodexConfigKey(
                rawAssignmentKey,
                parameter: parameter
            )
            if assignmentKey == key {
                removalRanges.append(removalRange)
            }
        }
        remove(removalRanges)
    }

    func inserting(_ arguments: [String]) -> [String] {
        guard arguments.isEmpty == false else { return argv }
        return Array(argv.prefix(executableIndex + 1))
            + arguments
            + Array(argv.dropFirst(executableIndex + 1))
    }

    private mutating func remove(_ ranges: [Range<Int>]) {
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            argv.removeSubrange(range)
            providerArgumentsEndIndex -= range.count
        }
    }

    private func unsafeFlagError(
        _ flag: String,
        parameter: String
    ) -> AgentLaunchError {
        .unsafeLaunchOverrideArgv(
            profileID: profileID,
            message: "\(flag) has no safely parseable value while replacing \(parameter)"
        )
    }

    private func normalizedCodexConfigKey(
        _ rawKey: String,
        parameter: String
    ) throws -> String {
        guard let quote = rawKey.first, quote == "\"" || quote == "'" else {
            let bareKeyCharacters = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
            )
            let bareSegments = rawKey.split(separator: ".", omittingEmptySubsequences: false)
            guard bareSegments.allSatisfy({ segment in
                segment.isEmpty == false
                    && segment.unicodeScalars.allSatisfy(bareKeyCharacters.contains)
            }) else {
                throw unsafeCodexConfigKeyError(rawKey, parameter: parameter)
            }
            return rawKey
        }
        guard rawKey.count >= 2, rawKey.last == quote else {
            throw unsafeCodexConfigKeyError(rawKey, parameter: parameter)
        }

        let innerStart = rawKey.index(after: rawKey.startIndex)
        let innerEnd = rawKey.index(before: rawKey.endIndex)
        let inner = rawKey[innerStart..<innerEnd]
        guard inner.isEmpty == false,
              inner.contains(quote) == false,
              inner.unicodeScalars.allSatisfy({
                  CharacterSet.controlCharacters.contains($0) == false
              }),
              quote != "\"" || inner.contains("\\") == false else {
            throw unsafeCodexConfigKeyError(rawKey, parameter: parameter)
        }
        return String(inner)
    }

    private func unsafeCodexConfigKeyError(
        _ key: String,
        parameter: String
    ) -> AgentLaunchError {
        .unsafeLaunchOverrideArgv(
            profileID: profileID,
            message: "Codex config key '\(key)' is ambiguous while replacing \(parameter)"
        )
    }

    private static func basename(_ value: String) -> String {
        URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }

    private static func executableBasenames(for agent: AgentKind) -> Set<String> {
        switch agent {
        case .codex:
            return ["codex", "cdx"]
        case .claude:
            return ["claude", "cc"]
        case .cursor:
            return ["cursor-agent"]
        case .opencode:
            return ["opencode"]
        case .mimocode:
            return ["mimo", "mimocode"]
        case .pi:
            return ["pi"]
        default:
            return [agent.rawValue]
        }
    }

    private static func wrappedCommandIndex(
        argv: [String],
        boundaryIndex: Int
    ) -> Int? {
        var index = 1
        while index < boundaryIndex {
            let argument = argv[index]
            if wrapperValueFlags.contains(argument) {
                guard index + 1 < boundaryIndex,
                      argv[index + 1].hasPrefix("-") == false else {
                    return nil
                }
                index += 2
                continue
            }
            if argument.hasPrefix("--"),
               let equalsIndex = argument.firstIndex(of: "="),
               equalsIndex > argument.index(argument.startIndex, offsetBy: 2),
               equalsIndex < argument.index(before: argument.endIndex) {
                index += 1
                continue
            }
            guard argument.hasPrefix("-") == false else { return nil }
            return index
        }
        return nil
    }

    private static let supportedWrapperBasenames: Set<String> = [
        "agent-safehouse",
        "run-sandboxed.sh",
    ]

    private static let wrapperValueFlags: Set<String> = [
        "--cwd",
        "--workdir",
    ]
}
