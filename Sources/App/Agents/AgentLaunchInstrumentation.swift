import CoreState
import Foundation

struct PreparedAgentLaunchCommand {
    let argv: [String]
    let environment: [String: String]
    let artifacts: PreparedAgentLaunchArtifacts?
}

struct PreparedAgentLaunchArtifacts {
    let directoryURL: URL
    let codexSessionLogURL: URL?
}

enum AgentLaunchInstrumentationError: LocalizedError {
    case invalidClaudeSettingsArgument
    case unsupportedClaudeSettingsFormat

    var errorDescription: String? {
        switch self {
        case .invalidClaudeSettingsArgument:
            return "Claude launch profile has an invalid --settings argument."
        case .unsupportedClaudeSettingsFormat:
            return "Claude settings must decode to a JSON object."
        }
    }
}

enum AgentLaunchInstrumentation {
    static func prepare(
        agent: AgentKind,
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?,
        fileManager: FileManager
    ) throws -> PreparedAgentLaunchCommand {
        if agent == .claude {
            return try prepareClaudeLaunch(
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            )
        }

        if agent == .codex {
            return try prepareCodexLaunch(
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                fileManager: fileManager
            )
        }

        return PreparedAgentLaunchCommand(argv: argv, environment: [:], artifacts: nil)
    }

    private static func prepareClaudeLaunch(
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?,
        fileManager: FileManager
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectoryURL = try makeArtifactsDirectory(
            prefix: "toastty-claude-launch",
            sessionID: sessionID,
            fileManager: fileManager
        )

        do {
            let hookScriptURL = artifactsDirectoryURL.appendingPathComponent("claude-hook.sh", isDirectory: false)
            let telemetryErrorLogURL = telemetryErrorLogURL(in: artifactsDirectoryURL)
            try writeExecutableScript(
                makeTelemetryForwarderScript(
                    cliExecutablePath: cliExecutablePath,
                    source: "claude-hooks",
                    telemetryErrorLogURL: telemetryErrorLogURL,
                    stderrFallbackURL: artifactsDirectoryURL.appendingPathComponent("claude-hook.stderr", isDirectory: false),
                    inputMode: .none
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
            try writeJSONObject(mergedSettings, to: settingsURL)

            return PreparedAgentLaunchCommand(
                argv: insertingArguments(
                    ["--settings", settingsURL.path],
                    into: existingSettings.argvWithoutSettings
                ),
                environment: [:],
                artifacts: PreparedAgentLaunchArtifacts(
                    directoryURL: artifactsDirectoryURL,
                    codexSessionLogURL: nil
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
        fileManager: FileManager
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectoryURL = try makeArtifactsDirectory(
            prefix: "toastty-codex-launch",
            sessionID: sessionID,
            fileManager: fileManager
        )

        do {
            let notifyScriptURL = artifactsDirectoryURL.appendingPathComponent("codex-notify.sh", isDirectory: false)
            let telemetryErrorLogURL = telemetryErrorLogURL(in: artifactsDirectoryURL)
            try writeExecutableScript(
                makeTelemetryForwarderScript(
                    cliExecutablePath: cliExecutablePath,
                    source: "codex-notify",
                    telemetryErrorLogURL: telemetryErrorLogURL,
                    stderrFallbackURL: artifactsDirectoryURL.appendingPathComponent("codex-notify.stderr", isDirectory: false),
                    inputMode: .stdinOrFirstArgument
                ),
                to: notifyScriptURL,
                fileManager: fileManager
            )

            let logURL = artifactsDirectoryURL.appendingPathComponent("codex-session.jsonl", isDirectory: false)
            let notifyArray = tomlStringArrayLiteral(["/bin/sh", notifyScriptURL.path])

            return PreparedAgentLaunchCommand(
                argv: insertingArguments(
                    ["-c", "notify=\(notifyArray)"],
                    into: argv
                ),
                environment: [
                    "CODEX_TUI_RECORD_SESSION": "1",
                    "CODEX_TUI_SESSION_LOG_PATH": logURL.path,
                ],
                artifacts: PreparedAgentLaunchArtifacts(
                    directoryURL: artifactsDirectoryURL,
                    codexSessionLogURL: logURL
                )
            )
        } catch {
            try? fileManager.removeItem(at: artifactsDirectoryURL)
            throw error
        }
    }
}

private extension AgentLaunchInstrumentation {
    enum TelemetryInputMode {
        case none
        case stdinOrFirstArgument
    }

    struct ResolvedClaudeSettings {
        let argvWithoutSettings: [String]
        let baseSettings: [String: Any]
    }

    static func makeArtifactsDirectory(
        prefix: String,
        sessionID: String,
        fileManager: FileManager
    ) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(sessionID)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

        var hooks = mergedSettings["hooks"] as? [String: Any] ?? [:]
        appendClaudeHookEntry(commandHook, to: "UserPromptSubmit", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "Stop", in: &hooks)
        appendClaudeHookEntry(wildcardCommandHook, to: "PostToolUse", in: &hooks)
        appendClaudeHookEntry(wildcardCommandHook, to: "PostToolUseFailure", in: &hooks)
        appendClaudeHookEntry(wildcardCommandHook, to: "PermissionRequest", in: &hooks)
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
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func telemetryErrorLogURL(in artifactsDirectoryURL: URL) -> URL {
        artifactsDirectoryURL.appendingPathComponent("telemetry-failures.log", isDirectory: false)
    }

    static func makeTelemetryForwarderScript(
        cliExecutablePath: String,
        source: String,
        telemetryErrorLogURL: URL,
        stderrFallbackURL: URL,
        inputMode: TelemetryInputMode
    ) -> String {
        let stderrTemplateURL = stderrFallbackURL.deletingLastPathComponent()
            .appendingPathComponent("telemetry-stderr.XXXXXX", isDirectory: false)
        let cliCommand = "\(shellQuote(cliExecutablePath)) session ingest-agent-event --source \(source)"
        let commandInvocationLines: [String]

        switch inputMode {
        case .none:
            commandInvocationLines = [
                "if \(cliCommand) >/dev/null 2>\"$stderr_file\"; then",
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
                "fi | \(cliCommand) >/dev/null 2>\"$stderr_file\"",
                "status=$?",
                "if [ \"$status\" -ne 0 ]; then",
                "  append_telemetry_failure \"$status\"",
                "fi",
            ]
        }

        return (
            [
                "#!/bin/sh",
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

    static func tomlStringArrayLiteral(_ values: [String]) -> String {
        "[\(values.map(tomlBasicStringLiteral(_:)).joined(separator: ","))]"
    }

    static func tomlBasicStringLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                escaped.append("\\\\")
            case "\"":
                escaped.append("\\\"")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped.append(String(format: "\\u%04x", Int(scalar.value)))
                } else {
                    escaped.append(String(scalar))
                }
            }
        }

        return "\"\(escaped)\""
    }

    static func shellQuote(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    static func insertingArguments(_ arguments: [String], into argv: [String]) -> [String] {
        guard let executable = argv.first else {
            return arguments
        }
        return [executable] + arguments + Array(argv.dropFirst())
    }

    static func normalizedNonEmptyValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

extension AgentLaunchInstrumentation {
    // Internal test seam for validating Codex config escaping behavior directly.
    static func tomlStringArrayLiteralForTesting(_ values: [String]) -> String {
        tomlStringArrayLiteral(values)
    }

    // Internal test seam for validating TOML basic string escaping directly.
    static func tomlBasicStringLiteralForTesting(_ value: String) -> String {
        tomlBasicStringLiteral(value)
    }
}
