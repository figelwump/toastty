import XCTest
@testable import ToasttyApp

final class CodexAppServerClientTests: XCTestCase {
    func testAssessmentRequiresExactToasttyPluginSkillSet() throws {
        let transport = RecordingCodexRPCTransport { invocation, requests in
            XCTAssertEqual(requests.map(\.method), ["skills/list", "hooks/list"])
            return [
                .success(Self.skillsResult([
                    ("toastty:expected", true),
                    ("toastty:unexpected", true),
                    ("foreign:skill", true),
                ])),
                .success(Self.hooksResult(command: "forwarder", trust: "trusted")),
            ]
        }
        let assessment = try CodexAppServerClient(transport: transport).assess(
            invocation: Self.invocation(),
            expectedSkillNames: ["toastty:expected"],
            forwarderCommand: "forwarder",
            legacyGlobalHooksPresent: false
        )

        XCTAssertEqual(assessment.installedSkillNames, ["toastty:expected", "toastty:unexpected"])
        XCTAssertFalse(assessment.hasExactPluginSkillSet)
        XCTAssertFalse(assessment.canInjectSessionConfiguration)
    }

    func testAssessmentKeepsManagedTrustDistinctFromTrusted() throws {
        let transport = RecordingCodexRPCTransport { _, _ in
            [
                .success(Self.skillsResult([("toastty:expected", true)])),
                .success(Self.hooksResult(command: "forwarder", trust: "managed")),
            ]
        }
        let assessment = try CodexAppServerClient(transport: transport).assess(
            invocation: Self.invocation(),
            expectedSkillNames: ["toastty:expected"],
            forwarderCommand: "forwarder",
            legacyGlobalHooksPresent: false
        )

        XCTAssertTrue(assessment.canInjectSessionConfiguration)
        XCTAssertFalse(assessment.canUseSessionIntegrations)
        XCTAssertTrue(assessment.sessionHooks.allSatisfy { $0.trust == .managed })
    }

    func testAssessmentRejectsDuplicateAndChangedHookDefinitions() throws {
        let transport = RecordingCodexRPCTransport { _, _ in
            var hooks = Self.hookObjects(command: "forwarder", trust: "trusted")
            hooks.append(hooks[0])
            var changed = hooks[1].objectValue!
            changed["timeoutSec"] = .int(99)
            hooks[1] = .object(changed)
            return [
                .success(Self.skillsResult([("toastty:expected", true)])),
                .success(.object([
                    "data": .array([.object([
                        "cwd": .string("/tmp"),
                        "hooks": .array(hooks),
                        "warnings": .array([]),
                        "errors": .array([]),
                    ])]),
                ])),
            ]
        }
        let assessment = try CodexAppServerClient(transport: transport).assess(
            invocation: Self.invocation(),
            expectedSkillNames: ["toastty:expected"],
            forwarderCommand: "forwarder",
            legacyGlobalHooksPresent: false
        )

        XCTAssertFalse(assessment.parsedAllSessionHooks)
        XCTAssertFalse(assessment.canInjectSessionConfiguration)
        XCTAssertFalse(assessment.errors.isEmpty)
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

    static func skillsResult(_ skills: [(String, Bool)]) -> CodexJSONValue {
        .object([
            "data": .array([.object([
                "cwd": .string("/tmp"),
                "skills": .array(skills.map { name, enabled in
                    .object([
                        "name": .string(name),
                        "enabled": .bool(enabled),
                        "description": .string("test"),
                        "path": .string("/tmp/\(name)"),
                        "scope": .string("user"),
                    ])
                }),
                "errors": .array([]),
            ])]),
        ])
    }

    static func hooksResult(command: String, trust: String) -> CodexJSONValue {
        .object([
            "data": .array([.object([
                "cwd": .string("/tmp"),
                "hooks": .array(hookObjects(command: command, trust: trust)),
                "warnings": .array([]),
                "errors": .array([]),
            ])]),
        ])
    }

    static func hookObjects(command: String, trust: String) -> [CodexJSONValue] {
        CodexSessionIntegrationContract.hookDefinitions.map { definition in
            var object: [String: CodexJSONValue] = [
                "source": .string("sessionFlags"),
                "command": .string(command),
                "eventName": .string(listValue(definition.event)),
                "timeoutSec": .int(CodexSessionIntegrationContract.hookTimeoutSeconds),
                "statusMessage": .string(CodexSessionIntegrationContract.hookStatusMessage),
                "trustStatus": .string(trust),
                "currentHash": .string("hash-\(definition.event.rawValue)"),
            ]
            object["matcher"] = definition.matcher.map(CodexJSONValue.string) ?? .null
            return .object(object)
        }
    }

    static func listValue(_ event: CodexSessionHookEvent) -> String {
        switch event {
        case .sessionStart: return "sessionStart"
        case .userPromptSubmit: return "userPromptSubmit"
        case .permissionRequest: return "permissionRequest"
        case .preToolUse: return "preToolUse"
        case .subagentStart: return "subagentStart"
        case .subagentStop: return "subagentStop"
        case .stop: return "stop"
        }
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
