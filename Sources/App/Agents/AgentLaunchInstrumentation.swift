import CoreState
import Foundation

struct PreparedAgentLaunchCommand {
    let argv: [String]
    let environment: [String: String]
    let artifacts: PreparedAgentLaunchArtifacts?
}

enum CodexStatusTrackingSource: Equatable {
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
    let directoryURL: URL
    let codexSessionLogURL: URL?
    let cleanupPolicy: LaunchArtifactsCleanupPolicy
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

    static func prepare(
        agent: AgentKind,
        argv: [String],
        cliExecutablePath: String,
        sessionID: String,
        workingDirectory: String?,
        fileManager: FileManager,
        launchEnvironment: [String: String] = [:],
        codexStatusTrackingSource: CodexStatusTrackingSource = .sessionLogFallback(reason: "default")
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
                fileManager: fileManager,
                statusTrackingSource: codexStatusTrackingSource
            )
        }

        if agent == .opencode {
            return try prepareOpenCodeFamilyLaunch(
                runtime: .opencode,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                fileManager: fileManager,
                launchEnvironment: launchEnvironment
            )
        }

        if agent == .mimocode {
            return try prepareOpenCodeFamilyLaunch(
                runtime: .mimocode,
                argv: argv,
                cliExecutablePath: cliExecutablePath,
                sessionID: sessionID,
                fileManager: fileManager,
                launchEnvironment: launchEnvironment
            )
        }

        if agent == .pi {
            return try preparePiLaunch(argv: argv, sessionID: sessionID, fileManager: fileManager)
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
                    inputMode: .stdinOrFirstArgument
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
            let insertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(
                for: .claude,
                argv: existingSettings.argvWithoutSettings
            )

            return PreparedAgentLaunchCommand(
                argv: insertingArguments(
                    ["--settings", settingsURL.path],
                    into: existingSettings.argvWithoutSettings,
                    afterIndex: insertionIndex
                ),
                environment: [:],
                artifacts: PreparedAgentLaunchArtifacts(
                    directoryURL: artifactsDirectoryURL,
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
        statusTrackingSource: CodexStatusTrackingSource
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectoryURL = try makeArtifactsDirectory(
            prefix: "toastty-codex-launch",
            sessionID: sessionID,
            fileManager: fileManager
        )

        do {
            let logURL = artifactsDirectoryURL.appendingPathComponent("codex-session.jsonl", isDirectory: false)
            var environment = baselineEnvironment(for: .codex)
            environment["CODEX_TUI_RECORD_SESSION"] = "1"
            environment["CODEX_TUI_SESSION_LOG_PATH"] = logURL.path
            let preparedArgv: [String]
            if statusTrackingSource == .hooks {
                preparedArgv = argv
            } else {
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
                let notifyArray = tomlStringArrayLiteral(["/bin/sh", notifyScriptURL.path])
                let insertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .codex, argv: argv)
                preparedArgv = insertingArguments(
                    ["-c", "notify=\(notifyArray)"],
                    into: argv,
                    afterIndex: insertionIndex
                )
            }

            return PreparedAgentLaunchCommand(
                argv: preparedArgv,
                environment: environment,
                artifacts: PreparedAgentLaunchArtifacts(
                    directoryURL: artifactsDirectoryURL,
                    codexSessionLogURL: logURL,
                    cleanupPolicy: .deleteImmediately
                )
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
        fileManager: FileManager,
        launchEnvironment: [String: String]
    ) throws -> PreparedAgentLaunchCommand {
        if normalizedNonEmptyValue(launchEnvironment[runtime.configContentEnvironmentKey]) != nil {
            throw AgentLaunchInstrumentationError.agentConfigContentEnvironmentAlreadySet(
                agent: runtime.agent,
                key: runtime.configContentEnvironmentKey
            )
        }

        let artifactsDirectoryURL = try makeArtifactsDirectory(
            prefix: runtime.artifactsDirectoryPrefix,
            sessionID: sessionID,
            fileManager: fileManager
        )

        do {
            let pluginURL = artifactsDirectoryURL.appendingPathComponent(runtime.pluginFilename, isDirectory: false)
            let telemetryErrorLogURL = telemetryErrorLogURL(in: artifactsDirectoryURL)
            try Data(
                makeOpenCodeFamilyStatusPlugin(
                    cliExecutablePath: cliExecutablePath,
                    source: runtime.eventSource,
                    telemetryErrorLogURL: telemetryErrorLogURL
                ).appending("\n").utf8
            ).write(to: pluginURL, options: .atomic)

            let configContent: [String: Any] = [
                "plugin": [
                    pluginURL.absoluteURL.standardizedFileURL.absoluteString,
                ],
            ]
            let configData = try JSONSerialization.data(withJSONObject: configContent, options: [.sortedKeys])
            let configString = String(decoding: configData, as: UTF8.self)

            return PreparedAgentLaunchCommand(
                argv: argv,
                environment: [
                    runtime.configContentEnvironmentKey: configString,
                ],
                artifacts: PreparedAgentLaunchArtifacts(
                    directoryURL: artifactsDirectoryURL,
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
        fileManager: FileManager
    ) throws -> PreparedAgentLaunchCommand {
        let artifactsDirectoryURL = try makeArtifactsDirectory(
            prefix: "toastty-pi-launch",
            sessionID: sessionID,
            fileManager: fileManager
        )

        let telemetryLogURL = artifactsDirectoryURL.appendingPathComponent("pi-telemetry.jsonl", isDirectory: false)
        let environment = [
            "TOASTTY_PI_TELEMETRY_LOG_PATH": telemetryLogURL.path,
        ]

        let insertionIndex = ManagedAgentCommandResolver.launchInsertionIndex(for: .pi, argv: argv)
        guard piLaunchAllowsExtensionInjection(argv: argv, commandIndex: insertionIndex) else {
            return PreparedAgentLaunchCommand(
                argv: argv,
                environment: environment,
                artifacts: PreparedAgentLaunchArtifacts(
                    directoryURL: artifactsDirectoryURL,
                    codexSessionLogURL: nil,
                    cleanupPolicy: .deleteImmediately
                )
            )
        }

        guard let extensionPath = resolvedPiExtensionPath() else {
            try? fileManager.removeItem(at: artifactsDirectoryURL)
            throw AgentLaunchInstrumentationError.missingPiExtensionResource
        }

        return PreparedAgentLaunchCommand(
            argv: insertingArguments(
                ["--extension", extensionPath],
                into: argv,
                afterIndex: insertionIndex
            ),
            environment: environment,
            artifacts: PreparedAgentLaunchArtifacts(
                directoryURL: artifactsDirectoryURL,
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
        appendClaudeHookEntry(commandHook, to: "SessionStart", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "UserPromptSubmit", in: &hooks)
        appendClaudeHookEntry(commandHook, to: "Stop", in: &hooks)
        appendClaudeHookEntry(wildcardCommandHook, to: "PreToolUse", in: &hooks)
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

    static func makeOpenCodeFamilyStatusPlugin(
        cliExecutablePath: String,
        source: String,
        telemetryErrorLogURL: URL
    ) -> String {
        let cliLiteral = jsonStringLiteral(cliExecutablePath)
        let sourceLiteral = jsonStringLiteral(source)
        let logLiteral = jsonStringLiteral(telemetryErrorLogURL.path)

        return """
        export async function ToasttyOpenCodeFamilyStatusPlugin() {
          const cliPath = \(cliLiteral);
          const source = \(sourceLiteral);
          const logPath = \(logLiteral);
          const isMiMoCode = source === "mimocode-plugin";
          let queue = Promise.resolve();
          let lastFinalText = "";
          let lastCompletedTextCandidate = "";
          let lastForwardedStatusKey = "";
          let lastForwardedFinalText = "";
          let suppressWorkingUntil = 0;
          const terminalWorkingSuppressMs = 2000;
          const pendingStatusKeys = new Set();
          const pendingFinalTexts = new Set();

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
          }

          function rememberFinalTextCandidate(input, output) {
            const text = finalTextFrom(input, output);
            if (text) lastCompletedTextCandidate = text;
            return text;
          }

          function statusKind(event) {
            if (!event || event.type !== "toastty.status") return "";
            return stringValue(objectValue(event.properties).kind, 80);
          }

          function isWorkingStatus(event) {
            return statusKind(event) === "working";
          }

          function isTerminalStatus(event) {
            if (!event) return false;
            if (event.type === "toastty.final") return true;
            const kind = statusKind(event);
            return kind === "ready" || kind === "idle" || kind === "error";
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
            if (event.type === "toastty.final") {
              lastForwardedStatusKey = "";
            }
            if (options.suppressFollowingWorking && isTerminalStatus(event)) {
              suppressWorkingUntil = nowMilliseconds() + terminalWorkingSuppressMs;
            } else if (isWorkingStatus(event)) {
              suppressWorkingUntil = 0;
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

          function messagePartDetail(properties) {
            const part = objectValue(properties.part);
            const partType = stringValue(part.type, 80) || stringValue(properties.type, 80);
            const tool = stringValue(part.tool, 80)
              || stringValue(part.name, 80)
              || stringValue(part.callID, 80)
              || stringValue(properties.tool, 80);
            if (tool || partType === "tool") return `Using ${displayToolName(tool)}`;
            if (partType === "reasoning" || partType === "thinking") return "Reasoning";
            if (partType === "text" || stringValue(part.text, 1) || stringValue(properties.text, 1)) return "Writing response";
            return "";
          }

          function finalTextFrom(input, output) {
            const inputObject = objectValue(input);
            const outputObject = objectValue(output);
            return stringValue(outputObject.text, 240)
              || stringValue(outputObject.finalText, 240)
              || stringValue(inputObject.finalText, 240)
              || stringValue(inputObject.text, 240);
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
                if (statusType === "idle") return toasttyStatus("ready", "Ready", lastFinalText);
                return;
              }

              case "session.idle":
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
                const detail = messagePartDetail(properties);
                return detail ? toasttyStatus("working", "Working", detail) : undefined;
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

          function enqueue(event, options = {}) {
            if (!event) return queue;
            if (shouldSuppressWorkingAfterTerminal(event)) return queue;
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
                fire(statusFromProviderEvent(normalizeProviderEvent(input)));
              } catch (error) {
                hookFailure("event", error);
              }
            },

            "permission.ask"(input) {
              try {
                fire(toasttyStatus("needs_approval", "Needs approval", permissionDetail(objectValue(input))));
              } catch (error) {
                hookFailure("permission.ask", error);
              }
            },

            "tool.execute.before"(input) {
              try {
                fire(toasttyStatus("working", "Working", `Using ${displayToolName(toolNameFromInput(input))}`));
              } catch (error) {
                hookFailure("tool.execute.before", error);
              }
            },

            "tool.execute.after"(input, output) {
              try {
                fire(toasttyStatus("working", "Working", toolAfterDetail(input, output)));
              } catch (error) {
                hookFailure("tool.execute.after", error);
              }
            },

            "experimental.text.complete"(input, output) {
              try {
                const text = rememberFinalTextCandidate(input, output);
                if (!isMiMoCode) return flush(toasttyFinal(text));
              } catch (error) {
                hookFailure("experimental.text.complete", error);
              }
            },
          };

          if (isMiMoCode) {
            hooks["session.pre"] = function () {
              try {
                resetTurnState();
                fire(toasttyStatus("working", "Working", "Starting"));
              } catch (error) {
                hookFailure("session.pre", error);
              }
            };

            hooks["session.userQuery.pre"] = function () {
              try {
                resetTurnState();
                fire(toasttyStatus("working", "Working", "Running query"));
              } catch (error) {
                hookFailure("session.userQuery.pre", error);
              }
            };

            hooks["session.userQuery.post"] = function (input, output) {
              try {
                const detail = errorDetail(objectValue(input).error) || errorDetail(objectValue(output).error);
                if (detail) {
                  return flush(toasttyStatus("error", "Error", detail), { suppressFollowingWorking: true });
                }
                rememberFinalTextCandidate(input, output);
              } catch (error) {
                hookFailure("session.userQuery.post", error);
              }
            };

            hooks["session.post"] = function (input, output) {
              try {
                const detail = errorDetail(objectValue(input).error) || errorDetail(objectValue(output).error);
                if (detail) {
                  return flush(toasttyStatus("error", "Error", detail), { suppressFollowingWorking: true });
                }
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

    static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
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
        tomlStringArrayLiteral(values)
    }

    // Internal test seam for validating TOML basic string escaping directly.
    static func tomlBasicStringLiteralForTesting(_ value: String) -> String {
        tomlBasicStringLiteral(value)
    }
}
