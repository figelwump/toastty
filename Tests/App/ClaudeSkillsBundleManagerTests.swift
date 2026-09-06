import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

final class ClaudeSkillsBundleManagerTests: XCTestCase {
    func testStagesImmutablePluginAndReusesVerifiedVersion() async throws {
        let rootURL = temporaryDirectory(named: "reuse")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent("staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: sourceURL, version: "1.2.3")

        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            stagingRootURL: stagingURL
        )
        let firstResult = await manager.prepareForManagedLaunch()
        let secondResult = await manager.prepareForManagedLaunch()
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.pluginRootPath))
        XCTAssertTrue(first.pluginRootPath.contains("1.2.3-\(first.contentDigest)"))
        XCTAssertEqual(
            manager.existingVerifiedConfiguration(),
            first
        )
        let deliveryStatus = await manager.deliveryStatus()
        XCTAssertEqual(deliveryStatus, .providedAtLaunch(first))
        let scriptPath = URL(fileURLWithPath: first.skillsRootPath)
            .appendingPathComponent("toastty-open-markdown/scripts/open.sh")
            .path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptPath))
        let cursorForwarderPath = URL(fileURLWithPath: first.pluginRootPath)
            .appendingPathComponent("cursor-hooks/forwarder.sh")
            .path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cursorForwarderPath))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: first.pluginRootPath)
                    .appendingPathComponent("hooks/hooks.json").path
            ),
            "Cursor hooks must not be discovered as Codex or Claude plugin hooks"
        )
        XCTAssertFalse(
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: first.pluginRootPath)
                    .appendingPathComponent("cursor-hooks/hooks.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: first.pluginRootPath)
                    .appendingPathComponent("cursor-hooks/hooks.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: first.skillsRootPath)
                    .appendingPathComponent("toastty-send-diagnostics/SKILL.md").path
            )
        )
    }

    func testChangedBundleCreatesNewVersionAndRetainsPreviousVersion() async throws {
        let rootURL = temporaryDirectory(named: "upgrade")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent("staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: sourceURL, version: "1.0.0")

        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            stagingRootURL: stagingURL
        )
        let firstResult = await manager.prepareForManagedLaunch()
        let first = try XCTUnwrap(firstResult)
        try makeManifest(at: sourceURL, version: "1.1.0")
        let secondResult = await manager.prepareForManagedLaunch()
        let second = try XCTUnwrap(secondResult)

        XCTAssertNotEqual(first.pluginRootPath, second.pluginRootPath)
        XCTAssertNotEqual(first.version, second.version)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.pluginRootPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.pluginRootPath))
    }

    func testMissingBundleFailsOpen() async {
        let rootURL = temporaryDirectory(named: "missing")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { nil },
            stagingRootURL: rootURL
        )

        let result = await manager.prepareForManagedLaunch()
        XCTAssertNil(result)
        XCTAssertNil(manager.existingVerifiedConfiguration())
        let deliveryStatus = await manager.deliveryStatus()
        guard case .unavailable = deliveryStatus else {
            return XCTFail("Expected unavailable delivery status")
        }
    }

    func testPluginReaderRejectsLeftoverDefaultHooks() throws {
        let rootURL = temporaryDirectory(named: "leftover-default-hooks")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: rootURL, version: "0.4.1")
        let defaultHooksURL = rootURL.appendingPathComponent("hooks/hooks.json")
        try FileManager.default.createDirectory(
            at: defaultHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{}".write(to: defaultHooksURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ToasttyAgentPluginBundle.read(pluginRootURL: rootURL)) { error in
            XCTAssertEqual(
                error as? ToasttyAgentPluginBundleError,
                .unexpectedDefaultHooks(defaultHooksURL.path)
            )
        }
    }

    func testStagesCurrentBundleBesideLegacyCursorHookLayout() async throws {
        let rootURL = temporaryDirectory(named: "legacy-cursor-upgrade")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("source/toastty")
        let stagingURL = rootURL.appendingPathComponent("staged")
        let legacyURL = stagingURL.appendingPathComponent("0.4.0-legacy/toastty")
        try makePlugin(at: legacyURL, version: "0.4.0")
        try FileManager.default.moveItem(
            at: legacyURL.appendingPathComponent("cursor-hooks"),
            to: legacyURL.appendingPathComponent("hooks")
        )
        let cursorManifestURL = legacyURL.appendingPathComponent(".cursor-plugin/plugin.json")
        let legacyManifest = try String(contentsOf: cursorManifestURL, encoding: .utf8)
            .replacingOccurrences(of: "./cursor-hooks/hooks.json", with: "./hooks/hooks.json")
        try legacyManifest.write(to: cursorManifestURL, atomically: true, encoding: .utf8)
        try makePlugin(at: sourceURL, version: "0.4.1")
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL }, stagingRootURL: stagingURL
        )

        let result = await manager.prepareForManagedLaunch()
        let configuration = try XCTUnwrap(result)
        let activeURL = URL(fileURLWithPath: configuration.pluginRootPath)
        XCTAssertEqual(configuration.version, "0.4.1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.appendingPathComponent("hooks").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.appendingPathComponent("cursor-hooks/hooks.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.appendingPathComponent("hooks/hooks.json").path))
    }

    func testPluginReaderRejectsBundleWithoutCursorAssets() throws {
        let rootURL = temporaryDirectory(named: "missing-cursor-assets")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: sourceURL, version: "1.2.3")
        try FileManager.default.removeItem(
            at: sourceURL.appendingPathComponent(".cursor-plugin", isDirectory: true)
        )
        try FileManager.default.removeItem(
            at: sourceURL.appendingPathComponent("cursor-hooks", isDirectory: true)
        )

        let manifestPath = sourceURL
            .appendingPathComponent(".cursor-plugin/plugin.json", isDirectory: false)
            .path
        XCTAssertThrowsError(try ToasttyAgentPluginBundle.read(pluginRootURL: sourceURL)) { error in
            XCTAssertEqual(
                error as? ToasttyAgentPluginBundleError,
                .unreadableManifest(manifestPath)
            )
        }
    }

    func testPluginReaderRejectsMissingCursorHookAssets() throws {
        let rootURL = temporaryDirectory(named: "missing-cursor-hook-assets")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        for (index, relativePath) in ["cursor-hooks/hooks.json", "cursor-hooks/forwarder.sh"].enumerated() {
            let sourceURL = rootURL.appendingPathComponent("case-\(index)/toastty", isDirectory: true)
            try makePlugin(at: sourceURL, version: "1.2.3")
            let missingURL = sourceURL.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.removeItem(at: missingURL)

            XCTAssertThrowsError(try ToasttyAgentPluginBundle.read(pluginRootURL: sourceURL)) { error in
                XCTAssertEqual(
                    error as? ToasttyAgentPluginBundleError,
                    .unreadablePlugin(missingURL.path),
                    relativePath
                )
            }
        }
    }

    func testDeliveryStatusDoesNotStagePluginBeforeManagedLaunch() async throws {
        let rootURL = temporaryDirectory(named: "status-without-staging")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent("staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: sourceURL, version: "1.2.3")
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            stagingRootURL: stagingURL
        )

        let deliveryStatus = await manager.deliveryStatus()
        XCTAssertEqual(deliveryStatus, .stagesOnNextLaunch(version: "1.2.3"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    func testDeliveryStatusReportsInvalidStagedPlugin() async throws {
        let rootURL = temporaryDirectory(named: "invalid-status")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent("staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: sourceURL, version: "1.2.3")
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            stagingRootURL: stagingURL
        )
        let preparedConfiguration = await manager.prepareForManagedLaunch()
        let configuration = try XCTUnwrap(preparedConfiguration)
        try "invalid".write(
            to: URL(fileURLWithPath: configuration.skillsRootPath)
                .appendingPathComponent("toastty-capabilities/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let deliveryStatus = await manager.deliveryStatus()
        guard case .unavailable = deliveryStatus else {
            return XCTFail("Expected invalid staged plugin to need attention")
        }
    }

    func testRuntimeIsolatedManagerStagesUnderIsolatedRootOnly() async throws {
        let rootURL = temporaryDirectory(named: "isolated-runtime")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let isolatedHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let realHomeURL = rootURL.appendingPathComponent("real-home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: realHomeURL, withIntermediateDirectories: true)
        try makePlugin(at: sourceURL, version: "1.2.3")
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: realHomeURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": isolatedHomeURL.path]
        )
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            runtimePaths: runtimePaths
        )

        let preparedConfiguration = await manager.prepareForManagedLaunch()
        let configuration = try XCTUnwrap(preparedConfiguration)

        let isolatedStagingRootPath = isolatedHomeURL
            .appendingPathComponent("agent-plugins/claude", isDirectory: true).path
        XCTAssertTrue(configuration.pluginRootPath.hasPrefix(isolatedStagingRootPath + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.pluginRootPath))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: realHomeURL.appendingPathComponent(".toastty").path),
            "Isolated runs must never write into the real home's .toastty"
        )
    }

    func testProductionRuntimePathsStageUnderHomeToastty() async throws {
        let rootURL = temporaryDirectory(named: "production-paths")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try makePlugin(at: sourceURL, version: "1.2.3")
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeURL.path,
            environment: [:]
        )
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            runtimePaths: runtimePaths
        )

        let preparedConfiguration = await manager.prepareForManagedLaunch()
        let configuration = try XCTUnwrap(preparedConfiguration)

        XCTAssertTrue(
            configuration.pluginRootPath.hasPrefix(
                homeURL.appendingPathComponent(".toastty/agent-plugins/claude", isDirectory: true).path + "/"
            )
        )
    }

    func testRestoredLaunchStagesChangedBundleBeforeResume() throws {
        let rootURL = temporaryDirectory(named: "restored-upgrade")
        let sourceURL = rootURL.appendingPathComponent("source/toastty", isDirectory: true)
        let stagingURL = rootURL.appendingPathComponent("staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try makePlugin(at: sourceURL, version: "1.0.0")
        let manager = ClaudeSkillsBundleManager(
            sourcePluginURLProvider: { sourceURL },
            stagingRootURL: stagingURL
        )
        let first = try XCTUnwrap(manager.prepareForRestoredManagedLaunch())
        try makeManifest(at: sourceURL, version: "1.1.0")

        let updated = try XCTUnwrap(manager.prepareForRestoredManagedLaunch())

        XCTAssertNotEqual(updated.pluginRootPath, first.pluginRootPath)
        XCTAssertEqual(updated.version, "1.1.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: updated.pluginRootPath))
    }
}

private extension ClaudeSkillsBundleManagerTests {
    func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-claude-skills-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    func makePlugin(at rootURL: URL, version: String) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try makeManifest(at: rootURL, version: version)
        for skill in ToasttyAgentPluginBundle.skills {
            let skillURL = rootURL.appendingPathComponent("skills/\(skill.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
            try "---\nname: \(skill.name)\ndescription: Test skill.\n---\n"
                .write(to: skillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let scriptsURL = rootURL.appendingPathComponent(
            "skills/toastty-open-markdown/scripts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n"
            .write(to: scriptsURL.appendingPathComponent("open.sh"), atomically: true, encoding: .utf8)
        let hooksURL = rootURL.appendingPathComponent("cursor-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksURL, withIntermediateDirectories: true)
        try "{}\n".write(
            to: hooksURL.appendingPathComponent("hooks.json"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: hooksURL.appendingPathComponent("forwarder.sh"),
            atomically: true,
            encoding: .utf8
        )
    }

    func makeManifest(at rootURL: URL, version: String) throws {
        let codexURL = rootURL.appendingPathComponent(".codex-plugin", isDirectory: true)
        let claudeURL = rootURL.appendingPathComponent(".claude-plugin", isDirectory: true)
        let cursorURL = rootURL.appendingPathComponent(".cursor-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: true)
        try """
        {"name":"toastty","version":"\(version)","skills":"./skills/"}
        """.write(to: codexURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try """
        {"name":"toastty","version":"\(version)"}
        """.write(to: claudeURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try """
        {"name":"toastty","version":"\(version)","skills":"./skills/","hooks":"./cursor-hooks/hooks.json"}
        """.write(to: cursorURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    }
}
