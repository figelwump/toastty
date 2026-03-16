import CoreState
import Darwin
import Foundation

struct CLIOptions: Equatable {
    var jsonOutput: Bool
    var socketPath: String
}

struct CLIInvocation: Equatable {
    var options: CLIOptions
    var command: CLICommand
}

enum CLICommand: Equatable {
    case notify(title: String, body: String, workspaceID: UUID?, panelID: UUID?)
    case sessionStart(sessionID: String, agent: AgentKind, panelID: UUID, cwd: String?, repoRoot: String?)
    case sessionStatus(sessionID: String, panelID: UUID?, kind: SessionStatusKind, summary: String, detail: String?)
    case sessionUpdateFiles(sessionID: String, panelID: UUID?, files: [String], cwd: String?, repoRoot: String?)
    case sessionIngestAgentEvent(sessionID: String, panelID: UUID?, source: AgentEventSource)
    case sessionStop(sessionID: String, panelID: UUID?, reason: String?)

    func makeEventEnvelope(requestID: String = UUID().uuidString) -> AutomationEventEnvelope {
        switch self {
        case .notify(let title, let body, let workspaceID, let panelID):
            var payload: [String: AutomationJSONValue] = [
                "title": .string(title),
                "body": .string(body),
            ]
            if let workspaceID {
                payload["workspaceID"] = .string(workspaceID.uuidString)
            }
            if let panelID {
                payload["panelID"] = .string(panelID.uuidString)
            }
            return AutomationEventEnvelope(
                eventType: "notification.emit",
                requestID: requestID,
                payload: payload
            )

        case .sessionStart(let sessionID, let agent, let panelID, let cwd, let repoRoot):
            var payload: [String: AutomationJSONValue] = [
                "agent": .string(agent.rawValue),
            ]
            if let cwd {
                payload["cwd"] = .string(cwd)
            }
            if let repoRoot {
                payload["repoRoot"] = .string(repoRoot)
            }
            return AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: panelID.uuidString,
                requestID: requestID,
                payload: payload
            )

        case .sessionStatus(let sessionID, let panelID, let kind, let summary, let detail):
            var payload: [String: AutomationJSONValue] = [
                "kind": .string(kind.rawValue),
                "summary": .string(summary),
            ]
            if let detail {
                payload["detail"] = .string(detail)
            }
            return AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                panelID: panelID?.uuidString,
                requestID: requestID,
                payload: payload
            )

        case .sessionUpdateFiles(let sessionID, let panelID, let files, let cwd, let repoRoot):
            var payload: [String: AutomationJSONValue] = [
                "files": .array(files.map(AutomationJSONValue.string)),
            ]
            if let cwd {
                payload["cwd"] = .string(cwd)
            }
            if let repoRoot {
                payload["repoRoot"] = .string(repoRoot)
            }
            return AutomationEventEnvelope(
                eventType: "session.update_files",
                sessionID: sessionID,
                panelID: panelID?.uuidString,
                requestID: requestID,
                payload: payload
            )

        case .sessionIngestAgentEvent:
            preconditionFailure("session ingest agent events are handled locally")

        case .sessionStop(let sessionID, let panelID, let reason):
            var payload: [String: AutomationJSONValue] = [:]
            if let reason {
                payload["reason"] = .string(reason)
            }
            return AutomationEventEnvelope(
                eventType: "session.stop",
                sessionID: sessionID,
                panelID: panelID?.uuidString,
                requestID: requestID,
                payload: payload
            )
        }
    }

    func successMessage(using response: AutomationResponseEnvelope) -> String {
        switch self {
        case .notify:
            return "notification emitted"
        case .sessionStart(let sessionID, _, _, _, _):
            let resolvedSessionID = response.result?.string("sessionID") ?? sessionID
            return resolvedSessionID
        case .sessionStatus(let sessionID, _, let kind, let summary, _):
            return "updated \(sessionID) to \(kind.rawValue): \(summary)"
        case .sessionUpdateFiles(let sessionID, _, let files, _, _):
            let queuedFiles = response.result?.int("queuedFiles") ?? files.count
            return "queued \(queuedFiles) files for \(sessionID)"
        case .sessionIngestAgentEvent(_, _, let source):
            return "processed \(source.rawValue) event"
        case .sessionStop(let sessionID, _, _):
            return "stopped \(sessionID)"
        }
    }
}

