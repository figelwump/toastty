import XCTest
@testable import ToasttyApp

final class CodexIntegrationManagerTests: XCTestCase {
    func testSetupDisablesBeforeInstallThenReappliesAndVerifies() throws {
        let fixture = try Fixture(skillNames: ["alpha", "beta"])
        defer { fixture.cleanup() }
        let transport = StatefulSetupTransport()
        let manager = fixture.manager(transport: transport)

        let result = try manager.setup(runtime: fixture.runtime)

        let methods = transport.methods
        let installIndex = try XCTUnwrap(methods.firstIndex(of: "plugin/install"))
        let writes = methods.enumerated().filter { $0.element == "skills/config/write" }.map(\.offset)
        XCTAssertEqual(writes.count, 4)
        XCTAssertTrue(writes.prefix(2).allSatisfy { $0 < installIndex })
        XCTAssertTrue(writes.suffix(2).allSatisfy { $0 > installIndex })
        XCTAssertTrue(result.status.plugin.state == .ready)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(".toastty/codex-plugin/plugins/toastty/.codex-plugin/plugin.json").path
        ))
        XCTAssertEqual(
            transport.firstParams(method: "marketplace/add")?["source"]?.stringValue,
            fixture.home.appendingPathComponent(".toastty/codex-plugin").path
        )
        XCTAssertEqual(
            transport.firstParams(method: "plugin/install")?["marketplacePath"]?.stringValue,
            fixture.home.appendingPathComponent(
                ".toastty/codex-plugin/.agents/plugins/marketplace.json"
            ).path
        )
        XCTAssertTrue(transport.codexHomes.allSatisfy { $0 == fixture.codexHome.path })
    }

    func testUpdateUsesMarketplaceUpgradeAndDisablesNewSkillBeforeRefresh() throws {
        let fixture = try Fixture(skillNames: ["alpha"])
        defer { fixture.cleanup() }
        let transport = StatefulSetupTransport()
        let manager = fixture.manager(transport: transport)
        _ = try manager.setup(runtime: fixture.runtime)
        transport.resetRecordedMethods()
        try fixture.addSkill(named: "beta")

        _ = try manager.setup(runtime: fixture.runtime)

        let methods = transport.methods
        let upgradeIndex = try XCTUnwrap(methods.firstIndex(of: "marketplace/upgrade"))
        XCTAssertNil(methods.firstIndex(of: "plugin/install"))
        let betaWriteIndex = try XCTUnwrap(transport.firstWriteIndex(name: "toastty:beta"))
        XCTAssertLessThan(betaWriteIndex, upgradeIndex)
    }

    func testSetupRejectsUnexpectedToasttySkillFromInstalledPlugin() throws {
        let fixture = try Fixture(skillNames: ["alpha"])
        defer { fixture.cleanup() }
        let transport = StatefulSetupTransport(extraInstalledSkill: "toastty:unexpected")
        let manager = fixture.manager(transport: transport)

        XCTAssertThrowsError(try manager.setup(runtime: fixture.runtime)) { error in
            guard case CodexIntegrationManagerError.installedSkillSetMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSetupMigratesOwnedLegacySkillAndPreservesModifiedConflict() throws {
        let fixture = try Fixture(skillNames: ["alpha", "beta"])
        defer { fixture.cleanup() }
        let legacyRoot = fixture.codexHome.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: legacyRoot.appendingPathComponent("alpha"),
            withDestinationURL: fixture.source.appendingPathComponent("plugins/toastty/skills/alpha")
        )
        let modified = legacyRoot.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: modified, withIntermediateDirectories: true)
        try Data("modified".utf8).write(to: modified.appendingPathComponent("SKILL.md"))

        let result = try fixture.manager(transport: StatefulSetupTransport()).setup(runtime: fixture.runtime)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("alpha").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modified.path))
        XCTAssertEqual(result.status.legacySkillConflictPaths, [modified.path])
        XCTAssertEqual(result.status.legacySkills.state, .warning)
    }

    func testUninstallRemovesPluginMarketplaceAndStableCopyButReportsDisabledTombstones() throws {
        let fixture = try Fixture(skillNames: ["alpha", "beta"])
        defer { fixture.cleanup() }
        let transport = StatefulSetupTransport()
        let manager = fixture.manager(transport: transport)
        _ = try manager.setup(runtime: fixture.runtime)
        transport.resetRecordedMethods()

        let status = try manager.uninstall(runtime: fixture.runtime, restoreLegacySkills: false)

        XCTAssertEqual(
            transport.methods.filter { ["plugin/uninstall", "marketplace/remove"].contains($0) },
            ["plugin/uninstall", "marketplace/remove"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.stableMarketplaceURL.path))
        XCTAssertEqual(status.plugin.state, .needsSetup)
        XCTAssertEqual(status.disabledNameTombstones, ["toastty:alpha", "toastty:beta"])
    }

    func testLegacyGlobalHookPresenceKeepsFallbackOwnership() throws {
        let fixture = try Fixture(skillNames: ["alpha"])
        defer { fixture.cleanup() }
        let transport = StatefulSetupTransport()
        let manager = fixture.manager(transport: transport)
        _ = try manager.setup(runtime: fixture.runtime)
        let hooksURL = fixture.codexHome.appendingPathComponent("hooks.json")
        let command = CodexStatusHookInstaller(
            homeDirectoryPath: fixture.home.path,
            codexHomePath: fixture.codexHome.path
        ).sessionLaunchForwarderCommand()
        let object: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": command]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: hooksURL)

        let decision = try manager.managedLaunchDecision(runtime: fixture.runtime)

        XCTAssertEqual(
            decision.statusTrackingSource,
            .sessionLogFallback(reason: "legacy_global_hooks_present")
        )
        XCTAssertEqual(decision.configuration?.legacyGlobalHooksPresent, true)
    }
}

