import CoreState
import XCTest
@testable import ToasttyApp

final class CodexManagedLaunchIntegrationResolverTests: XCTestCase {
    func testInvalidDirectHintFallsBackToRecognizedWrapperCodexExecutable() async throws {
        let fixture = try Fixture(trust: "trusted")
        defer { fixture.cleanup() }
        let resolver = fixture.resolver()
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["agent-safehouse", "codex"],
            cwd: fixture.root.path,
            codexCapabilityHint: ManagedCodexCapabilityHint(
                resolvedExecutablePath: "/bin/sh",
                codexHomePath: fixture.codexHome.path
            )
        )

        let decision = await resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.root.path
        )

        XCTAssertNotNil(decision.configuration)
        XCTAssertEqual(decision.statusTrackingSource, .hooks)
        XCTAssertEqual(fixture.transport.invocations.first?.executableURL, fixture.executable)
    }

    func testOpaqueWrapperIsNotExecutedAsCapabilityProbe() throws {
        let fixture = try Fixture(trust: "trusted")
        defer { fixture.cleanup() }
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["opaque-wrapper", "codex"],
            cwd: fixture.root.path,
            codexCapabilityHint: ManagedCodexCapabilityHint(
                resolvedExecutablePath: "/bin/sh",
                codexHomePath: fixture.codexHome.path
            )
        )

        let decision = fixture.resolver().resolve(request: request, workingDirectory: fixture.root.path)

        XCTAssertNil(decision.configuration)
        XCTAssertEqual(fixture.transport.invocations.count, 0)
        XCTAssertEqual(decision.statusTrackingSource, .sessionLogFallback(reason: "codex_executable_unresolved"))
    }

    func testRecognizedWrapperDoesNotTreatFlagValueAsCodexExecutable() throws {
        let fixture = try Fixture(trust: "trusted")
        defer { fixture.cleanup() }
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["agent-safehouse", "--profile", "codex", "npm", "test"],
            cwd: fixture.root.path
        )

        let decision = fixture.resolver().resolve(request: request, workingDirectory: fixture.root.path)

        XCTAssertNil(decision.configuration)
        XCTAssertEqual(fixture.transport.invocations.count, 0)
    }

    func testTrustedAssessmentCachesUntilLocalTrustStateChanges() async throws {
        let fixture = try Fixture(trust: "trusted")
        defer { fixture.cleanup() }
        let resolver = fixture.resolver()
        let request = fixture.directRequest()

        _ = await resolver.resolveForManagedLaunch(request: request, workingDirectory: fixture.root.path)
        _ = await resolver.resolveForManagedLaunch(request: request, workingDirectory: fixture.root.path)
        XCTAssertEqual(fixture.transport.invocations.count, 1)

        try Data(#"{"hooks":[]}"#.utf8).write(to: fixture.codexHome.appendingPathComponent("hooks.json"))
        _ = await resolver.resolveForManagedLaunch(request: request, workingDirectory: fixture.root.path)
        XCTAssertEqual(fixture.transport.invocations.count, 2)

        try Data(#"{"definition":"changed"}"#.utf8).write(
            to: fixture.home.appendingPathComponent(".toastty/codex-plugin/.agents/plugins/marketplace.json")
        )
        _ = await resolver.resolveForManagedLaunch(request: request, workingDirectory: fixture.root.path)
        XCTAssertEqual(fixture.transport.invocations.count, 3)
    }

    func testUntrustedAssessmentIsRecheckedOnEveryLaunch() async throws {
        let fixture = try Fixture(trust: "untrusted")
        defer { fixture.cleanup() }
        let resolver = fixture.resolver()
        let request = fixture.directRequest()

        let first = await resolver.resolveForManagedLaunch(request: request, workingDirectory: fixture.root.path)
        let second = await resolver.resolveForManagedLaunch(request: request, workingDirectory: fixture.root.path)

        XCTAssertNotNil(first.configuration)
        XCTAssertEqual(first.statusTrackingSource, .sessionLogFallback(reason: "session_hooks_awaiting_trust"))
        XCTAssertEqual(second.statusTrackingSource, first.statusTrackingSource)
        XCTAssertEqual(fixture.transport.invocations.count, 2)
    }

    func testProbeTimeoutReturnsFallbackWithoutBlockingMainActor() async throws {
        let fixture = try Fixture(trust: "trusted", delay: 0.2)
        defer { fixture.cleanup(after: 0.25) }
        let resolver = fixture.resolver(timeout: 0.02)
        let start = Date()

        let decision = await resolver.resolveForManagedLaunch(
            request: fixture.directRequest(),
            workingDirectory: fixture.root.path
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
        XCTAssertNil(decision.configuration)
        XCTAssertEqual(decision.statusTrackingSource, .sessionLogFallback(reason: "session_integration_probe_failed"))
    }

    @MainActor
    func testSlowProbeYieldsMainActorUntilTimeout() async throws {
        let fixture = try Fixture(trust: "trusted", delay: 0.2)
        defer { fixture.cleanup(after: 0.25) }
        let resolver = fixture.resolver(timeout: 0.05)
        var heartbeatRan = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5))
            heartbeatRan = true
        }

        _ = await resolver.resolveForManagedLaunch(
            request: fixture.directRequest(),
            workingDirectory: fixture.root.path
        )

        XCTAssertTrue(heartbeatRan)
    }
}

