import Darwin
import Foundation
import Testing
@testable import CoreState

struct DiagnosticsCollectorTests {
    @Test
    func collectsFullLogsWithoutTruncating() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-logs")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        let logsDirectory = runtimeHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("toastty.log", isDirectory: false)
        let previousURL = logsDirectory.appendingPathComponent("toastty.previous.log", isDirectory: false)
        let currentContent = (0..<2_000).map { "line-\($0) café socket=/tmp/toastty/events.sock" }.joined(separator: "\n")
        let previousContent = "previous café line"
        try currentContent.write(to: logURL, atomically: true, encoding: .utf8)
        try previousContent.write(to: previousURL, atomically: true, encoding: .utf8)

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [
                ToasttyRuntimePaths.environmentKey: runtimeHome.path,
                "TMPDIR": root.appendingPathComponent("tmp", isDirectory: true).path + "/",
            ],
            homeDirectoryPath: root.path
        )

        #expect(bundle.logs.current.content == currentContent)
        #expect(bundle.logs.current.truncated == false)
        #expect(bundle.logs.previous.content == previousContent)
        #expect(bundle.logs.previous.truncated == false)
    }

    @Test
    func detectsSharedShellIntegrationMarker() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-shell")
        defer { try? FileManager.default.removeItem(at: root) }

        let zshSource = ToasttyShellIntegrationMarkers.sourceLine(
            managedSnippetFileName: "toastty-profile-shell-integration.zsh"
        )
        try zshSource.write(
            to: root.appendingPathComponent(".zshrc", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [:],
            homeDirectoryPath: root.path
        )

        let zshrc = try #require(bundle.shell.detectedShells.first { $0.name == "zsh" })
        #expect(zshrc.sourcingMarkerPresent)
    }

    @Test
    func corruptInstanceJSONIsRecordedAsUnavailable() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-instance")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        try "{".write(
            to: runtimeHome.appendingPathComponent("instance.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path],
            homeDirectoryPath: root.path
        )

        #expect(bundle.app.instanceStatus.status == "unavailable")
        #expect(bundle.app.instanceStatus.detail?.contains("failed to read instance.json") == true)
        #expect(bundle.app.infoPlistStatus.detail == "app bundle path is unknown")
    }

    @Test
    func shellEnvironmentIncludesToasttyValuesAndNamesOnlyForOtherKeys() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-env")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [
                "PATH": "/bin:/usr/bin",
                "TOASTTY_SOCKET_PATH": "/tmp/socket.sock",
                "OPENAI_API_KEY": "secret",
            ],
            homeDirectoryPath: root.path
        )

        #expect(bundle.shell.environment.contains(DiagnosticsEnvironmentEntry(name: "PATH", value: "/bin:/usr/bin")))
        #expect(bundle.shell.environment.contains(DiagnosticsEnvironmentEntry(name: "TOASTTY_SOCKET_PATH", value: "/tmp/socket.sock")))
        #expect(bundle.shell.otherEnvironmentNames.contains("OPENAI_API_KEY"))
        #expect(bundle.shell.environment.contains(where: { $0.name == "OPENAI_API_KEY" }) == false)
    }
}

private func noSocketResult() -> DiagnosticsSocketProbeResult {
    DiagnosticsSocketProbeResult(
        socketPath: "/tmp/toastty-\(getuid())/events-v1.sock",
        pathSource: .legacy,
        state: .noSocket,
        stat: DiagnosticsSocketStat(exists: false, isSocket: false, mode: nil, ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil),
        instancePID: nil,
        instancePIDAlive: nil,
        connect: DiagnosticsSocketConnectResult(status: "not-found", errnoCode: nil, error: nil, latencyMs: nil),
        ping: nil,
        currentSocketRecord: nil,
        competingSockets: []
    )
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
