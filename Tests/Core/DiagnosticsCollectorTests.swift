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
    func collectsRecentCompleteLinesFromOversizedLogWithoutMutatingSource() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-log-tail")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        let logsDirectory = runtimeHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("toastty.log", isDirectory: false)
        let content = "first-marker\n"
            + String(repeating: "{\"message\":\"layout diagnostics\"}\n", count: 260_000)
            + "latest-marker\n"
        try Data(content.utf8).write(to: logURL)
        let originalData = try Data(contentsOf: logURL)
        let originalModifiedAt = try #require(
            FileManager.default.attributesOfItem(atPath: logURL.path)[.modificationDate] as? Date
        )

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path],
            homeDirectoryPath: root.path
        )

        let collected = try #require(bundle.logs.current.content)
        #expect(bundle.logs.current.sizeBytes == UInt64(originalData.count))
        #expect(bundle.logs.current.truncated)
        #expect(collected.utf8.count < originalData.count)
        #expect(collected.contains("latest-marker"))
        #expect(collected.contains("first-marker") == false)
        #expect(collected.hasPrefix("{\"message\":\"layout diagnostics\"}"))
        #expect(try Data(contentsOf: logURL) == originalData)
        let modifiedAtAfterCollection = try #require(
            FileManager.default.attributesOfItem(atPath: logURL.path)[.modificationDate] as? Date
        )
        #expect(modifiedAtAfterCollection == originalModifiedAt)
    }

    @Test
    func oversizedSingleLineLogIsSafelyOmitted() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-log-single-line")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        let logsDirectory = runtimeHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("toastty.log", isDirectory: false)
        try Data(repeating: 0x61, count: 8_000_001).write(to: logURL)

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path],
            homeDirectoryPath: root.path
        )

        #expect(bundle.logs.current.truncated)
        #expect(bundle.logs.current.sizeBytes == 8_000_001)
        #expect(bundle.logs.current.content == "")
        #expect(bundle.logs.current.readError == nil)
    }

    @Test
    func invalidUTF8LogBytesUseLossyDecoding() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-log-invalid-utf8")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        let logsDirectory = runtimeHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("toastty.log", isDirectory: false)
        try Data([0xFF, 0x0A]).write(to: logURL)

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path],
            homeDirectoryPath: root.path
        )

        #expect(bundle.logs.current.content == "�\n")
        #expect(bundle.logs.current.readError == nil)
        #expect(bundle.logs.current.truncated == false)
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

    @Test
    func collectsContentFreeWorkspaceLayoutSummaryWithoutMutatingStore() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-layout")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        let fileURL = runtimeHome.appendingPathComponent(
            "workspace-layout-profiles.json",
            isDirectory: false
        )
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        workspace.title = "Private project name"
        workspace.annotations = ["customer": WorkspaceAnnotation(text: "Secret account")]
        let panelID = try #require(workspace.focusedPanelID)
        guard case .terminal(var terminal) = workspace.panels[panelID] else {
            Issue.record("Expected bootstrap terminal panel")
            return
        }
        terminal.cwd = "/Users/example/private-project"
        workspace.panels[panelID] = .terminal(terminal)
        state.workspacesByID[workspaceID] = workspace
        #expect(
            WorkspaceLayoutPersistenceStore(fileURL: fileURL).persistLayout(
                WorkspaceLayoutSnapshot(state: state),
                for: "display-3456x2234@2x"
            )
        )
        let originalData = try Data(contentsOf: fileURL)
        let originalModifiedAt = try #require(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        )

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path],
            homeDirectoryPath: root.path
        )

        let layouts = try #require(bundle.workspaceLayouts)
        #expect(layouts.exists)
        #expect(layouts.status == .available)
        #expect(layouts.formatVersion == WorkspaceLayoutPersistenceStore.currentFormatVersion)
        let profile = try #require(layouts.profiles.first)
        #expect(profile.profileID == "display-3456x2234@2x")
        #expect(profile.windowCount == 1)
        #expect(profile.workspaceCount == 1)
        #expect(profile.tabCount == 1)
        #expect(profile.panelCount == 1)
        #expect(profile.fingerprint?.count == 64)
        #expect(profile.validationStatus == .available)

        let encodedSummary = String(decoding: try JSONEncoder().encode(layouts), as: UTF8.self)
        #expect(encodedSummary.contains("Private project name") == false)
        #expect(encodedSummary.contains("Secret account") == false)
        #expect(encodedSummary.contains("private-project") == false)
        #expect(try Data(contentsOf: fileURL) == originalData)
        let modifiedAtAfterCollection = try #require(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        )
        #expect(modifiedAtAfterCollection == originalModifiedAt)
    }

    @Test
    func recordsCorruptWorkspaceLayoutStoreAsUnavailable() throws {
        let root = try makeTemporaryDirectory(prefix: "diag-layout-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeHome = root.appendingPathComponent("runtime-home", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeHome, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: runtimeHome.appendingPathComponent(
                "workspace-layout-profiles.json",
                isDirectory: false
            )
        )

        let bundle = DiagnosticsCollector.collect(
            generatedAtMs: 1,
            note: nil,
            shellProbeFilePath: nil,
            socket: noSocketResult(),
            environment: [ToasttyRuntimePaths.environmentKey: runtimeHome.path],
            homeDirectoryPath: root.path
        )

        let layouts = try #require(bundle.workspaceLayouts)
        #expect(layouts.exists)
        #expect(layouts.status.status == "unavailable")
        #expect(layouts.status.detail?.contains("failed to read workspace layout file") == true)
        #expect(layouts.profiles.isEmpty)
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
