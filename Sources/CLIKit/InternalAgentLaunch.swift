import CoreState
import Darwin
import Foundation

struct InternalAgentLaunchInvocation: Equatable {
    let sessionID: String
    let agent: AgentKind
    let panelID: UUID
    let windowID: UUID
    let workspaceID: UUID
    let socketPath: String
    let cwd: String?
    let repoRoot: String?
    let childArguments: [String]
}

enum InternalAgentLaunchError: Error, LocalizedError, Equatable {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .runtime(let message):
            return message
        }
    }
}

enum InternalAgentLaunch {
    static let command = ToasttyInternalCommand.agentLaunch

    static func run(arguments: [String], environment: [String: String]) -> Int32 {
        do {
            let invocation = try parse(arguments: arguments)
            let launcher = AgentProcessLauncher(
                invocation: invocation,
                parentEnvironment: environment
            )
            return try launcher.run()
        } catch let error as InternalAgentLaunchError {
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

    static func parse(arguments: [String]) throws -> InternalAgentLaunchInvocation {
        var sessionID: String?
        var agent: AgentKind?
        var panelID: UUID?
        var windowID: UUID?
        var workspaceID: UUID?
        var socketPath: String?
        var cwd: String?
        var repoRoot: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let childArguments = Array(arguments.dropFirst(index + 1))
                guard childArguments.isEmpty == false else {
                    throw InternalAgentLaunchError.usage(
                        "\(command) requires a child command after --"
                    )
                }
                guard let sessionID else {
                    throw InternalAgentLaunchError.usage("--session is required")
                }
                guard let agent else {
                    throw InternalAgentLaunchError.usage("--agent is required")
                }
                guard let panelID else {
                    throw InternalAgentLaunchError.usage("--panel is required")
                }
                guard let windowID else {
                    throw InternalAgentLaunchError.usage("--window is required")
                }
                guard let workspaceID else {
                    throw InternalAgentLaunchError.usage("--workspace is required")
                }
                guard let socketPath, socketPath.isEmpty == false else {
                    throw InternalAgentLaunchError.usage("--socket-path is required")
                }
                return InternalAgentLaunchInvocation(
                    sessionID: sessionID,
                    agent: agent,
                    panelID: panelID,
                    windowID: windowID,
                    workspaceID: workspaceID,
                    socketPath: socketPath,
                    cwd: normalizedOptionalValue(cwd),
                    repoRoot: normalizedOptionalValue(repoRoot),
                    childArguments: childArguments
                )
            }

            guard argument.hasPrefix("--") else {
                throw InternalAgentLaunchError.usage("unexpected positional argument: \(argument)")
            }
            guard index + 1 < arguments.count else {
                throw InternalAgentLaunchError.usage("missing value for \(argument)")
            }

            let value = arguments[index + 1]
            switch argument {
            case "--session":
                sessionID = try normalizedRequiredValue(argument, value: value)
            case "--agent":
                let normalizedValue = try normalizedRequiredValue(argument, value: value)
                guard let parsedAgent = AgentKind(rawValue: normalizedValue) else {
                    throw InternalAgentLaunchError.usage("--agent must be one of: claude, codex")
                }
                agent = parsedAgent
            case "--panel":
                panelID = try parseUUIDFlag(argument, value: value)
            case "--window":
                windowID = try parseUUIDFlag(argument, value: value)
            case "--workspace":
                workspaceID = try parseUUIDFlag(argument, value: value)
            case "--socket-path":
                socketPath = try normalizedRequiredValue(argument, value: value)
            case "--cwd":
                cwd = value
            case "--repo-root":
                repoRoot = value
            default:
                throw InternalAgentLaunchError.usage("unknown option: \(argument)")
            }
            index += 2
        }

        throw InternalAgentLaunchError.usage("\(command) requires -- followed by the child command")
    }

    private static func parseUUIDFlag(_ flag: String, value: String) throws -> UUID {
        let normalizedValue = try normalizedRequiredValue(flag, value: value)
        guard let uuid = UUID(uuidString: normalizedValue) else {
            throw InternalAgentLaunchError.usage("\(flag) must be a UUID")
        }
        return uuid
    }

