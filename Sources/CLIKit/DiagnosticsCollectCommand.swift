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
        let rawBundle = DiagnosticsCollector.collect(
            note: options.note,
            shellProbeFilePath: options.shellProbePath,
            socket: probe,
            environment: environment,
            homeDirectoryPath: resolvedHomeDirectoryPath,
            fileManager: fileManager
        )
        let redacted = DiagnosticsRedactor().redact(rawBundle)
        try write(redacted, to: options.outputPath, fileManager: fileManager)
        try writeStdout(summary(for: redacted.bundle, outputPath: options.outputPath))
    }

    static func write(
        _ bundle: RedactedDiagnosticsBundle,
        to outputPath: String,
        fileManager: FileManager = .default
    ) throws {
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: false)
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: outputURL, options: [.atomic])
    }

    private static func summary(for bundle: DiagnosticsBundle, outputPath: String) -> String {
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

        return [
            "Toastty diagnostics collected",
            "Output: \(outputPath)",
            appLine,
            runtimeLine,
            "Socket: \(bundle.socket.state.rawValue) (\(bundle.socket.socketPath))",
            "Shell integration: \(shellInstalledCount)/\(shellExistingCount) existing init files reference Toastty",
            "Shim directory: \(bundle.shell.shimDirectory.path) (\(bundle.shell.shimDirectory.entries.count) entries)",
            currentLogLine,
            previousLogLine,
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
        let size = log.sizeBytes.map { "\($0) bytes" } ?? "unknown size"
        return "\(label): included \(size) from \(log.path)"
    }

    private static func writeStdout(_ string: String) throws {
        let output = string.hasSuffix("\n") ? string : string + "\n"
        FileHandle.standardOutput.write(output.data(using: .utf8) ?? Data())
    }
}
