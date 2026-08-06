import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

final class CodexManagedLaunchSkillsResolverTests: XCTestCase {
    func testDirectLaunchUsesResolvedExecutableThenFailsOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let customHome = fixture.rootURL.appendingPathComponent("custom-codex-home", isDirectory: true)
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["codex", "resume", "thread"],
            cwd: fixture.rootURL.path,
            environment: ["CODEX_HOME": customHome.path]
        )

        let decision = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertNil(decision.configuration)
        XCTAssertNil(decision.status)
        let invocation = try XCTUnwrap(fixture.pluginClient.invocations.first)
        XCTAssertEqual(invocation.executableURL, fixture.executableURL)
        XCTAssertEqual(
            invocation.processEnvironment.path,
            "\(fixture.executableURL.deletingLastPathComponent().path):/usr/bin:/bin"
        )
        // Population targets a throwaway home, never the launch CODEX_HOME.
        XCTAssertNotEqual(invocation.codexHomeURL, customHome)
    }

    func testOpaqueWrapperIsNeverProbed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["opaque-wrapper", "codex"],
            cwd: fixture.rootURL.path
        )

        let decision = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertNil(decision.configuration)
        XCTAssertNil(decision.status)
        XCTAssertEqual(fixture.pluginClient.invocations.count, 0)
    }

    func testUnsupportedRuntimeIsCachedAfterFirstProbe() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = fixture.directRequest()

        _ = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )
        _ = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertEqual(fixture.pluginClient.invocations.count, 1)
    }

    func testUnsupportedRuntimeIsRetriedAfterExecutableChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = fixture.directRequest()
        _ = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )
        try "#!/bin/sh\n# updated\nexit 0\n".write(
            to: fixture.executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.executableURL.path
        )

        _ = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertEqual(fixture.pluginClient.invocations.count, 2)
    }

    func testSynchronousRestorePathRunsBoundedProvisioningAndFailsOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let decision = fixture.resolver.resolveForRestoredManagedLaunch(
            request: fixture.directRequest(),
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertNil(decision.configuration)
        XCTAssertNil(decision.status)
        XCTAssertEqual(fixture.pluginClient.invocations.count, 1)
    }

    func testTypedCodexPathOverridesTheSharedLoginShellPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: ["codex"],
            cwd: fixture.rootURL.path,
            codexCapabilityHint: ManagedCodexCapabilityHint(
                resolvedExecutablePath: fixture.executableURL.path,
                processPath: "/typed/node/bin:/usr/bin:/bin"
            )
        )

        _ = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertEqual(
            fixture.pluginClient.invocations.first?.processEnvironment.path,
            "/typed/node/bin:/usr/bin:/bin"
        )
    }

    func testLegacyRequestWithoutShimMetadataFallsBackToSharedPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = ManagedAgentLaunchRequest(
            agent: .codex,
            panelID: UUID(),
            argv: [fixture.executableURL.path],
            cwd: fixture.rootURL.path,
            environment: ["PATH": "/untrusted/stale-shim:/usr/bin"]
        )

        _ = await fixture.resolver.resolveForManagedLaunch(
            request: request,
            workingDirectory: fixture.rootURL.path
        )

        XCTAssertEqual(
            fixture.pluginClient.invocations.first?.processEnvironment.path,
            "\(fixture.executableURL.deletingLastPathComponent().path):/usr/bin:/bin"
        )
    }

    func testProcessPathStoreRefreshesItsCachedValue() {
        let store = CodexProcessPathStore(path: "/old/bin", refreshPath: { "/new/bin" })

        XCTAssertEqual(store.currentPath(), "/old/bin")
        XCTAssertEqual(store.refresh(), "/new/bin")
        XCTAssertEqual(store.currentPath(), "/new/bin")
    }

    func testProcessPathStoreKeepsCachedValueWhenRefreshFails() {
        let store = CodexProcessPathStore(path: "/known-good/bin", refreshPath: { nil })

        XCTAssertEqual(store.refresh(), "/known-good/bin")
        XCTAssertEqual(store.currentPath(), "/known-good/bin")
    }
}

private extension CodexManagedLaunchSkillsResolverTests {
    final class Fixture {
        let rootURL: URL
        let homeURL: URL
        let executableURL: URL
        let pluginClient: UnsupportedRecordingPluginClient
        let resolver: CodexManagedLaunchSkillsResolver

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-codex-skills-resolver-\(UUID().uuidString)", isDirectory: true)
            homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
            executableURL = rootURL.appendingPathComponent("bin/codex")
            pluginClient = UnsupportedRecordingPluginClient()
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: executableURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "#!/bin/sh\nexit 0\n".write(
                to: executableURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )

            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let manager = CodexSkillsManager(
                runtimePaths: .resolve(homeDirectoryPath: homeURL.path, environment: [:]),
                homeDirectoryURL: homeURL,
                sourcePluginURLProvider: {
                    repositoryRoot.appendingPathComponent("plugins/toastty", isDirectory: true)
                },
                sourceMarketplaceURLProvider: { repositoryRoot },
                pluginClient: pluginClient
            )
            resolver = CodexManagedLaunchSkillsResolver(
                homeDirectoryURL: homeURL,
                manager: manager,
                processEnvironment: { ["PATH": "/usr/bin:/bin"] },
                processPathProvider: { [executableURL] in
                    executableURL.deletingLastPathComponent().path
                }
            )
        }

        func directRequest() -> ManagedAgentLaunchRequest {
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: UUID(),
                argv: ["codex"],
                cwd: rootURL.path
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}

/// Records the population invocation and reports an unsupported Codex CLI so
/// resolver-level fail-open and unsupported-caching behavior can be observed
/// without touching real state.
private final class UnsupportedRecordingPluginClient: CodexPluginCLIManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CodexIntegrationRuntime] = []

    var invocations: [CodexIntegrationRuntime] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func listMarketplaces(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexPluginMarketplace] {
        // Only the legacy-cleanup path lists marketplaces; these fixtures
        // never stage legacy state.
        XCTFail("listMarketplaces should not run without legacy state")
        return []
    }

    func listInstalledPlugins(runtime: CodexIntegrationRuntime, deadline: Date) throws -> [CodexInstalledPlugin] {
        XCTFail("listInstalledPlugins should not run without legacy state")
        return []
    }

    func addMarketplace(
        runtime: CodexIntegrationRuntime,
        sourcePath: String,
        deadline: Date
    ) throws -> String {
        lock.lock()
        storage.append(runtime)
        lock.unlock()
        throw CodexPluginCLIError.commandFailed(
            "plugin marketplace add",
            2,
            "unrecognized subcommand 'plugin'"
        )
    }

    func installPlugin(
        runtime: CodexIntegrationRuntime,
        selector: String,
        deadline: Date
    ) throws -> CodexPluginInstallation {
        XCTFail("Plugin install should not run after the marketplace add fails")
        throw CodexPluginCLIError.commandFailed("plugin add", 1, "unexpected")
    }

    func removePlugin(runtime: CodexIntegrationRuntime, selector: String, deadline: Date) throws {
        XCTFail("Plugin CLI remove should not run")
    }

    func removeMarketplace(runtime: CodexIntegrationRuntime, name: String, deadline: Date) throws {
        XCTFail("Marketplace remove should not run")
    }
}
