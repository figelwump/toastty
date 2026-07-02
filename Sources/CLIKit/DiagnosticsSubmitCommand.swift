import CoreState
import Foundation

struct DiagnosticsSubmitOptions: Equatable {
    var filePath: String
    var endpoint: String?
    var contact: String? = nil
    var yes: Bool
    var dryRun: Bool
    var allowSecretScanWarning: Bool
}

struct DiagnosticsSubmitHTTPResponse: Equatable {
    var statusCode: Int
    var data: Data
}

protocol DiagnosticsSubmitHTTPClient {
    func upload(_ request: URLRequest, body: Data) throws -> DiagnosticsSubmitHTTPResponse
}

struct URLSessionDiagnosticsSubmitHTTPClient: DiagnosticsSubmitHTTPClient {
    var timeoutSeconds: TimeInterval = 20

    func upload(_ request: URLRequest, body: Data) throws -> DiagnosticsSubmitHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedUploadResult()
        let task = session.uploadTask(with: request, from: body) { data, response, error in
            result.store(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        let snapshot = result.snapshot()
        if let error = snapshot.error {
            throw error
        }
        guard let httpResponse = snapshot.response as? HTTPURLResponse else {
            throw ToasttyCLIError.runtime("diagnostics submit failed: server did not return an HTTP response")
        }
        return DiagnosticsSubmitHTTPResponse(statusCode: httpResponse.statusCode, data: snapshot.data ?? Data())
    }
}

private final class LockedUploadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    private var error: Error?

    func store(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        let snapshot = (data, response, error)
        lock.unlock()
        return snapshot
    }
}

enum DiagnosticsSubmitCommand {
    private static let endpointEnvironmentKey = "TOASTTY_DIAGNOSTICS_ENDPOINT"
    private static let uploadKeyEnvironmentKey = "TOASTTY_DIAGNOSTICS_UPLOAD_KEY"
    private static let uploadKeyFileEnvironmentKey = "TOASTTY_DIAGNOSTICS_UPLOAD_KEY_FILE"
    private static let endpointInfoPlistKey = "ToasttyDiagnosticsEndpoint"
    private static let uploadKeyInfoPlistKey = "ToasttyDiagnosticsUploadKey"

