import Foundation
import Testing
@testable import CoreState

struct DiagnosticsRedactorTests {
    @Test
    func redactsSecretsWithoutRemovingDiagnosticContext() throws {
        var bundle = makeBundle()
        bundle.note = "token sk-test_abcdefghijklmnopqrstuvwxyz and path /Users/vishal/repo"
        bundle.logs.current.content = """
        {"message":"Authorization: Bearer abcdefghijklmnopqrstuvwxyz","metadata":{"cwd":"/Users/vishal/repo","OPENAI_API_KEY":"sk-test_abcdefghijklmnopqrstuvwxyz"}}
        """
        bundle.probe.rawShellProbe = """
        PATH=/Users/vishal/.toastty/bin:/usr/bin
        TOASTTY_SOCKET_PATH=/tmp/toastty-501/events-v1.sock
        OPENAI_API_KEY=sk-test_abcdefghijklmnopqrstuvwxyz
        git=https://user:password@example.com/repo.git
        """
        bundle.shell.environment = [
            DiagnosticsEnvironmentEntry(name: "PATH", value: "/Users/vishal/.toastty/bin:/usr/bin"),
            DiagnosticsEnvironmentEntry(name: "TOASTTY_SOCKET_PATH", value: "/tmp/toastty-501/events-v1.sock"),
            DiagnosticsEnvironmentEntry(name: "TOASTTY_API_KEY", value: "secret-value"),
        ]

        let redacted = DiagnosticsRedactor().redact(bundle).bundle
        let encoded = try String(decoding: JSONEncoder().encode(redacted), as: UTF8.self)

        #expect(encoded.contains("sk-test_abcdefghijklmnopqrstuvwxyz") == false)
        #expect(encoded.contains("Bearer abcdefghijklmnopqrstuvwxyz") == false)
        #expect(encoded.contains("secret-value") == false)
        #expect(encoded.contains("password@example.com") == false)
        #expect(redacted.note?.contains("/Users/vishal/repo") == true)
        #expect(redacted.logs.current.content?.contains("/Users/vishal/repo") == true)
        #expect(redacted.socket.socketPath == "/tmp/toastty-501/events-v1.sock")
        #expect(redacted.shell.environment.first { $0.name == "PATH" }?.value == "/Users/vishal/.toastty/bin:/usr/bin")
        #expect((redacted.redaction?.redactedKeyCount ?? 0) >= 4)
    }

    @Test
    func preservesHashesBuildIDsAndSocketPaths() throws {
        var bundle = makeBundle()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        bundle.logs.current.content = "build=20260627.1 hash=\(hash) socket=/tmp/toastty-501/events-v1-12345.sock"

        let redacted = DiagnosticsRedactor().redact(bundle).bundle

        #expect(redacted.logs.current.content?.contains(hash) == true)
        #expect(redacted.logs.current.content?.contains("/tmp/toastty-501/events-v1-12345.sock") == true)
        #expect(redacted.logs.current.content?.contains("<redacted") == false)
    }

    @Test
    func redactsSensitiveToasttyEnvironmentValues() throws {
        var bundle = makeBundle()
        bundle.shell.environment = [
            DiagnosticsEnvironmentEntry(name: "TOASTTY_SOCKET_PATH", value: "/tmp/toastty-501/events-v1.sock"),
            DiagnosticsEnvironmentEntry(name: "TOASTTY_PASSPHRASE", value: "plain words do not match token patterns"),
            DiagnosticsEnvironmentEntry(name: "TOASTTY_SESSION_ID", value: "session-identifier"),
        ]

        let redacted = DiagnosticsRedactor().redact(bundle).bundle

        #expect(redacted.shell.environment.first { $0.name == "TOASTTY_SOCKET_PATH" }?.value == "/tmp/toastty-501/events-v1.sock")
        #expect(redacted.shell.environment.first { $0.name == "TOASTTY_PASSPHRASE" }?.value == "<redacted:secret>")
        #expect(redacted.shell.environment.first { $0.name == "TOASTTY_SESSION_ID" }?.value == "<redacted:secret>")
    }

    @Test
    func avoidsAssignmentFalsePositivesForDiagnosticWords() throws {
        var bundle = makeBundle()
        bundle.logs.current.content = #"MONKEY=banana TOKENIZER_PATH=/tmp/tokenizer KEYBOARD=ansi "password":"plain secret""#

        let redacted = DiagnosticsRedactor().redact(bundle).bundle

        #expect(redacted.logs.current.content?.contains("MONKEY=banana") == true)
        #expect(redacted.logs.current.content?.contains("TOKENIZER_PATH=/tmp/tokenizer") == true)
        #expect(redacted.logs.current.content?.contains("KEYBOARD=ansi") == true)
        #expect(redacted.logs.current.content?.contains(#""password":"<redacted:secret>""#) == true)
        #expect(redacted.logs.current.content?.contains("plain secret") == false)
    }

    @Test
    func redactedBundleEncodesAsBundleRoot() throws {
        let bundle = DiagnosticsRedactor().redact(makeBundle())
        let data = try JSONEncoder().encode(bundle)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == DiagnosticsBundle.currentSchemaVersion)
        #expect(object["bundle"] == nil)
    }
}

private func makeBundle() -> DiagnosticsBundle {
    DiagnosticsBundle(
        generatedAtMs: 1_800_000_000_000,
        note: nil,
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
                sizeBytes: 0,
                modifiedAtMs: nil,
                content: "",
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
            configSummary: ["file_path": "/Users/vishal/Library/Logs/Toastty/toastty.log"]
        ),
        shell: DiagnosticsShellSection(
            detectedShells: [],
            shimDirectory: DiagnosticsDirectoryListing(path: "/Users/vishal/.toastty/bin", exists: false, entries: [], readError: nil),
            environment: [],
            otherEnvironmentNames: []
        ),
        system: DiagnosticsSystemSection(macosVersion: "Version 15.0", hardwareModel: "Mac16,1", arch: "arm64"),
        socket: DiagnosticsSocketProbeResult(
            socketPath: "/tmp/toastty-501/events-v1.sock",
            pathSource: .legacy,
            state: .noSocket,
            stat: DiagnosticsSocketStat(exists: false, isSocket: false, mode: nil, ownerUID: nil, groupID: nil, sizeBytes: nil, error: nil),
            instancePID: nil,
            instancePIDAlive: nil,
            connect: DiagnosticsSocketConnectResult(status: "not-found", errnoCode: nil, error: nil, latencyMs: nil),
            ping: nil,
            currentSocketRecord: nil,
            competingSockets: []
        ),
        probe: DiagnosticsProbeSection(shellProbePath: nil, rawShellProbe: nil, readError: nil)
    )
}
