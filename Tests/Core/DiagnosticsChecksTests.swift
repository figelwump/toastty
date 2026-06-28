import Foundation
import Testing
@testable import CoreState

struct DiagnosticsChecksTests {
    @Test
    func userHomeRuntimeAndHealthySocketPass() throws {
        let report = DiagnosticsCheckEvaluator.evaluate(
            diagnosticsBundle(
                socket: socketResult(state: .healthy),
                shell: shellSection(markerPresent: true),
                shimDirectory: shimDirectory(entries: [
                    DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
                ]),
                logs: logsSection(currentExists: true)
            )
        )

        #expect(report.overallStatus == .pass)
        #expect(report.summary.fail == 0)
        #expect(report.checks.first { $0.id == "app-runtime" }?.status == .pass)
        #expect(report.checks.first { $0.id == "automation-socket" }?.status == .pass)
    }

    @Test
    func missingEnvironmentSocketFailsWithTargetedRemediation() throws {
        let report = DiagnosticsCheckEvaluator.evaluate(
            diagnosticsBundle(
                socket: socketResult(state: .noSocket, pathSource: .environment),
                shell: shellSection(markerPresent: true),
                shimDirectory: shimDirectory(entries: [
                    DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
                ]),
                logs: logsSection(currentExists: true)
            )
        )

        let socket = try #require(report.checks.first { $0.id == "automation-socket" })
        #expect(report.overallStatus == .fail)
        #expect(report.summary.fail == 1)
        #expect(socket.status == .fail)
        #expect(socket.remediation?.contains("TOASTTY_SOCKET_PATH") == true)
    }

    @Test
    func missingShellIntegrationWarnsWithoutFailing() throws {
        let report = DiagnosticsCheckEvaluator.evaluate(
            diagnosticsBundle(
                socket: socketResult(state: .healthy),
                shell: shellSection(markerPresent: false),
                shimDirectory: shimDirectory(entries: [
                    DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
                ]),
                logs: logsSection(currentExists: true)
            )
        )

        let shell = try #require(report.checks.first { $0.id == "shell-integration" })
        #expect(report.overallStatus == .warn)
        #expect(report.summary.fail == 0)
        #expect(shell.status == .warn)
        #expect(shell.remediation?.contains("Install Shell Integration") == true)
    }

    @Test
    func reportDoesNotIncludeRawLogsOrProbeContent() throws {
        var bundle = diagnosticsBundle(
            socket: socketResult(state: .healthy),
            shell: shellSection(markerPresent: true),
            shimDirectory: shimDirectory(entries: [
                DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
            ]),
            logs: logsSection(currentExists: true)
        )
        bundle.logs.current.content = "raw-log-secret"
        bundle.probe.rawShellProbe = "raw-probe-secret"

        let report = DiagnosticsCheckEvaluator.evaluate(bundle)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        #expect(encoded.contains("raw-log-secret") == false)
        #expect(encoded.contains("raw-probe-secret") == false)
    }

    @Test
    func failedRuntimePIDAndSocketStatesHaveConcreteRemediation() throws {
        var deadPIDBundle = diagnosticsBundle(
            socket: socketResult(state: .healthy),
            shell: shellSection(markerPresent: true),
            shimDirectory: shimDirectory(entries: [
                DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
            ]),
            logs: logsSection(currentExists: true)
        )
        deadPIDBundle.app.pid = 12345
        deadPIDBundle.app.pidAlive = false

        let deadPID = try #require(DiagnosticsCheckEvaluator.evaluate(deadPIDBundle).checks.first { $0.id == "app-runtime" })
        #expect(deadPID.status == .fail)
        #expect(deadPID.remediation?.contains("Quit and reopen Toastty") == true)

        for state in [DiagnosticsSocketState.refused, .timeout, .stale] {
            let report = DiagnosticsCheckEvaluator.evaluate(
                diagnosticsBundle(
                    socket: socketResult(state: state),
                    shell: shellSection(markerPresent: true),
                    shimDirectory: shimDirectory(entries: [
                        DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
                    ]),
                    logs: logsSection(currentExists: true)
                )
            )
            let socket = try #require(report.checks.first { $0.id == "automation-socket" })
            #expect(socket.status == .fail)
            #expect(socket.remediation?.isEmpty == false)
        }
    }

    @Test
    func logCheckDistinguishesDisabledLoggingFromNoConfiguredFile() throws {
        var disabled = logsSection(currentExists: false)
        disabled.configSummary["enabled"] = "false"
        var noFile = logsSection(currentExists: false)
        noFile.configSummary["file_path"] = ""

        let disabledReport = DiagnosticsCheckEvaluator.evaluate(
            diagnosticsBundle(
                socket: socketResult(state: .healthy),
                shell: shellSection(markerPresent: true),
                shimDirectory: shimDirectory(entries: [
                    DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
                ]),
                logs: disabled
            )
        )
        let noFileReport = DiagnosticsCheckEvaluator.evaluate(
            diagnosticsBundle(
                socket: socketResult(state: .healthy),
                shell: shellSection(markerPresent: true),
                shimDirectory: shimDirectory(entries: [
                    DiagnosticsDirectoryEntry(name: "codex", isDirectory: false, isExecutable: true, sizeBytes: 12),
                ]),
                logs: noFile
            )
        )

        #expect(disabledReport.checks.first { $0.id == "logs" }?.summary == "Logging is disabled by configuration.")
        #expect(noFileReport.checks.first { $0.id == "logs" }?.summary == "No log file is configured.")
    }
}

