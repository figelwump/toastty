import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct DiagnosticsSubmitCommandTests {
    @Test
    func submitWithoutYesDoesNotUpload() throws {
        let fileURL = try writeBundle(redactedBundle())
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: Data())
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: "https://diagnostics.example.com",
                yes: false,
                dryRun: false,
                allowSecretScanWarning: false
            ),
            environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
            httpClient: client
        )

        #expect(client.uploads.isEmpty)
    }

    @Test
    func submitUploadsApprovedBundle() throws {
        let fileURL = try writeBundle(redactedBundle())
        let originalBody = try Data(contentsOf: fileURL)
        let response = try JSONEncoder().encode(
            DiagnosticsSubmitCommandTestResponse(
                reportID: "TT-20260628-ABCDEFGH",
                receivedAtMs: 1_800_000_000_000,
                expiresAtMs: 1_802_592_000_000
            )
        )
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: response)
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: nil,
                yes: true,
                dryRun: false,
                allowSecretScanWarning: false
            ),
            environment: [
                "TOASTTY_DIAGNOSTICS_ENDPOINT": "https://diagnostics.example.com",
                "TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key",
            ],
            httpClient: client
        )

        let upload = try #require(client.uploads.first)
        #expect(client.uploads.count == 1)
        #expect(upload.request.url?.absoluteString == "https://diagnostics.example.com/v1/diagnostics")
        #expect(upload.request.value(forHTTPHeaderField: "x-toastty-diagnostics-key") == "test-key")
        #expect(upload.request.value(forHTTPHeaderField: "content-type") == "application/json; charset=utf-8")
        #expect(upload.body == originalBody)
        #expect(try Data(contentsOf: fileURL) == originalBody)
    }

    @Test
    func submitWithContactAppendsNoteOnlyInUploadPayload() throws {
        let fileURL = try writeBundle(redactedBundle())
        try addUnknownFutureSection(to: fileURL)
        let originalBody = try Data(contentsOf: fileURL)
        let response = try JSONEncoder().encode(
            DiagnosticsSubmitCommandTestResponse(
                reportID: "TT-20260628-ABCDEFGH",
                receivedAtMs: 1_800_000_000_000,
                expiresAtMs: nil
            )
        )
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: response)
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: "https://diagnostics.example.com",
                contact: "cheech <cheech@example.com>",
                yes: true,
                dryRun: false,
                allowSecretScanWarning: false
            ),
            environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
            httpClient: client
        )

        let upload = try #require(client.uploads.first)
        let uploadedBundle = try JSONDecoder().decode(DiagnosticsBundle.self, from: upload.body)
        let uploadedObject = try #require(JSONSerialization.jsonObject(with: upload.body) as? [String: Any])
        let futureSection = try #require(uploadedObject["futureSection"] as? [String: Any])
        #expect(upload.body != originalBody)
        #expect(uploadedBundle.note == "terminal didn't connect\nContact: cheech <cheech@example.com>")
        #expect(futureSection["preserved"] as? Bool == true)
        #expect(try Data(contentsOf: fileURL) == originalBody)
    }

    @Test
    func submitWithBlankContactUploadsExactFile() throws {
        let fileURL = try writeBundle(redactedBundle())
        let originalBody = try Data(contentsOf: fileURL)
        let response = try JSONEncoder().encode(
            DiagnosticsSubmitCommandTestResponse(
                reportID: "TT-20260628-ABCDEFGH",
                receivedAtMs: 1_800_000_000_000,
                expiresAtMs: nil
            )
        )
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: response)
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: "https://diagnostics.example.com",
                contact: "  ",
                yes: true,
                dryRun: false,
                allowSecretScanWarning: false
            ),
            environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
            httpClient: client
        )

        let upload = try #require(client.uploads.first)
        #expect(upload.body == originalBody)
        #expect(try Data(contentsOf: fileURL) == originalBody)
    }

    @Test
    func submitWithContactRejectsSecretScanFindingsInFinalPayload() throws {
        let fileURL = try writeBundle(redactedBundle())
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: Data())
        )

        do {
            try DiagnosticsSubmitCommand.run(
                options: DiagnosticsSubmitOptions(
                    filePath: fileURL.path,
                    endpoint: "https://diagnostics.example.com",
                    contact: "token sk-test_abcdefghijklmnopqrstuvwxyz",
                    yes: true,
                    dryRun: false,
                    allowSecretScanWarning: false
                ),
                environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
                httpClient: client
            )
            Issue.record("expected secret scan failure")
        } catch let error as DiagnosticsSubmissionPreflightError {
            guard case .secretScanFindings(let findings) = error else {
                Issue.record("expected secret scan findings")
                return
            }
            #expect(findings.contains { $0.ruleID == "openai-token" })
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(client.uploads.isEmpty)
    }

    @Test
    func submitAppendsDiagnosticsPathAfterCustomEndpointPath() throws {
        let fileURL = try writeBundle(redactedBundle())
        let response = try JSONEncoder().encode(
            DiagnosticsSubmitCommandTestResponse(
                reportID: "TT-20260628-ABCDEFGH",
                receivedAtMs: 1,
                expiresAtMs: nil
            )
        )
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: response)
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: "http://127.0.0.1:8787/dev",
                yes: true,
                dryRun: false,
                allowSecretScanWarning: false
            ),
            environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
            httpClient: client
        )

        #expect(client.uploads.first?.request.url?.absoluteString == "http://127.0.0.1:8787/dev/v1/diagnostics")
    }

    @Test
    func submitNormalizesDiagnosticsEndpointTrailingSlash() throws {
        let fileURL = try writeBundle(redactedBundle())
        let response = try JSONEncoder().encode(
            DiagnosticsSubmitCommandTestResponse(
                reportID: "TT-20260628-ABCDEFGH",
                receivedAtMs: 1,
                expiresAtMs: nil
            )
        )
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: response)
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: "https://diagnostics.example.com/v1/diagnostics/",
                yes: true,
                dryRun: false,
                allowSecretScanWarning: false
            ),
            environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
            httpClient: client
        )

        #expect(client.uploads.first?.request.url?.absoluteString == "https://diagnostics.example.com/v1/diagnostics")
    }

    @Test
    func submitRejectsSecretScanFindingsWithoutOverride() throws {
        var bundle = redactedBundle()
        bundle.logs.current.content = "leaked sk-test_abcdefghijklmnopqrstuvwxyz"
        let fileURL = try writeBundle(bundle)
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: Data())
        )

        do {
            try DiagnosticsSubmitCommand.run(
                options: DiagnosticsSubmitOptions(
                    filePath: fileURL.path,
                    endpoint: "https://diagnostics.example.com",
                    yes: true,
                    dryRun: false,
                    allowSecretScanWarning: false
                ),
                environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
                httpClient: client
            )
            Issue.record("expected secret scan failure")
        } catch let error as DiagnosticsSubmissionPreflightError {
            guard case .secretScanFindings(let findings) = error else {
                Issue.record("expected secret scan findings")
                return
            }
            #expect(findings.contains { $0.ruleID == "openai-token" })
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(client.uploads.isEmpty)
    }

    @Test
    func submitOverrideSendsOverrideHeader() throws {
        var bundle = redactedBundle()
        bundle.logs.current.content = "leaked sk-test_abcdefghijklmnopqrstuvwxyz"
        let fileURL = try writeBundle(bundle)
        let response = try JSONEncoder().encode(
            DiagnosticsSubmitCommandTestResponse(reportID: "TT-20260628-ABCDEFGH", receivedAtMs: 1, expiresAtMs: nil)
        )
        let client = MockDiagnosticsHTTPClient(
            response: DiagnosticsSubmitHTTPResponse(statusCode: 200, data: response)
        )

        try DiagnosticsSubmitCommand.run(
            options: DiagnosticsSubmitOptions(
                filePath: fileURL.path,
                endpoint: "https://diagnostics.example.com",
                yes: true,
                dryRun: false,
                allowSecretScanWarning: true
            ),
            environment: ["TOASTTY_DIAGNOSTICS_UPLOAD_KEY": "test-key"],
            httpClient: client
        )

        #expect(client.uploads.first?.request.value(forHTTPHeaderField: "x-toastty-secret-scan-override") == "1")
    }
}