enum ToasttyCLIError: Error, LocalizedError, Equatable {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .runtime(let message):
            return message
        }
    }
}

public enum ToasttyCLI {
    public static func run(arguments: [String], environment: [String: String]) -> Int32 {
        do {
            let invocation = try parse(arguments: arguments, environment: environment)
            switch invocation.command {
            case .sessionIngestAgentEvent(let sessionID, let panelID, let source):
                return try runSessionIngestAgentEvent(
                    options: invocation.options,
                    source: source,
                    sessionID: sessionID,
                    panelID: panelID
                )

            default:
                let client = ToasttySocketClient(socketPath: invocation.options.socketPath)
                let response = try client.send(invocation.command.makeEventEnvelope())

                if invocation.options.jsonOutput {
                    try writeStdout(jsonString(for: response))
                } else if response.ok {
                    try writeStdout(invocation.command.successMessage(using: response))
                } else if let error = response.error {
                    throw ToasttyCLIError.runtime("\(error.code): \(error.message)")
                } else {
                    throw ToasttyCLIError.runtime("request failed")
                }

                return response.ok ? 0 : 1
            }
        } catch let error as ToasttyCLIError {
            fputs((error.localizedDescription + "\n").applyingNewline(), stderr)
            if case .usage = error {
                return 64
            }
            return 1
        } catch {
            fputs((error.localizedDescription + "\n").applyingNewline(), stderr)
            return 1
        }
    }

    static func parse(arguments: [String], environment: [String: String]) throws -> CLIInvocation {
        if arguments.contains("--help") || arguments.contains("-h") {
            throw ToasttyCLIError.usage(usage)
        }

        let (options, remainingArguments) = try parseGlobalOptions(arguments: arguments, environment: environment)
        guard let command = remainingArguments.first else {
            throw ToasttyCLIError.usage(usage)
        }

        switch command {
        case "notify":
            return CLIInvocation(
                options: options,
                command: try parseNotifyCommand(Array(remainingArguments.dropFirst()))
            )

        case "session":
            return CLIInvocation(
                options: options,
                command: try parseSessionCommand(Array(remainingArguments.dropFirst()), environment: environment)
            )

        default:
            throw ToasttyCLIError.usage("unknown command: \(command)\n\n\(usage)")
        }
    }

    static let usage = """
    Usage:
      toastty [--json] [--socket-path <path>] notify <title> <body> [--workspace <id>] [--panel <id>]
      toastty [--json] [--socket-path <path>] session start --agent <id> --panel <id> [--session <id>] [--cwd <path>] [--repo-root <path>]
      toastty [--json] [--socket-path <path>] session status --session <id> [--panel <id>] --kind idle|working|needs_approval|ready|error --summary <text> [--detail <text>]
      toastty [--json] [--socket-path <path>] session update-files --session <id> [--panel <id>] --file <path> [--file <path> ...] [--cwd <path>] [--repo-root <path>]
      toastty [--json] [--socket-path <path>] session ingest-agent-event --source claude-hooks|codex-notify [--session <id>] [--panel <id>]
      toastty [--json] [--socket-path <path>] session stop --session <id> [--panel <id>] [--reason <text>]
    """

