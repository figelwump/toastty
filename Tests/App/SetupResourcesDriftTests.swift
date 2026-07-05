@testable import ToasttyApp
import Foundation
import XCTest

final class SetupResourcesDriftTests: XCTestCase {
    func testStarterSkillSetMatchesM1Bundle() throws {
        let starterSkillsURL = setupResourcesURL()
            .appendingPathComponent("starter-skills", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: starterSkillsURL,
            includingPropertiesForKeys: nil
        )
        let names = entries
            .filter { $0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            names,
            [
                "toastty-capabilities",
                "toastty-open-markdown",
                "toastty-scratchpad",
            ]
        )
    }

    func testSetupResourcesAvoidRepoLocalPathsAndDevEnvVars() throws {
        let repoRootPath = repoRootURL().path
        let homePath = NSHomeDirectory()
        for fileURL in try regularFiles(under: setupResourcesURL()) {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(content.contains(repoRootPath), fileURL.path)
            XCTAssertFalse(content.contains(homePath), fileURL.path)
            XCTAssertFalse(content.contains("/Users/vishal"), fileURL.path)
            XCTAssertFalse(content.contains("toastty-agent-getting-started"), fileURL.path)
            XCTAssertFalse(content.contains("TOASTTY_DEV_WORKTREE_ROOT"), fileURL.path)
        }
    }

    func testSkillScriptReferencesStayInsideTheirSkillDirectory() throws {
        let starterSkillsURL = setupResourcesURL()
            .appendingPathComponent("starter-skills", isDirectory: true)
        let regex = try NSRegularExpression(
            pattern: #"(?:~/)?\.agents/skills/([A-Za-z0-9_-]+)/scripts/([A-Za-z0-9._-]+)"#
        )

        for skillURL in try FileManager.default.contentsOfDirectory(
            at: starterSkillsURL,
            includingPropertiesForKeys: nil
        ) where skillURL.hasDirectoryPath {
            let skillName = skillURL.lastPathComponent
            let skillMarkdownURL = skillURL.appendingPathComponent("SKILL.md", isDirectory: false)
            let content = try String(contentsOf: skillMarkdownURL, encoding: .utf8)
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = regex.matches(in: content, range: nsRange)

            for match in matches {
                let referencedSkill = try XCTUnwrap(Range(match.range(at: 1), in: content))
                let referencedScript = try XCTUnwrap(Range(match.range(at: 2), in: content))
                XCTAssertEqual(String(content[referencedSkill]), skillName)
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: skillURL
                            .appendingPathComponent("scripts", isDirectory: true)
                            .appendingPathComponent(String(content[referencedScript]), isDirectory: false)
                            .path
                    ),
                    "Missing script \(content[referencedScript]) for \(skillName)"
                )
            }
        }
    }

    func testCapabilitiesSkillMentionsOnlyKnownActionAndQueryIDs() throws {
        let content = try String(
            contentsOf: setupResourcesURL()
                .appendingPathComponent("starter-skills", isDirectory: true)
                .appendingPathComponent("toastty-capabilities", isDirectory: true)
                .appendingPathComponent("SKILL.md", isDirectory: false),
            encoding: .utf8
        )
        let knownIDs = Set(AppControlActionID.allCases.map(\.rawValue))
            .union(AppControlQueryID.allCases.map(\.rawValue))
        let regex = try NSRegularExpression(
            pattern: #"\b(?:window|workspace|panel|terminal|agent|config|app)\.[A-Za-z0-9._-]+"#
        )
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let mentionedIDs = Set(
            regex.matches(in: content, range: nsRange).compactMap { match -> String? in
                guard let range = Range(match.range, in: content) else { return nil }
                return String(content[range])
            }
        )

        XCTAssertFalse(mentionedIDs.isEmpty)
        XCTAssertLessThan(
            mentionedIDs.count,
            knownIDs.count / 2,
            "Capabilities skill should teach discovery and examples, not duplicate the full catalog."
        )
        XCTAssertTrue(
            mentionedIDs.subtracting(knownIDs).isEmpty,
            "Unknown IDs: \(mentionedIDs.subtracting(knownIDs).sorted().joined(separator: ", "))"
        )
    }

    func testOnboardingGuideMentionsEveryShippedSetupSubcommand() throws {
        let guide = try String(
            contentsOf: setupResourcesURL().appendingPathComponent("onboarding-guide.md", isDirectory: false),
            encoding: .utf8
        )

        for command in [
            "toastty setup guide",
            "toastty setup skills list",
            "toastty setup print-skill",
        ] {
            XCTAssertTrue(guide.contains(command), "Guide is missing \(command)")
        }
    }

    private func setupResourcesURL() -> URL {
        repoRootURL()
            .appendingPathComponent("Sources/App/Resources/Setup", isDirectory: true)
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func regularFiles(under rootURL: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files
    }
}