private func diagnosticsBundle(
    socket: DiagnosticsSocketProbeResult,
    shell: DiagnosticsShellSection,
    shimDirectory: DiagnosticsDirectoryListing,
    logs: DiagnosticsLogsSection
) -> DiagnosticsBundle {
    DiagnosticsBundle(
        generatedAtMs: 1_800_000_000_000,
        note: nil,
        app: DiagnosticsAppSection(
            shortVersion: nil,
            build: nil,
            bundlePath: nil,
            executablePath: nil,
            runtimeHomePath: nil,
            runtimeHomeStrategy: ToasttyRuntimeHomeStrategy.userHome.rawValue,
            runtimeLabel: nil,
            isDevWorktree: false,
            pid: nil,
            pidAlive: nil,
            runID: nil,
            instanceFilePath: nil,
            instanceStatus: .unavailable("runtime instance manifest is unavailable for user-home runtime"),
            infoPlistStatus: .unavailable("app bundle path is unknown")
        ),
        logs: logs,
        shell: DiagnosticsShellSection(
            detectedShells: shell.detectedShells,
            shimDirectory: shimDirectory,
            environment: shell.environment,
            otherEnvironmentNames: shell.otherEnvironmentNames
        ),
        system: DiagnosticsSystemSection(macosVersion: "Version 15.0", hardwareModel: "Mac16,1", arch: "arm64"),
        socket: socket,
        probe: DiagnosticsProbeSection(shellProbePath: nil, rawShellProbe: nil, readError: nil),
        redaction: nil
    )
}

private func socketResult(
    state: DiagnosticsSocketState,
    pathSource: DiagnosticsSocketPathSource = .runtimeHome
) -> DiagnosticsSocketProbeResult {
    let connect: DiagnosticsSocketConnectResult
    let ping: DiagnosticsSocketPingResult?
    let stat: DiagnosticsSocketStat
    switch state {
    case .healthy:
        connect = DiagnosticsSocketConnectResult(status: "connected", errnoCode: nil, error: nil, latencyMs: 1)
        ping = DiagnosticsSocketPingResult(
            ok: true,
            latencyMs: 1,
            automationEnabled: true,
            appUptimeMs: 100,
            protocolVersion: "1.0",
            error: nil
        )
        stat = DiagnosticsSocketStat(exists: true, isSocket: true, mode: "0700", ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil)
    case .noSocket:
        connect = DiagnosticsSocketConnectResult(status: "not-found", errnoCode: nil, error: nil, latencyMs: nil)
        ping = nil
        stat = DiagnosticsSocketStat(exists: false, isSocket: false, mode: nil, ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil)
    case .refused:
        connect = DiagnosticsSocketConnectResult(status: "refused", errnoCode: nil, error: "Connection refused", latencyMs: 1)
        ping = nil
        stat = DiagnosticsSocketStat(exists: true, isSocket: true, mode: "0700", ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil)
    case .timeout:
        connect = DiagnosticsSocketConnectResult(status: "timeout", errnoCode: nil, error: "timed out", latencyMs: 2_000)
        ping = nil
        stat = DiagnosticsSocketStat(exists: true, isSocket: true, mode: "0700", ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil)
    case .stale:
        connect = DiagnosticsSocketConnectResult(status: "not-socket", errnoCode: nil, error: nil, latencyMs: nil)
        ping = nil
        stat = DiagnosticsSocketStat(exists: true, isSocket: false, mode: "0644", ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil)
    }

    return DiagnosticsSocketProbeResult(
        socketPath: "/tmp/toastty-501/events-v1.sock",
        pathSource: pathSource,
        state: state,
        stat: stat,
        instancePID: nil,
        instancePIDAlive: nil,
        connect: connect,
        ping: ping,
        currentSocketRecord: nil,
        competingSockets: []
    )
}

private func shellSection(markerPresent: Bool) -> DiagnosticsShellSection {
    DiagnosticsShellSection(
        detectedShells: [
            DiagnosticsShellInitFile(
                name: "zsh",
                rcPath: "/Users/example/.zshrc",
                exists: true,
                sourcingMarkerPresent: markerPresent,
                readError: nil
            ),
        ],
        shimDirectory: shimDirectory(entries: []),
        environment: [],
        otherEnvironmentNames: []
    )
}

private func shimDirectory(entries: [DiagnosticsDirectoryEntry]) -> DiagnosticsDirectoryListing {
    DiagnosticsDirectoryListing(
        path: "/Users/example/.toastty/bin",
        exists: true,
        entries: entries,
        readError: nil
    )
}

private func logsSection(currentExists: Bool) -> DiagnosticsLogsSection {
    DiagnosticsLogsSection(
        current: DiagnosticsLogFile(
            path: "/Users/example/Library/Logs/Toastty/toastty.log",
            exists: currentExists,
            sizeBytes: currentExists ? 128 : nil,
            modifiedAtMs: nil,
            content: currentExists ? "{}" : nil,
            readError: nil
        ),
        previous: DiagnosticsLogFile(
            path: "/Users/example/Library/Logs/Toastty/toastty.previous.log",
            exists: false,
            sizeBytes: nil,
            modifiedAtMs: nil,
            content: nil,
            readError: nil
        ),
        configSummary: [
            "enabled": "true",
            "file_path": "/Users/example/Library/Logs/Toastty/toastty.log",
        ]
    )
}