    static func run(
        options: DiagnosticsSubmitOptions,
        environment: [String: String],
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        httpClient: DiagnosticsSubmitHTTPClient = URLSessionDiagnosticsSubmitHTTPClient()
    ) throws {
        let fileURL = URL(fileURLWithPath: options.filePath, isDirectory: false)
        let filePayload = try Data(contentsOf: fileURL)
        let payload = try preparedPayload(
            filePayload: filePayload,
            contact: options.contact,
            allowSecretScanWarning: options.allowSecretScanWarning
        )
        let endpoint = resolvedValue(
            explicit: options.endpoint,
            environmentKey: endpointEnvironmentKey,
            infoPlistKey: endpointInfoPlistKey,
            environment: environment,
            bundle: bundle
        )
        let uploadURL = try endpoint.map(makeUploadURL)
        let shouldUpload = options.yes && options.dryRun == false

        if shouldUpload == false {
            try writeStdout(
                previewSummary(
                    preflight: payload.preflight,
                    filePath: options.filePath,
                    includesContact: payload.includesContact,
                    endpoint: uploadURL?.absoluteString,
                    dryRun: options.dryRun,
                    hasApproval: options.yes
                )
            )
            return
        }

        guard let uploadURL else {
            throw ToasttyCLIError.runtime(
                "diagnostics submit requires --endpoint, \(endpointEnvironmentKey), or a build-injected endpoint"
            )
        }
        let uploadKey = try resolvedUploadKey(environment: environment, bundle: bundle, fileManager: fileManager)
        guard let uploadKey else {
            throw ToasttyCLIError.runtime(
                "diagnostics submit requires \(uploadKeyEnvironmentKey), \(uploadKeyFileEnvironmentKey), or a build-injected upload key"
            )
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(uploadKey, forHTTPHeaderField: "x-toastty-diagnostics-key")
        request.setValue("toastty-cli", forHTTPHeaderField: "user-agent")
        if options.allowSecretScanWarning {
            request.setValue("1", forHTTPHeaderField: "x-toastty-secret-scan-override")
        }

        let response = try httpClient.upload(request, body: payload.data)
        guard (200..<300).contains(response.statusCode) else {
            throw ToasttyCLIError.runtime(errorMessage(for: response))
        }

        let decoded = try JSONDecoder().decode(DiagnosticsSubmitResponse.self, from: response.data)
        try writeStdout(
            [
                "Toastty diagnostics submitted",
                "Report ID: \(decoded.reportID)",
                "Endpoint: \(uploadURL.absoluteString)",
                "File: \(options.filePath)",
                payload.includesContact ? "Contact: included in submitted note" : nil,
                decoded.expiresAtMs.map { "Expires at: \($0) ms since epoch" },
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        )
    }

    private static func resolvedUploadKey(
        environment: [String: String],
        bundle: Bundle,
        fileManager: FileManager
    ) throws -> String? {
        if let value = nonEmpty(environment[uploadKeyEnvironmentKey]) {
            return value
        }
        if let keyFilePath = nonEmpty(environment[uploadKeyFileEnvironmentKey]) {
            let data = try Data(contentsOf: URL(fileURLWithPath: keyFilePath, isDirectory: false))
            guard let value = String(data: data, encoding: .utf8) else {
                throw ToasttyCLIError.runtime("\(uploadKeyFileEnvironmentKey) must point at a UTF-8 file")
            }
            return nonEmpty(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nonEmpty(bundle.object(forInfoDictionaryKey: uploadKeyInfoPlistKey) as? String)
    }

    private static func resolvedValue(
        explicit: String?,
        environmentKey: String,
        infoPlistKey: String,
        environment: [String: String],
        bundle: Bundle
    ) -> String? {
        nonEmpty(explicit)
            ?? nonEmpty(environment[environmentKey])
            ?? nonEmpty(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    private static func preparedPayload(
        filePayload: Data,
        contact: String?,
        allowSecretScanWarning: Bool
    ) throws -> (data: Data, preflight: DiagnosticsSubmissionPreflightReport, includesContact: Bool) {
        let preflightOptions = DiagnosticsSubmissionPreflightOptions(
            allowSecretScanWarning: allowSecretScanWarning
        )
        let initialPreflight = try DiagnosticsSubmissionPreflight.validate(
            jsonData: filePayload,
            options: preflightOptions
        )
        guard let contact = nonEmpty(contact) else {
            return (filePayload, initialPreflight, false)
        }

        let payload = try jsonPayloadByAppendingContact(
            to: filePayload,
            existingNote: initialPreflight.bundle.note,
            contact: contact
        )
        let finalPreflight = try DiagnosticsSubmissionPreflight.validate(
            jsonData: payload,
            options: preflightOptions
        )
        return (payload, finalPreflight, true)
    }

    private static func noteByAppendingContact(existingNote: String?, contact: String) -> String {
        let contactLine = "Contact: \(contact)"
        guard let existingNote = nonEmpty(existingNote) else {
            return contactLine
        }
        return existingNote + "\n" + contactLine
    }

    private static func jsonPayloadByAppendingContact(
        to filePayload: Data,
        existingNote: String?,
        contact: String
    ) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: filePayload)
        guard var object = value as? [String: Any] else {
            throw DiagnosticsSubmissionPreflightError.invalidJSON("diagnostics bundle root must be a JSON object")
        }
        object["note"] = noteByAppendingContact(existingNote: existingNote, contact: contact)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func makeUploadURL(endpoint: String) throws -> URL {
        guard var components = URLComponents(string: endpoint),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false else {
            throw ToasttyCLIError.runtime("diagnostics endpoint is not a valid URL: \(endpoint)")
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1/diagnostics"
        } else if path == "v1/diagnostics" {
            components.path = "/v1/diagnostics"
        } else {
            components.path = "/" + path + "/v1/diagnostics"
        }

        guard let url = components.url else {
            throw ToasttyCLIError.runtime("diagnostics endpoint is not a valid URL: \(endpoint)")
        }
        return url
    }

    private static func previewSummary(
        preflight: DiagnosticsSubmissionPreflightReport,
        filePath: String,
        includesContact: Bool,
        endpoint: String?,
        dryRun: Bool,
        hasApproval: Bool
    ) -> String {
        let bundle = preflight.bundle
        let appVersion = [bundle.app.shortVersion, bundle.app.build.map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
        let findingLine = preflight.findings.isEmpty
            ? "Secret scan: clear"
            : "Secret scan: warning - " + preflight.findings
                .map { "\($0.label) (\($0.matchCount))" }
                .joined(separator: ", ")

        return [
            "Toastty diagnostics ready to submit",
            "File: \(filePath)",
            "Size: \(preflight.sizeBytes) bytes",
            "Endpoint: \(endpoint ?? "<unset>")",
            appVersion.isEmpty ? "App: unavailable" : "App: \(appVersion)",
            "Socket: \(bundle.socket.state.rawValue)",
            "Current log: \(logUploadSummary(bundle.logs.current))",
            "Previous log: \(logUploadSummary(bundle.logs.previous))",
            "Redactions: \(bundle.redaction?.redactedKeyCount ?? 0) using rules v\(bundle.redaction?.rulesVersion ?? 0)",
            includesContact ? "Contact: included in submitted note" : nil,
            findingLine,
            dryRun
                ? "Dry run: no upload performed."
                : hasApproval
                    ? "No upload performed because --dry-run was set."
                    : includesContact
                        ? "No upload performed. Rerun with --yes to submit this file with contact included."
                        : "No upload performed. Rerun with --yes to submit this exact file.",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    private static func logUploadSummary(_ log: DiagnosticsLogFile) -> String {
        guard log.exists else {
            return "missing"
        }
        if let readError = log.readError {
            return "unreadable (\(readError))"
        }
        let size = log.sizeBytes.map { "\($0) bytes" } ?? "unknown size"
        return "\(size), truncated=\(log.truncated)"
    }

    private static func errorMessage(for response: DiagnosticsSubmitHTTPResponse) -> String {
        if let decoded = try? JSONDecoder().decode(DiagnosticsSubmitErrorResponse.self, from: response.data) {
            return "diagnostics submit failed (\(response.statusCode)): \(decoded.error.code): \(decoded.error.message)"
        }
        let body = String(data: response.data, encoding: .utf8) ?? "<non-UTF-8 response>"
        return "diagnostics submit failed (\(response.statusCode)): \(body)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private static func writeStdout(_ string: String) throws {
        let output = string.hasSuffix("\n") ? string : string + "\n"
        FileHandle.standardOutput.write(output.data(using: .utf8) ?? Data())
    }
}

private struct DiagnosticsSubmitResponse: Decodable {
    var reportID: String
    var receivedAtMs: Int64
    var expiresAtMs: Int64?
}

private struct DiagnosticsSubmitErrorResponse: Decodable {
    struct Body: Decodable {
        var code: String
        var message: String
    }

    var error: Body
}
