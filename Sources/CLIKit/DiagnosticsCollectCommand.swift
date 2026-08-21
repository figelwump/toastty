import CoreState
import Foundation

struct DiagnosticsCollectOptions: Equatable {
    var shellProbePath: String?
    var note: String?
    var outputPath: String
}

enum DiagnosticsCollectCommand {
    static func run(
        options: DiagnosticsCollectOptions,
        socketPath: String,
        socketPathSourceOverride: DiagnosticsSocketPathSource?,
        environment: [String: String],
        homeDirectoryPath: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        let resolvedHomeDirectoryPath = homeDirectoryPath ?? environment["HOME"] ?? NSHomeDirectory()
        let probe = DiagnosticsSocketProbe().probe(
            environment: environment,
            homeDirectoryPath: resolvedHomeDirectoryPath,
            socketPathOverride: socketPath,
            pathSourceOverride: socketPathSourceOverride
        )
        let automation = DiagnosticsAutomationCollector.collect(socket: probe)
        let rawBundle = DiagnosticsCollector.collect(
            note: options.note,
            shellProbeFilePath: options.shellProbePath,
            socket: probe,
            automation: automation,
            environment: environment,
            homeDirectoryPath: resolvedHomeDirectoryPath,
            fileManager: fileManager
        )
        let payload = try preparedPayload(rawBundle)
        try write(payload.data, to: options.outputPath, fileManager: fileManager)
        try writeStdout(
            summary(
                for: payload.bundle,
                outputPath: options.outputPath,
                outputSizeBytes: payload.data.count
            )
        )
    }

