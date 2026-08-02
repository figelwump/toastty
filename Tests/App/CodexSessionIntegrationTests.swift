import Foundation
import XCTest
@testable import ToasttyApp

final class CodexSessionIntegrationTests: XCTestCase {
    func testManifestReaderDerivesSortedQualifiedSkillNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-plugin-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".codex-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"name":"toastty","skills":"./skills/"}"#.utf8).write(
            to: root.appendingPathComponent(".codex-plugin/plugin.json")
        )
        for name in ["worktree-done", "toastty-scratchpad"] {
            let directory = root.appendingPathComponent("skills/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: Test\n---\n".utf8).write(
                to: directory.appendingPathComponent("SKILL.md")
            )
        }

        let manifest = try CodexPluginSkillManifestReader.read(pluginDirectoryURL: root)

        XCTAssertEqual(manifest.pluginName, "toastty")
        XCTAssertEqual(manifest.skillNames, ["toastty-scratchpad", "worktree-done"])
        XCTAssertEqual(
            manifest.qualifiedSkillNames,
            ["toastty:toastty-scratchpad", "toastty:worktree-done"]
        )
    }

    func testLaunchOverridesAreDeterministicAndEscapeToml() {
        let overrides = CodexSessionIntegrationContract.launchOverrides(
            enabling: ["toastty:worktree-done", "toastty:toastty-\"scratchpad\\"],
            forwarderCommand: #"/bin/sh '/tmp/Toastty Hooks/forwarder.sh'"#
        )

        XCTAssertEqual(
            overrides[0],
            #"skills.config=[{name="toastty:toastty-\"scratchpad\\",enabled=true},{name="toastty:worktree-done",enabled=true}]"#
        )
        XCTAssertEqual(overrides.count, 2)
        XCTAssertTrue(overrides[1].hasPrefix("hooks={SessionStart="))
        XCTAssertTrue(overrides[1].contains(#"PermissionRequest=[{matcher="*""#))
        XCTAssertTrue(overrides[1].contains(#"command="/bin/sh '/tmp/Toastty Hooks/forwarder.sh'""#))
        XCTAssertEqual(overrides[1].components(separatedBy: "type=\"command\"").count - 1, 7)
    }

    func testAssessmentRequiresExactSkillsAndAllTrustedHooks() {
        let skillNames = ["toastty:toastty-scratchpad"]
        let hooks = CodexSessionHookEvent.allCases.map {
            CodexSessionHookAssessment(event: $0, trust: .trusted, definitionHash: "hash-\($0.rawValue)")
        }
        let assessment = CodexSessionIntegrationAssessment(
            support: .supported,
            expectedSkillNames: skillNames,
            installedSkillNames: skillNames,
            enabledSkillNames: skillNames,
            sessionHooks: hooks,
            legacyGlobalHooksPresent: false,
            warnings: [],
            errors: []
        )

        XCTAssertTrue(assessment.canUseSessionIntegrations)
        XCTAssertTrue(assessment.allSessionHooksTrusted)
    }

    func testAssessmentRejectsUntrustedManagedChangedOrMismatchedHooks() {
        let skillNames = ["toastty:toastty-scratchpad"]
        for trust in [
            CodexHookTrustState.untrusted,
            .managed,
            .changed,
            .unknown,
        ] {
            var hooks = CodexSessionHookEvent.allCases.map {
                CodexSessionHookAssessment(event: $0, trust: .trusted, definitionHash: nil)
            }
            hooks[0] = CodexSessionHookAssessment(
                event: hooks[0].event,
                trust: trust,
                definitionHash: nil
            )
            let assessment = makeAssessment(skillNames: skillNames, hooks: hooks)
            XCTAssertFalse(assessment.canUseSessionIntegrations, "Unexpected trust acceptance: \(trust)")
            XCTAssertTrue(assessment.canInjectSessionConfiguration)
        }

        let mismatchedHooks = CodexSessionHookEvent.allCases.map {
            CodexSessionHookAssessment(
                event: $0,
                trust: .trusted,
                definitionHash: nil,
                definitionMatchesExpected: $0 != .sessionStart
            )
        }
        XCTAssertFalse(makeAssessment(skillNames: skillNames, hooks: mismatchedHooks).parsedAllSessionHooks)
    }

    func testAssessmentRejectsEmptySkillsDuplicateHooksAndLegacyGlobals() {
        let trustedHooks = CodexSessionHookEvent.allCases.map {
            CodexSessionHookAssessment(event: $0, trust: .trusted, definitionHash: nil)
        }
        XCTAssertFalse(makeAssessment(skillNames: [], hooks: trustedHooks).managedSkillsEnabled)

        let duplicateHooks = trustedHooks + [trustedHooks[0]]
        XCTAssertFalse(
            makeAssessment(
                skillNames: ["toastty:toastty-scratchpad"],
                hooks: duplicateHooks
            ).parsedAllSessionHooks
        )

        let legacyAssessment = makeAssessment(
            skillNames: ["toastty:toastty-scratchpad"],
            hooks: trustedHooks,
            legacyGlobalHooksPresent: true
        )
        XCTAssertFalse(legacyAssessment.canUseSessionIntegrations)
        XCTAssertTrue(legacyAssessment.canInjectSessionConfiguration)
    }

    func testManifestReaderRejectsWrongPluginNameAndEscapingSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-plugin-contract-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-plugin-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".codex-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let manifestURL = root.appendingPathComponent(".codex-plugin/plugin.json")
        try Data(#"{"name":"other","skills":"./skills/"}"#.utf8).write(to: manifestURL)
        XCTAssertThrowsError(try CodexPluginSkillManifestReader.read(pluginDirectoryURL: root))

        let skillsLink = root.appendingPathComponent("skills")
        try FileManager.default.createSymbolicLink(at: skillsLink, withDestinationURL: outside)
        try Data(#"{"name":"toastty","skills":"./skills/"}"#.utf8).write(to: manifestURL)
        XCTAssertThrowsError(try CodexPluginSkillManifestReader.read(pluginDirectoryURL: root))
    }

    private func makeAssessment(
        skillNames: [String],
        hooks: [CodexSessionHookAssessment],
        legacyGlobalHooksPresent: Bool = false
    ) -> CodexSessionIntegrationAssessment {
        CodexSessionIntegrationAssessment(
            support: .supported,
            expectedSkillNames: skillNames,
            installedSkillNames: skillNames,
            enabledSkillNames: skillNames,
            sessionHooks: hooks,
            legacyGlobalHooksPresent: legacyGlobalHooksPresent,
            warnings: [],
            errors: []
        )
    }
}