private extension CodexManagedLaunchIntegrationResolverTests {
    final class Fixture {
        let root: URL
        let home: URL
        let codexHome: URL
        let executable: URL
        let transport: AssessmentTransport
        let manager: CodexIntegrationManager

        init(trust: String, delay: TimeInterval = 0) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-codex-resolver-tests-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
            executable = root.appendingPathComponent("bin/codex")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let plugin = home.appendingPathComponent(
                ".toastty/codex-plugin/plugins/toastty",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: plugin.appendingPathComponent(".codex-plugin", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".toastty/codex-plugin/.agents/plugins", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data(#"{"name":"toastty","skills":"skills"}"#.utf8)
                .write(to: plugin.appendingPathComponent(".codex-plugin/plugin.json"))
            let skill = plugin.appendingPathComponent("skills/alpha", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: alpha\ndescription: test\n---\n".utf8)
                .write(to: skill.appendingPathComponent("SKILL.md"))
            try Data("{}".utf8).write(
                to: home.appendingPathComponent(".toastty/codex-plugin/.agents/plugins/marketplace.json")
            )

            let forwarder = CodexStatusHookInstaller(
                homeDirectoryPath: home.path,
                codexHomePath: codexHome.path
            ).sessionLaunchForwarderCommand()
            transport = AssessmentTransport(trust: trust, forwarderCommand: forwarder, delay: delay)
            manager = CodexIntegrationManager(
                homeDirectoryURL: home,
                sourceMarketplaceURLProvider: { nil },
                client: CodexAppServerClient(transport: transport)
            )
        }

        func resolver(timeout: TimeInterval = 0.5) -> CodexManagedLaunchIntegrationResolver {
            CodexManagedLaunchIntegrationResolver(
                homeDirectoryURL: home,
                manager: manager,
                processEnvironment: { [executable] in
                    ["PATH": executable.deletingLastPathComponent().path]
                },
                timeout: timeout
            )
        }

        func directRequest() -> ManagedAgentLaunchRequest {
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: UUID(),
                argv: ["codex"],
                cwd: root.path,
                codexCapabilityHint: ManagedCodexCapabilityHint(
                    resolvedExecutablePath: executable.path,
                    codexHomePath: codexHome.path
                )
            )
        }

        func cleanup(after delay: TimeInterval = 0) {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class AssessmentTransport: CodexAppServerRPCTransporting, @unchecked Sendable {
    private let trust: String
    private let forwarderCommand: String
    private let delay: TimeInterval
    private let lock = NSLock()
    private var storage: [CodexAppServerInvocation] = []

    init(trust: String, forwarderCommand: String, delay: TimeInterval) {
        self.trust = trust
        self.forwarderCommand = forwarderCommand
        self.delay = delay
    }

    var invocations: [CodexAppServerInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func perform(
        invocation: CodexAppServerInvocation,
        requests: [CodexAppServerRPCRequest]
    ) throws -> [CodexAppServerRPCResponse] {
        lock.lock()
        storage.append(invocation)
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return requests.map { request in
            switch request.method {
            case "skills/list":
                .init(result: .object([
                    "data": .array([.object([
                        "cwd": .string(invocation.workingDirectoryURL.path),
                        "skills": .array([.object([
                            "name": .string("toastty:alpha"),
                            "enabled": .bool(true),
                        ])]),
                        "errors": .array([]),
                    ])]),
                ]), errorCode: nil, errorMessage: nil)
            case "hooks/list":
                .init(result: Self.hooksResult(command: forwarderCommand, trust: trust), errorCode: nil, errorMessage: nil)
            default:
                .init(result: .object([:]), errorCode: nil, errorMessage: nil)
            }
        }
    }

    private static func hooksResult(command: String, trust: String) -> CodexJSONValue {
        let hooks = CodexSessionIntegrationContract.hookDefinitions.map { definition -> CodexJSONValue in
            let event: String = switch definition.event {
            case .sessionStart: "sessionStart"
            case .userPromptSubmit: "userPromptSubmit"
            case .permissionRequest: "permissionRequest"
            case .preToolUse: "preToolUse"
            case .subagentStart: "subagentStart"
            case .subagentStop: "subagentStop"
            case .stop: "stop"
            }
            return .object([
                "source": .string("sessionFlags"),
                "command": .string(command),
                "eventName": .string(event),
                "matcher": definition.matcher.map(CodexJSONValue.string) ?? .null,
                "timeoutSec": .int(CodexSessionIntegrationContract.hookTimeoutSeconds),
                "statusMessage": .string(CodexSessionIntegrationContract.hookStatusMessage),
                "trustStatus": .string(trust),
                "currentHash": .string("hash"),
            ])
        }
        return .object([
            "data": .array([.object([
                "cwd": .string("/tmp"),
                "hooks": .array(hooks),
                "warnings": .array([]),
                "errors": .array([]),
            ])]),
        ])
    }
}
