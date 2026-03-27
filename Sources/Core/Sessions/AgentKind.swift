import Foundation

public struct AgentKind: RawRepresentable, Codable, Hashable, Equatable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        guard normalized == normalized.lowercased() else { return nil }

        let leading = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        guard let firstScalar = normalized.unicodeScalars.first,
              leading.contains(firstScalar) else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard normalized.unicodeScalars.dropFirst().allSatisfy(allowed.contains) else { return nil }
        self.rawValue = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let parsed = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid agent ID: \(rawValue)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claude = Self(rawValue: "claude")!
    public static let codex = Self(rawValue: "codex")!

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        default:
            return rawValue
                .split(separator: "-")
                .map { component in
                    component.prefix(1).uppercased() + component.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}

public enum ManagedAgentCommandResolver {
    public static func launchInsertionIndex(for agent: AgentKind, argv: [String]) -> Int {
        let commandBasenames = launchCommandBasenames(for: agent)
        guard commandBasenames.isEmpty == false else {
            return 0
        }

        for (index, argument) in argv.enumerated() {
            if commandBasenames.contains(commandBasename(argument)) {
                return index
            }
        }

        return 0
    }

    public static func inferManagedAgent(commandName: String, argv: [String]) -> AgentKind? {
        let normalizedCommandName = commandBasename(commandName)
        if let exactAgent = exactBuiltInAgent(for: normalizedCommandName) {
            return exactAgent
        }

        return wrappedBuiltInAgent(in: Array(argv.dropFirst()))
    }

    public static func shimCommandNames(for catalog: AgentCatalog) -> Set<String> {
        var commandNames: Set<String> = [AgentKind.codex.rawValue, AgentKind.claude.rawValue]

        for profile in catalog.profiles {
            guard let agent = AgentKind(rawValue: profile.id),
                  isBuiltIn(agent),
                  let executable = profile.argv.first else {
                continue
            }

            let shimCommandName = URL(fileURLWithPath: executable).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard shimCommandName.isEmpty == false else {
                continue
            }

            let wrapsBuiltInAgent = launchInsertionIndex(for: agent, argv: profile.argv) > 0
            guard wrapsBuiltInAgent else {
                continue
            }

            commandNames.insert(shimCommandName)
        }

        return commandNames
    }
}

private extension ManagedAgentCommandResolver {
    static func isBuiltIn(_ agent: AgentKind) -> Bool {
        agent == .codex || agent == .claude
    }

    static func launchCommandBasenames(for agent: AgentKind) -> Set<String> {
        switch agent {
        case .codex:
            return ["codex", "cdx"]
        case .claude:
            return ["claude", "cc"]
        default:
            return [agent.rawValue]
        }
    }

    static func exactBuiltInAgent(for commandBasename: String) -> AgentKind? {
        switch commandBasename {
        case AgentKind.codex.rawValue:
            return .codex
        case AgentKind.claude.rawValue:
            return .claude
        default:
            return nil
        }
    }

    static func wrappedBuiltInAgent(in arguments: [String]) -> AgentKind? {
        var skipNextArgument = false

        for argument in arguments {
            let trimmedArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedArgument.isEmpty == false else {
                continue
            }

            if skipNextArgument {
                skipNextArgument = false
                continue
            }

            if trimmedArgument == "--" {
                return nil
            }

            if trimmedArgument.hasPrefix("--") {
                if trimmedArgument.contains("=") == false {
                    skipNextArgument = true
                }
                continue
            }

            if trimmedArgument.hasPrefix("-") {
                continue
            }

            return wrappedBuiltInAgent(for: commandBasename(trimmedArgument))
        }

        return nil
    }

    static func wrappedBuiltInAgent(for commandBasename: String) -> AgentKind? {
        switch commandBasename {
        case "codex", "cdx":
            return .codex
        case "claude":
            return .claude
        default:
            return nil
        }
    }

    static func commandBasename(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
    }
}