    private static func parseGlobalOptions(
        arguments: [String],
        environment: [String: String]
    ) throws -> (CLIOptions, [String]) {
        var jsonOutput = false
        var socketPath = AutomationConfig.resolveSocketPath(environment: environment)
        var remaining: [String] = []

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                jsonOutput = true
                index += 1

            case "--socket-path":
                guard index + 1 < arguments.count else {
                    throw ToasttyCLIError.usage("missing value for --socket-path\n\n\(usage)")
                }
                socketPath = arguments[index + 1]
                index += 2

            default:
                remaining.append(arguments[index])
                index += 1
            }
        }

        return (CLIOptions(jsonOutput: jsonOutput, socketPath: socketPath), remaining)
    }

    private static func parseNotifyCommand(_ arguments: [String]) throws -> CLICommand {
        let parsed = try parseCommandArguments(
            arguments,
            valueOptions: ["--workspace", "--panel"]
        )

        guard parsed.positionals.count == 2 else {
            throw ToasttyCLIError.usage("notify requires <title> and <body>\n\n\(usage)")
        }

        let workspaceID = try parseOptionalUUID(flag: "--workspace", value: parsed.singleValue("--workspace"))
        let panelID = try parseOptionalUUID(flag: "--panel", value: parsed.singleValue("--panel"))
        return .notify(
            title: parsed.positionals[0],
            body: parsed.positionals[1],
            workspaceID: workspaceID,
            panelID: panelID
        )
    }

    private static func parseSessionCommand(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> CLICommand {
        guard let subcommand = arguments.first else {
            throw ToasttyCLIError.usage("session requires a subcommand\n\n\(usage)")
        }

        let remainingArguments = Array(arguments.dropFirst())
        switch subcommand {
        case "start":
            let parsed = try parseCommandArguments(
                remainingArguments,
                valueOptions: ["--agent", "--panel", "--session", "--cwd", "--repo-root"]
            )

            guard parsed.positionals.isEmpty else {
                throw ToasttyCLIError.usage("session start does not accept positional arguments\n\n\(usage)")
            }

            let agentValue = try requireResolvedValue(
                flag: "--agent",
                environmentKey: ToasttyLaunchContextEnvironment.agentKey,
                in: parsed,
                environment: environment
            )
            guard let agent = AgentKind(rawValue: agentValue.value) else {
                throw ToasttyCLIError.usage("\(agentValue.source) must be a lowercase agent ID")
            }
            let panelID = try parseRequiredUUID(
                flag: "--panel",
                environmentKey: ToasttyLaunchContextEnvironment.panelIDKey,
                in: parsed,
                environment: environment
            )
            let sessionID = resolvedValue(
                for: "--session",
                environmentKey: ToasttyLaunchContextEnvironment.sessionIDKey,
                in: parsed,
                environment: environment
            )?.value ?? UUID().uuidString

            return .sessionStart(
                sessionID: sessionID,
                agent: agent,
                panelID: panelID,
                cwd: resolvedValue(
                    for: "--cwd",
                    environmentKey: ToasttyLaunchContextEnvironment.cwdKey,
                    in: parsed,
                    environment: environment
                )?.nonEmptyValue,
                repoRoot: resolvedValue(
                    for: "--repo-root",
                    environmentKey: ToasttyLaunchContextEnvironment.repoRootKey,
                    in: parsed,
                    environment: environment
                )?.nonEmptyValue
            )

        case "status":
            let parsed = try parseCommandArguments(
                remainingArguments,
                valueOptions: ["--session", "--panel", "--kind", "--summary", "--detail"]
            )

            guard parsed.positionals.isEmpty else {
                throw ToasttyCLIError.usage("session status does not accept positional arguments\n\n\(usage)")
            }

            let kindValue = try requireValue("--kind", in: parsed)
            guard let kind = SessionStatusKind(rawValue: kindValue) else {
                throw ToasttyCLIError.usage("kind must be one of: idle, working, needs_approval, ready, error")
            }

            return .sessionStatus(
                sessionID: try requireValue(
                    "--session",
                    environmentKey: ToasttyLaunchContextEnvironment.sessionIDKey,
                    in: parsed,
                    environment: environment
                ),
                panelID: try parseOptionalUUID(
                    flag: "--panel",
                    environmentKey: ToasttyLaunchContextEnvironment.panelIDKey,
                    in: parsed,
                    environment: environment
                ),
                kind: kind,
                summary: try requireValue("--summary", in: parsed),
                detail: parsed.singleValue("--detail")
            )

        case "update-files":
            let parsed = try parseCommandArguments(
                remainingArguments,
                valueOptions: ["--session", "--panel", "--file", "--cwd", "--repo-root"]
            )

            guard parsed.positionals.isEmpty else {
                throw ToasttyCLIError.usage("session update-files does not accept positional arguments\n\n\(usage)")
            }

            let files = parsed.values("--file")
            guard files.isEmpty == false else {
                throw ToasttyCLIError.usage("session update-files requires at least one --file\n\n\(usage)")
            }
            guard files.allSatisfy({ $0.isEmpty == false }) else {
                throw ToasttyCLIError.usage("session update-files does not allow empty --file values\n\n\(usage)")
            }

            return .sessionUpdateFiles(
                sessionID: try requireValue(
                    "--session",
                    environmentKey: ToasttyLaunchContextEnvironment.sessionIDKey,
                    in: parsed,
                    environment: environment
                ),
                panelID: try parseOptionalUUID(
                    flag: "--panel",
                    environmentKey: ToasttyLaunchContextEnvironment.panelIDKey,
                    in: parsed,
                    environment: environment
                ),
                files: files,
                cwd: resolvedValue(
                    for: "--cwd",
                    environmentKey: ToasttyLaunchContextEnvironment.cwdKey,
                    in: parsed,
                    environment: environment
                )?.nonEmptyValue,
                repoRoot: resolvedValue(
                    for: "--repo-root",
                    environmentKey: ToasttyLaunchContextEnvironment.repoRootKey,
                    in: parsed,
                    environment: environment
                )?.nonEmptyValue
            )

        case "ingest-agent-event":
            let parsed = try parseCommandArguments(
                remainingArguments,
                valueOptions: ["--source", "--session", "--panel"]
            )

            guard parsed.positionals.isEmpty else {
                throw ToasttyCLIError.usage("session ingest-agent-event does not accept positional arguments\n\n\(usage)")
            }

            let sourceValue = try requireValue("--source", in: parsed)
            guard let source = AgentEventSource(rawValue: sourceValue) else {
                throw ToasttyCLIError.usage("source must be one of: claude-hooks, codex-notify")
            }

            return .sessionIngestAgentEvent(
                sessionID: try requireValue(
                    "--session",
                    environmentKey: ToasttyLaunchContextEnvironment.sessionIDKey,
                    in: parsed,
                    environment: environment
                ),
                panelID: try parseOptionalUUID(
                    flag: "--panel",
                    environmentKey: ToasttyLaunchContextEnvironment.panelIDKey,
                    in: parsed,
                    environment: environment
                ),
                source: source
            )

        case "stop":
            let parsed = try parseCommandArguments(
                remainingArguments,
                valueOptions: ["--session", "--panel", "--reason"]
            )

            guard parsed.positionals.isEmpty else {
                throw ToasttyCLIError.usage("session stop does not accept positional arguments\n\n\(usage)")
            }

            return .sessionStop(
                sessionID: try requireValue(
                    "--session",
                    environmentKey: ToasttyLaunchContextEnvironment.sessionIDKey,
                    in: parsed,
                    environment: environment
                ),
                panelID: try parseOptionalUUID(
                    flag: "--panel",
                    environmentKey: ToasttyLaunchContextEnvironment.panelIDKey,
                    in: parsed,
                    environment: environment
                ),
                reason: parsed.singleValue("--reason")
            )

        default:
            throw ToasttyCLIError.usage("unknown session subcommand: \(subcommand)\n\n\(usage)")
        }
    }

    private static func parseCommandArguments(
        _ arguments: [String],
        valueOptions: Set<String>
    ) throws -> ParsedCommandArguments {
        var parsed = ParsedCommandArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw ToasttyCLIError.usage("missing value for \(argument)\n\n\(usage)")
                }
                parsed.recordValue(arguments[index + 1], for: argument)
                index += 2
                continue
            }

            if argument.hasPrefix("--") {
                throw ToasttyCLIError.usage("unknown option: \(argument)\n\n\(usage)")
            }

            parsed.positionals.append(argument)
            index += 1
        }

        return parsed
    }

    private static func requireValue(_ flag: String, in parsed: ParsedCommandArguments) throws -> String {
        guard let value = parsed.singleValue(flag), value.isEmpty == false else {
            throw ToasttyCLIError.usage("\(flag) is required\n\n\(usage)")
        }
        return value
    }

    private static func requireValue(
        _ flag: String,
        environmentKey: String,
        in parsed: ParsedCommandArguments,
        environment: [String: String]
    ) throws -> String {
        try requireResolvedValue(
            flag: flag,
            environmentKey: environmentKey,
            in: parsed,
            environment: environment
        ).value
    }

    private static func parseRequiredUUID(flag: String, in parsed: ParsedCommandArguments) throws -> UUID {
        let value = try requireValue(flag, in: parsed)
        guard let uuid = UUID(uuidString: value) else {
            throw ToasttyCLIError.usage("\(flag) must be a UUID")
        }
        return uuid
    }

    private static func parseRequiredUUID(
        flag: String,
        environmentKey: String,
        in parsed: ParsedCommandArguments,
        environment: [String: String]
    ) throws -> UUID {
        let resolved = try requireResolvedValue(
            flag: flag,
            environmentKey: environmentKey,
            in: parsed,
            environment: environment
        )
        guard let uuid = UUID(uuidString: resolved.value) else {
            throw ToasttyCLIError.usage("\(resolved.source) must be a UUID")
        }
        return uuid
    }

    private static func parseOptionalUUID(flag: String, value: String?) throws -> UUID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw ToasttyCLIError.usage("\(flag) must be a UUID")
        }
        return uuid
    }

    private static func parseOptionalUUID(
        flag: String,
        environmentKey: String,
        in parsed: ParsedCommandArguments,
        environment: [String: String]
    ) throws -> UUID? {
        guard let resolved = resolvedValue(
            for: flag,
            environmentKey: environmentKey,
            in: parsed,
            environment: environment
        ) else {
            return nil
        }
        guard let value = resolved.nonEmptyValue else {
            if resolved.source == flag {
                throw ToasttyCLIError.usage("\(flag) must be a UUID")
            }
            return nil
        }
        guard let uuid = UUID(uuidString: value) else {
            throw ToasttyCLIError.usage("\(resolved.source) must be a UUID")
        }
        return uuid
    }

    private static func requireResolvedValue(
        flag: String,
        environmentKey: String,
        in parsed: ParsedCommandArguments,
        environment: [String: String]
    ) throws -> ResolvedArgumentValue {
        guard let resolved = resolvedValue(
            for: flag,
            environmentKey: environmentKey,
            in: parsed,
            environment: environment
        ) else {
            throw ToasttyCLIError.usage("\(flag) is required\n\n\(usage)")
        }
        guard let nonEmptyValue = resolved.nonEmptyValue else {
            throw ToasttyCLIError.usage("\(resolved.source) is required\n\n\(usage)")
        }
        return ResolvedArgumentValue(value: nonEmptyValue, source: resolved.source)
    }

    private static func resolvedValue(
        for flag: String,
        environmentKey: String,
        in parsed: ParsedCommandArguments,
        environment: [String: String]
    ) -> ResolvedArgumentValue? {
        if let explicitValue = parsed.singleValue(flag) {
            return ResolvedArgumentValue(value: explicitValue, source: flag)
        }

        guard let environmentValue = environment[environmentKey] else {
            return nil
        }
        return ResolvedArgumentValue(value: environmentValue, source: environmentKey)
    }

    private static func jsonString(for response: AutomationResponseEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToasttyCLIError.runtime("failed to encode response")
        }
        return string
    }

    private static func writeStdout(_ string: String) throws {
        FileHandle.standardOutput.write((string.applyingNewline()).data(using: .utf8) ?? Data())
    }

    private static func runSessionIngestAgentEvent(
        options: CLIOptions,
        source: AgentEventSource,
        sessionID: String,
        panelID: UUID?
    ) throws -> Int32 {
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        let commands = try AgentEventIngestor.commands(
            for: source,
            sessionID: sessionID,
            panelID: panelID,
            payload: payload
        )

        let client = ToasttySocketClient(socketPath: options.socketPath)
        for command in commands {
            let response = try client.send(command.makeEventEnvelope())
            if response.ok == false {
                if let error = response.error {
                    throw ToasttyCLIError.runtime("\(error.code): \(error.message)")
                }
                throw ToasttyCLIError.runtime("request failed")
            }
        }

        let result = SessionIngestResult(processedCount: commands.count)
        if options.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let string = String(data: try encoder.encode(result), encoding: .utf8) else {
                throw ToasttyCLIError.runtime("failed to encode response")
            }
            try writeStdout(string)
        } else {
            try writeStdout("processed \(result.processedCount) updates")
        }

        return 0
    }
}

private struct SessionIngestResult: Codable, Equatable {
    let processedCount: Int
}

private struct ParsedCommandArguments {
    var positionals: [String] = []
    private var optionValues: [String: [String]] = [:]

    mutating func recordValue(_ value: String, for flag: String) {
        optionValues[flag, default: []].append(value)
    }

    func singleValue(_ flag: String) -> String? {
        optionValues[flag]?.last
    }

    func values(_ flag: String) -> [String] {
        optionValues[flag] ?? []
    }
}

private struct ResolvedArgumentValue {
    let value: String
    let source: String

    var nonEmptyValue: String? {
        value.isEmpty ? nil : value
    }
}

private extension String {
    func applyingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }
}