    static func write(
        _ data: Data,
        to outputPath: String,
        fileManager: FileManager = .default
    ) throws {
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: false)
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: [.atomic])
    }

    static func preparedPayload(
        _ rawBundle: DiagnosticsBundle,
        maximumBodyBytes: Int = DiagnosticsSubmissionLimits.maximumCollectedBodyBytes
    ) throws -> (bundle: DiagnosticsBundle, data: Data) {
        var candidate = rawBundle
        var iterationCount = 0

        while true {
            iterationCount += 1
            guard iterationCount <= 128 else {
                throw ToasttyCLIError.runtime(
                    "diagnostics collection could not converge on an upload-safe bundle size"
                )
            }
            let redacted = DiagnosticsRedactor().redact(candidate)
            let data = try encode(redacted)
            if data.count <= maximumBodyBytes {
                return (redacted.bundle, data)
            }

            if shrink(&candidate.logs.previous, retainingAtLeast: 1_000_000)
                || shrink(&candidate.logs.current, retainingAtLeast: 1_000_000) {
                continue
            }

            if candidate.probe.rawShellProbe != nil {
                candidate.probe.rawShellProbe = nil
                candidate.probe.readError = "shell probe omitted because the diagnostics bundle exceeded the upload size limit"
                continue
            }

            if shrink(&candidate.logs.previous, retainingAtLeast: 0)
                || shrink(&candidate.logs.current, retainingAtLeast: 0) {
                continue
            }

            throw ToasttyCLIError.runtime(
                "diagnostics collection cannot fit within the \(maximumBodyBytes)-byte upload-safe limit after truncating embedded logs"
            )
        }
    }

    private static func encode(_ bundle: RedactedDiagnosticsBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    private static func shrink(
        _ log: inout DiagnosticsLogFile,
        retainingAtLeast minimumBytes: Int
    ) -> Bool {
        guard let content = log.content else {
            return false
        }
        let contentSize = content.utf8.count
        guard contentSize > minimumBytes else {
            return false
        }

        let targetBytes = max(minimumBytes, contentSize / 2)
        log.content = recentCompleteLines(from: content, maximumBytes: targetBytes)
        log.truncated = true
        return true
    }

    private static func recentCompleteLines(from content: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else {
            return ""
        }
        let data = Data(content.utf8)
        guard data.count > maximumBytes else {
            return content
        }
        let tail = data.suffix(maximumBytes)
        guard let newlineIndex = tail.firstIndex(of: 0x0A) else {
            return ""
        }
        let completeLines = tail.suffix(from: tail.index(after: newlineIndex))
        return String(decoding: completeLines, as: UTF8.self)
    }

    private static func summary(
        for bundle: DiagnosticsBundle,
        outputPath: String,
        outputSizeBytes: Int
    ) -> String {
        let appVersion = [bundle.app.shortVersion, bundle.app.build.map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
        let appLine = appVersion.isEmpty
            ? "App: unavailable - \(bundle.app.infoPlistStatus.detail ?? bundle.app.instanceStatus.detail ?? "unknown")"
            : "App: \(appVersion)"
        let runtimeLine = "Runtime: \(bundle.app.runtimeLabel ?? bundle.app.runtimeHomeStrategy)"
            + (bundle.app.isDevWorktree ? " (dev worktree)" : "")
        let shellInstalledCount = bundle.shell.detectedShells.filter(\.sourcingMarkerPresent).count
        let shellExistingCount = bundle.shell.detectedShells.filter(\.exists).count
        let currentLogLine = logSummary("Current log", bundle.logs.current)
        let previousLogLine = logSummary("Previous log", bundle.logs.previous)
        let workspaceLayoutsLine = workspaceLayoutsSummary(bundle.workspaceLayouts)
        let automationLine = automationSummary(bundle.automation)
        let checkReport = DiagnosticsCheckEvaluator.evaluate(bundle)

        return [
            "Toastty diagnostics collected",
            "Output: \(outputPath)",
            "Size: \(outputSizeBytes) bytes",
            appLine,
            runtimeLine,
            "Checks: \(checkReport.summary.pass) passed, \(checkReport.summary.warn) warnings, \(checkReport.summary.fail) failed",
            "Socket: \(bundle.socket.state.rawValue) (\(bundle.socket.socketPath))",
            "Shell integration: \(shellInstalledCount)/\(shellExistingCount) existing init files reference Toastty",
            "Shim directory: \(bundle.shell.shimDirectory.path) (\(bundle.shell.shimDirectory.entries.count) entries)",
            workspaceLayoutsLine,
            currentLogLine,
            previousLogLine,
            automationLine,
            "Redactions: \(bundle.redaction?.redactedKeyCount ?? 0) using rules v\(bundle.redaction?.rulesVersion ?? 0)",
        ]
        .joined(separator: "\n")
    }

    private static func logSummary(_ label: String, _ log: DiagnosticsLogFile) -> String {
        guard log.exists else {
            return "\(label): missing at \(log.path)"
        }
        if let readError = log.readError {
            return "\(label): unreadable at \(log.path) (\(readError))"
        }
        let sourceSize = log.sizeBytes.map { "\($0) bytes" } ?? "unknown size"
        let embeddedSize = log.content.map { "\($0.utf8.count) bytes" } ?? "0 bytes"
        if log.truncated {
            return "\(label): included recent \(embeddedSize) from \(sourceSize) at \(log.path) (truncated)"
        }
        return "\(label): included \(embeddedSize) from \(log.path)"
    }

    private static func workspaceLayoutsSummary(
        _ workspaceLayouts: DiagnosticsWorkspaceLayoutsSection?
    ) -> String {
        guard let workspaceLayouts else {
            return "Workspace layouts: unavailable"
        }
        guard workspaceLayouts.status.status == "available" else {
            return "Workspace layouts: unavailable (\(workspaceLayouts.status.detail ?? "unknown"))"
        }
        let invalidCount = workspaceLayouts.profiles.filter {
            $0.validationStatus.status != "available"
        }.count
        return "Workspace layouts: included \(workspaceLayouts.profiles.count) profiles"
            + (invalidCount > 0 ? " (\(invalidCount) invalid)" : "")
    }

    private static func automationSummary(_ automation: DiagnosticsAutomationSection?) -> String {
        guard let automation else {
            return "Automation audit: unavailable"
        }
        guard automation.status.status == "available" else {
            return "Automation audit: unavailable (\(automation.status.detail ?? "unknown"))"
        }
        return "Automation audit: included \(automation.recentRequests.count) recent calls"
    }

    private static func writeStdout(_ string: String) throws {
        let output = string.hasSuffix("\n") ? string : string + "\n"
        FileHandle.standardOutput.write(output.data(using: .utf8) ?? Data())
    }
}

private enum DiagnosticsAutomationCollector {
    static func collect(socket: DiagnosticsSocketProbeResult) -> DiagnosticsAutomationSection {
        guard socket.state == .healthy else {
            return .unavailable("automation socket is not healthy")
        }

        do {
            let response = try ToasttySocketClient(socketPath: socket.socketPath, timeoutInterval: 2).send(
                AutomationRequestEnvelope(
                    requestID: UUID().uuidString,
                    command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
                )
            )
            guard response.ok else {
                return .unavailable(
                    response.error.map { "\($0.code): \($0.message)" } ?? "automation diagnostics request failed"
                )
            }
            guard let result = response.result else {
                return .unavailable("automation diagnostics response did not include a result")
            }
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(DiagnosticsAutomationSection.self, from: data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
