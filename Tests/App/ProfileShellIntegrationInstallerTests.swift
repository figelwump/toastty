@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

final class ProfileShellIntegrationInstallerTests: XCTestCase {
    func testInstallationPlanUsesZshRcForZsh() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/zsh" }
        )

        let plan = try installer.installationPlan()

        XCTAssertEqual(plan.shell, .zsh)
        XCTAssertEqual(plan.initFileURL.path, homeDirectoryURL.appendingPathComponent(".zshrc").path)
        XCTAssertEqual(
            plan.sourceLine,
            "source \"$HOME/.toastty/shell/toastty-profile-shell-integration.zsh\""
        )
    }

    func testResolvedShellPathPrefersLoginShellOverEnvironmentShell() {
        XCTAssertEqual(
            ProfileShellIntegrationInstaller.resolvedShellPath(
                environment: ["SHELL": "/bin/bash"],
                loginShellPath: "/bin/zsh"
            ),
            "/bin/zsh"
        )
    }

    func testInstallationPlanAcceptsLoginShellPrefixedZshName() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "-zsh" }
        )

        let plan = try installer.installationPlan()

        XCTAssertEqual(plan.shell, .zsh)
    }

    func testInstallationPlanUsesFishConfigForFish() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/usr/local/bin/fish" }
        )

        let plan = try installer.installationPlan()

        XCTAssertEqual(plan.shell, .fish)
        XCTAssertEqual(
            plan.initFileURL.path,
            homeDirectoryURL.appendingPathComponent(".config/fish/config.fish").path
        )
        XCTAssertEqual(
            plan.sourceLine,
            "source \"$HOME/.toastty/shell/toastty-profile-shell-integration.fish\""
        )
    }

    func testInstallWritesManagedZshSnippetAndUpdatesZshrc() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        try writeFile(
            """
            export PATH="$HOME/bin:$PATH"
            """,
            to: homeDirectoryURL.appendingPathComponent(".zshrc")
        )
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/zsh" }
        )

        let result = try installer.install()

        XCTAssertTrue(result.updatedInitFile)
        XCTAssertFalse(result.createdInitFile)

        let zshrcContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".zshrc"),
            encoding: .utf8
        )
        XCTAssertTrue(zshrcContents.contains("source \"$HOME/.toastty/shell/toastty-profile-shell-integration.zsh\""))
        XCTAssertTrue(zshrcContents.contains("# Added by Toastty terminal profile shell integration"))
        XCTAssertTrue(
            zshrcContents.contains(
                "Keep this near the end of this file, after other PATH, history, and prompt-hook changes"
            )
        )

        let snippetContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh"),
            encoding: .utf8
        )
        XCTAssertTrue(snippetContents.contains("_toastty_restore_agent_shim_path"))
        XCTAssertTrue(snippetContents.contains("_toastty_initialize_pane_journal"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_AGENT_SHIM_DIR"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_PANE_JOURNAL_FILE"))
        XCTAssertTrue(snippetContents.contains("print -sr -- \"$entry\""))
        XCTAssertTrue(snippetContents.contains("printf '%s\\0' \"$entry\""))
        XCTAssertTrue(snippetContents.contains("add-zsh-hook precmd _toastty_precmd"))
        XCTAssertTrue(snippetContents.contains("add-zsh-hook preexec _toastty_preexec"))
    }

    func testInstallIsIdempotentWhenManagedSnippetAlreadyReferenced() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/zsh" }
        )

        let firstResult = try installer.install()
        let installedStatus = try installer.installationStatus()
        let secondResult = try installer.install()

        XCTAssertTrue(installedStatus.isInstalled)
        XCTAssertFalse(installedStatus.needsManagedSnippetWrite)
        XCTAssertFalse(installedStatus.needsInitFileUpdate)
        XCTAssertTrue(firstResult.updatedManagedSnippet)
        XCTAssertTrue(firstResult.updatedInitFile)
        XCTAssertFalse(secondResult.updatedInitFile)
        XCTAssertFalse(secondResult.updatedManagedSnippet)

        let zshrcContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".zshrc"),
            encoding: .utf8
        )
        XCTAssertEqual(
            zshrcContents.components(separatedBy: "toastty-profile-shell-integration.zsh").count - 1,
            1
        )
    }

    func testInstallationStatusRequiresSnippetRewriteWhenManagedSnippetIsOutdated() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/zsh" }
        )
        let plan = try installer.installationPlan()
        try writeFile(
            """
            # Added by Toastty terminal profile shell integration
            source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
            """,
            to: plan.initFileURL
        )
        try writeFile(
            """
            # stale snippet
            """,
            to: plan.managedSnippetURL
        )

        let status = try installer.installationStatus(plan: plan)

        XCTAssertFalse(status.isInstalled)
        XCTAssertTrue(status.needsManagedSnippetWrite)
        XCTAssertFalse(status.needsInitFileUpdate)
        XCTAssertFalse(status.createsInitFile)
    }

    func testInstallationStatusRequiresInitFileUpdateWhenReferenceIsCommentedOut() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/zsh" }
        )
        let plan = try installer.installationPlan()
        try writeFile(
            """
            # source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
            """,
            to: plan.initFileURL
        )
        try writeFile(plan.shell.managedSnippetContents + "\n", to: plan.managedSnippetURL)

        let status = try installer.installationStatus(plan: plan)

        XCTAssertFalse(status.isInstalled)
        XCTAssertFalse(status.needsManagedSnippetWrite)
        XCTAssertTrue(status.needsInitFileUpdate)
        XCTAssertFalse(status.createsInitFile)
    }

    func testRefreshManagedSnippetIfInstalledUpdatesStaleSnippetDuringRuntimeIsolation() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/shell-runtime"],
            shellPathProvider: { "/bin/zsh" }
        )
        let managedSnippetURL = homeDirectoryURL
            .appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh")
        try writeFile(
            """
            # Added by Toastty terminal profile shell integration
            source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
            """,
            to: homeDirectoryURL.appendingPathComponent(".zshrc")
        )
        try writeFile("# stale snippet\n", to: managedSnippetURL)

        let updated = try installer.refreshManagedSnippetIfInstalled()

        XCTAssertTrue(updated)
        let snippetContents = try String(contentsOf: managedSnippetURL, encoding: .utf8)
        XCTAssertTrue(snippetContents.contains("_toastty_restore_agent_shim_path"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_AGENT_SHIM_DIR"))
    }

    func testRefreshManagedSnippetIfInstalledUpdatesManagedSnippetsAcrossSupportedShells() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/shell-runtime"],
            shellPathProvider: { "/bin/zsh" }
        )
        let zshSnippetURL = homeDirectoryURL
            .appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh")
        let bashSnippetURL = homeDirectoryURL
            .appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.bash")
        let fishSnippetURL = homeDirectoryURL
            .appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.fish")
        try writeFile(
            """
            # Added by Toastty terminal profile shell integration
            source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
            """,
            to: homeDirectoryURL.appendingPathComponent(".zshrc")
        )
        try writeFile(
            """
            # Added by Toastty terminal profile shell integration
            source "$HOME/.toastty/shell/toastty-profile-shell-integration.bash"
            """,
            to: homeDirectoryURL.appendingPathComponent(".bash_profile")
        )
        try writeFile(
            """
            # Added by Toastty terminal profile shell integration
            source "$HOME/.toastty/shell/toastty-profile-shell-integration.fish"
            """,
            to: homeDirectoryURL.appendingPathComponent(".config/fish/config.fish")
        )
        try writeFile("# stale zsh snippet\n", to: zshSnippetURL)
        try writeFile("# stale bash snippet\n", to: bashSnippetURL)
        try writeFile("# stale fish snippet\n", to: fishSnippetURL)

        let updated = try installer.refreshManagedSnippetIfInstalled()

        XCTAssertTrue(updated)

        let zshSnippetContents = try String(contentsOf: zshSnippetURL, encoding: .utf8)
        XCTAssertTrue(zshSnippetContents.contains("_toastty_initialize_pane_journal"))

        let bashSnippetContents = try String(contentsOf: bashSnippetURL, encoding: .utf8)
        XCTAssertTrue(bashSnippetContents.contains("_toastty_initialize_pane_journal"))

        let fishSnippetContents = try String(contentsOf: fishSnippetURL, encoding: .utf8)
        XCTAssertTrue(fishSnippetContents.contains("_toastty_initialize_pane_journal"))
    }

    func testBashInstallationUsesProfileWhenBashProfileIsMissing() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        try writeFile(
            """
            export EDITOR="vim"
            """,
            to: homeDirectoryURL.appendingPathComponent(".profile")
        )
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/bash" }
        )

        let result = try installer.install()

        XCTAssertEqual(result.plan.shell, .bash)
        XCTAssertEqual(result.plan.initFileURL.path, homeDirectoryURL.appendingPathComponent(".profile").path)

        let profileContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".profile"),
            encoding: .utf8
        )
        XCTAssertTrue(profileContents.contains("source \"$HOME/.toastty/shell/toastty-profile-shell-integration.bash\""))

        let snippetContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.bash"),
            encoding: .utf8
        )
        XCTAssertTrue(snippetContents.contains("_toastty_restore_agent_shim_path"))
        XCTAssertTrue(snippetContents.contains("_toastty_initialize_pane_journal"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_AGENT_SHIM_DIR"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_PANE_JOURNAL_FILE"))
        XCTAssertTrue(snippetContents.contains("builtin history -s -- \"$entry\""))
        XCTAssertTrue(snippetContents.contains("printf '%s\\0' \"$entry\""))
        XCTAssertTrue(snippetContents.contains("PROMPT_COMMAND=\"_toastty_prompt_command"))
    }

    func testBashInstallationCreatesBashProfileWhenOnlyBashrcExists() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        try writeFile(
            """
            export PATH="$HOME/.local/bin:$PATH"
            """,
            to: homeDirectoryURL.appendingPathComponent(".bashrc")
        )
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/bash" }
        )

        let result = try installer.install()

        XCTAssertEqual(result.plan.initFileURL.path, homeDirectoryURL.appendingPathComponent(".bash_profile").path)
        XCTAssertTrue(result.createdInitFile)

        let bashProfileContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".bash_profile"),
            encoding: .utf8
        )
        XCTAssertTrue(bashProfileContents.contains("source \"$HOME/.toastty/shell/toastty-profile-shell-integration.bash\""))
    }

    func testInstallWritesManagedFishSnippetAndCreatesFishConfig() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/usr/local/bin/fish" }
        )

        let result = try installer.install()

        XCTAssertEqual(result.plan.shell, .fish)
        XCTAssertTrue(result.updatedInitFile)
        XCTAssertTrue(result.createdInitFile)

        let configContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".config/fish/config.fish"),
            encoding: .utf8
        )
        XCTAssertTrue(configContents.contains("source \"$HOME/.toastty/shell/toastty-profile-shell-integration.fish\""))
        XCTAssertTrue(configContents.contains("# Added by Toastty terminal profile shell integration"))

        let snippetContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.fish"),
            encoding: .utf8
        )
        XCTAssertTrue(snippetContents.contains("if not status --is-interactive"))
        XCTAssertTrue(snippetContents.contains("_toastty_restore_agent_shim_path"))
        XCTAssertTrue(snippetContents.contains("_toastty_initialize_pane_journal"))
        XCTAssertTrue(snippetContents.contains("builtin history append -- \"$entry\""))
        XCTAssertTrue(snippetContents.contains("TOASTTY_PANE_JOURNAL_FILE"))
        XCTAssertTrue(snippetContents.contains("--on-event fish_prompt"))
        XCTAssertTrue(snippetContents.contains("--on-event fish_preexec"))
        XCTAssertTrue(snippetContents.contains("--on-event fish_postexec"))
    }

    func testInstallationPlanRejectsUnsupportedShell() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/bin/tcsh" }
        )

        XCTAssertThrowsError(try installer.installationPlan()) { error in
            guard case .unsupportedShell(let shellPath) = error as? ProfileShellIntegrationInstallerError else {
                return XCTFail("Expected unsupported shell error, got \(error)")
            }
            XCTAssertEqual(shellPath, "/bin/tcsh")
        }
    }

    func testInstallationPlanRejectsRuntimeHomeSandbox() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: ["TOASTTY_RUNTIME_HOME": "/tmp/toastty-runtime-home-tests/shell-runtime"],
            shellPathProvider: { "/bin/zsh" }
        )

        XCTAssertThrowsError(try installer.installationPlan()) { error in
            guard case .runtimeHomeUnsupported(let path) = error as? ProfileShellIntegrationInstallerError else {
                return XCTFail("Expected runtime home unsupported error, got \(error)")
            }
            XCTAssertEqual(path, "/tmp/toastty-runtime-home-tests/shell-runtime")
        }
    }

    func testManagedZshSnippetRestoresAgentShimPathToFront() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let shimDirectory = "/tmp/toastty-agent-shims"
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; print -r -- \"$PATH\"",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                "PATH": "/Users/vishal/.bun/bin:\(shimDirectory):/usr/bin",
                "TOASTTY_AGENT_SHIM_DIR": shimDirectory,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        let components = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        XCTAssertEqual(components.first, shimDirectory)
        XCTAssertEqual(components.filter { $0 == shimDirectory }.count, 1)
    }

    func testManagedZshSnippetLeavesPathUnchangedWithoutAgentShimDirectory() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let originalPath = "/Users/vishal/.bun/bin:/usr/bin"
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; print -r -- \"$PATH\"",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                "PATH": originalPath,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            originalPath
        )
    }

    func testManagedZshSnippetImportsPaneJournalOnRestore() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-zsh\0git status\0".utf8).write(to: journalFileURL, options: .atomic)
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; fc -ln 1 2>/dev/null || true",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertTrue(output.contains("echo toastty-zsh"))
        XCTAssertTrue(output.contains("git status"))
    }

    func testManagedZshSnippetSkipsPaneJournalImportForCreateLaunches() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-zsh\0".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; fc -ln 1 2>/dev/null || true",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "create",
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertFalse(output.contains("echo toastty-zsh"))
    }

    func testManagedZshSnippetPreservesLaunchReasonForSubsequentCommands() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; printf '%s\\n' \"$TOASTTY_LAUNCH_REASON\"",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            "restore"
        )
    }

    func testManagedZshSnippetDoesNotReimportPaneJournalInNestedShell() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try paneJournalData(entries: ["echo toastty-zsh"]).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; TOASTTY_TEST_SNIPPET=\"$1\" zsh -fic 'source \"$TOASTTY_TEST_SNIPPET\"; fc -ln 1 2>/dev/null || true'",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertFalse(output.contains("echo toastty-zsh"))
    }

    func testManagedZshSnippetSkipsIncompleteTrailingPaneJournalEntry() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-zsh\0git status".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; fc -ln 1 2>/dev/null || true",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertTrue(output.contains("echo toastty-zsh"))
        XCTAssertFalse(output.contains("git status"))
    }

    func testManagedZshSnippetCompactsPaneJournalToMostRecentEntries() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let entries = (1...5_002).map { "echo toastty-zsh-\($0)" }
        try paneJournalData(entries: entries).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; entries=(); while IFS= read -r -d '' entry; do entries+=(\"$entry\"); done < \"$TOASTTY_PANE_JOURNAL_FILE\"; print -r -- ${#entries}; print -r -- ${entries[1]}; print -r -- ${entries[-1]}",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(
            output.split(separator: "\n").map(String.init),
            ["5000", "echo toastty-zsh-3", "echo toastty-zsh-5002"]
        )
    }

    func testManagedZshSnippetAppendsNewHistoryEntriesToPaneJournal() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; print -s -- \"echo toastty-zsh\"; _toastty_append_last_history_entry_to_journal; while IFS= read -r -d '' entry; do print -r -- \"$entry\"; done < \"$TOASTTY_PANE_JOURNAL_FILE\"",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            "echo toastty-zsh"
        )
    }

    func testManagedZshSnippetAvoidsDuplicateJournalWritesForSameHistoryEntry() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-zsh.journal")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; print -s -- \"echo toastty-zsh\"; _toastty_append_last_history_entry_to_journal; _toastty_append_last_history_entry_to_journal; while IFS= read -r -d '' entry; do print -r -- \"$entry\"; done < \"$TOASTTY_PANE_JOURNAL_FILE\"",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(output.split(separator: "\n").map(String.init), ["echo toastty-zsh"])
    }

    func testManagedBashSnippetRestoresAgentShimPathToFront() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let shimDirectory = "/tmp/toastty-agent-shims"
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; printf '%s\\n' \"$PATH\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                "PATH": "/Users/vishal/.bun/bin:\(shimDirectory):/usr/bin",
                "TOASTTY_AGENT_SHIM_DIR": shimDirectory,
            ]
        )

        let components = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        XCTAssertEqual(components.first, shimDirectory)
        XCTAssertEqual(components.filter { $0 == shimDirectory }.count, 1)
    }

    func testManagedBashSnippetLeavesPathUnchangedWithoutAgentShimDirectory() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let originalPath = "/Users/vishal/.bun/bin:/usr/bin"
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; printf '%s\\n' \"$PATH\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                "PATH": originalPath,
            ]
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), originalPath)
    }

    func testManagedBashSnippetLeavesSharedHistoryFileUnchanged() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        let sharedHistoryFile = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/shared/bash.history")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; printf '%s\\n' \"$HISTFILE\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                "HISTFILE": sharedHistoryFile.path,
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            sharedHistoryFile.path
        )
    }

    func testManagedBashSnippetImportsPaneJournalOnRestore() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-bash\0git status\0".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; history",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
            ]
        )

        XCTAssertTrue(output.contains("echo toastty-bash"))
        XCTAssertTrue(output.contains("git status"))
    }

    func testManagedBashSnippetSkipsPaneJournalImportForCreateLaunches() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-bash\0".utf8).write(to: journalFileURL, options: .atomic)
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; history",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "create",
            ]
        )

        XCTAssertFalse(output.contains("echo toastty-bash"))
    }

    func testManagedBashSnippetPreservesLaunchReasonForSubsequentCommands() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; printf '%s\\n' \"$TOASTTY_LAUNCH_REASON\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            "restore"
        )
    }

    func testManagedBashSnippetDoesNotReimportPaneJournalInNestedShell() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try paneJournalData(entries: ["echo toastty-bash"]).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; TOASTTY_TEST_SNIPPET=\"$1\" bash --noprofile --norc -ic 'source \"$TOASTTY_TEST_SNIPPET\"; history'",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
            ]
        )

        XCTAssertFalse(output.contains("echo toastty-bash"))
    }

    func testManagedBashSnippetSkipsIncompleteTrailingPaneJournalEntry() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-bash\0git status".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; history",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
            ]
        )

        XCTAssertTrue(output.contains("echo toastty-bash"))
        XCTAssertFalse(output.contains("git status"))
    }

    func testManagedBashSnippetParsesDigitLeadingCommandsWhenHistoryTimestampsAreEnabled() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; _TOASTTY_JOURNAL_LAST_HISTCMD=0; HISTTIMEFORMAT='[%F %T] '; history -s -- '123toastty'; _toastty_append_last_history_entry_to_journal; while IFS= read -r -d '' entry; do printf '%s\\n' \"$entry\"; done < \"$TOASTTY_PANE_JOURNAL_FILE\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            "123toastty"
        )
    }

    func testManagedBashSnippetCompactsPaneJournalToMostRecentEntries() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let entries = (1...5_002).map { "echo toastty-bash-\($0)" }
        try paneJournalData(entries: entries).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; entries=(); while IFS= read -r -d '' entry; do entries+=(\"$entry\"); done < \"$TOASTTY_PANE_JOURNAL_FILE\"; last_index=$(( ${#entries[@]} - 1 )); printf '%s\\n' \"${#entries[@]}\" \"${entries[0]}\" \"${entries[$last_index]}\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
            ]
        )

        XCTAssertEqual(
            output.split(separator: "\n").map(String.init),
            ["5000", "echo toastty-bash-3", "echo toastty-bash-5002"]
        )
    }

    func testManagedBashSnippetAppendsNewHistoryEntriesToPaneJournal() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; _TOASTTY_JOURNAL_LAST_HISTCMD=0; history -s -- \"echo toastty-bash\"; _toastty_append_last_history_entry_to_journal; while IFS= read -r -d '' entry; do printf '%s\\n' \"$entry\"; done < \"$TOASTTY_PANE_JOURNAL_FILE\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
            ]
        )

        XCTAssertEqual(
            output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            "echo toastty-bash"
        )
    }

    func testManagedBashSnippetAvoidsDuplicateJournalWritesForSameHistoryEntry() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-bash.journal")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; _TOASTTY_JOURNAL_LAST_HISTCMD=0; history -s -- \"echo toastty-bash\"; _toastty_append_last_history_entry_to_journal; _toastty_append_last_history_entry_to_journal; while IFS= read -r -d '' entry; do printf '%s\\n' \"$entry\"; done < \"$TOASTTY_PANE_JOURNAL_FILE\"",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
            ]
        )

        XCTAssertEqual(output.split(separator: "\n").map(String.init), ["echo toastty-bash"])
    }

    func testManagedFishSnippetRestoresAgentShimPathToFront() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let shimDirectory = "/tmp/toastty-agent-shims"
        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; string join ':' $PATH",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [
                    "PATH": "/Users/vishal/.bun/bin:\(shimDirectory):/usr/bin",
                    "TOASTTY_AGENT_SHIM_DIR": shimDirectory,
                ]
            )
        )

        let components = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        XCTAssertEqual(components.first, shimDirectory)
        XCTAssertEqual(components.filter { $0 == shimDirectory }.count, 1)
    }

    func testManagedFishSnippetLeavesPathUnchangedWithoutAgentShimDirectory() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let originalPath = "/Users/vishal/.bun/bin:/usr/bin"
        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; set before (string join ':' $PATH); source \"$argv[1]\"; printf '%s\\n%s\\n' \"$before\" (string join ':' $PATH)",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: ["PATH": originalPath]
            )
        )

        XCTAssertEqual(
            output.split(separator: "\n").map(String.init),
            [originalPath, originalPath]
        )
    }

    func testManagedFishSnippetImportsPaneJournalOnRestore() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-fish\0git status\0".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; history search --max 10",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [
                    ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                    ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                ]
            )
        )

        XCTAssertTrue(output.contains("echo toastty-fish"))
        XCTAssertTrue(output.contains("git status"))
    }

    func testManagedFishSnippetSkipsPaneJournalImportForCreateLaunches() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-fish\0".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; history search --max 10",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [
                    ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                    ToasttyLaunchContextEnvironment.launchReasonKey: "create",
                ]
            )
        )

        XCTAssertFalse(output.contains("echo toastty-fish"))
    }

    func testManagedFishSnippetPreservesLaunchReasonForSubsequentCommands() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; printf '%s\\n' \"$TOASTTY_LAUNCH_REASON\"",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [ToasttyLaunchContextEnvironment.launchReasonKey: "restore"]
            )
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "restore")
    }

    func testManagedFishSnippetDoesNotReimportPaneJournalInNestedShell() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try paneJournalData(entries: ["echo toastty-fish"]).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; set -gx TOASTTY_TEST_SNIPPET \"$argv[1]\"; set -gx TOASTTY_TEST_FISH \"$argv[2]\"; \"$TOASTTY_TEST_FISH\" -N -i -c 'set -g fish_greeting; source \"$argv[1]\"; history search --max 5' \"$TOASTTY_TEST_SNIPPET\"",
                snippetURL.path,
                fishExecutableURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [
                    ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                    ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                ]
            )
        )

        XCTAssertFalse(output.contains("echo toastty-fish"))
    }

    func testManagedFishSnippetSkipsIncompleteTrailingPaneJournalEntry() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("echo toastty-fish\0git status".utf8).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; history search --max 10",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [
                    ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                    ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                ]
            )
        )

        XCTAssertTrue(output.contains("echo toastty-fish"))
        XCTAssertFalse(output.contains("git status"))
    }

    func testManagedFishSnippetCompactsPaneJournalToMostRecentEntries() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")
        try FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let entries = (1...5_002).map { "echo toastty-fish-\($0)" }
        try paneJournalData(entries: entries).write(to: journalFileURL, options: .atomic)

        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; set entries; while read --null --local entry; set entries $entries \"$entry\"; end < \"$TOASTTY_PANE_JOURNAL_FILE\"; set last_index (count $entries); printf '%s\\n%s\\n%s\\n' (count $entries) \"$entries[1]\" \"$entries[$last_index]\"",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path]
            )
        )

        XCTAssertEqual(
            output.split(separator: "\n").map(String.init),
            ["5000", "echo toastty-fish-3", "echo toastty-fish-5002"]
        )
    }

    func testManagedFishSnippetAppendsNewHistoryEntriesToPaneJournal() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")
        let output = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; emit fish_preexec 'echo toastty-fish'; emit fish_postexec 'echo toastty-fish'; while read --null --local entry; printf '%s\\n' \"$entry\"; end < \"$TOASTTY_PANE_JOURNAL_FILE\"",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path]
            )
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "echo toastty-fish")
    }

    func testManagedFishSnippetSkipsCommandsHiddenFromFishHistory() throws {
        let fishExecutableURL = try requireFishExecutableURL()
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.fish.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.fish"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let journalFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/pane-journals/test-fish.journal")

        let leadingSpaceOutput = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; emit fish_preexec ' echo toastty-fish'; emit fish_postexec ' echo toastty-fish'; if test -r \"$TOASTTY_PANE_JOURNAL_FILE\"; while read --null --local entry; printf '%s\\n' \"$entry\"; end < \"$TOASTTY_PANE_JOURNAL_FILE\"; end",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path]
            )
        )
        XCTAssertTrue(leadingSpaceOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let disabledHistoryOutput = try runProcess(
            executableURL: fishExecutableURL,
            arguments: [
                "-N",
                "-i",
                "-c",
                "set -g fish_greeting; source \"$argv[1]\"; emit fish_preexec 'echo toastty-fish'; emit fish_postexec 'echo toastty-fish'; if test -r \"$TOASTTY_PANE_JOURNAL_FILE\"; while read --null --local entry; printf '%s\\n' \"$entry\"; end < \"$TOASTTY_PANE_JOURNAL_FILE\"; end",
                snippetURL.path,
            ],
            environment: try fishTestEnvironment(
                for: snippetURL,
                overriding: [
                    ToasttyLaunchContextEnvironment.paneJournalFileKey: journalFileURL.path,
                    "fish_history": "",
                ]
            )
        )
        XCTAssertTrue(disabledHistoryOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-shell-integration-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

@discardableResult
private func writeStandaloneSnippet(_ contents: String, fileName: String) throws -> URL {
    let directoryURL = try makeTemporaryHomeDirectory()
    let snippetURL = directoryURL.appendingPathComponent(fileName)
    try contents.write(to: snippetURL, atomically: true, encoding: .utf8)
    return snippetURL
}

private func fishTestEnvironment(
    for snippetURL: URL,
    overriding overrides: [String: String] = [:]
) throws -> [String: String] {
    let homeDirectoryURL = snippetURL.deletingLastPathComponent()
    let configDirectoryURL = homeDirectoryURL.appendingPathComponent(".config", isDirectory: true)
    let dataDirectoryURL = homeDirectoryURL.appendingPathComponent(".local/share", isDirectory: true)
    try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)

    var environment = [
        "HOME": homeDirectoryURL.path,
        "TERM": "xterm-256color",
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        "XDG_CONFIG_HOME": configDirectoryURL.path,
        "XDG_DATA_HOME": dataDirectoryURL.path,
        "fish_history": "toastty_shell_integration_tests",
    ]
    for (key, value) in overrides {
        environment[key] = value
    }
    return environment
}

private func requireFishExecutableURL() throws -> URL {
    let candidatePaths = [
        "/opt/homebrew/bin/fish",
        "/usr/local/bin/fish",
        "/usr/bin/fish",
    ]
    for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }

    let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in pathEnvironment.split(separator: ":").map(String.init) where directory.isEmpty == false {
        let candidatePath = URL(fileURLWithPath: directory)
            .appendingPathComponent("fish")
            .path
        if FileManager.default.isExecutableFile(atPath: candidatePath) {
            return URL(fileURLWithPath: candidatePath)
        }
    }

    throw XCTSkip("fish is not installed")
}

private func runProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]
) throws -> String {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let stderr = String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    XCTAssertEqual(process.terminationStatus, 0, "stderr: \(stderr)")
    return stdout
}

private func paneJournalData(entries: [String]) -> Data {
    guard entries.isEmpty == false else { return Data() }
    return Data(entries.joined(separator: "\0").appending("\0").utf8)
}

private func writeFile(_ contents: String, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}
