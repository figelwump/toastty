import Foundation

public enum DiagnosticsCheckStatus: String, Codable, Equatable, Sendable {
    case pass
    case warn
    case fail
}

public struct DiagnosticsCheckReport: Codable, Equatable, Sendable {
    public var generatedAtMs: Int64
    public var overallStatus: DiagnosticsCheckStatus
    public var summary: DiagnosticsCheckSummary
    public var checks: [DiagnosticsCheckResult]

    public init(
        generatedAtMs: Int64,
        overallStatus: DiagnosticsCheckStatus,
        summary: DiagnosticsCheckSummary,
        checks: [DiagnosticsCheckResult]
    ) {
        self.generatedAtMs = generatedAtMs
        self.overallStatus = overallStatus
        self.summary = summary
        self.checks = checks
    }
}

public struct DiagnosticsCheckSummary: Codable, Equatable, Sendable {
    public var pass: Int
    public var warn: Int
    public var fail: Int

    public init(pass: Int, warn: Int, fail: Int) {
        self.pass = pass
        self.warn = warn
        self.fail = fail
    }
}

public struct DiagnosticsCheckResult: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: DiagnosticsCheckStatus
    public var summary: String
    public var evidence: [String]
    public var remediation: String?

    public init(
        id: String,
        title: String,
        status: DiagnosticsCheckStatus,
        summary: String,
        evidence: [String],
        remediation: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.evidence = evidence
        self.remediation = remediation
    }
}

public enum DiagnosticsCheckEvaluator {
    public static func evaluate(_ bundle: DiagnosticsBundle) -> DiagnosticsCheckReport {
        let checks = [
            runtimeCheck(bundle),
            socketCheck(bundle.socket),
            shellIntegrationCheck(bundle.shell),
            agentShimCheck(bundle.shell.shimDirectory),
            logCheck(bundle.logs),
        ]
        let summary = DiagnosticsCheckSummary(
            pass: checks.filter { $0.status == .pass }.count,
            warn: checks.filter { $0.status == .warn }.count,
            fail: checks.filter { $0.status == .fail }.count
        )
        let overallStatus: DiagnosticsCheckStatus
        if summary.fail > 0 {
            overallStatus = .fail
        } else if summary.warn > 0 {
            overallStatus = .warn
        } else {
            overallStatus = .pass
        }

        return DiagnosticsCheckReport(
            generatedAtMs: bundle.generatedAtMs,
            overallStatus: overallStatus,
            summary: summary,
            checks: checks
        )
    }