private extension CodexIntegrationManagerTests {
    final class Fixture {
        let root: URL
        let home: URL
        let codexHome: URL
        let source: URL
        let executable: URL

        init(skillNames: [String]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-codex-manager-tests-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
            source = root.appendingPathComponent("bundle/CodexPluginMarketplace", isDirectory: true)
            executable = root.appendingPathComponent("bin/codex", isDirectory: false)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent("plugins/toastty/.codex-plugin", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent(".agents/plugins", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data(#"{"name":"toastty","plugins":[{"name":"toastty","source":"./plugins/toastty"}]}"#.utf8)
                .write(to: source.appendingPathComponent(".agents/plugins/marketplace.json"))
            try Data(#"{"name":"toastty","skills":"skills"}"#.utf8)
                .write(to: source.appendingPathComponent("plugins/toastty/.codex-plugin/plugin.json"))
            for name in skillNames {
                try addSkill(named: name)
            }
        }

        var runtime: CodexIntegrationRuntime {
            CodexIntegrationRuntime(
                executableURL: executable,
                codexHomeURL: codexHome,
                workingDirectoryURL: root
            )
        }

        func manager(transport: StatefulSetupTransport) -> CodexIntegrationManager {
            CodexIntegrationManager(
                homeDirectoryURL: home,
                sourceMarketplaceURLProvider: { [source] in source },
                client: CodexAppServerClient(transport: transport),
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
        }

        func addSkill(named name: String) throws {
            let skill = source.appendingPathComponent("plugins/toastty/skills/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: test\n---\n".utf8)
                .write(to: skill.appendingPathComponent("SKILL.md"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class StatefulSetupTransport: CodexAppServerRPCTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, [String: CodexJSONValue])] = []
    private var disabledNames = Set<String>()
    private var pluginInstalled = false
    private let extraInstalledSkill: String?
    private(set) var codexHomes: [String] = []

    init(extraInstalledSkill: String? = nil) {
        self.extraInstalledSkill = extraInstalledSkill
    }

    var methods: [String] {
        lock.withLock { recorded.map(\.0) }
    }

    func resetRecordedMethods() {
        lock.withLock { recorded.removeAll() }
    }

    func firstWriteIndex(name: String) -> Int? {
        lock.withLock {
            recorded.firstIndex { method, params in
                method == "skills/config/write" && params["name"]?.stringValue == name
            }
        }
    }

    func firstParams(method: String) -> [String: CodexJSONValue]? {
        lock.withLock {
            recorded.first(where: { $0.0 == method })?.1
        }
    }

    func perform(
        invocation: CodexAppServerInvocation,
        requests: [CodexAppServerRPCRequest]
    ) throws -> [CodexAppServerRPCResponse] {
        lock.lock()
        defer { lock.unlock() }
        codexHomes.append(invocation.codexHomeURL.path)
        return requests.map { request in
            recorded.append((request.method, request.params))
            switch request.method {
            case "skills/config/write":
                if let name = request.params["name"]?.stringValue {
                    disabledNames.insert(name)
                }
                return .init(result: .object(["effectiveEnabled": .bool(false)]), errorCode: nil, errorMessage: nil)
            case "marketplace/add":
                return .init(result: .object([
                    "marketplaceName": .string("toastty"),
                    "installedRoot": .string(invocation.codexHomeURL.path),
                    "alreadyAdded": .bool(pluginInstalled),
                ]), errorCode: nil, errorMessage: nil)
            case "plugin/installed":
                let plugins: [CodexJSONValue] = pluginInstalled ? [
                    .object([
                        "id": .string("toastty@toastty"),
                        "name": .string("toastty"),
                        "installed": .bool(true),
                    ]),
                ] : []
                return .init(result: .object([
                    "marketplaces": .array([.object([
                        "name": .string("toastty"),
                        "path": .string("/tmp/marketplace.json"),
                        "plugins": .array(plugins),
                    ])]),
                    "marketplaceLoadErrors": .array([]),
                ]), errorCode: nil, errorMessage: nil)
            case "plugin/install", "marketplace/upgrade":
                pluginInstalled = true
                return .init(result: .object([:]), errorCode: nil, errorMessage: nil)
            case "plugin/uninstall":
                pluginInstalled = false
                return .init(result: .object([:]), errorCode: nil, errorMessage: nil)
            case "marketplace/remove":
                return .init(result: .object([:]), errorCode: nil, errorMessage: nil)
            case "skills/list":
                let managed = invocation.configOverrides.isEmpty == false
                var names = disabledNames.sorted()
                if let extraInstalledSkill { names.append(extraInstalledSkill) }
                return .init(result: .object([
                    "data": .array([.object([
                        "cwd": .string(invocation.workingDirectoryURL.path),
                        "skills": .array(names.map { name in
                            .object(["name": .string(name), "enabled": .bool(managed)])
                        }),
                        "errors": .array([]),
                    ])]),
                ]), errorCode: nil, errorMessage: nil)
            case "hooks/list":
                let command = invocation.configOverrides
                    .first(where: { $0.hasPrefix("hooks=") })
                    .flatMap(Self.forwarderCommand(from:)) ?? "missing"
                return .init(result: Self.hooksResult(command: command), errorCode: nil, errorMessage: nil)
            default:
                return .init(result: .object([:]), errorCode: nil, errorMessage: nil)
            }
        }
    }

    private static func forwarderCommand(from override: String) -> String? {
        // The assessment compares the parsed app-server command with the same
        // stable command supplied by the manager. Tests recover that single
        // TOML basic string without trying to parse unrelated config fields.
        guard let range = override.range(of: "command=\"") else { return nil }
        let suffix = override[range.upperBound...]
        guard let end = suffix.firstIndex(of: "\"") else { return nil }
        return String(suffix[..<end]).replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func hooksResult(command: String) -> CodexJSONValue {
        let hooks = CodexSessionIntegrationContract.hookDefinitions.map { definition -> CodexJSONValue in
            let listValue: String = switch definition.event {
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
                "eventName": .string(listValue),
                "matcher": definition.matcher.map(CodexJSONValue.string) ?? .null,
                "timeoutSec": .int(CodexSessionIntegrationContract.hookTimeoutSeconds),
                "statusMessage": .string(CodexSessionIntegrationContract.hookStatusMessage),
                "trustStatus": .string("untrusted"),
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

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
