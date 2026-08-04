import XCTest
@testable import ToasttyApp

final class CodexAppServerClientTests: XCTestCase {
    func testWriteSkillConfigsSortsAndUsesOnlyPublicSkillsConfigWrite() throws {
        let transport = RecordingCodexRPCTransport { invocation, requests in
            XCTAssertEqual(invocation.codexHomeURL.path, "/tmp/codex-home")
            XCTAssertEqual(requests.map(\.method), ["skills/config/write", "skills/config/write"])
            XCTAssertEqual(requests.map { $0.params["name"]?.stringValue }, [
                "toastty:toastty-scratchpad",
                "toastty:worktree-create",
            ])
            XCTAssertTrue(requests.allSatisfy { $0.params["enabled"]?.boolValue == false })
            return requests.map {
                _ in .success(.object(["effectiveEnabled": .bool(false)]))
            }
        }

        try CodexAppServerClient(transport: transport).writeSkillConfigs(
            invocation: Self.invocation(),
            states: [
                CodexSkillState(name: "toastty:worktree-create", enabled: false),
                CodexSkillState(name: "toastty:toastty-scratchpad", enabled: false),
            ]
        )
    }

    func testListSkillsUsesForceReloadAndDecodesAllCwdGroups() throws {
        let transport = RecordingCodexRPCTransport { invocation, requests in
            XCTAssertEqual(requests.map(\.method), ["skills/list"])
            XCTAssertEqual(requests[0].params["cwds"], .array([.string(invocation.workingDirectoryURL.path)]))
            XCTAssertEqual(requests[0].params["forceReload"], .bool(true))
            return [
                .success(.object([
                    "data": .array([
                        .object([
                            "cwd": .string("/tmp/one"),
                            "skills": .array([
                                .object(["name": .string("toastty:first"), "enabled": .bool(false)]),
                            ]),
                        ]),
                        .object([
                            "cwd": .string("/tmp/two"),
                            "skills": .array([
                                .object(["name": .string("foreign:skill"), "enabled": .bool(true)]),
                            ]),
                        ]),
                    ]),
                ])),
            ]
        }

        let states = try CodexAppServerClient(transport: transport).listSkills(
            invocation: Self.invocation()
        )

        XCTAssertEqual(states, [
            CodexSkillState(name: "toastty:first", enabled: false),
            CodexSkillState(name: "foreign:skill", enabled: true),
        ])
    }

    func testWriteRejectsAnUnexpectedEffectiveEnabledValue() {
        let transport = RecordingCodexRPCTransport { _, _ in
            [.success(.object(["effectiveEnabled": .bool(true)]))]
        }

        XCTAssertThrowsError(
            try CodexAppServerClient(transport: transport).writeSkillConfigs(
                invocation: Self.invocation(),
                states: [CodexSkillState(name: "toastty:test", enabled: false)]
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexAppServerClientError,
                .malformedResponse("skills/config/write")
            )
        }
    }

    func testProcessTransportAppliesManagedEnvironmentToAppServer() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-app-server-environment-\(UUID().uuidString)", isDirectory: true)
        let executableURL = rootURL.appendingPathComponent("codex", isDirectory: false)
        let captureURL = rootURL.appendingPathComponent("environment.txt", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s|%s|%s' "$PATH" "$CODEX_HOME" "$TOASTTY_TEST_MARKER" > '\(captureURL.path)'
        exit 42
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let transport = CodexAppServerProcessTransport(baseEnvironment: {
            ["PATH": "/gui-only", "TOASTTY_TEST_MARKER": "preserved"]
        })
        let invocation = CodexAppServerInvocation(
            executableURL: executableURL,
            codexHomeURL: URL(fileURLWithPath: "/tmp/managed-codex-home"),
            processPath: "/custom/node/bin:/usr/bin:/bin",
            workingDirectoryURL: rootURL,
            configOverrides: [],
            timeout: 1
        )

        XCTAssertThrowsError(
            try transport.perform(
                invocation: invocation,
                requests: [CodexAppServerRPCRequest(method: "skills/list", params: [:])]
            )
        )

        XCTAssertEqual(
            try String(contentsOf: captureURL, encoding: .utf8),
            "/custom/node/bin:/usr/bin:/bin|/tmp/managed-codex-home|preserved"
        )
    }
}

private extension CodexAppServerClientTests {
    static func invocation() -> CodexAppServerInvocation {
        CodexAppServerInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            codexHomeURL: URL(fileURLWithPath: "/tmp/codex-home"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            configOverrides: [],
            timeout: 1
        )
    }
}

private final class RecordingCodexRPCTransport: CodexAppServerRPCTransporting, @unchecked Sendable {
    typealias Handler = (CodexAppServerInvocation, [CodexAppServerRPCRequest]) throws -> [CodexAppServerRPCResponse]
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func perform(
        invocation: CodexAppServerInvocation,
        requests: [CodexAppServerRPCRequest]
    ) throws -> [CodexAppServerRPCResponse] {
        try handler(invocation, requests)
    }
}

private extension CodexAppServerRPCResponse {
    static func success(_ result: CodexJSONValue) -> Self {
        Self(result: result, errorCode: nil, errorMessage: nil)
    }
}