private final class MockDiagnosticsHTTPClient: DiagnosticsSubmitHTTPClient {
    struct Upload {
        var request: URLRequest
        var body: Data
    }

    var uploads: [Upload] = []
    var response: DiagnosticsSubmitHTTPResponse

    init(response: DiagnosticsSubmitHTTPResponse) {
        self.response = response
    }

    func upload(_ request: URLRequest, body: Data) throws -> DiagnosticsSubmitHTTPResponse {
        uploads.append(Upload(request: request, body: body))
        return response
    }
}

private struct DiagnosticsSubmitCommandTestResponse: Encodable {
    var reportID: String
    var receivedAtMs: Int64
    var expiresAtMs: Int64?
}

private func writeBundle(_ bundle: DiagnosticsBundle) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("diag-submit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("bundle.json", isDirectory: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(bundle).write(to: fileURL)
    return fileURL
}

private func addUnknownFutureSection(to fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["futureSection"] = ["preserved": true]
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try updated.write(to: fileURL)
}

private func redactedBundle() -> DiagnosticsBundle {
    DiagnosticsBundle(
        generatedAtMs: 1_800_000_000_000,
        note: "terminal didn't connect",
        app: DiagnosticsAppSection(
            shortVersion: "1.0",
            build: "100",
            bundlePath: "/Applications/Toastty.app",
            executablePath: "/Applications/Toastty.app/Contents/MacOS/Toastty",
            runtimeHomePath: nil,
            runtimeHomeStrategy: "user-home",
            runtimeLabel: nil,
            isDevWorktree: false,
            pid: nil,
            pidAlive: nil,
            runID: nil,
            instanceFilePath: nil,
            instanceStatus: .available,
            infoPlistStatus: .available
        ),
        logs: DiagnosticsLogsSection(
            current: DiagnosticsLogFile(
                path: "/Users/vishal/Library/Logs/Toastty/toastty.log",
                exists: true,
                sizeBytes: 12,
                modifiedAtMs: nil,
                content: "socket healthy",
                readError: nil
            ),
            previous: DiagnosticsLogFile(
                path: "/Users/vishal/Library/Logs/Toastty/toastty.previous.log",
                exists: false,
                sizeBytes: nil,
                modifiedAtMs: nil,
                content: nil,
                readError: nil
            ),
            configSummary: [:]
        ),
        shell: DiagnosticsShellSection(
            detectedShells: [],
            shimDirectory: DiagnosticsDirectoryListing(path: "/Users/vishal/.toastty/bin", exists: true, entries: [], readError: nil),
            environment: [],
            otherEnvironmentNames: []
        ),
        system: DiagnosticsSystemSection(macosVersion: "Version 15.0", hardwareModel: "Mac16,1", arch: "arm64"),
        socket: DiagnosticsSocketProbeResult(
            socketPath: "/tmp/toastty-501/events-v1.sock",
            pathSource: .legacy,
            state: .healthy,
            stat: DiagnosticsSocketStat(exists: true, isSocket: true, mode: nil, ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil),
            instancePID: nil,
            instancePIDAlive: nil,
            connect: DiagnosticsSocketConnectResult(status: "connected", errnoCode: nil, error: nil, latencyMs: 1),
            ping: nil,
            currentSocketRecord: nil,
            competingSockets: []
        ),
        probe: DiagnosticsProbeSection(shellProbePath: nil, rawShellProbe: nil, readError: nil),
        redaction: DiagnosticsRedactionSection(rulesVersion: DiagnosticsRedactor.rulesVersion, redactedKeyCount: 1)
    )
}
