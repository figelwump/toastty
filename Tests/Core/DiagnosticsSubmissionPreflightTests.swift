import Foundation
import Testing
@testable import CoreState

struct DiagnosticsSubmissionPreflightTests {
    @Test
    func scannerMatchesSharedFixtures() throws {
        let fixtures = try loadSecretScanFixtures()

        for fixture in fixtures.positive {
            let expectedFindings = try #require(fixture.expectedFindings, "missing expected findings for: \(fixture.name)")
            let findings = DiagnosticsSecretScanner.scan(fixture.text)
            #expect(findings.map(\.ruleID) == expectedFindings.map(\.ruleID), "unexpected rule IDs for: \(fixture.name)")
            #expect(findings.map(\.matchCount) == expectedFindings.map(\.matchCount), "unexpected match counts for: \(fixture.name)")
        }

        for fixture in fixtures.negative {
            #expect(
                DiagnosticsSecretScanner.scan(fixture.text).isEmpty,
                "expected negative fixture not to match: \(fixture.name)"
            )
        }
    }

    @Test
    func preflightAcceptsRedactedBundle() throws {
        let bundle = redactedBundle()
        let data = try JSONEncoder().encode(bundle)

        let report = try DiagnosticsSubmissionPreflight.validate(jsonData: data)

        #expect(report.bundle.schemaVersion == DiagnosticsBundle.currentSchemaVersion)
        #expect(report.sizeBytes == data.count)
        #expect(report.findings.isEmpty)
    }

    @Test
    func preflightRejectsMissingRedactionMetadata() throws {
        var bundle = redactedBundle()
        bundle.redaction = nil
        let data = try JSONEncoder().encode(bundle)

        do {
            _ = try DiagnosticsSubmissionPreflight.validate(jsonData: data)
            Issue.record("expected preflight failure")
        } catch let error as DiagnosticsSubmissionPreflightError {
            #expect(error == .missingRedactionMetadata)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func preflightRejectsSecretFindingsUnlessOverrideIsSet() throws {
        var bundle = redactedBundle()
        bundle.logs.current.content = "leaked sk-test_abcdefghijklmnopqrstuvwxyz"
        let data = try JSONEncoder().encode(bundle)

        do {
            _ = try DiagnosticsSubmissionPreflight.validate(jsonData: data)
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

        let report = try DiagnosticsSubmissionPreflight.validate(
            jsonData: data,
            options: DiagnosticsSubmissionPreflightOptions(allowSecretScanWarning: true)
        )
        #expect(report.findings.contains { $0.ruleID == "openai-token" })
    }

    @Test
    func preflightRejectsOversizedPayloadBeforeDecoding() throws {
        let data = Data(#"{"schemaVersion":1}"#.utf8)

        do {
            _ = try DiagnosticsSubmissionPreflight.validate(
                jsonData: data,
                options: DiagnosticsSubmissionPreflightOptions(maxBodyBytes: data.count - 1)
            )
            Issue.record("expected size failure")
        } catch let error as DiagnosticsSubmissionPreflightError {
            #expect(error == .payloadTooLarge(sizeBytes: data.count, maxBodyBytes: data.count - 1))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private struct SecretScanFixtures: Decodable {
    struct Fixture: Decodable {
        struct ExpectedFinding: Decodable {
            var ruleID: String
            var matchCount: Int
        }

        var name: String
        var text: String
        var expectedFindings: [ExpectedFinding]?
    }

    var positive: [Fixture]
    var negative: [Fixture]
}

private func loadSecretScanFixtures() throws -> SecretScanFixtures {
    let fileURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Shared/Diagnostics/secret-scan-fixtures.json", isDirectory: false)
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(SecretScanFixtures.self, from: data)
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
