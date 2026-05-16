import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct ManagedAgentResumeResolverTests {
    @Test
    func resolveReturnsCodexResumeLaunchForValidRestoredRecord() throws {
        let fixture = try makeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let panelID = UUID()
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: panelID,
            terminalState: TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "",
                launchWorkingDirectory: "/tmp/stale",
                profileBinding: TerminalProfileBinding(profileID: "zmx"),
                resumeRecord: record
            ),
            launchReason: .restore,
            baseEnvironmentVariables: ["PATH": "/tmp/bin:/usr/bin"]
        )

        guard case .launch(let configuration) = resolution else {
            Issue.record("expected resume launch configuration")
            return
        }
        #expect(configuration.initialInput == "codex resume 019e2823-f520-7690-91b6-cd84eb52dd8a")
        #expect(configuration.workingDirectoryOverride == fixture.cwdURL.path)
        #expect(configuration.environmentVariables["PATH"] == "/tmp/bin:/usr/bin")
        #expect(configuration.environmentVariables["TOASTTY_PANEL_ID"] == panelID.uuidString)
        #expect(configuration.environmentVariables["TOASTTY_LAUNCH_REASON"] == "restore")
        #expect(configuration.environmentVariables["TOASTTY_MANAGED_AGENT_RESUME_PROVIDER"] == "codex")
    }

    @Test
    func resolveReturnsClaudeResumeLaunchForValidRestoredRecord() throws {
        let fixture = try makeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "db4f311b-12d0-4f61-ba81-0ae44ed10492",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: UUID(),
            terminalState: TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "",
                resumeRecord: record
            ),
            launchReason: .restore
        )

        guard case .launch(let configuration) = resolution else {
            Issue.record("expected resume launch configuration")
            return
        }
        #expect(configuration.initialInput == "claude --resume db4f311b-12d0-4f61-ba81-0ae44ed10492")
        #expect(configuration.workingDirectoryOverride == fixture.cwdURL.path)
    }

    @Test
    func resolveUsesConfiguredAgentProfileWrapperForResumeCommand() throws {
        let fixture = try makeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: UUID(),
            terminalState: TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "", resumeRecord: record),
            launchReason: .restore,
            agentCatalog: AgentCatalog(
                profiles: [
                    AgentProfile(
                        id: "codex",
                        displayName: "Codex",
                        argv: [
                            "agent-safehouse",
                            "--workdir=/tmp/repo",
                            "/opt/homebrew/bin/codex",
                            "--dangerously-bypass-approvals-and-sandbox",
                        ]
                    ),
                ]
            )
        )

        guard case .launch(let configuration) = resolution else {
            Issue.record("expected resume launch configuration")
            return
        }
        #expect(
            configuration.initialInput ==
                "agent-safehouse --workdir=/tmp/repo /opt/homebrew/bin/codex resume 019e2823-f520-7690-91b6-cd84eb52dd8a --dangerously-bypass-approvals-and-sandbox"
        )
    }

    @Test
    func resolveClearsMissingSessionFileBeforeFallingBack() throws {
        let fixture = try makeResumeFixture(createSessionFile: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: UUID(),
            terminalState: TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "", resumeRecord: record),
            launchReason: .restore
        )

        #expect(resolution == .clearRecord(reason: .missingSessionFile))
    }

    @Test
    func resolveClearsMissingWorkingDirectoryBeforeFallingBack() throws {
        let fixture = try makeResumeFixture(createCWD: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: UUID(),
            terminalState: TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "", resumeRecord: record),
            launchReason: .restore
        )

        #expect(resolution == .clearRecord(reason: .missingWorkingDirectory))
    }

    @Test
    func resolveIgnoresRecordsForFreshCreates() throws {
        let fixture = try makeResumeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: UUID(),
            terminalState: TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "", resumeRecord: record),
            launchReason: .create
        )

        #expect(resolution == .none)
    }

    @Test
    func resolveIgnoresUnsupportedAgentRecordsBeforeStorageValidation() throws {
        let fixture = try makeResumeFixture(createSessionFile: false, createCWD: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = ManagedAgentResumeRecord(
            agent: .pi,
            nativeSessionID: "pi-session",
            sessionFilePath: fixture.sessionFileURL.path,
            cwd: fixture.cwdURL.path,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let resolution = ManagedAgentResumeResolver.resolve(
            panelID: UUID(),
            terminalState: TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "", resumeRecord: record),
            launchReason: .restore
        )

        #expect(resolution == .none)
    }
}

private func makeResumeFixture(
    createSessionFile: Bool = true,
    createCWD: Bool = true
) throws -> (rootURL: URL, cwdURL: URL, sessionFileURL: URL) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-resume-resolver-\(UUID().uuidString)", isDirectory: true)
    let cwdURL = rootURL.appendingPathComponent("repo", isDirectory: true)
    let sessionFileURL = rootURL.appendingPathComponent("session.jsonl", isDirectory: false)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    if createCWD {
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
    }
    if createSessionFile {
        try Data("{}".utf8).write(to: sessionFileURL)
    }
    return (rootURL, cwdURL, sessionFileURL)
}
