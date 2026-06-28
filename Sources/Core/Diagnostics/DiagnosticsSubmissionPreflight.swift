import Foundation

public struct DiagnosticsSubmissionPreflightOptions: Equatable, Sendable {
    public var maxBodyBytes: Int
    public var minimumRedactionRulesVersion: Int
    public var allowSecretScanWarning: Bool

    public init(
        maxBodyBytes: Int = 15_000_000,
        minimumRedactionRulesVersion: Int = DiagnosticsRedactor.rulesVersion,
        allowSecretScanWarning: Bool = false
    ) {
        self.maxBodyBytes = maxBodyBytes
        self.minimumRedactionRulesVersion = minimumRedactionRulesVersion
        self.allowSecretScanWarning = allowSecretScanWarning
    }
}

public struct DiagnosticsSubmissionPreflightReport: Equatable, Sendable {
    public var bundle: DiagnosticsBundle
    public var sizeBytes: Int
    public var findings: [DiagnosticsSecretScanFinding]

    public init(bundle: DiagnosticsBundle, sizeBytes: Int, findings: [DiagnosticsSecretScanFinding]) {
        self.bundle = bundle
        self.sizeBytes = sizeBytes
        self.findings = findings
    }
}

public enum DiagnosticsSubmissionPreflightError: Error, LocalizedError, Equatable {
    case payloadTooLarge(sizeBytes: Int, maxBodyBytes: Int)
    case invalidUTF8
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case missingRedactionMetadata
    case staleRedactionRulesVersion(found: Int, minimum: Int)
    case secretScanFindings([DiagnosticsSecretScanFinding])

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let sizeBytes, let maxBodyBytes):
            return "diagnostics file is \(sizeBytes) bytes, which exceeds the \(maxBodyBytes)-byte upload limit"
        case .invalidUTF8:
            return "diagnostics file is not valid UTF-8"
        case .invalidJSON(let detail):
            return "diagnostics file is not a valid diagnostics bundle: \(detail)"
        case .unsupportedSchemaVersion(let version):
            return "diagnostics bundle schemaVersion \(version) is not supported"
        case .missingRedactionMetadata:
            return "diagnostics bundle is missing redaction metadata; rerun diagnostics collect"
        case .staleRedactionRulesVersion(let found, let minimum):
            return "diagnostics bundle uses redaction rules v\(found); v\(minimum) or newer is required"
        case .secretScanFindings(let findings):
            let labels = findings.map { "\($0.label) (\($0.matchCount))" }.joined(separator: ", ")
            return "diagnostics bundle still appears to contain secrets: \(labels)"
        }
    }
}

public enum DiagnosticsSubmissionPreflight {
    public static func validate(
        jsonData: Data,
        options: DiagnosticsSubmissionPreflightOptions = DiagnosticsSubmissionPreflightOptions()
    ) throws -> DiagnosticsSubmissionPreflightReport {
        guard jsonData.count <= options.maxBodyBytes else {
            throw DiagnosticsSubmissionPreflightError.payloadTooLarge(
                sizeBytes: jsonData.count,
                maxBodyBytes: options.maxBodyBytes
            )
        }

        guard let jsonText = String(data: jsonData, encoding: .utf8) else {
            throw DiagnosticsSubmissionPreflightError.invalidUTF8
        }

        let bundle: DiagnosticsBundle
        do {
            bundle = try JSONDecoder().decode(DiagnosticsBundle.self, from: jsonData)
        } catch {
            throw DiagnosticsSubmissionPreflightError.invalidJSON(error.localizedDescription)
        }

        guard bundle.schemaVersion == DiagnosticsBundle.currentSchemaVersion else {
            throw DiagnosticsSubmissionPreflightError.unsupportedSchemaVersion(bundle.schemaVersion)
        }

        guard let redaction = bundle.redaction else {
            throw DiagnosticsSubmissionPreflightError.missingRedactionMetadata
        }

        guard redaction.rulesVersion >= options.minimumRedactionRulesVersion else {
            throw DiagnosticsSubmissionPreflightError.staleRedactionRulesVersion(
                found: redaction.rulesVersion,
                minimum: options.minimumRedactionRulesVersion
            )
        }

        let findings = DiagnosticsSecretScanner.scan(jsonText)
        if findings.isEmpty == false && options.allowSecretScanWarning == false {
            throw DiagnosticsSubmissionPreflightError.secretScanFindings(findings)
        }

        return DiagnosticsSubmissionPreflightReport(
            bundle: bundle,
            sizeBytes: jsonData.count,
            findings: findings
        )
    }
}
