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
        let scriptPath = URL(fileURLWithPath: first.skillsRootPath)
            .appendingPathComponent("toastty-open-markdown/scripts/open.sh")
            .path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptPath))
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
    }

    func makeManifest(at rootURL: URL, version: String) throws {
        let codexURL = rootURL.appendingPathComponent(".codex-plugin", isDirectory: true)
        let claudeURL = rootURL.appendingPathComponent(".claude-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeURL, withIntermediateDirectories: true)
        try """
        {"name":"toastty","version":"\(version)","skills":"./skills/"}
        """.write(to: codexURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        try """
        {"name":"toastty","version":"\(version)"}
        """.write(to: claudeURL.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    }
}
