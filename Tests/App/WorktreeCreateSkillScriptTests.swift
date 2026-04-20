import Foundation
import XCTest

final class WorktreeCreateSkillScriptTests: XCTestCase {
    func testOpenSessionScriptRequiresPanelContextWhenWindowIDIsOmitted() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-script")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let result = try runScript(
            at: skillScriptURL(),
            environment: [
                "TOASTTY_CLI_PATH": "/usr/bin/true",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--startup-command", "printf 'noop\\n'",
            ]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("TOASTTY_PANEL_ID is required when --window-id is omitted"))
    }

    func testOpenSessionScriptResolvesWindowIDFromTerminalStateAndUsesItForWorkspaceCreate() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-worktree-create-success")
        defer { try? fileManager.removeItem(at: rootURL) }

        let worktreeURL = rootURL.appendingPathComponent("worktree", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)

        let handoffURL = worktreeURL.appendingPathComponent("WORKTREE_HANDOFF.md", isDirectory: false)
        try Data("# Handoff\n".utf8).write(to: handoffURL, options: .atomic)

        let invocationLogURL = rootURL.appendingPathComponent("cli-invocations.log", isDirectory: false)
        let fakeCLIURL = try makeExecutableScript(
            named: "fake-toastty-cli",
            contents: """
            #!/bin/sh
            set -eu
            printf '%s\\n' \"$*\" >> \"${FAKE_TOASTTY_LOG:?}\"
            if [ \"${1:-}\" = \"--json\" ]; then
              shift
            fi
            case \"$1 $2 $3\" in
              \"query run terminal.state\")
                if [ \"${4:-}\" = \"--panel\" ]; then
                  cat <<'EOF'
            {"result":{"windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"22222222-2222-2222-2222-222222222222","panelID":"33333333-3333-3333-3333-333333333333","title":"~","cwd":"/tmp","shell":"zsh","profileID":null}}
            EOF
                else
                  cat <<'EOF'
            {"result":{"windowID":"11111111-1111-1111-1111-111111111111","workspaceID":"44444444-4444-4444-4444-444444444444","panelID":"55555555-5555-5555-5555-555555555555","title":"workspace terminal","cwd":"/tmp/worktree","shell":"zsh","profileID":null}}
            EOF
                fi
                ;;
              \"query run workspace.snapshot\")
                cat <<'EOF'
            {"result":{"workspaceID":"44444444-4444-4444-4444-444444444444"}}
            EOF
                ;;
              \"action run terminal.send-text\")
                cat <<'EOF'
            {"result":{"workspaceID":"44444444-4444-4444-4444-444444444444","panelID":"55555555-5555-5555-5555-555555555555","submitted":true,"available":true}}
            EOF
                ;;
              *)
                printf 'ran %s\\n' \"$2\"
                ;;
            esac
            """,
            in: rootURL
        )

        let result = try runScript(
            at: skillScriptURL(),
            environment: [
                "FAKE_TOASTTY_LOG": invocationLogURL.path,
                "TOASTTY_CLI_PATH": fakeCLIURL.path,
                "TOASTTY_PANEL_ID": "33333333-3333-3333-3333-333333333333",
            ],
            arguments: [
                "--workspace-name", "smoke",
                "--worktree-path", worktreeURL.path,
                "--handoff-file", handoffURL.path,
                "--startup-command", "printf 'noop\\n'",
                "--json",
            ]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.stdout.contains("\"window_id\": \"11111111-1111-1111-1111-111111111111\""))
        XCTAssertTrue(result.stdout.contains("\"workspace_id\": \"44444444-4444-4444-4444-444444444444\""))
        XCTAssertTrue(result.stdout.contains("\"panel_id\": \"55555555-5555-5555-5555-555555555555\""))

        let invocations = try String(contentsOf: invocationLogURL, encoding: .utf8)
        XCTAssertTrue(invocations.contains("query run terminal.state --panel 33333333-3333-3333-3333-333333333333"))
        XCTAssertTrue(invocations.contains("action run workspace.create --window 11111111-1111-1111-1111-111111111111 title=smoke"))
        XCTAssertTrue(invocations.contains("query run workspace.snapshot --window 11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(invocations.contains("query run terminal.state --workspace 44444444-4444-4444-4444-444444444444"))
    }

    private func skillScriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".agents/skills/worktree-create/scripts/open-toastty-worktree-session.sh", isDirectory: false)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func makeExecutableScript(
        named name: String,
        contents: String,
        in directoryURL: URL
    ) throws -> URL {
        let scriptURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try Data(contents.appending("\n").utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func runScript(
        at scriptURL: URL,
        environment: [String: String],
        arguments: [String]
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
