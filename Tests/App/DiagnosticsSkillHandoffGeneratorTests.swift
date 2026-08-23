import Foundation
import XCTest
@testable import ToasttyApp

final class DiagnosticsSkillHandoffGeneratorTests: XCTestCase {
    func testPromptPointsAtBundledSkillAndCLIWithoutDuplicatingWorkflow() {
        let prompt = DiagnosticsSkillHandoffGenerator.prompt(
            skillPath: "/Applications/Toastty Beta.app/Contents/Resources/ToasttyAgentPluginBundle/plugins/toastty/skills/toastty-send-diagnostics/SKILL.md",
            cliPath: "/Applications/Toastty Beta.app/Contents/Helpers/toastty"
        )

        XCTAssertTrue(prompt.contains("I want to send Toastty diagnostics."))
        XCTAssertTrue(
            prompt.contains(
                "/Applications/Toastty Beta.app/Contents/Resources/ToasttyAgentPluginBundle/plugins/toastty/skills/toastty-send-diagnostics/SKILL.md"
            )
        )
        XCTAssertTrue(prompt.contains("/Applications/Toastty Beta.app/Contents/Helpers/toastty"))
        XCTAssertTrue(prompt.contains("Use these exact bundled paths."))
        XCTAssertTrue(prompt.contains("If either is inaccessible, stop and tell me."))
        XCTAssertFalse(prompt.contains("/Applications/Toastty.app/Contents/Helpers/toastty"))
        XCTAssertFalse(prompt.contains("TOASTTY_SKILLS_ROOT"))
        XCTAssertFalse(prompt.contains("contact information"))
        XCTAssertFalse(prompt.contains("diagnostics collect"))
        XCTAssertFalse(prompt.contains("diagnostics submit"))
    }

    func testPromptPreservesLiteralApostrophesInPaths() {
        let prompt = DiagnosticsSkillHandoffGenerator.prompt(
            skillPath: "/tmp/O'Brien/Toastty.app/skill/SKILL.md",
            cliPath: "/tmp/O'Brien/Toastty.app/toastty"
        )

        XCTAssertTrue(prompt.contains("\n/tmp/O'Brien/Toastty.app/skill/SKILL.md\n"))
        XCTAssertTrue(prompt.contains("\n/tmp/O'Brien/Toastty.app/toastty\n"))
        XCTAssertFalse(prompt.contains("'\\''"))
    }

    func testSkillNameMatchesTheShippedCatalog() {
        XCTAssertTrue(
            ToasttyAgentPluginBundle.skills.contains {
                $0.name == DiagnosticsSkillHandoffGenerator.skillName
            }
        )
    }

    func testShippedSkillPreservesCollectionReviewConsentAndRetryContract() throws {
        let skill = try String(
            contentsOf: repoRootURL()
                .appendingPathComponent("plugins/toastty/skills", isDirectory: true)
                .appendingPathComponent("toastty-send-diagnostics", isDirectory: true)
                .appendingPathComponent("SKILL.md", isDirectory: false),
            encoding: .utf8
        )

        for requiredText in [
            "name: toastty-send-diagnostics",
            "asks to send Toastty diagnostics",
            "Do not infer post-review approval from the initial request",
            "Do not submit in the same uninterrupted step as collection and review",
            "Never derive contact details from Git configuration",
            "umask 077",
            "\"$TC\" --json doctor",
            "\"$TC\" diagnostics collect",
            "workspace layout profile summary",
            "updater/layout lifecycle events",
            "Do not paste the full diagnostics JSON",
            "Do not run broad heuristic grep or token scans",
            "Do not wrap the user-side submit command in `sv exec`",
            "retry the exact same command at most once",
            "Do not retry HTTP, authentication, TLS, connection-timeout",
            "report the returned Toastty diagnostics report ID",
        ] {
            XCTAssertTrue(skill.contains(requiredText), "Skill is missing: \(requiredText)")
        }

        let reviewRange = try XCTUnwrap(skill.range(of: "## Review"))
        let approvalRange = try XCTUnwrap(
            skill.range(of: "Only after a new explicit approval")
        )
        let submitRange = try XCTUnwrap(
            skill.range(of: "diagnostics submit --file")
        )
        XCTAssertLessThan(reviewRange.lowerBound, approvalRange.lowerBound)
        XCTAssertLessThan(approvalRange.lowerBound, submitRange.lowerBound)
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