    private static func runtimeCheck(_ bundle: DiagnosticsBundle) -> DiagnosticsCheckResult {
        var evidence = [
            "runtime: \(bundle.app.runtimeLabel ?? bundle.app.runtimeHomeStrategy)",
        ]
        if let runtimeHomePath = bundle.app.runtimeHomePath {
            evidence.append("runtime home: \(runtimeHomePath)")
        }
        if let instanceFilePath = bundle.app.instanceFilePath {
            evidence.append("instance file: \(instanceFilePath)")
        }
        if let pid = bundle.app.pid {
            let liveness = bundle.app.pidAlive.map { $0 ? "alive" : "not alive" } ?? "unknown"
            evidence.append("instance pid: \(pid) (\(liveness))")
        }
        let appVersion = [bundle.app.shortVersion, bundle.app.build.map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
        if appVersion.isEmpty == false {
            evidence.append("app version: \(appVersion)")
        }

        if bundle.app.pidAlive == false {
            return DiagnosticsCheckResult(
                id: "app-runtime",
                title: "App runtime",
                status: .fail,
                summary: "The recorded Toastty instance process is no longer running.",
                evidence: evidence,
                remediation: "Quit and reopen Toastty, then rerun `toastty doctor`."
            )
        }

        if bundle.app.instanceStatus.status != "available" {
            if bundle.app.runtimeHomeStrategy == ToasttyRuntimeHomeStrategy.userHome.rawValue {
                return DiagnosticsCheckResult(
                    id: "app-runtime",
                    title: "App runtime",
                    status: .pass,
                    summary: "Using the normal user-home runtime; no instance manifest is expected.",
                    evidence: evidence + availabilityEvidence("instance", bundle.app.instanceStatus),
                    remediation: nil
                )
            }

            return DiagnosticsCheckResult(
                id: "app-runtime",
                title: "App runtime",
                status: .warn,
                summary: "Toastty's runtime instance manifest is unavailable.",
                evidence: evidence + availabilityEvidence("instance", bundle.app.instanceStatus),
                remediation: "Open Toastty once for this runtime, then rerun `toastty doctor` from the same environment."
            )
        }

        return DiagnosticsCheckResult(
            id: "app-runtime",
            title: "App runtime",
            status: .pass,
            summary: "Toastty runtime metadata is available.",
            evidence: evidence,
            remediation: nil
        )
    }

    private static func socketCheck(_ socket: DiagnosticsSocketProbeResult) -> DiagnosticsCheckResult {
        var evidence = [
            "path: \(socket.socketPath)",
            "source: \(socket.pathSource.rawValue)",
            "connect: \(socket.connect.status)",
        ]
        if let latencyMs = socket.connect.latencyMs {
            evidence.append("connect latency: \(latencyMs)ms")
        }
        if let error = socket.connect.error {
            evidence.append("connect error: \(error)")
        }
        if let ping = socket.ping {
            evidence.append("ping: \(ping.ok ? "ok" : "failed")")
            if let latencyMs = ping.latencyMs {
                evidence.append("ping latency: \(latencyMs)ms")
            }
            if let protocolVersion = ping.protocolVersion {
                evidence.append("protocol: \(protocolVersion)")
            }
            if let error = ping.error {
                evidence.append("ping error: \(error)")
            }
        }
        if socket.competingSockets.isEmpty == false {
            evidence.append("competing sockets: \(socket.competingSockets.count)")
        }

        switch socket.state {
        case .healthy:
            return DiagnosticsCheckResult(
                id: "automation-socket",
                title: "Automation socket",
                status: .pass,
                summary: "Toastty's automation socket is reachable.",
                evidence: evidence,
                remediation: nil
            )
        case .noSocket:
            return DiagnosticsCheckResult(
                id: "automation-socket",
                title: "Automation socket",
                status: .fail,
                summary: "No Toastty automation socket was found at the resolved path.",
                evidence: evidence,
                remediation: socketPathRemediation(socket)
            )
        case .refused:
            return DiagnosticsCheckResult(
                id: "automation-socket",
                title: "Automation socket",
                status: .fail,
                summary: "The socket exists but refused the connection.",
                evidence: evidence,
                remediation: staleSocketRemediation
            )
        case .timeout:
            return DiagnosticsCheckResult(
                id: "automation-socket",
                title: "Automation socket",
                status: .fail,
                summary: "Connecting to Toastty's automation socket timed out.",
                evidence: evidence,
                remediation: "Toastty may be hung. Quit and reopen Toastty, then rerun `toastty doctor`."
            )
        case .stale:
            return DiagnosticsCheckResult(
                id: "automation-socket",
                title: "Automation socket",
                status: .fail,
                summary: "The resolved socket appears stale or is not responding correctly.",
                evidence: evidence,
                remediation: staleSocketRemediation
            )
        }
    }

    private static func shellIntegrationCheck(_ shell: DiagnosticsShellSection) -> DiagnosticsCheckResult {
        let existing = shell.detectedShells.filter(\.exists)
        let installed = existing.filter(\.sourcingMarkerPresent)
        let readErrors = existing.compactMap { file -> String? in
            guard let readError = file.readError else { return nil }
            return "\(file.rcPath): \(readError)"
        }

        var evidence = [
            "existing init files: \(existing.count)",
            "Toastty source markers: \(installed.count)",
        ]
        if readErrors.isEmpty == false {
            evidence.append("read errors: \(limitedList(readErrors))")
        }

        if existing.isEmpty {
            return DiagnosticsCheckResult(
                id: "shell-integration",
                title: "Shell integration",
                status: .warn,
                summary: "No supported zsh, bash, or fish init files were found.",
                evidence: evidence,
                remediation: "Use Toastty > Install Shell Integration... after creating the shell init file you use."
            )
        }

        if installed.isEmpty {
            return DiagnosticsCheckResult(
                id: "shell-integration",
                title: "Shell integration",
                status: .warn,
                summary: "Existing shell init files do not source Toastty's managed shell integration.",
                evidence: evidence + existing.map { "\($0.name): \($0.rcPath)" },
                remediation: "Use Toastty > Install Shell Integration..., then start a new terminal pane."
            )
        }

        if readErrors.isEmpty == false {
            return DiagnosticsCheckResult(
                id: "shell-integration",
                title: "Shell integration",
                status: .warn,
                summary: "Toastty shell integration is installed, but at least one init file could not be read.",
                evidence: evidence,
                remediation: "Check the permissions on the unreadable shell init files."
            )
        }

        return DiagnosticsCheckResult(
            id: "shell-integration",
            title: "Shell integration",
            status: .pass,
            summary: "At least one existing shell init file sources Toastty's managed integration.",
            evidence: evidence + installed.map { "\($0.name): \($0.rcPath)" },
            remediation: nil
        )
    }

    private static func agentShimCheck(_ shimDirectory: DiagnosticsDirectoryListing) -> DiagnosticsCheckResult {
        var evidence = [
            "path: \(shimDirectory.path)",
            "entries: \(shimDirectory.entries.count)",
        ]
        if let readError = shimDirectory.readError {
            evidence.append("read error: \(readError)")
        }
        let executableEntries = shimDirectory.entries.filter { $0.isDirectory == false && $0.isExecutable }
        let nonExecutableEntries = shimDirectory.entries.filter { $0.isDirectory == false && $0.isExecutable == false }
        if nonExecutableEntries.isEmpty == false {
            evidence.append("non-executable entries: \(limitedList(nonExecutableEntries.map(\.name)))")
        }

        if shimDirectory.exists == false {
            return DiagnosticsCheckResult(
                id: "agent-shims",
                title: "Agent command shims",
                status: .warn,
                summary: "Toastty's agent shim directory does not exist.",
                evidence: evidence,
                remediation: "Launch Toastty and run the agent setup flow so managed agent command shims can be installed."
            )
        }

        if shimDirectory.readError != nil {
            return DiagnosticsCheckResult(
                id: "agent-shims",
                title: "Agent command shims",
                status: .warn,
                summary: "Toastty's agent shim directory exists but could not be read.",
                evidence: evidence,
                remediation: "Check permissions on \(shimDirectory.path)."
            )
        }

        if executableEntries.isEmpty {
            return DiagnosticsCheckResult(
                id: "agent-shims",
                title: "Agent command shims",
                status: .warn,
                summary: "No executable agent shims were found.",
                evidence: evidence,
                remediation: "Run the Toastty agent setup flow again if manual agent commands are not being tracked."
            )
        }

        return DiagnosticsCheckResult(
            id: "agent-shims",
            title: "Agent command shims",
            status: nonExecutableEntries.isEmpty ? .pass : .warn,
            summary: nonExecutableEntries.isEmpty
                ? "Toastty's agent shim directory contains executable entries."
                : "Toastty's agent shim directory has executable entries, but some files are not executable.",
            evidence: evidence,
            remediation: nonExecutableEntries.isEmpty ? nil : "Run the Toastty agent setup flow again to refresh managed shims."
        )
    }

    private static func logCheck(_ logs: DiagnosticsLogsSection) -> DiagnosticsCheckResult {
        let loggingEnabled = logs.configSummary["enabled"] != "false"
        let configuredFilePath = logs.configSummary["file_path"] ?? logs.current.path
        var evidence = [
            "configured path: \(configuredFilePath)",
            "current path: \(logs.current.path)",
        ]
        if let sizeBytes = logs.current.sizeBytes {
            evidence.append("current size: \(sizeBytes) bytes")
        }
        if let readError = logs.current.readError {
            evidence.append("read error: \(readError)")
        }

        if loggingEnabled == false {
            return DiagnosticsCheckResult(
                id: "logs",
                title: "Logs",
                status: .pass,
                summary: "Logging is disabled by configuration.",
                evidence: evidence,
                remediation: nil
            )
        }

        if configuredFilePath.isEmpty {
            return DiagnosticsCheckResult(
                id: "logs",
                title: "Logs",
                status: .pass,
                summary: "No log file is configured.",
                evidence: evidence,
                remediation: nil
            )
        }

        if logs.current.exists == false {
            return DiagnosticsCheckResult(
                id: "logs",
                title: "Logs",
                status: .warn,
                summary: "Toastty's current log file does not exist yet.",
                evidence: evidence,
                remediation: "Open Toastty and reproduce the issue once so a fresh log can be written."
            )
        }

        if let readError = logs.current.readError {
            return DiagnosticsCheckResult(
                id: "logs",
                title: "Logs",
                status: .warn,
                summary: "Toastty's current log file exists but could not be read.",
                evidence: evidence,
                remediation: "Check permissions on \(logs.current.path): \(readError)"
            )
        }

        return DiagnosticsCheckResult(
            id: "logs",
            title: "Logs",
            status: .pass,
            summary: "Toastty's current log file is readable.",
            evidence: evidence,
            remediation: nil
        )
    }

    private static func availabilityEvidence(_ label: String, _ availability: DiagnosticsAvailability) -> [String] {
        guard let detail = availability.detail else {
            return ["\(label): \(availability.status)"]
        }
        return ["\(label): \(availability.status) (\(detail))"]
    }

    private static func socketPathRemediation(_ socket: DiagnosticsSocketProbeResult) -> String {
        switch socket.pathSource {
        case .cliOption, .environment:
            return "Unset TOASTTY_SOCKET_PATH or pass --socket-path for a live Toastty instance, then rerun `toastty doctor`."
        default:
            return "Open Toastty, wait for it to finish launching, then rerun `toastty doctor`."
        }
    }

    private static let staleSocketRemediation = "Quit and reopen Toastty. If TOASTTY_SOCKET_PATH is set, unset it unless you intentionally target that instance."

    private static func limitedList(_ values: [String], limit: Int = 4) -> String {
        if values.count <= limit {
            return values.joined(separator: ", ")
        }
        return values.prefix(limit).joined(separator: ", ") + ", +\(values.count - limit) more"
    }
}
