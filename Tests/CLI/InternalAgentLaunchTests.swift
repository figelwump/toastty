import CoreState
import Darwin
import Foundation
import Testing
@testable import ToasttyCLIKit

struct InternalAgentLaunchTests {
    @Test
    func parseBuildsInvocationWithChildCommand() throws {
        let panelID = UUID()
        let windowID = UUID()
        let workspaceID = UUID()

        let invocation = try InternalAgentLaunch.parse(arguments: [
            "--session", "sess-123",
            "--agent", "codex",
            "--panel", panelID.uuidString,
            "--window", windowID.uuidString,
            "--workspace", workspaceID.uuidString,
            "--socket-path", "/tmp/toastty.sock",
            "--cwd", "/repo",
            "--repo-root", "/repo",
            "--",
            "codex",
            "--help",
        ])

        #expect(invocation.sessionID == "sess-123")
        #expect(invocation.agent == .codex)
        #expect(invocation.panelID == panelID)
        #expect(invocation.windowID == windowID)
        #expect(invocation.workspaceID == workspaceID)
        #expect(invocation.socketPath == "/tmp/toastty.sock")
        #expect(invocation.cwd == "/repo")
        #expect(invocation.repoRoot == "/repo")
        #expect(invocation.childArguments == ["codex", "--help"])
    }

    @Test
    func launcherEmitsSessionStartAndStopAroundChildProcess() throws {
        let socketPath = "/tmp/toastty-internal-launch-\(UUID().uuidString.prefix(8)).sock"
        let listeningSocket = try makeListeningSocket(at: socketPath)
        defer {
            close(listeningSocket)
            unlink(socketPath)
        }

        let capturedEvents = CapturedEventsBox()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completion.signal() }
            capturedEvents.value = (try? captureEvents(expectedCount: 2, listeningSocket: listeningSocket)) ?? []
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-internal-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let scriptPath = tempDirectory.appendingPathComponent("capture-env.sh").path
        let outputPath = tempDirectory.appendingPathComponent("env.txt").path
        try writeScript(at: scriptPath)

        let panelID = UUID()
        let windowID = UUID()
        let workspaceID = UUID()
        let exitCode = ToasttyCLI.run(
            arguments: [
                ToasttyInternalCommand.agentLaunch,
                "--session", "sess-launch",
                "--agent", "claude",
                "--panel", panelID.uuidString,
                "--window", windowID.uuidString,
                "--workspace", workspaceID.uuidString,
                "--socket-path", socketPath,
                "--cwd", "/repo/project",
                "--repo-root", "/repo",
                "--",
                "/bin/sh",
                scriptPath,
                outputPath,
            ],
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ]
        )

        #expect(exitCode == 0)
        #expect(completion.wait(timeout: .now() + 2) == .success)
        #expect(capturedEvents.value.count == 2)

        let startEvent = capturedEvents.value[0]
        #expect(startEvent.eventType == "session.start")
        #expect(startEvent.sessionID == "sess-launch")
        #expect(startEvent.panelID == panelID.uuidString)
        #expect(startEvent.payload.string("agent") == "claude")
        #expect(startEvent.payload.string("cwd") == "/repo/project")
        #expect(startEvent.payload.string("repoRoot") == "/repo")

        let stopEvent = capturedEvents.value[1]
        #expect(stopEvent.eventType == "session.stop")
        #expect(stopEvent.sessionID == "sess-launch")
        #expect(stopEvent.panelID == panelID.uuidString)

        let outputLines = try String(contentsOfFile: outputPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(outputLines.count >= 7)
        #expect(outputLines[0] == "claude")
        #expect(outputLines[1] == "sess-launch")
        #expect(outputLines[2] == panelID.uuidString)
        #expect(outputLines[3] == socketPath)
        #expect(outputLines[4] == "/repo/project")
        #expect(outputLines[5] == "/repo")
        #expect(outputLines[6].isEmpty == false)
    }
}

private func writeScript(at path: String) throws {
    let script = """
    #!/bin/sh
    output_path="$1"
    {
      printf '%s\\n' "$TOASTTY_AGENT"
      printf '%s\\n' "$TOASTTY_SESSION_ID"
      printf '%s\\n' "$TOASTTY_PANEL_ID"
      printf '%s\\n' "$TOASTTY_SOCKET_PATH"
      printf '%s\\n' "$TOASTTY_CWD"
      printf '%s\\n' "$TOASTTY_REPO_ROOT"
      printf '%s\\n' "$TOASTTY_CLI_PATH"
    } > "$output_path"
    """
    try script.write(toFile: path, atomically: true, encoding: .utf8)
}

private func captureEvents(expectedCount: Int, listeningSocket: Int32) throws -> [AutomationEventEnvelope] {
    var events: [AutomationEventEnvelope] = []
    for _ in 0..<expectedCount {
        let clientFD = accept(listeningSocket, nil, nil)
        guard clientFD >= 0 else {
            throw SocketCaptureError.acceptFailed
        }
        defer { close(clientFD) }

        let payload = try readLine(from: clientFD)
        let envelope = try JSONDecoder().decode(AutomationEventEnvelope.self, from: payload)
        events.append(envelope)

        let response = AutomationResponseEnvelope(
            requestID: envelope.requestID ?? UUID().uuidString,
            ok: true,
            result: [:],
            error: nil
        )
        let responseData = try JSONEncoder().encode(response) + Data([0x0A])
        try responseData.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var totalBytesWritten = 0
            while totalBytesWritten < buffer.count {
                let bytesWritten = write(clientFD, baseAddress.advanced(by: totalBytesWritten), buffer.count - totalBytesWritten)
                guard bytesWritten > 0 else {
                    throw SocketCaptureError.writeFailed
                }
                totalBytesWritten += bytesWritten
            }
        }
    }
    return events
}

private func readLine(from fileDescriptor: Int32) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let bytesRead = read(fileDescriptor, &byte, 1)
        guard bytesRead >= 0 else {
            throw SocketCaptureError.readFailed
        }
        if bytesRead == 0 {
            throw SocketCaptureError.unexpectedEOF
        }
        if byte == 0x0A {
            return data
        }
        data.append(byte)
    }
}

private func makeListeningSocket(at socketPath: String) throws -> Int32 {
    unlink(socketPath)

    let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
        throw SocketCaptureError.socketCreationFailed
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        pathBytes.withUnsafeBytes { source in
            if let destination = buffer.baseAddress, let source = source.baseAddress {
                memcpy(destination, source, pathBytes.count)
            }
        }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(serverFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        close(serverFD)
        throw SocketCaptureError.bindFailed
    }

    guard listen(serverFD, 4) == 0 else {
        close(serverFD)
        throw SocketCaptureError.listenFailed
    }
    return serverFD
}

private enum SocketCaptureError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case acceptFailed
    case readFailed
    case writeFailed
    case unexpectedEOF
}

private final class CapturedEventsBox: @unchecked Sendable {
    var value: [AutomationEventEnvelope] = []
}
