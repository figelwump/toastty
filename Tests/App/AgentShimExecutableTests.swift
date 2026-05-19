import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AgentShimExecutableTests {
    @Test
    func typedCodexShimPreflightRunAnywayReissuesPrepareWithSkipAndLaunchesPlan() throws {
        let fixture = try AgentShimExecutableFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(preflightDecision: .runAnyway)

        #expect(result.exitStatus == 7)
        #expect(result.stderr.isEmpty)

        let cliLog = try fixture.cliLogContents()
        #expect(cliLog.contains("agent prepare-managed-launch"))
        #expect(cliLog.contains("--preflight-policy interactive"))
        #expect(cliLog.contains("agent managed-launch-preflight-decision --token preflight-token"))
        #expect(cliLog.contains("--preflight-policy skip"))
        #expect(cliLog.contains("session stop --session sess-preflight --reason process_exit"))

        let agentLog = try fixture.agentLogContents()
        #expect(agentLog.contains("agent --managed-plan"))
        #expect(agentLog.contains("session=sess-preflight"))
        #expect(agentLog.contains("panel=\(fixture.panelID.uuidString)"))
    }

    @Test
    func typedCodexShimPreflightSetUpHooksCancelsWithoutLaunchingAgent() throws {
        let fixture = try AgentShimExecutableFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(preflightDecision: .setUpHooks)

        #expect(result.exitStatus == 0)
        #expect(result.stderr.contains("Toastty opened Codex status hook setup. Launch cancelled."))

        let cliLog = try fixture.cliLogContents()
        #expect(cliLog.contains("agent prepare-managed-launch"))
        #expect(cliLog.contains("--preflight-policy interactive"))
        #expect(cliLog.contains("agent managed-launch-preflight-decision --token preflight-token"))
        #expect(cliLog.contains("--preflight-policy skip") == false)
        #expect(cliLog.contains("session stop") == false)
        #expect(try fixture.agentLogContents().isEmpty)
    }
}

private struct AgentShimExecutableFixture {
    let rootURL: URL
    let panelID: UUID
    private let shimLinkURL: URL
    private let fakeCLIURL: URL
    private let cliLogURL: URL
    private let agentLogURL: URL
    private let realBinURL: URL

    static func make() throws -> Self {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-agent-shim-executable-\(UUID().uuidString)", isDirectory: true)
        let shimDirectoryURL = rootURL.appendingPathComponent("shim", isDirectory: true)
        let realBinURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let fakeCLIURL = rootURL.appendingPathComponent("fake-toastty", isDirectory: false)
        let cliLogURL = rootURL.appendingPathComponent("cli.log", isDirectory: false)
        let agentLogURL = rootURL.appendingPathComponent("agent.log", isDirectory: false)
        let shimLinkURL = shimDirectoryURL.appendingPathComponent("cdx", isDirectory: false)

        try fileManager.createDirectory(at: shimDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realBinURL, withIntermediateDirectories: true)

        let shimPath = try #require(ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath())
        try fileManager.createSymbolicLink(
            at: shimLinkURL,
            withDestinationURL: URL(fileURLWithPath: shimPath)
        )

        try writeExecutableScript(
            at: fakeCLIURL,
            contents: fakeCLIScript()
        )
        try writeExecutableScript(
            at: realBinURL.appendingPathComponent("cdx", isDirectory: false),
            contents: fakeAgentScript()
        )

        return Self(
            rootURL: rootURL,
            panelID: UUID(),
            shimLinkURL: shimLinkURL,
            fakeCLIURL: fakeCLIURL,
            cliLogURL: cliLogURL,
            agentLogURL: agentLogURL,
            realBinURL: realBinURL
        )
    }

