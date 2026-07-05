import CoreState
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
    func setupInstallHooksParsesAgent() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "install-hooks", "--agent", "codex"],
            environment: [:]
        )

        guard case .setup(.installHooks(let agent, let apply)) = invocation.command else {
            Issue.record("expected setup install-hooks command")
            return
        }

        #expect(agent == .codex)
        #expect(apply == false)
    }

    @Test
    func setupInstallSkillParsesRuntime() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "install-skill", "toastty-scratchpad", "--runtime", "codex", "--apply"],
            environment: [:]
        )

        guard case .setup(.installSkill(let name, let runtime, let apply)) = invocation.command else {
            Issue.record("expected setup install-skill command")
            return
        }

        #expect(name == "toastty-scratchpad")
        #expect(runtime == .codex)
        #expect(apply)
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
    func setupInstallerFailsOutsideToasttyPane() throws {
        let setupURL = try makeTemporarySetupResources()
        defer { try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent()) }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-capabilities", runtime: .claude, apply: false),
            jsonOutput: true,
            environment: [:],
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 1)
        #expect(result.applied == false)
        #expect(result.warnings.contains { $0.contains("Open a Toastty terminal pane") || $0.contains("Toastty terminal pane") })
    }

    @Test
    func setupInstallerAppliesShellIntegrationToTemporaryHome() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installShellIntegration(shell: .zsh, apply: true),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL),
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".zshrc").path))
        #expect(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh").path))
        #expect(result.changedFiles.contains(homeURL.appendingPathComponent(".zshrc").path))
    }

    @Test
    func setupInstallerSurfacesShellRuntimeIsolationAsWarning() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        var environment = paneEnvironment(homeURL: homeURL)
        environment[ToasttyRuntimePaths.environmentKey] = "/tmp/toastty-runtime-home-tests/shell-runtime"

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installShellIntegration(shell: .zsh, apply: false),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied == false)
        #expect(result.warnings.contains { $0.contains("runtime isolation") })
    }

    @Test
    func setupInstallerAppliesCodexHooksToTemporaryHome() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installHooks(agent: .codex, apply: true),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL),
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".codex/hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(".toastty/codex-hooks/forwarder.sh").path))
    }

    @Test
    func setupInstallerExplainsNonCodexHooks() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installHooks(agent: .claude, apply: false),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL),
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.plannedChanges.isEmpty)
        #expect(result.warnings.contains { $0.contains("does not need global status hooks") })
    }

    @Test
    func setupInstallerInstallsSkillAndRewritesRuntimeScriptPaths() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .codex, apply: true),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL),
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))
        let skillURL = homeURL.appendingPathComponent(".codex/skills/toastty-scratchpad", isDirectory: true)
        let skillMarkdown = try String(
            contentsOf: skillURL.appendingPathComponent("SKILL.md", isDirectory: false),
            encoding: .utf8
        )
        let scriptURL = skillURL.appendingPathComponent("scripts/publish-scratchpad-html.sh", isDirectory: false)
        let scriptValues = try scriptURL.resourceValues(forKeys: [.isExecutableKey])

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(skillMarkdown.contains("~/.codex/skills/toastty-scratchpad/scripts/publish-scratchpad-html.sh"))
        #expect(FileManager.default.fileExists(atPath: skillURL.appendingPathComponent(".toastty-skill.json").path))
        #expect(scriptValues.isExecutable == true)
    }

    @Test
    func setupInstallerCopiesDotfilesAndDoesNotRewriteAbsoluteAgentPaths() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let sourceSkillURL = setupURL
            .appendingPathComponent("starter-skills", isDirectory: true)
            .appendingPathComponent("toastty-scratchpad", isDirectory: true)
        try "dotfile config".write(
            to: sourceSkillURL.appendingPathComponent(".skill-config", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "\n/tmp/.agents/skills/toastty-scratchpad/scripts/not-managed.sh\n".append(
            to: sourceSkillURL.appendingPathComponent("SKILL.md", isDirectory: false)
        )

        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .codex, apply: true),
            jsonOutput: true,
            environment: paneEnvironment(homeURL: homeURL),
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let installedSkillURL = homeURL.appendingPathComponent(".codex/skills/toastty-scratchpad", isDirectory: true)
        let skillMarkdown = try String(
            contentsOf: installedSkillURL.appendingPathComponent("SKILL.md", isDirectory: false),
            encoding: .utf8
        )

        #expect(FileManager.default.fileExists(atPath: installedSkillURL.appendingPathComponent(".skill-config").path))
        #expect(skillMarkdown.contains("~/.codex/skills/toastty-scratchpad/scripts/publish-scratchpad-html.sh"))
        #expect(skillMarkdown.contains("/tmp/.agents/skills/toastty-scratchpad/scripts/not-managed.sh"))
    }

    @Test
    func setupInstallerRefusesModifiedSkillInstall() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let environment = paneEnvironment(homeURL: homeURL)
        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let skillMarkdownURL = homeURL.appendingPathComponent(".agents/skills/toastty-scratchpad/SKILL.md", isDirectory: false)
        try "\nlocal edit\n".append(to: skillMarkdownURL)

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 1)
        #expect(result.applied == false)
        #expect(result.warnings.contains { $0.contains("Refusing to overwrite") })
    }

    @Test
    func setupInstallerRefusesExecutableBitTampering() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let environment = paneEnvironment(homeURL: homeURL)
        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let scriptURL = homeURL.appendingPathComponent(
            ".agents/skills/toastty-scratchpad/scripts/publish-scratchpad-html.sh",
            isDirectory: false
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 1)
        #expect(result.warnings.contains { $0.contains("Refusing to overwrite") })
    }

    @Test
    func setupInstallerAllRuntimeConflictDoesNotPartiallyInstall() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let environment = paneEnvironment(homeURL: homeURL)
        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let claudeSkillMarkdownURL = homeURL.appendingPathComponent(
            ".agents/skills/toastty-scratchpad/SKILL.md",
            isDirectory: false
        )
        try "\nlocal edit\n".append(to: claudeSkillMarkdownURL)

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .all, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))
        let codexSkillURL = homeURL.appendingPathComponent(".codex/skills/toastty-scratchpad", isDirectory: true)

        #expect(execution.exitCode == 1)
        #expect(result.applied == false)
        #expect(result.changedFiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: codexSkillURL.path) == false)
    }

    @Test
    func setupInstallerRemovesStaleFilesFromPristineManagedSkill() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let environment = paneEnvironment(homeURL: homeURL)
        let sourceLegacyURL = setupURL
            .appendingPathComponent("starter-skills", isDirectory: true)
            .appendingPathComponent("toastty-scratchpad", isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("legacy-helper.sh", isDirectory: false)
        try """
        #!/usr/bin/env bash
        echo legacy
        """.write(to: sourceLegacyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceLegacyURL.path)

        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let installedLegacyURL = homeURL.appendingPathComponent(
            ".agents/skills/toastty-scratchpad/scripts/legacy-helper.sh",
            isDirectory: false
        )
        #expect(FileManager.default.fileExists(atPath: installedLegacyURL.path))

        try FileManager.default.removeItem(at: sourceLegacyURL)
        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(result.changedFiles.contains(installedLegacyURL.path))
        #expect(FileManager.default.fileExists(atPath: installedLegacyURL.path) == false)
    }

    @Test
    func setupInstallerDryRunReportsManagedContentUpdates() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let environment = paneEnvironment(homeURL: homeURL)
        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let sourceSkillMarkdownURL = setupURL
            .appendingPathComponent("starter-skills", isDirectory: true)
            .appendingPathComponent("toastty-scratchpad", isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        try "\nupdated bundled instructions\n".append(to: sourceSkillMarkdownURL)
        let installedSkillMarkdownURL = homeURL.appendingPathComponent(
            ".agents/skills/toastty-scratchpad/SKILL.md",
            isDirectory: false
        )

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: false),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))

        #expect(execution.exitCode == 0)
        #expect(result.applied == false)
        #expect(result.changedFiles.isEmpty)
        #expect(result.plannedChanges.contains("Update \(installedSkillMarkdownURL.path)"))
    }

    @Test
    func setupInstallerRepairsStaleManifestWhenContentMatchesDesired() throws {
        let setupURL = try makeTemporarySetupResources()
        let homeURL = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: homeURL)
        }
        let environment = paneEnvironment(homeURL: homeURL)
        _ = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let manifestURL = homeURL.appendingPathComponent(
            ".agents/skills/toastty-scratchpad/.toastty-skill.json",
            isDirectory: false
        )
        try """
        {
          "contentHash" : "stale",
          "name" : "toastty-scratchpad",
          "version" : 1
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let execution = try SetupInstallerCommandRunner.execute(
            command: .installSkill(name: "toastty-scratchpad", runtime: .claude, apply: true),
            jsonOutput: true,
            environment: environment,
            store: SetupResourceStore(setupDirectoryURL: setupURL)
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))
        let repairedManifest = try String(contentsOf: manifestURL, encoding: .utf8)

        #expect(execution.exitCode == 0)
        #expect(result.applied)
        #expect(result.changedFiles == [manifestURL.path])
        #expect(repairedManifest.contains("\"stale\"") == false)
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
            if skill == .toasttyScratchpad {
                let scriptsURL = skillURL.appendingPathComponent("scripts", isDirectory: true)
                try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
                let scriptURL = scriptsURL.appendingPathComponent("publish-scratchpad-html.sh", isDirectory: false)
                try """
                #!/usr/bin/env bash
                echo scratchpad
                """.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            }
            try """
            ---
            name: \(skill.rawValue)
            ---

            # \(skill.rawValue)

            \(skill == .toasttyScratchpad ? "~/.agents/skills/toastty-scratchpad/scripts/publish-scratchpad-html.sh" : "")
            """.write(
                to: skillURL.appendingPathComponent("SKILL.md", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        return setupURL
    }

    private func makeTemporaryHome() throws -> URL {
        let homeURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("toastty-setup-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        return homeURL
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

private extension String {
    func append(to url: URL) throws {
        let data = Data(utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
