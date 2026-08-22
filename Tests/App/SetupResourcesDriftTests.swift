@testable import ToasttyApp
import Foundation
import XCTest

final class SetupResourcesDriftTests: XCTestCase {
    func testShippedSkillSetMatchesSharedCatalog() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: shippedSkillsURL(),
            includingPropertiesForKeys: nil
        )
        let names = entries
            .filter { $0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            names,
            ToasttyAgentPluginBundle.skills.map(\.name).sorted()
        )
        XCTAssertEqual(ToasttyAgentPluginBundle.skills.count, 5)
        XCTAssertTrue(
            (try? regularFiles(
                under: setupResourcesURL().appendingPathComponent("starter-skills", isDirectory: true)
            ))?.isEmpty ?? true
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
        let starterSkillsURL = shippedSkillsURL()
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
            contentsOf: shippedSkillsURL()
                .appendingPathComponent("toastty-capabilities", isDirectory: true)
                .appendingPathComponent("SKILL.md", isDirectory: false),
            encoding: .utf8
        )
        let knownIDs = Set(AppControlActionID.allCases.map(\.rawValue))
            .union(AppControlQueryID.allCases.map(\.rawValue))
        let mentionedIDs = try mentionedAppControlIDs(in: content)

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

    func testCapabilitiesSkillDocumentsBoundedChildLaunchHandoff() throws {
        let content = try String(
            contentsOf: shippedSkillsURL()
                .appendingPathComponent("toastty-capabilities", isDirectory: true)
                .appendingPathComponent("SKILL.md", isDirectory: false),
            encoding: .utf8
        )

        XCTAssertTrue(
            content.contains(
                "The `--workspace` selector on `agent.launch` chooses where the child is placed; "
                    + "it does not assign the child's exact workspace scope."
            )
        )
        XCTAssertTrue(content.contains("not pre-execution isolation"))
        XCTAssertTrue(content.contains("Do not put child-scoping commands in `initialCommands`"))
        XCTAssertTrue(content.contains("For an existing workspace"))

        let sectionStart = try XCTUnwrap(
            content.range(of: "### Launch A Workspace-Bounded Child Agent")
        )
        let contentFromSection = content[sectionStart.lowerBound...]
        let sectionEnd = try XCTUnwrap(
            contentFromSection.range(of: "### Open Browser And Local Document Panels")
        )
        let launchSection = contentFromSection[..<sectionEnd.lowerBound]

        let orderedCommandFragments = [
            "--json session scope show \\\n    --session \"$TOASTTY_SESSION_ID\"",
            "--json session scope set-current \\\n      --session \"$TOASTTY_SESSION_ID\"",
            "--json action run workspace.create",
            "--json action run agent.launch",
            "--json session scope set \\\n    --session \"$child_session_id\" \\\n    --workspace \"$workspace_id\"",
            "--json session scope show \\\n    --session \"$child_session_id\"",
        ]

        var remainingSection = launchSection[...]
        for fragment in orderedCommandFragments {
            guard let fragmentRange = remainingSection.range(of: fragment) else {
                XCTFail("Bounded child launch example is missing ordered fragment: \(fragment)")
                return
            }
            remainingSection = remainingSection[fragmentRange.upperBound...]
        }

        for verification in [
            "if [ -z \"${TOASTTY_SESSION_ID:-}\" ] || [ -z \"${TOASTTY_PANEL_ID:-}\" ]",
            "parent_began_unrestricted=\"false\"",
            "launch_attempted=\"false\"",
            "trap report_launch_failure EXIT",
            "--json session scope clear",
            "Restored the parent session to its previous unrestricted state",
            "x.get(\"isScoped\") is True",
            "x.get(\"workspaceIDs\") == [w]",
            "x.get(\"effectiveWorkspaceIDs\") == [w]",
            "child may already exist and the child may be running with broader inherited scope",
        ] {
            XCTAssertTrue(
                launchSection.contains(verification),
                "Bounded child launch example is missing verification: \(verification)"
            )
        }
    }

    func testOnboardingGuideMentionsOnlyKnownAppControlIDs() throws {
        let guide = try String(
            contentsOf: setupResourcesURL().appendingPathComponent("onboarding-guide.md", isDirectory: false),
            encoding: .utf8
        )
        let knownIDs = Set(AppControlActionID.allCases.map(\.rawValue))
            .union(AppControlQueryID.allCases.map(\.rawValue))
        let mentionedIDs = try mentionedAppControlIDs(in: guide)

        for expectedActionID in [
            AppControlActionID.panelScratchpadSetContent.rawValue,
            AppControlActionID.panelCreateLocalDocument.rawValue,
            AppControlActionID.panelCreateBrowser.rawValue,
        ] {
            XCTAssertTrue(mentionedIDs.contains(expectedActionID), "Guide is missing \(expectedActionID)")
        }
        XCTAssertTrue(
            mentionedIDs.subtracting(knownIDs).isEmpty,
            "Guide mentions unknown app-control IDs: \(mentionedIDs.subtracting(knownIDs).sorted().joined(separator: ", "))"
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
            "toastty setup install-shell-integration",
            "toastty setup install-hooks",
        ] {
            XCTAssertTrue(guide.contains(command), "Guide is missing \(command)")
        }
        for retiredCommand in ["toastty setup print-skill", "toastty setup install-skill"] {
            XCTAssertFalse(guide.contains(retiredCommand), "Guide still mentions \(retiredCommand)")
        }
    }

    func testOnboardingGuideCapturesM4FlowDecisions() throws {
        let guide = try String(
            contentsOf: setupResourcesURL().appendingPathComponent("onboarding-guide.md", isDirectory: false),
            encoding: .utf8
        )

        for requiredText in [
            "Use your detected agent identity for tone only",
            "do not gate setup on it",
            "Fresh users are often unmanaged",
            "Dry-run shell integration first",
            "install-shell-integration --dry-run",
            "`--dry-run` and `--apply` are mutually exclusive",
            "Codex may ask the user to trust the hook once",
            "Terminal profiles as optional manual setup",
            "fresh Toastty pane",
            "--resume",
            "No skills installation is required",
            "~/.toastty/skills/<name>/SKILL.md",
            "Running sessions keep the skills they launched with",
            "Wait for an explicit OK before every `--apply`",
            "Scratchpad: managed sessions only",
            "panel.create.local-document",
            "panel.create.browser",
            "scope_denied",
            "Canceling keeps already completed progress intact",
        ] {
            XCTAssertTrue(guide.contains(requiredText), "Guide is missing M4 decision text: \(requiredText)")
        }
    }

    func testOnboardingGuideDoesNotReintroduceSupersededSkillMatrix() throws {
        let guide = try String(
            contentsOf: setupResourcesURL().appendingPathComponent("onboarding-guide.md", isDirectory: false),
            encoding: .utf8
        )

        for supersededText in [
            "toastty-orchestrator-builder",
            "interview-and-tailor",
            "interview-and-tailor matrix",
            "interview & tailor",
            "tailored copy into each chosen dir",
        ] {
            XCTAssertFalse(
                guide.localizedCaseInsensitiveContains(supersededText),
                "Guide reintroduced superseded Phase 2 text: \(supersededText)"
            )
        }

        let tailorRegex = try NSRegularExpression(pattern: #"(?i)\binterview\s*(?:&|and|-)\s*tailor\b"#)
        let guideRange = NSRange(guide.startIndex..<guide.endIndex, in: guide)
        XCTAssertNil(
            tailorRegex.firstMatch(in: guide, range: guideRange),
            "Guide reintroduced the superseded interview/tailor matrix concept"
        )
    }

    private func setupResourcesURL() -> URL {
        repoRootURL()
            .appendingPathComponent("Sources/App/Resources/Setup", isDirectory: true)
    }

    private func shippedSkillsURL() -> URL {
        repoRootURL()
            .appendingPathComponent("plugins/toastty/skills", isDirectory: true)
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

    private func mentionedAppControlIDs(in content: String) throws -> Set<String> {
        let regex = try NSRegularExpression(
            pattern: #"\b(?:window|workspace|panel|terminal|agent|config|app)\.[A-Za-z0-9._-]+"#
        )
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        return Set(
            regex.matches(in: content, range: nsRange).compactMap { match -> String? in
                guard let range = Range(match.range, in: content) else { return nil }
                return String(content[range])
            }
        )
    }
}