    private static func normalizedRequiredValue(_ flag: String, value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw InternalAgentLaunchError.usage("\(flag) is required")
        }
        return trimmed
    }

    private static func normalizedOptionalValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private struct AgentProcessLauncher {
    let invocation: InternalAgentLaunchInvocation
    let parentEnvironment: [String: String]

    func run() throws -> Int32 {
        let executableURL = try resolveExecutableURL(for: invocation.childArguments[0], environment: parentEnvironment)

        let childProcess = Process()
        childProcess.executableURL = executableURL
        childProcess.arguments = Array(invocation.childArguments.dropFirst())
        childProcess.environment = childEnvironment(cliPath: resolvedCLIPath())
        childProcess.standardInput = FileHandle.standardInput
        childProcess.standardOutput = FileHandle.standardOutput
        childProcess.standardError = FileHandle.standardError

        do {
            try childProcess.run()
        } catch {
            throw InternalAgentLaunchError.runtime("failed to launch \(invocation.agent.rawValue): \(error.localizedDescription)")
        }

        let signalHandlers = installIgnoredTerminalSignals()
        defer { restoreTerminalSignals(signalHandlers) }

        do {
            try sendEvent(startEventEnvelope())
        } catch {
            childProcess.terminate()
            childProcess.waitUntilExit()
            throw error
        }

        childProcess.waitUntilExit()

        do {
            try sendEvent(stopEventEnvelope(for: childProcess))
        } catch {
            fputs(("warning: failed to record session stop: \(error.localizedDescription)\n").applyingNewline(), stderr)
        }

        switch childProcess.terminationReason {
        case .exit:
            return childProcess.terminationStatus
        case .uncaughtSignal:
            return 128 + childProcess.terminationStatus
        @unknown default:
            return 1
        }
    }

    private func childEnvironment(cliPath: String) -> [String: String] {
        var environment = parentEnvironment
        environment[ToasttyLaunchContextEnvironment.agentKey] = invocation.agent.rawValue
        environment[ToasttyLaunchContextEnvironment.sessionIDKey] = invocation.sessionID
        environment[ToasttyLaunchContextEnvironment.panelIDKey] = invocation.panelID.uuidString
        environment[ToasttyLaunchContextEnvironment.socketPathKey] = invocation.socketPath
        environment[ToasttyLaunchContextEnvironment.cliPathKey] = cliPath
        if let cwd = invocation.cwd {
            environment[ToasttyLaunchContextEnvironment.cwdKey] = cwd
        }
        if let repoRoot = invocation.repoRoot {
            environment[ToasttyLaunchContextEnvironment.repoRootKey] = repoRoot
        }
        return environment
    }

    private func resolvedCLIPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .path
    }

    private func startEventEnvelope() -> AutomationEventEnvelope {
        var payload: [String: AutomationJSONValue] = [
            "agent": .string(invocation.agent.rawValue),
        ]
        if let cwd = invocation.cwd {
            payload["cwd"] = .string(cwd)
        }
        if let repoRoot = invocation.repoRoot {
            payload["repoRoot"] = .string(repoRoot)
        }
        return AutomationEventEnvelope(
            eventType: "session.start",
            sessionID: invocation.sessionID,
            panelID: invocation.panelID.uuidString,
            requestID: UUID().uuidString,
            payload: payload
        )
    }

    private func stopEventEnvelope(for process: Process) -> AutomationEventEnvelope {
        var payload: [String: AutomationJSONValue] = [:]
        if let reason = stopReason(for: process) {
            payload["reason"] = .string(reason)
        }
        return AutomationEventEnvelope(
            eventType: "session.stop",
            sessionID: invocation.sessionID,
            panelID: invocation.panelID.uuidString,
            requestID: UUID().uuidString,
            payload: payload
        )
    }

    private func stopReason(for process: Process) -> String? {
        switch process.terminationReason {
        case .exit:
            guard process.terminationStatus != 0 else { return nil }
            return "exit \(process.terminationStatus)"
        case .uncaughtSignal:
            return "signal \(process.terminationStatus)"
        @unknown default:
            return "unknown"
        }
    }

    private func sendEvent(_ envelope: AutomationEventEnvelope) throws {
        let client = ToasttySocketClient(socketPath: invocation.socketPath)
        let response = try client.send(envelope)
        if response.ok == false {
            let message = response.error?.message ?? "request failed"
            throw InternalAgentLaunchError.runtime(message)
        }
    }

    private func resolveExecutableURL(for executable: String, environment: [String: String]) throws -> URL {
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw InternalAgentLaunchError.runtime("executable not found: \(executable)")
            }
            return url
        }

        let pathValue = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidatePath = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(executable)
                .path
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath)
            }
        }

        throw InternalAgentLaunchError.runtime("executable not found in PATH: \(executable)")
    }

    private func installIgnoredTerminalSignals() -> [(Int32, sig_t?)] {
        [
            (SIGINT, signal(SIGINT, SIG_IGN)),
            (SIGHUP, signal(SIGHUP, SIG_IGN)),
            (SIGQUIT, signal(SIGQUIT, SIG_IGN)),
            (SIGTERM, signal(SIGTERM, SIG_IGN)),
        ]
    }

    private func restoreTerminalSignals(_ handlers: [(Int32, sig_t?)]) {
        for (signalNumber, previousHandler) in handlers {
            _ = signal(signalNumber, previousHandler)
        }
    }
}

private extension String {
    func applyingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }
}
