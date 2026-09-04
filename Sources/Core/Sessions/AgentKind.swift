import Foundation
import RemoteProtocol

public extension AgentKind {
    /// Runtimes that take Toastty's staged skills tree additively at launch —
    /// the shipped `skills/<name>/SKILL.md` tree, plus the user snapshot's
    /// tree when one is delivered — without rewriting any user configuration.
    /// Codex is deliberately absent: it receives the same payloads through its
    /// managed profile overlay instead.
    var usesStagedSkillsTree: Bool {
        switch self {
        case .claude, .cursor, .mimocode, .opencode, .pi:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .cursor:
            return "Cursor"
        case .mimocode:
            return "MiMo Code"
        case .opencode:
            return "OpenCode"
        case .pi:
            return "Pi"
        case .processWatch:
            return "Process Watch"
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
        guard protectedCursorCommandNames.contains(normalizedCommandName) == false else {
            return nil
        }
        if let exactAgent = exactBuiltInAgent(for: normalizedCommandName) {
            return exactAgent
        }

        return wrappedBuiltInAgent(in: Array(argv.dropFirst()))
    }

    public static func shimCommandNames(for catalog: AgentCatalog) -> Set<String> {
        var commandNames: Set<String> = [
            AgentKind.codex.rawValue,
            "cdx",
            AgentKind.claude.rawValue,
            "cursor-agent",
            "mimo",
            AgentKind.mimocode.rawValue,
            AgentKind.opencode.rawValue,
            AgentKind.pi.rawValue,
        ]

        for profile in catalog.profiles {
            guard let agent = AgentKind(rawValue: profile.id),
                  isBuiltIn(agent) else {
                continue
            }

            // Cursor also ships a collision-prone generic `agent` alias, while
            // `cursor` belongs to the desktop app. Neither may become a Toastty
            // shim, even when an in-memory catalog bypasses agents.toml validation.
            commandNames.formUnion(
                profile.manualCommandNames.filter {
                    protectedCursorCommandNames.contains(commandBasename($0)) == false
                }
            )

            guard let executable = profile.argv.first else {
                continue
            }
            guard profile.manualCommandNames.isEmpty else {
                continue
            }

            let shimCommandName = URL(fileURLWithPath: executable).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard shimCommandName.isEmpty == false else {
                continue
            }
            guard protectedCursorCommandNames.contains(shimCommandName.lowercased()) == false else {
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
    /// Cursor's generic `agent` alias is collision-prone, while `cursor` is
    /// the separate desktop shell command. Neither identifies Cursor Agent.
    static let protectedCursorCommandNames: Set<String> = ["agent", "cursor"]

    static func isBuiltIn(_ agent: AgentKind) -> Bool {
        agent == .codex
            || agent == .claude
            || agent == .cursor
            || agent == .mimocode
            || agent == .opencode
            || agent == .pi
    }

    static func launchCommandBasenames(for agent: AgentKind) -> Set<String> {
        switch agent {
        case .codex:
            return ["codex", "cdx"]
        case .claude:
            return ["claude", "cc"]
        case .cursor:
            return ["cursor-agent"]
        case .mimocode:
            return ["mimo", "mimocode"]
        case .opencode:
            return ["opencode"]
        case .pi:
            return ["pi"]
        default:
            return [agent.rawValue]
        }
    }

    static func exactBuiltInAgent(for commandBasename: String) -> AgentKind? {
        switch commandBasename {
        case AgentKind.codex.rawValue, "cdx":
            return .codex
        case AgentKind.claude.rawValue:
            return .claude
        case "cursor-agent":
            return .cursor
        case "mimo", AgentKind.mimocode.rawValue:
            return .mimocode
        case AgentKind.opencode.rawValue:
            return .opencode
        case AgentKind.pi.rawValue:
            return .pi
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
        case "cursor-agent":
            return .cursor
        case "mimo", "mimocode":
            return .mimocode
        case "opencode":
            return .opencode
        case "pi":
            return .pi
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
