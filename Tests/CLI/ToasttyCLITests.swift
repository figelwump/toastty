import CoreState
import Darwin
import Foundation
import Testing
@testable import ToasttyCLIKit

struct ToasttyCLITests {
    @Test
    func actionListParsesStructuredCommand() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["action", "list"],
            environment: [:]
        )

        guard case .appControlList(let kind) = invocation.command else {
            Issue.record("expected app control list command")
            return
        }

        #expect(kind == .action)
    }

    @Test
    func actionRunParsesSelectorsAndRepeatableValues() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "action", "run", "terminal.drop-image-files",
                "--window", windowID.uuidString,
                "--workspace", workspaceID.uuidString,
                "files=/tmp/a.png",
                "files=/tmp/b.png",
                "cwd=/tmp",
                "allowUnavailable=true",
            ],
            environment: [:]
        )

        guard case .appControlRun(let kind, let id, let args) = invocation.command else {
            Issue.record("expected app control run command")
            return
        }

        #expect(kind == .action)
        #expect(id == "terminal.drop-image-files")
        #expect(args["windowID"] == .string(windowID.uuidString))
        #expect(args["workspaceID"] == .string(workspaceID.uuidString))
        #expect(args["files"] == .array([.string("/tmp/a.png"), .string("/tmp/b.png")]))
        #expect(args["cwd"] == .string("/tmp"))
        #expect(args["allowUnavailable"] == .string("true"))
    }

    @Test
    func actionRunParsesRepeatableInitialCommands() throws {
        let workspaceID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "action", "run", "agent.launch",
                "--workspace", workspaceID.uuidString,
                "profileID=codex",
                "cwd=/tmp/worktree",
                "initialCommands=direnv allow",
                "initialCommands=printf ready",
                "initialPrompt=/work-on POP-1234",
            ],
            environment: [:]
        )

        guard case .appControlRun(let kind, let id, let args) = invocation.command else {
            Issue.record("expected app control run command")
            return
        }

        #expect(kind == .action)
        #expect(id == "agent.launch")
        #expect(args["workspaceID"] == .string(workspaceID.uuidString))
        #expect(args["profileID"] == .string("codex"))
        #expect(args["cwd"] == .string("/tmp/worktree"))
        #expect(args["initialCommands"] == .array([.string("direnv allow"), .string("printf ready")]))
        #expect(args["initialPrompt"] == .string("/work-on POP-1234"))
    }

    @Test
    func queryRunParsesStructuredCommand() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "query", "run", "terminal.visible-text",
                "--panel", panelID.uuidString,
                "contains=needle",
            ],
            environment: [:]
        )

        guard case .appControlRun(let kind, let id, let args) = invocation.command else {
            Issue.record("expected app control query run command")
            return
        }

        #expect(kind == .query)
        #expect(id == "terminal.visible-text")
        #expect(args["panelID"] == .string(panelID.uuidString))
        #expect(args["contains"] == .string("needle"))
    }

    @Test
    func actionRunRejectsMalformedKeyValueArguments() {
        do {
            _ = try ToasttyCLI.parse(
                arguments: [
                    "action", "run", "workspace.rename",
                    "title",
                ],
                environment: [:]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("expected key=value"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func agentPrepareManagedLaunchBuildsStructuredRequest() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "prepare-managed-launch",
                "--agent", "codex",
                "--panel", panelID.uuidString,
                "--cwd", "/tmp/repo",
                "--arg", "codex",
                "--arg", "--model",
                "--arg", "gpt-5.4",
            ],
            environment: [:]
        )

        guard case .agentPrepareManagedLaunch(let request) = invocation.command else {
            Issue.record("expected managed launch preparation command")
            return
        }

        #expect(request.agent == .codex)
        #expect(request.panelID == panelID)
        #expect(request.cwd == "/tmp/repo")
        #expect(request.argv == ["codex", "--model", "gpt-5.4"])
        #expect(request.environment.isEmpty)
        #expect(request.preflightPolicy == .skip)
    }

    @Test
    func agentPrepareManagedLaunchParsesInteractivePreflightPolicy() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "prepare-managed-launch",
                "--agent", "codex",
                "--panel", panelID.uuidString,
                "--preflight-policy", "interactive",
                "--arg", "codex",
            ],
            environment: [:]
        )

        guard case .agentPrepareManagedLaunch(let request) = invocation.command else {
            Issue.record("expected managed launch preparation command")
            return
        }

        #expect(request.preflightPolicy == .interactive)
    }

    @Test
    func agentPrepareManagedLaunchCapturesOpenCodeConfigContentEnvironment() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "prepare-managed-launch",
                "--agent", "opencode",
                "--panel", panelID.uuidString,
                "--arg", "opencode",
            ],
            environment: [
                "OPENCODE_CONFIG_CONTENT": #"{"plugin":["user-plugin"]}"#,
                "MIMOCODE_CONFIG_CONTENT": #"{"plugin":["mimo-plugin"]}"#,
                "PATH": "/usr/bin",
            ]
        )

        guard case .agentPrepareManagedLaunch(let request) = invocation.command else {
            Issue.record("expected managed launch preparation command")
            return
        }

        #expect(request.agent == .opencode)
        #expect(request.environment == [
            "OPENCODE_CONFIG_CONTENT": #"{"plugin":["user-plugin"]}"#,
        ])
    }

    @Test
    func agentPrepareManagedLaunchCapturesMiMoConfigContentEnvironment() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "prepare-managed-launch",
                "--agent", "mimocode",
                "--panel", panelID.uuidString,
                "--arg", "mimo",
            ],
            environment: [
                "MIMOCODE_CONFIG_CONTENT": #"{"plugin":["mimo-plugin"]}"#,
                "OPENCODE_CONFIG_CONTENT": #"{"plugin":["open-plugin"]}"#,
            ]
        )

        guard case .agentPrepareManagedLaunch(let request) = invocation.command else {
            Issue.record("expected managed launch preparation command")
            return
        }

        #expect(request.agent == .mimocode)
        #expect(request.environment == [
            "MIMOCODE_CONFIG_CONTENT": #"{"plugin":["mimo-plugin"]}"#,
        ])
    }

    @Test
    func agentManagedLaunchPreflightDecisionParsesToken() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "agent", "managed-launch-preflight-decision",
                "--token", "preflight-token",
            ],
            environment: [:]
        )

        guard case .agentManagedLaunchPreflightDecision(let token) = invocation.command else {
            Issue.record("expected managed launch preflight decision command")
            return
        }

        #expect(token == "preflight-token")
    }

    @Test
    func diagnosticsCollectParsesOptions() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "diagnostics", "collect",
                "--shell-probe", "/tmp/probe.txt",
                "--note", "socket failed",
                "--out", "/tmp/toastty-diag.json",
            ],
            environment: ["TMPDIR": "/tmp/toastty-cli-tests/"]
        )

        guard case .diagnosticsCollect(let options) = invocation.command else {
            Issue.record("expected diagnostics collect command")
            return
        }

        #expect(options.shellProbePath == "/tmp/probe.txt")
        #expect(options.note == "socket failed")
        #expect(options.outputPath == "/tmp/toastty-diag.json")
    }

    @Test
    func diagnosticsCollectDefaultsOutputPathUnderTMPDIR() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["diagnostics", "collect"],
            environment: ["TMPDIR": "/tmp/toastty-cli-tests/"]
        )

        guard case .diagnosticsCollect(let options) = invocation.command else {
            Issue.record("expected diagnostics collect command")
            return
        }

        #expect(options.outputPath.hasPrefix("/tmp/toastty-cli-tests/toastty-diag-"))
        #expect(options.outputPath.hasSuffix(".json"))
    }

    @Test
    func diagnosticsCollectWritesRedactedBundleWithoutLiveSocket() throws {
        let root = try makeCLITemporaryDirectory(prefix: "toastty-cli-diag")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        let temp = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let probeURL = root.appendingPathComponent("probe.txt", isDirectory: false)
        let outputURL = root.appendingPathComponent("diag.json", isDirectory: false)
        try """
        PATH=/Users/vishal/.toastty/bin:/usr/bin
        TOASTTY_SOCKET_PATH=/tmp/toastty/events-v1.sock
        OPENAI_API_KEY=sk-test_abcdefghijklmnopqrstuvwxyz
        """.write(to: probeURL, atomically: true, encoding: .utf8)

        let exitCode = ToasttyCLI.run(
            arguments: [
                "diagnostics", "collect",
                "--shell-probe", probeURL.path,
                "--note", "note contains sk-test_abcdefghijklmnopqrstuvwxyz",
                "--out", outputURL.path,
            ],
            environment: [
                "HOME": root.path,
                ToasttyRuntimePaths.environmentKey: runtimeHome.path,
                "TMPDIR": temp.path + "/",
            ]
        )

        #expect(exitCode == 0)
        let data = try Data(contentsOf: outputURL)
        let bundle = try JSONDecoder().decode(DiagnosticsBundle.self, from: data)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(bundle.socket.state == .noSocket)
        #expect(bundle.probe.rawShellProbe?.contains("/tmp/toastty/events-v1.sock") == true)
        #expect(bundle.probe.rawShellProbe?.contains("sk-test_abcdefghijklmnopqrstuvwxyz") == false)
        #expect(bundle.note?.contains("sk-test_abcdefghijklmnopqrstuvwxyz") == false)
        #expect(encoded.contains("\"redaction\""))
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
    func sessionStatusAcceptsIdleKind() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "status",
                "--session", "sess-123",
                "--kind", "idle",
                "--summary", "Waiting",
            ],
            environment: [:]
        )

        guard case .sessionStatus(_, _, let kind, let summary, let detail) = invocation.command else {
            Issue.record("expected session status command")
            return
        }

        #expect(kind == .idle)
        #expect(summary == "Waiting")
        #expect(detail == nil)
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
    func sessionIngestAgentEventFallsBackToLaunchContextEnvironment() throws {
        let panelID = UUID()
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "ingest-agent-event",
                "--source", "claude-hooks",
            ],
            environment: [
                "TOASTTY_SESSION_ID": "sess-env",
                "TOASTTY_PANEL_ID": panelID.uuidString,
            ]
        )

        guard case .sessionIngestAgentEvent(let sessionID, let parsedPanelID, let source) = invocation.command else {
            Issue.record("expected session ingest command")
            return
        }

        #expect(sessionID == "sess-env")
        #expect(parsedPanelID == panelID)
        #expect(source == .claudeHooks)
    }

    @Test
    func sessionIngestAgentEventAcceptsOpenCodeFamilySources() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: [
                "session", "ingest-agent-event",
                "--source", "mimocode-plugin",
            ],
            environment: [
                "TOASTTY_SESSION_ID": "sess-env",
            ]
        )

        guard case .sessionIngestAgentEvent(let sessionID, let parsedPanelID, let source) = invocation.command else {
            Issue.record("expected session ingest command")
            return
        }

        #expect(sessionID == "sess-env")
        #expect(parsedPanelID == nil)
        #expect(source == .mimocodePlugin)
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

private func makeCLITemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
