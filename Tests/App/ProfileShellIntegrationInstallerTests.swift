@testable import ToasttyApp
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
        XCTAssertTrue(zshrcContents.contains("Keep this near the end of this file, after all other PATH and history-file changes"))

        let snippetContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh"),
            encoding: .utf8
        )
        XCTAssertTrue(snippetContents.contains("_toastty_restore_agent_shim_path"))
        XCTAssertTrue(snippetContents.contains("_toastty_configure_pane_history"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_AGENT_SHIM_DIR"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_PANE_HISTORY_FILE"))
        XCTAssertTrue(snippetContents.contains("fc -p \"$pane_history_file\""))
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
        try writeFile("# stale zsh snippet\n", to: zshSnippetURL)
        try writeFile("# stale bash snippet\n", to: bashSnippetURL)

        let updated = try installer.refreshManagedSnippetIfInstalled()

        XCTAssertTrue(updated)

        let zshSnippetContents = try String(contentsOf: zshSnippetURL, encoding: .utf8)
        XCTAssertTrue(zshSnippetContents.contains("_toastty_configure_pane_history"))

        let bashSnippetContents = try String(contentsOf: bashSnippetURL, encoding: .utf8)
        XCTAssertTrue(bashSnippetContents.contains("_toastty_configure_pane_history"))
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
        XCTAssertTrue(snippetContents.contains("_toastty_configure_pane_history"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_AGENT_SHIM_DIR"))
        XCTAssertTrue(snippetContents.contains("TOASTTY_PANE_HISTORY_FILE"))
        XCTAssertTrue(snippetContents.contains("history -r \"$HISTFILE\""))
        XCTAssertTrue(snippetContents.contains("history -a"))
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

    func testInstallationPlanRejectsUnsupportedShell() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: [:],
            shellPathProvider: { "/opt/homebrew/bin/fish" }
        )

        XCTAssertThrowsError(try installer.installationPlan()) { error in
            guard case .unsupportedShell(let shellPath) = error as? ProfileShellIntegrationInstallerError else {
                return XCTFail("Expected unsupported shell error, got \(error)")
            }
            XCTAssertEqual(shellPath, "/opt/homebrew/bin/fish")
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

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), originalPath)
    }

    func testManagedZshSnippetUsesPaneHistoryFile() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let historyFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/panes/test-zsh.history")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; print -r -- \"$HISTFILE\"",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                "TOASTTY_PANE_HISTORY_FILE": historyFileURL.path,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), historyFileURL.path)
    }

    func testManagedZshSnippetLoadsPaneHistoryFromExistingFile() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.zsh.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.zsh"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let historyFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/panes/test-zsh.history")
        try writeFile("echo toastty-zsh\n", to: historyFileURL)

        let restoredOutput = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-fic",
                "source \"$1\"; fc -ln 1",
                "toastty-zsh-test",
                snippetURL.path,
            ],
            environment: [
                "TOASTTY_PANE_HISTORY_FILE": historyFileURL.path,
                "ZDOTDIR": snippetURL.deletingLastPathComponent().path,
            ]
        )

        XCTAssertTrue(restoredOutput.contains("echo toastty-zsh"))
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

    func testManagedBashSnippetUsesPaneHistoryFile() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let historyFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/panes/test-bash.history")
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
                "TOASTTY_PANE_HISTORY_FILE": historyFileURL.path,
            ]
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), historyFileURL.path)
    }

    func testManagedBashSnippetLoadsPaneHistoryFromExistingFile() throws {
        let snippetURL = try writeStandaloneSnippet(
            ProfileShellIntegrationShell.bash.managedSnippetContents + "\n",
            fileName: "toastty-profile-shell-integration.bash"
        )
        defer { try? FileManager.default.removeItem(at: snippetURL.deletingLastPathComponent()) }

        let historyFileURL = snippetURL.deletingLastPathComponent()
            .appendingPathComponent("history/panes/test-bash.history")
        try writeFile("echo toastty-bash\n", to: historyFileURL)

        let restoredOutput = try runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                "--noprofile",
                "--norc",
                "-ic",
                "source \"$1\"; history 1",
                "toastty-bash-test",
                snippetURL.path,
            ],
            environment: [
                "TOASTTY_PANE_HISTORY_FILE": historyFileURL.path,
            ]
        )

        XCTAssertTrue(restoredOutput.contains("echo toastty-bash"))
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

private func writeFile(_ contents: String, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}
