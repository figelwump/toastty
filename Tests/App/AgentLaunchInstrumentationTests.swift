import Foundation
import XCTest
@testable import ToasttyApp

final class AgentLaunchInstrumentationTests: XCTestCase {
    override func tearDown() {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = nil
        super.tearDown()
    }

    func testPrepareClaudeLaunchMergesInlineSettingsArgument() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: [
                "claude",
                "--settings={\"model\":\"sonnet\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/bin/echo existing\"}]}]}}",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv.first, "claude")
        let settingsIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "--settings"))
        let settingsPath = try XCTUnwrap(preparedLaunch.argv[safe: settingsIndex + 1])
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "sonnet")
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
        XCTAssertNil(hooks["PostToolUseFailure"])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["Notification"])

        let notificationEntries = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let matcherEntry = notificationEntries.first { entry in
            (entry["matcher"] as? String) == "*"
        }
        XCTAssertNotNil(matcherEntry, "Notification hook should have a wildcard matcher entry")
    }

    func testPrepareCodexLaunchFormatsNotifyOverrideAsTomlArray() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex", "--yolo"],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv.first, "codex")
        let configIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "-c"))
        let configValue = try XCTUnwrap(preparedLaunch.argv[safe: configIndex + 1])
        let notifyScriptPath = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL.appendingPathComponent("codex-notify.sh").path)

        XCTAssertEqual(
            configValue,
            "notify=[\"/bin/sh\",\"\(notifyScriptPath)\"]"
        )
        XCTAssertFalse(configValue.contains("\\/"))
        XCTAssertEqual(preparedLaunch.argv.last, "--yolo")
        XCTAssertEqual(preparedLaunch.environment["CODEX_TUI_RECORD_SESSION"], "1")
        XCTAssertEqual(preparedLaunch.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"], "1")
        XCTAssertEqual(
            preparedLaunch.environment["CODEX_TUI_SESSION_LOG_PATH"],
            preparedLaunch.artifacts?.codexSessionLogURL?.path
        )
    }

    func testPrepareCodexLaunchInsertsNotifyAfterWrappedCodexCommand() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "--workdir=/tmp/repo",
                "codex",
                "--dangerously-bypass-approvals-and-sandbox",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "--workdir=/tmp/repo",
                "codex",
                "-c",
                "notify=[\"/bin/sh\",\"\(try XCTUnwrap(preparedLaunch.artifacts?.directoryURL.appendingPathComponent("codex-notify.sh").path))\"]",
                "--dangerously-bypass-approvals-and-sandbox",
            ]
        )
    }

    func testPrepareClaudeLaunchInsertsSettingsAfterWrappedClaudeCommand() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "claude",
                "--dangerously-skip-permissions",
            ],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let settingsIndex = try XCTUnwrap(preparedLaunch.argv.firstIndex(of: "--settings"))
        let settingsPath = try XCTUnwrap(preparedLaunch.argv[safe: settingsIndex + 1])
        XCTAssertEqual(
            Array(preparedLaunch.argv.prefix(4)),
            [
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                "claude",
                "--settings",
                settingsPath,
            ]
        )
        XCTAssertEqual(preparedLaunch.argv.last, "--dangerously-skip-permissions")
    }

    func testPreparePiLaunchInsertsToasttyExtensionAfterPiCommand() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = {
            "/Applications/Toastty.app/Contents/Resources/AgentExtensions/toastty-pi-extension.js"
        }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["agent-safehouse", "--cwd", "/tmp/repo", "pi", "--mode", "text"],
            cliExecutablePath: "/bin/sh",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(
            preparedLaunch.argv,
            [
                "agent-safehouse",
                "--cwd",
                "/tmp/repo",
                "pi",
                "--extension",
                "/Applications/Toastty.app/Contents/Resources/AgentExtensions/toastty-pi-extension.js",
                "--mode",
                "text",
            ]
        )
        XCTAssertEqual(
            preparedLaunch.environment["TOASTTY_PI_TELEMETRY_LOG_PATH"],
            preparedLaunch.artifacts?.directoryURL.appendingPathComponent("pi-telemetry.jsonl").path
        )
    }

    func testPreparePiLaunchPreservesUserExtensionAndAddsToasttyExtension() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--extension", "/user/ext.js"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(
            preparedLaunch.argv,
            ["pi", "--extension", "/toastty/pi-extension.js", "--extension", "/user/ext.js"]
        )
    }

    func testPreparePiLaunchSkipsToasttyExtensionForNoExtensionsBeforeTerminator() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--no-extensions", "--extension", "/user/ext.js"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(preparedLaunch.argv, ["pi", "--no-extensions", "--extension", "/user/ext.js"])
        XCTAssertNotNil(preparedLaunch.environment["TOASTTY_PI_TELEMETRY_LOG_PATH"])
    }

    func testPreparePiLaunchTreatsShortNoExtensionFlagAsOptOutBeforeTerminatorOnly() throws {
        AgentLaunchInstrumentation.piExtensionPathProviderForTesting = { "/toastty/pi-extension.js" }

        let optedOutLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "-ne"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )
        let terminatorLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .pi,
            argv: ["pi", "--", "--no-extensions"],
            cliExecutablePath: "/bin/sh",
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: .default
        )

        defer {
            for artifacts in [optedOutLaunch.artifacts, terminatorLaunch.artifacts].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: artifacts.directoryURL)
            }
        }

        XCTAssertEqual(optedOutLaunch.argv, ["pi", "-ne"])
        XCTAssertEqual(terminatorLaunch.argv, ["pi", "--extension", "/toastty/pi-extension.js", "--", "--no-extensions"])
    }

    func testPreparedClaudeHookScriptLogsTelemetryFailuresWithoutWritingToStdout() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude"],
            cliExecutablePath: "/definitely/missing-toastty-cli",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let artifactsURL = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL)
        let scriptURL = artifactsURL.appendingPathComponent("claude-hook.sh", isDirectory: false)
        let telemetryLogURL = artifactsURL.appendingPathComponent("telemetry-failures.log", isDirectory: false)

        let result = try runScript(
            at: scriptURL,
            environment: ["TOASTTY_SOCKET_PATH": "/tmp/test-claude-hooks.sock"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")

        let telemetryLog = try String(contentsOf: telemetryLogURL, encoding: .utf8)
        XCTAssertTrue(telemetryLog.contains("source=claude-hooks"))
        XCTAssertTrue(telemetryLog.contains("socket_path=/tmp/test-claude-hooks.sock"))
        XCTAssertTrue(telemetryLog.contains("exit_code="))
        XCTAssertTrue(telemetryLog.contains("stderr: "))
    }

    func testPreparedClaudeHookScriptForwardsHookPayload() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-claude-hook-forward-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let capturedArgsURL = rootURL.appendingPathComponent("args.txt", isDirectory: false)
        let capturedPayloadURL = rootURL.appendingPathComponent("payload.json", isDirectory: false)
        let fakeCLIURL = rootURL.appendingPathComponent("toastty-cli", isDirectory: false)
        try Data(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(capturedArgsURL.path)'
            cat > '\(capturedPayloadURL.path)'
            exit 0

            """.utf8
        ).write(to: fakeCLIURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLIURL.path)

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .claude,
            argv: ["claude"],
            cliExecutablePath: fakeCLIURL.path,
            sessionID: "test-\(UUID().uuidString)",
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let scriptURL = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL.appendingPathComponent("claude-hook.sh"))
        let payload = #"{"hook_event_name":"SessionStart","session_id":"claude-session","transcript_path":"/tmp/claude.jsonl"}"#
        let result = try runScript(
            at: scriptURL,
            environment: ["TOASTTY_SOCKET_PATH": "/tmp/test-claude-hooks.sock"],
            standardInput: Data(payload.utf8)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(try String(contentsOf: capturedPayloadURL, encoding: .utf8), payload)
        XCTAssertEqual(
            try String(contentsOf: capturedArgsURL, encoding: .utf8),
            "session\ningest-agent-event\n--source\nclaude-hooks\n"
        )
    }

    func testPreparedCodexNotifyScriptLogsTelemetryFailuresWithoutWritingToStdout() throws {
        let fileManager = FileManager.default
        let sessionID = "test-\(UUID().uuidString)"

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex"],
            cliExecutablePath: "/definitely/missing-toastty-cli",
            sessionID: sessionID,
            workingDirectory: nil,
            fileManager: fileManager
        )

        defer {
            if let artifacts = preparedLaunch.artifacts {
                try? fileManager.removeItem(at: artifacts.directoryURL)
            }
        }

        let artifactsURL = try XCTUnwrap(preparedLaunch.artifacts?.directoryURL)
        let scriptURL = artifactsURL.appendingPathComponent("codex-notify.sh", isDirectory: false)
        let telemetryLogURL = artifactsURL.appendingPathComponent("telemetry-failures.log", isDirectory: false)

        let result = try runScript(
            at: scriptURL,
            environment: ["TOASTTY_SOCKET_PATH": "/tmp/test-codex-hooks.sock"],
            arguments: ["{\"kind\":\"task_complete\"}"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")

        let telemetryLog = try String(contentsOf: telemetryLogURL, encoding: .utf8)
        XCTAssertTrue(telemetryLog.contains("source=codex-notify"))
        XCTAssertTrue(telemetryLog.contains("socket_path=/tmp/test-codex-hooks.sock"))
        XCTAssertTrue(telemetryLog.contains("exit_code="))
        XCTAssertTrue(telemetryLog.contains("stderr: "))
    }

    func testTomlBasicStringLiteralEscapesSpecialCharacters() {
        let literal = AgentLaunchInstrumentation.tomlBasicStringLiteralForTesting("line\n\t\"\\\u{7F}\u{0001}")

        XCTAssertEqual(literal, "\"line\\n\\t\\\"\\\\\\u007f\\u0001\"")
    }

    func testTomlStringArrayLiteralEscapesEmbeddedSpecialCharacters() {
        let literal = AgentLaunchInstrumentation.tomlStringArrayLiteralForTesting([
            "/bin/sh",
            "path with quote \" and slash \\ and newline \n",
        ])

        XCTAssertEqual(
            literal,
            "[\"/bin/sh\",\"path with quote \\\" and slash \\\\ and newline \\n\"]"
        )
    }

    private func runScript(
        at scriptURL: URL,
        environment: [String: String],
        arguments: [String] = [],
        standardInput: Data? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let inputPipe = Pipe()
        process.standardInput = inputPipe

        try process.run()
        if let standardInput {
            inputPipe.fileHandleForWriting.write(standardInput)
        }
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
