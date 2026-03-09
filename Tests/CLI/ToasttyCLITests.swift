import CoreState
import Darwin
import Foundation
import Testing
@testable import ToasttyCLIKit

struct ToasttyCLITests {
    @Test
    func agentRunParsesProfileAndLaunchContext() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "run", "codex",
                "--session", "sess-123",
                "--panel", panelID.uuidString,
            ],
            environment: [:]
        )

        guard case .agentRun(let command) = invocation.command else {
            Issue.record("expected agent run command")
            return
        }

        #expect(command.profileID == "codex")
        #expect(command.sessionID == "sess-123")
        #expect(command.panelID == panelID)
    }

    @Test
    func agentRunPreparesResolvedProfileWithToasttyContext() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        let agentsFileURL = AgentProfilesFile.fileURL(homeDirectoryPath: tempHome.path)
        try FileManager.default.createDirectory(at: agentsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [codex]
        displayName = "Codex"
        argv = ["codex", "--model", "gpt-5-codex"]
        """.write(to: agentsFileURL, atomically: true, encoding: .utf8)

        let panelID = UUID()
        let prepared = try AgentRunCommandRunner.prepareProcess(
            command: AgentRunCommand(profileID: "codex", sessionID: "sess-123", panelID: panelID),
            socketPath: "/tmp/toastty.sock",
            environment: ["PATH": "/usr/bin"],
            homeDirectoryPath: tempHome.path,
            currentDirectoryPath: "/tmp/project",
            executablePath: "/Applications/Toastty.app/Contents/MacOS/toastty"
        )

        #expect(prepared.argv == ["codex", "--model", "gpt-5-codex"])
        #expect(prepared.environment["TOASTTY_AGENT"] == "codex")
        #expect(prepared.environment["TOASTTY_SESSION_ID"] == "sess-123")
        #expect(prepared.environment["TOASTTY_PANEL_ID"] == panelID.uuidString)
        #expect(prepared.environment["TOASTTY_SOCKET_PATH"] == "/tmp/toastty.sock")
        #expect(prepared.environment["TOASTTY_CLI_PATH"] == "/Applications/Toastty.app/Contents/MacOS/toastty")
        #expect(prepared.environment["TOASTTY_CWD"] == "/tmp/project")
    }

    @Test
    func agentRunRejectsMissingLaunchContext() {
        do {
            _ = try ToasttyCLI.parse(
                arguments: [
                    "agent", "run", "codex",
                ],
                environment: [:]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("--session is required"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func agentRunCanResolveLaunchContextFromEnvironment() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "run", "codex",
            ],
            environment: [
                "TOASTTY_SESSION_ID": "sess-env",
                "TOASTTY_PANEL_ID": panelID.uuidString,
            ]
        )

        guard case .agentRun(let command) = invocation.command else {
            Issue.record("expected agent run command")
            return
        }

        #expect(command.sessionID == "sess-env")
        #expect(command.panelID == panelID)
    }

    @Test
    func sessionStartGeneratesSessionIDWhenOmitted() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "start",
                "--agent", "codex",
                "--panel", panelID.uuidString,
            ],
            environment: [
                "TOASTTY_SOCKET_PATH": "/tmp/toastty-cli.sock",
            ]
        )

        #expect(invocation.options.socketPath == "/tmp/toastty-cli.sock")

        guard case .sessionStart(let sessionID, let agent, let parsedPanelID, let cwd, let repoRoot) = invocation.command else {
            Issue.record("expected session start command")
            return
        }

        #expect(UUID(uuidString: sessionID) != nil)
        #expect(agent == .codex)
        #expect(parsedPanelID == panelID)
        #expect(cwd == nil)
        #expect(repoRoot == nil)
    }

    @Test
    func sessionStatusBuildsStructuredStatusCommand() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "--json",
                "session", "status",
                "--session", "sess-123",
                "--panel", panelID.uuidString,
                "--kind", "needs_approval",
                "--summary", "needs approval",
                "--detail", "Approve applying the migration?",
            ],
            environment: [:]
        )

        #expect(invocation.options.jsonOutput)

        guard case .sessionStatus(let sessionID, let parsedPanelID, let kind, let summary, let detail) = invocation.command else {
            Issue.record("expected session status command")
            return
        }

        #expect(sessionID == "sess-123")
        #expect(parsedPanelID == panelID)
        #expect(kind == .needsApproval)
        #expect(summary == "needs approval")
        #expect(detail == "Approve applying the migration?")
    }

    @Test
    func sessionStatusFallsBackToLaunchContextEnvironment() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "status",
                "--kind", "working",
                "--summary", "editing 3 files",
            ],
            environment: [
                "TOASTTY_SESSION_ID": "sess-env",
                "TOASTTY_PANEL_ID": panelID.uuidString,
            ]
        )

        guard case .sessionStatus(let sessionID, let parsedPanelID, let kind, let summary, let detail) = invocation.command else {
            Issue.record("expected session status command")
            return
        }

        #expect(sessionID == "sess-env")
        #expect(parsedPanelID == panelID)
        #expect(kind == .working)
        #expect(summary == "editing 3 files")
        #expect(detail == nil)
    }

    @Test
    func sessionStartAcceptsCustomAgentIDs() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "start",
                "--agent", "gemini",
                "--panel", panelID.uuidString,
            ],
            environment: [:]
        )

        guard case .sessionStart(_, let agent, let parsedPanelID, _, _) = invocation.command else {
            Issue.record("expected session start command")
            return
        }

        #expect(agent.rawValue == "gemini")
        #expect(parsedPanelID == panelID)
    }

    @Test
    func sessionStopCanOmitPanelWhenOnlySessionEnvironmentIsAvailable() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "stop",
            ],
            environment: [
                "TOASTTY_SESSION_ID": "sess-env",
            ]
        )

        guard case .sessionStop(let sessionID, let panelID, let reason) = invocation.command else {
            Issue.record("expected session stop command")
            return
        }

        #expect(sessionID == "sess-env")
        #expect(panelID == nil)
        #expect(reason == nil)
    }

    @Test
    func sessionStatusRejectsInvalidLaunchContextPanelID() {
        do {
            _ = try ToasttyCLI.parse(
                arguments: [
                    "session", "status",
                    "--kind", "working",
                    "--summary", "editing 3 files",
                ],
                environment: [
                    "TOASTTY_SESSION_ID": "sess-env",
                    "TOASTTY_PANEL_ID": "not-a-uuid",
                ]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("TOASTTY_PANEL_ID must be a UUID"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func updateFilesRequiresAtLeastOneFile() {
        let panelID = UUID().uuidString

        do {
            _ = try ToasttyCLI.parse(
                arguments: [
                    "session", "update-files",
                    "--session", "sess-123",
                    "--panel", panelID,
                ],
                environment: [:]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("at least one --file"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func updateFilesRejectsEmptyFileValues() {
        let panelID = UUID().uuidString

        do {
            _ = try ToasttyCLI.parse(
                arguments: [
                    "session", "update-files",
                    "--session", "sess-123",
                    "--panel", panelID,
                    "--file", "",
                ],
                environment: [:]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("does not allow empty --file"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func notifyParsesOptionalRoutingFlags() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "notify",
                "Needs approval",
                "Approve applying the migration?",
                "--workspace", workspaceID.uuidString,
                "--panel", panelID.uuidString,
            ],
            environment: [:]
        )

        guard case .notify(let title, let body, let parsedWorkspaceID, let parsedPanelID) = invocation.command else {
            Issue.record("expected notify command")
            return
        }

        #expect(title == "Needs approval")
        #expect(body == "Approve applying the migration?")
        #expect(parsedWorkspaceID == workspaceID)
        #expect(parsedPanelID == panelID)
    }

    @Test
    func socketClientTimesOutWhenServerDoesNotReply() throws {
        let socketPath = "/tmp/toastty-cli-tests-\(UUID().uuidString.prefix(8)).sock"
        let serverFD = try makeListeningSocket(at: socketPath)
        defer {
            close(serverFD)
            unlink(socketPath)
        }

        DispatchQueue.global().async {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                return
            }
            usleep(300_000)
            close(clientFD)
        }

        let client = ToasttySocketClient(socketPath: socketPath, timeoutInterval: 0.1)
        let envelope = AutomationEventEnvelope(
            eventType: "notification.emit",
            requestID: UUID().uuidString,
            payload: [
                "title": .string("Test"),
                "body": .string("Body"),
            ]
        )

        do {
            _ = try client.send(envelope)
            Issue.record("expected timeout error")
        } catch let error as ToasttyCLIError {
            guard case .runtime(let message) = error else {
                Issue.record("expected runtime error")
                return
            }
            #expect(message.contains("timed out"))
        }
    }
}

private func makeListeningSocket(at socketPath: String) throws -> Int32 {
    unlink(socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw CLITestSocketError.socket("socket() failed: \(String(cString: strerror(errno)))")
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= maxPathLength else {
        close(fd)
        throw CLITestSocketError.socket("socket path too long")
    }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        pathBytes.withUnsafeBytes { source in
            if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                memcpy(destinationAddress, sourceAddress, pathBytes.count)
            }
        }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        let message = String(cString: strerror(errno))
        close(fd)
        throw CLITestSocketError.socket("bind() failed: \(message)")
    }

    guard listen(fd, 1) == 0 else {
        let message = String(cString: strerror(errno))
        close(fd)
        throw CLITestSocketError.socket("listen() failed: \(message)")
    }

    return fd
}

private enum CLITestSocketError: Error {
    case socket(String)
}
