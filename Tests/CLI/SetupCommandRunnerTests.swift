import Foundation
import Testing
@testable import ToasttyCLIKit

struct SetupCommandRunnerTests {
    @Test
    func setupGuideParsesDefaultTextFormat() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "guide"],
            environment: [:]
        )

        guard case .setup(.guide(let format)) = invocation.command else {
            Issue.record("expected setup guide command")
            return
        }

        #expect(format == .text)
    }

    @Test
    func setupGuideParsesMarkdownFormat() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "guide", "--format", "md"],
            environment: [:]
        )

        guard case .setup(.guide(let format)) = invocation.command else {
            Issue.record("expected setup guide command")
            return
        }

        #expect(format == .md)
    }

    @Test
    func setupSkillsListParses() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "skills", "list"],
            environment: [:]
        )

        guard case .setup(.skillsList) = invocation.command else {
            Issue.record("expected setup skills list command")
            return
        }
    }

    @Test
    func setupAcceptsGlobalJSONFlagAfterSubcommand() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "skills", "list", "--json"],
            environment: [:]
        )

        guard case .setup(.skillsList) = invocation.command else {
            Issue.record("expected setup skills list command")
            return
        }

        #expect(invocation.options.jsonOutput)
    }

    @Test
    func setupPrintSkillParsesName() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "print-skill", "toastty-capabilities"],
            environment: [:]
        )

        guard case .setup(.printSkill(let name)) = invocation.command else {
            Issue.record("expected setup print-skill command")
            return
        }

        #expect(name == "toastty-capabilities")
    }

    @Test
    func setupRejectsMissingSubcommand() {
        do {
            _ = try ToasttyCLI.parse(
                arguments: ["setup"],
                environment: [:]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("setup requires a subcommand"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func setupGuideRejectsUnknownFormat() {
        do {
            _ = try ToasttyCLI.parse(
                arguments: ["setup", "guide", "--format", "html"],
                environment: [:]
            )
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("--format must be one of: text, md"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func setupRunnerRendersGuideAndStarterSkillsFromResourceStore() throws {
        let setupURL = try makeTemporarySetupResources()
        defer { try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent()) }
        let store = SetupResourceStore(setupDirectoryURL: setupURL)

        let guideText = try SetupCommandRunner.render(
            command: .guide(format: .text),
            jsonOutput: false,
            store: store
        )
        #expect(guideText.contains("Guide Title"))
        #expect(guideText.contains("echo setup"))
        #expect(guideText.contains("# Guide Title") == false)
        #expect(guideText.trimmingCharacters(in: .newlines) == "Guide Title\n\necho setup")

        let guideMarkdown = try SetupCommandRunner.render(
            command: .guide(format: .md),
            jsonOutput: false,
            store: store
        )
        #expect(guideMarkdown.contains("# Guide Title"))

        let skillList = try SetupCommandRunner.render(
            command: .skillsList,
            jsonOutput: false,
            store: store
        )
        #expect(skillList == "toastty-capabilities\ntoastty-scratchpad\ntoastty-open-markdown")

        let skillMarkdown = try SetupCommandRunner.render(
            command: .printSkill(name: "toastty-capabilities"),
            jsonOutput: false,
            store: store
        )
        #expect(skillMarkdown.contains("name: toastty-capabilities"))

        let jsonList = try SetupCommandRunner.render(
            command: .skillsList,
            jsonOutput: true,
            store: store
        )
        #expect(jsonList.contains("\"skills\""))
        #expect(jsonList.contains("toastty-open-markdown"))

        let jsonGuide = try SetupCommandRunner.render(
            command: .guide(format: .md),
            jsonOutput: true,
            store: store
        )
        #expect(jsonGuide.contains("\"content\""))
        #expect(jsonGuide.contains("\"format\" : \"md\""))

        let jsonSkill = try SetupCommandRunner.render(
            command: .printSkill(name: "toastty-capabilities"),
            jsonOutput: true,
            store: store
        )
        #expect(jsonSkill.contains("\"content\""))
        #expect(jsonSkill.contains("\"name\" : \"toastty-capabilities\""))
    }

    @Test
    func setupRunnerRejectsUnknownStarterSkill() throws {
        let setupURL = try makeTemporarySetupResources()
        defer { try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent()) }
        let store = SetupResourceStore(setupDirectoryURL: setupURL)

        do {
            _ = try SetupCommandRunner.render(
                command: .printSkill(name: "unknown-skill"),
                jsonOutput: false,
                store: store
            )
            Issue.record("expected render failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("unknown starter skill"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func makeTemporarySetupResources() throws -> URL {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("toastty-setup-tests-\(UUID().uuidString)", isDirectory: true)
        let setupURL = rootURL.appendingPathComponent("Setup", isDirectory: true)
        let starterSkillsURL = setupURL.appendingPathComponent("starter-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: starterSkillsURL, withIntermediateDirectories: true)
        try """
        # Guide Title

        ```bash
        echo setup
        ```
        """.write(
            to: setupURL.appendingPathComponent("onboarding-guide.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        for skill in StarterSkill.allCases {
            let skillURL = starterSkillsURL.appendingPathComponent(skill.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
            try """
            ---
            name: \(skill.rawValue)
            ---

            # \(skill.rawValue)
            """.write(
                to: skillURL.appendingPathComponent("SKILL.md", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        return setupURL
    }
}
