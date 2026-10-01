import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct SetupCommandRunnerTests {
    @Test
    func setupGuideParsesDefaultTextFormat() throws {
        let invocation = try ToasttyCLI.parse(arguments: ["setup", "guide"], environment: [:])

        guard case .setup(.guide(.onboarding, let format)) = invocation.command else {
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

        guard case .setup(.guide(.onboarding, let format)) = invocation.command else {
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
        ["setup", "install-workflow", "worktree-handoff", "--dry-run", "--apply"],
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
    func setupGuideParsesWorkflowsTopic() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "guide", "--topic", "workflows", "--format", "md"],
            environment: [:]
        )

        guard case .setup(.guide(let topic, let format)) = invocation.command else {
            Issue.record("expected setup guide command")
            return
        }
        #expect(topic == .workflows)
        #expect(format == .md)
    }

    @Test
    func setupInstallWorkflowParsesNameAndApply() throws {
        let invocation = try ToasttyCLI.parse(
            arguments: ["setup", "install-workflow", "worktree-handoff", "--apply"],
            environment: [:]
        )

        guard case .setup(.installWorkflow(let name, let apply)) = invocation.command else {
            Issue.record("expected setup install-workflow command")
            return
        }
        #expect(name == "worktree-handoff")
        #expect(apply)
    }

    @Test(arguments: [
        (["setup", "guide", "--topic", "recipes"], "--topic must be one of: onboarding, workflows"),
        (["setup", "install-workflow"], "requires one workflow name (available: worktree-handoff)"),
        (["setup", "install-workflow", "a", "b"], "requires one workflow name"),
        (["setup", "install-workflow", "deploy-everything"], "unknown workflow: deploy-everything (available: worktree-handoff)"),
    ])
    func setupRejectsInvalidGuideTopicsAndWorkflowNames(arguments: [String], expectedMessage: String) {
        do {
            _ = try ToasttyCLI.parse(arguments: arguments, environment: [:])
            Issue.record("expected parse failure")
        } catch let error as ToasttyCLIError {
            guard case .usage(let message) = error else {
                Issue.record("expected usage error")
                return
            }
            #expect(message.contains(expectedMessage))
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
            command: .guide(topic: .onboarding, format: .text),
            jsonOutput: false,
            store: store
        )
        #expect(guideText.trimmingCharacters(in: .newlines) == "Guide Title\n\necho setup")

        let guideMarkdown = try SetupCommandRunner.render(
            command: .guide(topic: .onboarding, format: .md),
            jsonOutput: false,
            store: store
        )
        #expect(guideMarkdown.contains("# Guide Title"))

        let jsonGuide = try SetupCommandRunner.render(
            command: .guide(topic: .onboarding, format: .md),
            jsonOutput: true,
            store: store
        )
        #expect(jsonGuide.contains("\"content\""))
        #expect(jsonGuide.contains("\"format\" : \"md\""))
    }

    @Test
    func setupRunnerRendersWorkflowGuideTopic() throws {
        let setupURL = try makeTemporarySetupResources()
        defer { try? FileManager.default.removeItem(at: setupURL.deletingLastPathComponent()) }
        try "# Workflow Guide\n\nBuild one.\n".write(
            to: setupURL.appendingPathComponent("workflow-guide.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let store = SetupResourceStore(setupDirectoryURL: setupURL)

        let text = try SetupCommandRunner.render(
            command: .guide(topic: .workflows, format: .text),
            jsonOutput: false,
            store: store
        )
        #expect(text.hasPrefix("Workflow Guide"))

        let json = try SetupCommandRunner.render(
            command: .guide(topic: .workflows, format: .md),
            jsonOutput: true,
            store: store
        )
        #expect(json.contains("\"topic\" : \"workflows\""))
        #expect(json.contains("# Workflow Guide"))
    }

    // MARK: - install-workflow

    @Test
    func installWorkflowDryRunPlansEveryPackageAndWritesNothing() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }

        let (result, exitCode) = try fixture.run(apply: false)

        #expect(exitCode == 0)
        #expect(result.outcome == .dryRun)
        #expect(result.plannedChanges.count == 3)
        #expect(result.plannedChanges.allSatisfy { $0.hasPrefix("Install worktree-") })
        #expect(result.changedFiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.skillsRoot.path) == false)
    }

    @Test
    func installWorkflowApplyCopiesPackagesAndRerunIsNoChange() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }

        let (result, exitCode) = try fixture.run(apply: true)

        #expect(exitCode == 0)
        #expect(result.outcome == .applied)
        #expect(result.warnings.isEmpty)
        #expect(result.changedFiles == WorkflowFixture.packageNames.map {
            fixture.skillsRoot.appendingPathComponent($0, isDirectory: true).path
        })
        let installedScript = fixture.skillsRoot.appendingPathComponent("worktree-create/scripts/run.sh")
        #expect(try String(contentsOf: installedScript, encoding: .utf8) == "#!/bin/sh\necho worktree-create\n")
        #expect(FileManager.default.isExecutableFile(atPath: installedScript.path))
        #expect(FileManager.default.isExecutableFile(
            atPath: fixture.skillsRoot.appendingPathComponent("worktree-done/SKILL.md").path
        ) == false)
        // Staging directories are renamed into place, not left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.skillsRoot.path)
            .filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)

        // Finder metadata and Python caches in an installed package are not changes.
        try Data().write(to: fixture.skillsRoot.appendingPathComponent("worktree-create/.DS_Store"))
        let cacheURL = fixture.skillsRoot.appendingPathComponent("worktree-create/scripts/__pycache__", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cacheURL.appendingPathComponent("run.cpython-312.pyc"))

        let (rerun, rerunExitCode) = try fixture.run(apply: true)
        #expect(rerunExitCode == 0)
        #expect(rerun.outcome == .noChanges)
        #expect(rerun.changedFiles.isEmpty)
    }

    @Test
    func installWorkflowRefusesWhenAnExistingPackageDiffers() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }
        let customizedURL = fixture.skillsRoot.appendingPathComponent("worktree-create", isDirectory: true)
        try FileManager.default.createDirectory(at: customizedURL, withIntermediateDirectories: true)
        let customizedSkill = customizedURL.appendingPathComponent("SKILL.md")
        try "my customized skill".write(to: customizedSkill, atomically: true, encoding: .utf8)

        let (dryRun, dryRunExitCode) = try fixture.run(apply: false)
        #expect(dryRunExitCode == 0)
        #expect(dryRun.outcome == .dryRun)
        #expect(dryRun.warnings.contains { $0.contains("worktree-create") && $0.contains("differs from the bundled version") })

        let (result, exitCode) = try fixture.run(apply: true)
        #expect(exitCode == 1)
        #expect(result.outcome == .refused)
        #expect(result.applied == false)
        #expect(result.changedFiles.isEmpty)
        #expect(try String(contentsOf: customizedSkill, encoding: .utf8) == "my customized skill")
        // All-or-nothing: the non-conflicting packages are not installed either.
        #expect(FileManager.default.fileExists(
            atPath: fixture.skillsRoot.appendingPathComponent("worktree-done").path
        ) == false)
    }

    @Test
    func installWorkflowTreatsLostScriptPermissionAsAChange() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }
        _ = try fixture.run(apply: true)
        let scriptPath = fixture.skillsRoot.appendingPathComponent("worktree-create/scripts/run.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptPath)

        let (result, exitCode) = try fixture.run(apply: true)

        #expect(exitCode == 1)
        #expect(result.outcome == .refused)
        #expect(result.warnings.contains { $0.contains("worktree-create") })
    }

    @Test
    func installWorkflowRollsBackEarlierPackagesWhenALaterRenameFails() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }
        let installer = SetupWorkflowInstaller(
            workflow: try #require(ToasttyWorkflowCatalog.workflow(named: "worktree-handoff")),
            packagesDirectoryURL: fixture.packagesRoot,
            userSkillsDirectoryURL: fixture.skillsRoot,
            fileManager: SecondMoveFailingFileManager()
        )

        let (result, exitCode) = try installer.result(apply: true)

        #expect(exitCode == 1)
        #expect(result.outcome == .failed)
        #expect(result.changedFiles.isEmpty)
        // Neither the package published before the failure nor any staging directory remains.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.skillsRoot.path).isEmpty)
    }

    @Test
    func installWorkflowTreatsSymlinkedPackageAsConflict() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.skillsRoot, withIntermediateDirectories: true)
        // Even a link to an identical copy is a conflict: the skill catalog rejects symlinked packages.
        try FileManager.default.createSymbolicLink(
            at: fixture.skillsRoot.appendingPathComponent("worktree-done", isDirectory: true),
            withDestinationURL: fixture.packagesRoot.appendingPathComponent("worktree-done", isDirectory: true)
        )

        let (result, exitCode) = try fixture.run(apply: true)

        #expect(exitCode == 1)
        #expect(result.outcome == .refused)
        #expect(result.warnings.contains { $0.contains("worktree-done") && $0.contains("symbolic link") })
    }

    @Test
    func installWorkflowFailsClearlyWhenTheBuildLacksBundledPackages() throws {
        let fixture = try WorkflowFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.packagesRoot.appendingPathComponent("worktree-cleanup"))

        #expect(throws: ToasttyCLIError.self) {
            _ = try fixture.run(apply: false)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.skillsRoot.path) == false)
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

