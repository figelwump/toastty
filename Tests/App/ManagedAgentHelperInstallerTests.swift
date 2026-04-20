import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

final class ManagedAgentHelperInstallerTests: XCTestCase {
    func testResolvePathsStagesHelpersIntoRuntimeBinForRuntimeIsolatedRuns() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-managed-helpers")
        defer { try? fileManager.removeItem(at: rootURL) }

        let runtimeHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": runtimeHomeURL.path]
        )
        try runtimePaths.prepare(fileManager: fileManager)

        let sourceCLIURL = try makeExecutableScript(
            named: "source-toastty",
            contents: "#!/bin/sh\nexit 0\n",
            in: rootURL
        )
        let sourceShimURL = try makeExecutableScript(
            named: "source-toastty-agent-shim",
            contents: "#!/bin/sh\nexit 0\n",
            in: rootURL
        )

        let resolvedPaths = try ManagedAgentHelperInstaller(
            runtimePaths: runtimePaths,
            fileManager: fileManager,
            cliExecutablePathProvider: { sourceCLIURL.path },
            agentShimExecutablePathProvider: { sourceShimURL.path }
        ).resolvePaths()

        XCTAssertEqual(
            resolvedPaths.cliExecutablePath,
            runtimePaths.agentShimDirectoryURL.appendingPathComponent("toastty", isDirectory: false).path
        )
        XCTAssertEqual(
            resolvedPaths.agentShimExecutablePath,
            runtimePaths.agentShimDirectoryURL
                .appendingPathComponent("toastty-agent-shim", isDirectory: false)
                .path
        )
        XCTAssertTrue(
            fileManager.isExecutableFile(
                atPath: try XCTUnwrap(resolvedPaths.cliExecutablePath)
            )
        )
        XCTAssertTrue(
            fileManager.isExecutableFile(
                atPath: try XCTUnwrap(resolvedPaths.agentShimExecutablePath)
            )
        )
        XCTAssertEqual(
            try String(contentsOfFile: try XCTUnwrap(resolvedPaths.cliExecutablePath), encoding: .utf8),
            try String(contentsOf: sourceCLIURL, encoding: .utf8)
        )
        XCTAssertEqual(
            try String(contentsOfFile: try XCTUnwrap(resolvedPaths.agentShimExecutablePath), encoding: .utf8),
            try String(contentsOf: sourceShimURL, encoding: .utf8)
        )
    }

    func testStagedCLIKeepsCodexNotifyScriptWorkingAfterOriginalSourceDisappears() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory(prefix: "toastty-managed-notify")
        defer { try? fileManager.removeItem(at: rootURL) }

        let runtimeHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: rootURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": runtimeHomeURL.path]
        )
        try runtimePaths.prepare(fileManager: fileManager)

        let sourceCLIURL = try makeExecutableScript(
            named: "source-toastty",
            contents: """
            #!/bin/sh
            printf '%s\n' "$@" > "${TEST_ARGS_FILE:?}"
            cat > "${TEST_STDIN_FILE:?}"
            """,
            in: rootURL
        )
        let sourceShimURL = try makeExecutableScript(
            named: "source-toastty-agent-shim",
            contents: "#!/bin/sh\nexit 0\n",
            in: rootURL
        )

        let resolvedPaths = try ManagedAgentHelperInstaller(
            runtimePaths: runtimePaths,
            fileManager: fileManager,
            cliExecutablePathProvider: { sourceCLIURL.path },
            agentShimExecutablePathProvider: { sourceShimURL.path }
        ).resolvePaths()
        let stagedCLIPath = try XCTUnwrap(resolvedPaths.cliExecutablePath)

        try fileManager.removeItem(at: sourceCLIURL)
        try fileManager.removeItem(at: sourceShimURL)

        let preparedLaunch = try AgentLaunchInstrumentation.prepare(
            agent: .codex,
            argv: ["codex"],
            cliExecutablePath: stagedCLIPath,
            sessionID: "test-\(UUID().uuidString)",
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
        let argsURL = rootURL.appendingPathComponent("captured-args.txt", isDirectory: false)
        let stdinURL = rootURL.appendingPathComponent("captured-stdin.txt", isDirectory: false)
        let payload = #"{"type":"task_complete","last_agent_message":"done"}"#
        let hookScript = try String(contentsOf: scriptURL, encoding: .utf8)

        let result = try runScript(
            at: scriptURL,
            environment: [
                "TEST_ARGS_FILE": argsURL.path,
                "TEST_STDIN_FILE": stdinURL.path,
            ],
            arguments: [payload]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(hookScript.contains(stagedCLIPath))
        XCTAssertFalse(hookScript.contains(sourceCLIURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: telemetryLogURL.path))
        XCTAssertEqual(
            try String(contentsOf: argsURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init),
            ["session", "ingest-agent-event", "--source", "codex-notify"]
        )
        XCTAssertEqual(try String(contentsOf: stdinURL, encoding: .utf8), payload)
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
