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
        #expect(cliLog.contains("--resolved-codex-executable \(fixture.realCodexURL.path)"))
        #expect(cliLog.contains("--codex-process-path \(fixture.expectedCodexProcessPath)"))
        #expect(cliLog.contains(fixture.shimDirectoryURL.path + ":") == false)
        #expect(cliLog.contains("session stop --session sess-preflight --reason process_exit"))

        let agentLog = try fixture.agentLogContents()
        #expect(agentLog.contains("agent --managed-plan"))
        #expect(agentLog.contains("session=sess-preflight"))
        #expect(agentLog.contains("panel=\(fixture.panelID.uuidString)"))
    }

    @Test
    func typedCodexShimRecordsSpawnedProcessAsArtifactOwner() throws {
        let fixture = try AgentShimExecutableFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(preflightDecision: .runAnyway)

        #expect(result.exitStatus == 7)
        #expect(try fixture.recordedOwnerPID() == fixture.spawnedAgentPID())
        #expect(try fixture.agentLogContents().contains("owner_file="))
        #expect(
            try fixture.agentLogContents().contains(
                "owner_file=\(fixture.ownerRecordURL.path)"
            ) == false
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.ownerRecordURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func managedBypassCodexShimRecordsSpawnedProcessAsArtifactOwner() throws {
        let fixture = try AgentShimExecutableFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(
            preflightDecision: .runAnyway,
            inheritedSessionID: "sess-direct",
            managedShimBypass: true,
            ownerRecordInInitialEnvironment: true,
            extraEnvironment: [
                "CODEX_TUI_RECORD_SESSION": "1",
                "CODEX_TUI_SESSION_LOG_PATH": "/tmp/parent-codex-session.jsonl",
            ]
        )

        #expect(result.exitStatus == 7)
        #expect(try fixture.recordedOwnerPID() == fixture.spawnedAgentPID())
        #expect(try fixture.cliLogContents().isEmpty)
        #expect(
            try fixture.agentLogContents().contains(
                "owner_file=\(fixture.ownerRecordURL.path)"
            ) == false
        )
        let agentLog = try fixture.agentLogContents()
        #expect(agentLog.contains("session=sess-direct"))
        #expect(agentLog.contains("record_session=1"))
        #expect(agentLog.contains("session_log=/tmp/parent-codex-session.jsonl"))
        #expect(agentLog.contains("shim_bypass=\n"))
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

    @Test
    func typedCodexShimReportsHookSetupFailureFromSetupDecision() throws {
        let fixture = try AgentShimExecutableFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(
            preflightDecision: .setUpHooks,
            preflightDecisionMessage: "Unable to set up Codex status hooks: Hooks file is read-only"
        )

        #expect(result.exitStatus == 1)
        #expect(result.stderr.contains("Unable to set up Codex status hooks: Hooks file is read-only"))
        #expect(try fixture.agentLogContents().isEmpty)
    }

    @Test
    func typedMiMoCodeShimResolvesRealMimoBinaryWithoutProfileConfiguration() throws {
        let fixture = try AgentShimExecutableFixture.make(shimCommandName: "mimocode", realBinaryName: "mimo")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(preflightDecision: .runAnyway)

        #expect(result.exitStatus == 7)
        #expect(result.stderr.isEmpty)

        let cliLog = try fixture.cliLogContents()
        #expect(cliLog.contains("agent prepare-managed-launch --agent mimocode"))

        let agentLog = try fixture.agentLogContents()
        #expect(agentLog.contains("agent --managed-plan"))
        #expect(agentLog.contains("session=sess-preflight"))
    }

    @Test
    func inheritedCodexSessionTracksBackgroundActivityWithoutParentSessionContext() throws {
        let fixture = try AgentShimExecutableFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(
            preflightDecision: .runAnyway,
            inheritedSessionID: "sess-parent",
            extraEnvironment: [
                ToasttyLaunchContextEnvironment.agentKey: "codex",
                ToasttyLaunchContextEnvironment.launchReasonKey: "managed",
                ToasttyLaunchContextEnvironment.cwdKey: "/parent/cwd",
                ToasttyLaunchContextEnvironment.repoRootKey: "/parent/repo",
                ToasttyLaunchContextEnvironment.socketPathKey: "/tmp/parent.sock",
                ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey: "/tmp/parent-owner",
                "CODEX_TUI_RECORD_SESSION": "1",
                "CODEX_TUI_SESSION_LOG_PATH": "/tmp/parent-codex-session.jsonl",
            ]
        )

        #expect(result.exitStatus == 7)
        #expect(result.stderr.isEmpty)

        let cliLog = try fixture.cliLogContents()
        #expect(cliLog.contains("agent prepare-managed-launch") == false)
        #expect(cliLog.contains("session background-activity start --session sess-parent"))
        #expect(cliLog.contains("--panel \(fixture.panelID.uuidString)"))
        #expect(cliLog.contains("--kind child_agent"))
        #expect(cliLog.contains("--display-name Codex"))
        #expect(cliLog.contains("--pid "))
        #expect(cliLog.contains("session background-activity finish --session sess-parent"))

        let agentLog = try fixture.agentLogContents()
        #expect(agentLog.contains("agent --typed-in-terminal"))
        #expect(agentLog.contains("session=\n"))
        #expect(agentLog.contains("panel=\n"))
        #expect(agentLog.contains("toastty_agent=\n"))
        #expect(agentLog.contains("launch_reason=\n"))
        #expect(agentLog.contains("toastty_cwd=\n"))
        #expect(agentLog.contains("repo_root=\n"))
        #expect(agentLog.contains("socket_path=\n"))
        #expect(agentLog.contains("cli_path=\n"))
        #expect(agentLog.contains("owner_file=\n"))
        #expect(agentLog.contains("record_session=\n"))
        #expect(agentLog.contains("session_log=\n"))
    }

    @Test
    func inheritedNonCodexSessionPreservesParentLaunchContext() throws {
        let fixture = try AgentShimExecutableFixture.make(
            shimCommandName: "mimocode",
            realBinaryName: "mimo"
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(
            preflightDecision: .runAnyway,
            inheritedSessionID: "sess-parent",
            extraEnvironment: [
                "CODEX_TUI_RECORD_SESSION": "1",
                "CODEX_TUI_SESSION_LOG_PATH": "/tmp/parent-codex-session.jsonl",
            ]
        )

        #expect(result.exitStatus == 7)
        #expect(result.stderr.isEmpty)
        #expect(try fixture.cliLogContents().contains("session background-activity start"))
        let agentLog = try fixture.agentLogContents()
        #expect(agentLog.contains("session=sess-parent"))
        #expect(agentLog.contains("panel=\(fixture.panelID.uuidString)"))
        #expect(agentLog.contains("cli_path=\(fixture.fakeCLIPath)"))
        #expect(agentLog.contains("record_session=\n"))
        #expect(agentLog.contains("session_log=\n"))
    }

    @Test
    func missingUnderlyingAgentDoesNotResolveShimToItself() throws {
        let fixture = try AgentShimExecutableFixture.make(
            shimCommandName: "pi",
            installRealBinary: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(
            preflightDecision: .runAnyway,
            inheritedSessionID: "sess-parent"
        )

        #expect(result.exitStatus == 127)
        #expect(result.stderr == "pi: command not found\n")
        #expect(try fixture.cliLogContents().isEmpty)
        #expect(try fixture.agentLogContents().isEmpty)
    }

    @Test
    func loginShellExecutableFallbackLaunchesRealAgentOutsideShimDirectory() throws {
        let fixture = try AgentShimExecutableFixture.make(
            shimCommandName: "pi",
            realBinaryAvailableOnlyToDirectProbe: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let result = try fixture.run(
            preflightDecision: .runAnyway,
            inheritedSessionID: "sess-parent"
        )

        #expect(result.exitStatus == 7)
        #expect(result.stderr.isEmpty)
        #expect(try fixture.cliLogContents().contains("session background-activity start"))
        #expect(try fixture.agentLogContents().contains("agent --typed-in-terminal"))
    }
}

private struct AgentShimExecutableFixture {
    let rootURL: URL
    let panelID: UUID
    let ownerRecordURL: URL
    private let shimLinkURL: URL
    private let fakeCLIURL: URL
    private let cliLogURL: URL
    private let agentLogURL: URL
    private let realBinURL: URL
    private let includeRealBinInInitialPath: Bool

    var shimDirectoryURL: URL {
        shimLinkURL.deletingLastPathComponent()
    }

    var realCodexURL: URL {
        realBinURL.appendingPathComponent("cdx", isDirectory: false)
    }

    var expectedCodexProcessPath: String {
        [realBinURL.path, "/usr/bin", "/bin"].joined(separator: ":")
    }

    var fakeCLIPath: String {
        fakeCLIURL.path
    }

    static func make(
        shimCommandName: String = "cdx",
        realBinaryName: String? = nil,
        installRealBinary: Bool = true,
        realBinaryAvailableOnlyToDirectProbe: Bool = false
    ) throws -> Self {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-agent-shim-executable-\(UUID().uuidString)", isDirectory: true)
        let shimDirectoryURL = rootURL.appendingPathComponent("shim", isDirectory: true)
        let realBinURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let fakeCLIURL = rootURL.appendingPathComponent("fake-toastty", isDirectory: false)
        let cliLogURL = rootURL.appendingPathComponent("cli.log", isDirectory: false)
        let agentLogURL = rootURL.appendingPathComponent("agent.log", isDirectory: false)
        let ownerRecordURL = rootURL.appendingPathComponent("owner-pid", isDirectory: false)
        let shimLinkURL = shimDirectoryURL.appendingPathComponent(shimCommandName, isDirectory: false)
        let realBinaryName = realBinaryName ?? shimCommandName

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
        if installRealBinary {
            try writeExecutableScript(
                at: realBinURL.appendingPathComponent(realBinaryName, isDirectory: false),
                contents: fakeAgentScript()
            )
        }
        if realBinaryAvailableOnlyToDirectProbe {
            let profile = """
            if [[ -e "$ZDOTDIR/.initial-path-probe-complete" ]]; then
              export PATH="$ZDOTDIR/bin:$PATH"
            else
              : > "$ZDOTDIR/.initial-path-probe-complete"
            fi
            """
            // The shim probes the account's login shell, which is bash on CI.
            for profileName in [".zprofile", ".bash_profile"] {
                try profile.write(
                    to: rootURL.appendingPathComponent(profileName, isDirectory: false),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }

        return Self(
            rootURL: rootURL,
            panelID: UUID(),
            ownerRecordURL: ownerRecordURL,
            shimLinkURL: shimLinkURL,
            fakeCLIURL: fakeCLIURL,
            cliLogURL: cliLogURL,
            agentLogURL: agentLogURL,
            realBinURL: realBinURL,
            includeRealBinInInitialPath: realBinaryAvailableOnlyToDirectProbe == false
        )
    }

    func run(
        preflightDecision: ManagedAgentLaunchPreflightDecisionKind,
        preflightDecisionMessage: String? = nil,
        inheritedSessionID: String? = nil,
        managedShimBypass: Bool = false,
        ownerRecordInInitialEnvironment: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) throws -> AgentShimRunResult {
        let process = Process()
        process.executableURL = shimLinkURL
        process.arguments = ["--typed-in-terminal"]

        var environment = ProcessInfo.processInfo.environment
        var pathEntries = [
            shimLinkURL.deletingLastPathComponent().path,
        ]
        if includeRealBinInInitialPath {
            pathEntries.append(realBinURL.path)
        }
        pathEntries.append(contentsOf: ["/usr/bin", "/bin"])
        environment["PATH"] = pathEntries.joined(separator: ":")
        environment["PWD"] = "/tmp/repo"
        environment[ToasttyLaunchContextEnvironment.cliPathKey] = fakeCLIURL.path
        environment[ToasttyLaunchContextEnvironment.panelIDKey] = panelID.uuidString
        environment[ToasttyLaunchContextEnvironment.sessionIDKey] = inheritedSessionID
        environment[ToasttyLaunchContextEnvironment.agentBasePathKey] = nil
        environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey] = shimDirectoryURL.path
        environment[ToasttyLaunchContextEnvironment.managedAgentShimBypassKey] = managedShimBypass ? "1" : nil
        environment[ToasttyLaunchContextEnvironment.managedAgentArtifactOwnerFileKey] =
            ownerRecordInInitialEnvironment ? ownerRecordURL.path : nil
        environment["ZDOTDIR"] = rootURL.path
        if includeRealBinInInitialPath == false {
            // Bash reads its login profile from HOME; isolate the child shell
            // just as ZDOTDIR isolates zsh, without touching the user's files.
            environment["HOME"] = rootURL.path
        }
        environment["TOASTTY_LOG_DISABLE"] = "1"
        environment["TOASTTY_FAKE_CLI_LOG"] = cliLogURL.path
        environment["TOASTTY_FAKE_AGENT_LOG"] = agentLogURL.path
        environment["TOASTTY_FAKE_OWNER_FILE"] = ownerRecordURL.path
        environment["TOASTTY_FAKE_PREFLIGHT_DECISION"] = preflightDecision.rawValue
        environment["TOASTTY_FAKE_PREFLIGHT_DECISION_MESSAGE"] = preflightDecisionMessage
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
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

    func recordedOwnerPID() throws -> Int32 {
        let value = try fileContentsIfPresent(at: ownerRecordURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int32(value))
    }

    func spawnedAgentPID() throws -> Int32 {
        let line = try #require(
            agentLogContents().split(separator: "\n").first { $0.hasPrefix("pid=") }
        )
        return try #require(Int32(line.dropFirst("pid=".count)))
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
            "TOASTTY_REPO_ROOT": "/tmp/repo",
            "TOASTTY_MANAGED_ARTIFACT_OWNER_FILE": "$TOASTTY_FAKE_OWNER_FILE"
          }
        }
        JSON
          exit 0
        fi

        if [ "${1:-}" = "agent" ] && [ "${2:-}" = "managed-launch-preflight-decision" ]; then
          if [ -n "${TOASTTY_FAKE_PREFLIGHT_DECISION_MESSAGE:-}" ]; then
            printf '{"kind":"%s","message":"%s"}\\n' "${TOASTTY_FAKE_PREFLIGHT_DECISION:-runAnyway}" "$TOASTTY_FAKE_PREFLIGHT_DECISION_MESSAGE"
            exit 0
          fi
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
          printf 'toastty_agent=%s\\n' "${TOASTTY_AGENT:-}"
          printf 'launch_reason=%s\\n' "${TOASTTY_LAUNCH_REASON:-}"
          printf 'toastty_cwd=%s\\n' "${TOASTTY_CWD:-}"
          printf 'repo_root=%s\\n' "${TOASTTY_REPO_ROOT:-}"
          printf 'socket_path=%s\\n' "${TOASTTY_SOCKET_PATH:-}"
          printf 'cli_path=%s\\n' "${TOASTTY_CLI_PATH:-}"
          printf 'shim_bypass=%s\\n' "${TOASTTY_MANAGED_AGENT_SHIM_BYPASS:-}"
          printf 'record_session=%s\\n' "${CODEX_TUI_RECORD_SESSION:-}"
          printf 'session_log=%s\\n' "${CODEX_TUI_SESSION_LOG_PATH:-}"
          printf 'pid=%s\\n' "$$"
          printf 'owner_file=%s\\n' "${TOASTTY_MANAGED_ARTIFACT_OWNER_FILE:-}"
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
