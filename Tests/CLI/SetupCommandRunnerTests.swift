import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct SetupCommandRunnerTests {
    @Test
    func setupGuideParsesDefaultTextFormat() throws {
        let invocation = try ToasttyCLI.parse(arguments: ["setup", "guide"], environment: [:])

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
    func setupSkillsListParsesWithGlobalJSONFlag() throws {
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

    @Test(arguments: ["print-skill", "install-skill"])
    func retiredSkillSetupCommandsAreRejected(subcommand: String) {
        do {
            _ = try ToasttyCLI.parse(
                arguments: ["setup", subcommand, "toastty-capabilities"],
                environment: [:]
            )
            Issue.record("expected retired command to be rejected")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("unknown setup subcommand: \(subcommand)"))
            #expect(message.contains("setup skills list"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func setupInstallShellIntegrationParsesApplyAndShell() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "install-shell-integration", "--shell", "fish", "--apply"],
            environment: [:]
        )

        guard case .setup(.installShellIntegration(let shell, let apply)) = invocation.command else {
            Issue.record("expected setup install-shell-integration command")
            return
        }
        #expect(shell == .fish)
        #expect(apply)
    }

    @Test
    func setupInstallHooksParsesAgentAndDryRun() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "install-hooks", "--agent", "codex", "--dry-run"],
            environment: [:]
        )

        guard case .setup(.installHooks(let agent, let apply)) = invocation.command else {
            Issue.record("expected setup install-hooks command")
            return
        }
        #expect(agent == .codex)
        #expect(apply == false)
    }

    @Test(arguments: [
        ["setup", "install-shell-integration", "--dry-run", "--apply"],
        ["setup", "install-hooks", "--agent", "codex", "--dry-run", "--apply"],
    ])
    func setupInstallCommandsRejectDryRunCombinedWithApply(arguments: [String]) {
        do {
            _ = try ToasttyCLI.parse(arguments: arguments, environment: [:])
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains("either --dry-run or --apply"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func setupRejectsMissingSubcommand() {
        do {
            _ = try ToasttyCLI.parse(arguments: ["setup"], environment: [:])
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
    func setupInstallerFailsOutsideToasttyPane() throws {
        let execution = try SetupInstallerCommandRunner.execute(
            command: .installShellIntegration(shell: .zsh, apply: false),
            jsonOutput: true,
            environment: [:]
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 1)
        #expect(result.applied == false)
        #expect(result.warnings.contains { $0.contains("Toastty terminal pane") })
    }

    @Test
    func setupInstallerAppliesShellIntegrationToTemporaryHome() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installShellIntegration(shell: .zsh, apply: true),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".zshrc").path))
        #expect(FileManager.default.fileExists(
            atPath: homeURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh").path
        ))
    }

    @Test
    func setupInstallerSurfacesShellRuntimeIsolationAsWarning() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        var environment = paneEnvironment(homeURL: homeURL)
        environment[ToasttyRuntimePaths.environmentKey] = "/tmp/toastty-runtime-home-tests/shell-runtime"

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installShellIntegration(shell: .zsh, apply: false),
            jsonOutput: true,
            environment: environment
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied == false)
        #expect(result.warnings.contains { $0.contains("runtime isolation") })
    }

    @Test
    func setupInstallerAppliesCodexHooksToTemporaryHome() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installHooks(agent: .codex, apply: true),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".codex/hooks.json").path))
        #expect(FileManager.default.fileExists(
            atPath: homeURL.appendingPathComponent(".toastty/codex-hooks/forwarder.sh").path
        ))
    }

    @Test
    func setupInstallerExplainsNonCodexHooks() throws {
        let homeURL = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: homeURL) }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installHooks(agent: .claude, apply: false),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.plannedChanges.isEmpty)
        #expect(result.warnings.contains { $0.contains("does not need global status hooks") })
    }

    @Test
    func setupRunnerRendersGuideFromResourceStore() throws {
        let setupURL = try makeTemporarySetupResources()
        defer { try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent()) }
        let store = SetupResourceStore(setupDirectoryURL: setupURL)

        let guideText = try SetupCommandRunner.render(
            command: .guide(format: .text),
            jsonOutput: false,
            store: store
        )
        #expect(guideText.trimmingCharacters(in: .newlines) == "Guide Title\n\necho setup")

        let guideMarkdown = try SetupCommandRunner.render(
            command: .guide(format: .md),
            jsonOutput: false,
            store: store
        )
        #expect(guideMarkdown.contains("# Guide Title"))

        let jsonGuide = try SetupCommandRunner.render(
            command: .guide(format: .md),
            jsonOutput: true,
            store: store
        )
        #expect(jsonGuide.contains("\"content\""))
        #expect(jsonGuide.contains("\"format\" : \"md\""))
    }

    @Test
    func setupSkillsListRendersShippedAcceptedAndExcludedSkills() throws {
        let setupURL = try makeTemporarySetupResources()
        let skillsRoot = try makeTemporarySkillsRoot()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        try writeSkill(named: "zeta-skill", under: skillsRoot)
        try writeSkill(named: "alpha-skill", under: skillsRoot)
        try FileManager.default.createDirectory(
            at: skillsRoot.appendingPathComponent("broken-skill", isDirectory: true),
            withIntermediateDirectories: true
        )
        let environment = [
            ToasttyLaunchContextEnvironment.userSkillsRootKey: skillsRoot.path,
        ]
        let store = SetupResourceStore(setupDirectoryURL: setupURL)

        let text = try SetupCommandRunner.render(
            command: .skillsList,
            jsonOutput: false,
            store: store,
            environment: environment
        )

        for shippedName in ToasttyShippedSkillCatalog.skills.map(\.name) {
            #expect(text.contains("toastty:\(shippedName)"))
        }
        let alphaRange = try #require(text.range(of: "- alpha-skill"))
        let zetaRange = try #require(text.range(of: "- zeta-skill"))
        #expect(alphaRange.lowerBound < zetaRange.lowerBound)
        #expect(text.contains("Excluded user packages:"))
        #expect(text.contains("broken-skill"))
        #expect(text.contains(UserSkillDiagnostic.missingSkillFile.displayMessage))

        let json = try SetupCommandRunner.render(
            command: .skillsList,
            jsonOutput: true,
            store: store,
            environment: environment
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["userSkillsRoot"] as? String == skillsRoot.path)
        let skills = try #require(object["skills"] as? [[String: Any]])
        #expect(skills.count == ToasttyShippedSkillCatalog.skills.count + 3)
        #expect(skills.contains {
            $0["name"] as? String == "alpha-skill"
                && $0["source"] as? String == "user"
                && $0["inclusion"] as? String == "included"
        })
        #expect(skills.contains {
            $0["name"] as? String == "broken-skill"
                && $0["diagnosticCode"] as? String == UserSkillDiagnostic.missingSkillFile.code
        })
    }

    @Test
    func setupSkillsListTreatsMissingRootAsEmptyWithoutCreatingIt() throws {
        let setupURL = try makeTemporarySetupResources()
        let parentURL = try makeTemporaryHome()
        let missingRoot = parentURL.appendingPathComponent("not-created", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: parentURL)
        }

        let text = try SetupCommandRunner.render(
            command: .skillsList,
            jsonOutput: false,
            store: SetupResourceStore(setupDirectoryURL: setupURL),
            environment: [
                ToasttyLaunchContextEnvironment.userSkillsRootKey: missingRoot.path,
            ]
        )

        #expect(text.contains("- None found"))
        #expect(FileManager.default.fileExists(atPath: missingRoot.path) == false)
    }

    private func makeTemporarySetupResources() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-setup-tests-\(UUID().uuidString)", isDirectory: true)
        let setupURL = rootURL.appendingPathComponent("Setup", isDirectory: true)
        try FileManager.default.createDirectory(at: setupURL, withIntermediateDirectories: true)
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
        return setupURL
    }

    private func makeTemporaryHome() throws -> URL {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-setup-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        return homeURL
    }

    private func makeTemporarySkillsRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-skills-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func writeSkill(named name: String, under rootURL: URL) throws {
        let skillURL = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: Test skill \(name)
        ---

        # \(name)
        """.write(
            to: skillURL.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func paneEnvironment(homeURL: URL) -> [String: String] {
        [
            "HOME": homeURL.path,
            "SHELL": "/bin/zsh",
            ToasttyLaunchContextEnvironment.cliPathKey: "/tmp/toastty",
            ToasttyLaunchContextEnvironment.panelIDKey: UUID().uuidString,
        ]
    }
}
