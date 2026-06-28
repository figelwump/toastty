import CoreState
import Foundation

struct DiagnosticsDoctorOptions: Equatable {}

enum DiagnosticsDoctorCommand {
    static func run(
        options _: DiagnosticsDoctorOptions,
        socketPath: String,
        socketPathSourceOverride: DiagnosticsSocketPathSource?,
        jsonOutput: Bool,
        environment: [String: String],
        homeDirectoryPath: String? = nil,
        fileManager: FileManager = .default
    ) throws -> Int32 {
        let resolvedHomeDirectoryPath = homeDirectoryPath ?? environment["HOME"] ?? NSHomeDirectory()
        let probe = DiagnosticsSocketProbe().probe(
            environment: environment,
            homeDirectoryPath: resolvedHomeDirectoryPath,
            socketPathOverride: socketPath,
            pathSourceOverride: socketPathSourceOverride
        )
        let bundle = DiagnosticsCollector.collect(
            note: nil,
            shellProbeFilePath: nil,
            socket: probe,
            environment: environment,
            homeDirectoryPath: resolvedHomeDirectoryPath,
            fileManager: fileManager
        )
        let report = DiagnosticsCheckEvaluator.evaluate(bundle)
        if jsonOutput {
            try writeStdout(renderJSON(report))
        } else {
            try writeStdout(renderHuman(report))
        }
        return exitCode(for: report)
    }

    static func exitCode(for report: DiagnosticsCheckReport) -> Int32 {
        report.summary.fail > 0 ? 1 : 0
    }

    static func renderHuman(_ report: DiagnosticsCheckReport) -> String {
        var lines = [
            "Toastty doctor",
            "Overall: \(report.overallStatus.rawValue)",
            "Checks: \(report.summary.pass) passed, \(report.summary.warn) warnings, \(report.summary.fail) failed",
            "",
        ]

        for check in report.checks {
            lines.append("[\(check.status.rawValue)] \(check.title)")
            lines.append("  \(check.summary)")
            for evidence in check.evidence {
                lines.append("  - \(evidence)")
            }
            if let remediation = check.remediation {
                lines.append("  Fix: \(remediation)")
            }
            lines.append("")
        }

        while lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func renderJSON(_ report: DiagnosticsCheckReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToasttyCLIError.runtime("failed to encode doctor report")
        }
        return string
    }

    private static func writeStdout(_ string: String) throws {
        let output = string.hasSuffix("\n") ? string : string + "\n"
        FileHandle.standardOutput.write(output.data(using: .utf8) ?? Data())
    }
}