    func run(preflightDecision: ManagedAgentLaunchPreflightDecisionKind) throws -> AgentShimRunResult {
        let process = Process()
        process.executableURL = shimLinkURL
        process.arguments = ["--typed-in-terminal"]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            shimLinkURL.deletingLastPathComponent().path,
            realBinURL.path,
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
        environment["PWD"] = "/tmp/repo"
        environment[ToasttyLaunchContextEnvironment.cliPathKey] = fakeCLIURL.path
        environment[ToasttyLaunchContextEnvironment.panelIDKey] = panelID.uuidString
        environment[ToasttyLaunchContextEnvironment.sessionIDKey] = nil
        environment[ToasttyLaunchContextEnvironment.agentBasePathKey] = nil
        environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = nil
        environment["TOASTTY_LOG_DISABLE"] = "1"
        environment["TOASTTY_FAKE_CLI_LOG"] = cliLogURL.path
        environment["TOASTTY_FAKE_AGENT_LOG"] = agentLogURL.path
        environment["TOASTTY_FAKE_PREFLIGHT_DECISION"] = preflightDecision.rawValue
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw AgentShimExecutableTestError.timedOut
        }
        process.waitUntilExit()

        return AgentShimRunResult(
            exitStatus: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    func cliLogContents() throws -> String {
        try fileContentsIfPresent(at: cliLogURL)
    }

    func agentLogContents() throws -> String {
        try fileContentsIfPresent(at: agentLogURL)
    }

    private static func writeExecutableScript(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func fakeCLIScript() -> String {
        """
        #!/bin/sh
        {
          printf 'cli'
          for arg in "$@"; do
            printf ' %s' "$arg"
          done
          printf '\\n'
        } >> "$TOASTTY_FAKE_CLI_LOG"

        if [ "${1:-}" = "agent" ] && [ "${2:-}" = "prepare-managed-launch" ]; then
          shift 2
          panel=""
          policy="skip"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --panel)
                panel="$2"
                shift 2
                ;;
              --preflight-policy)
                policy="$2"
                shift 2
                ;;
              --agent|--cwd|--arg)
                shift 2
                ;;
              *)
                shift
                ;;
            esac
          done

          if [ "$policy" = "interactive" ]; then
            cat <<JSON
        {
          "kind": "preflightRequired",
          "preflight": {
            "token": "preflight-token",
            "agent": "codex",
            "panelID": "$panel",
            "windowID": "11111111-1111-1111-1111-111111111111",
            "title": "Set Up Codex Status Hooks",
            "message": "Codex hooks are missing.",
            "canOpenSetup": true,
            "pollIntervalMilliseconds": 50
          }
        }
        JSON
            exit 0
          fi

          cat <<JSON
        {
          "sessionID": "sess-preflight",
          "agent": "codex",
          "panelID": "$panel",
          "windowID": "11111111-1111-1111-1111-111111111111",
          "workspaceID": "22222222-2222-2222-2222-222222222222",
          "cwd": "/tmp/repo",
          "repoRoot": "/tmp/repo",
          "argv": ["cdx", "--managed-plan"],
          "environment": {
            "TOASTTY_SESSION_ID": "sess-preflight",
            "TOASTTY_PANEL_ID": "$panel",
            "TOASTTY_CWD": "/tmp/repo",
            "TOASTTY_REPO_ROOT": "/tmp/repo"
          }
        }
        JSON
          exit 0
        fi

        if [ "${1:-}" = "agent" ] && [ "${2:-}" = "managed-launch-preflight-decision" ]; then
          printf '{"kind":"%s"}\\n' "${TOASTTY_FAKE_PREFLIGHT_DECISION:-runAnyway}"
          exit 0
        fi

        if [ "${1:-}" = "session" ] && [ "${2:-}" = "stop" ]; then
          printf '{}\\n'
          exit 0
        fi

        printf '{}\\n'
        """
    }

    private static func fakeAgentScript() -> String {
        """
        #!/bin/sh
        {
          printf 'agent'
          for arg in "$@"; do
            printf ' %s' "$arg"
          done
          printf '\\n'
          printf 'session=%s\\n' "${TOASTTY_SESSION_ID:-}"
          printf 'panel=%s\\n' "${TOASTTY_PANEL_ID:-}"
        } >> "$TOASTTY_FAKE_AGENT_LOG"
        exit 7
        """
    }
}

private struct AgentShimRunResult {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
}

private enum AgentShimExecutableTestError: Error {
    case timedOut
}

private func fileContentsIfPresent(at url: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return ""
    }
    return try String(contentsOf: url, encoding: .utf8)
}
