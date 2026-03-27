import Foundation
import XCTest
@testable import ToasttyApp

final class AgentLaunchInstrumentationTests: XCTestCase {
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
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["PostToolUse"])
        XCTAssertNotNil(hooks["PostToolUseFailure"])
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
        arguments: [String] = []
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
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