/// Bundled workflow packages and an empty user skills root, both temporary,
/// wired through the same environment variables the real CLI reads.
private struct WorkflowFixture {
    static let packageNames = ["worktree-create", "worktree-done", "worktree-cleanup"]

    let rootURL: URL
    let resourcesURL: URL
    let packagesRoot: URL
    let skillsRoot: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-workflow-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
        packagesRoot = resourcesURL.appendingPathComponent(ToasttyWorkflowCatalog.bundledPackagesSubpath, isDirectory: true)
        skillsRoot = rootURL.appendingPathComponent("skills", isDirectory: true)
        for name in Self.packageNames {
            let packageURL = packagesRoot.appendingPathComponent(name, isDirectory: true)
            let scriptsURL = packageURL.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
            try """
            ---
            name: \(name)
            description: Test workflow package \(name)
            ---

            # \(name)
            """.write(to: packageURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let scriptURL = scriptsURL.appendingPathComponent("run.sh")
            try "#!/bin/sh\necho \(name)\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }
    }

    func run(apply: Bool) throws -> (SetupInstallerResult, Int32) {
        let execution = try SetupInstallerCommandRunner.execute(
            command: .installWorkflow(name: "worktree-handoff", apply: apply),
            jsonOutput: true,
            environment: [
                "HOME": rootURL.path,
                ToasttyLaunchContextEnvironment.cliPathKey: "/tmp/toastty",
                ToasttyLaunchContextEnvironment.panelIDKey: UUID().uuidString,
                ToasttyLaunchContextEnvironment.appResourcesPathKey: resourcesURL.path,
                ToasttyLaunchContextEnvironment.userSkillsRootKey: skillsRoot.path,
            ]
        )
        let result = try JSONDecoder().decode(SetupInstallerResult.self, from: Data(execution.output.utf8))
        return (result, execution.exitCode)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class SecondMoveFailingFileManager: FileManager, @unchecked Sendable {
    private var moveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 2 {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
