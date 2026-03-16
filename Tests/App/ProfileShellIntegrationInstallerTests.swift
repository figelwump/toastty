@testable import ToasttyApp
import Foundation
import XCTest

final class ProfileShellIntegrationInstallerTests: XCTestCase {
    func testInstallationPlanUsesZshRcForZsh() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
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

        let snippetContents = try String(
            contentsOf: homeDirectoryURL.appendingPathComponent(".toastty/shell/toastty-profile-shell-integration.zsh"),
            encoding: .utf8
        )
        XCTAssertTrue(snippetContents.contains("add-zsh-hook precmd _toastty_precmd"))
        XCTAssertTrue(snippetContents.contains("add-zsh-hook preexec _toastty_preexec"))
    }

    func testInstallIsIdempotentWhenManagedSnippetAlreadyReferenced() throws {
        let homeDirectoryURL = try makeTemporaryHomeDirectory()
        let installer = ProfileShellIntegrationInstaller(
            homeDirectoryPath: homeDirectoryURL.path,
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
            shellPathProvider: { "/opt/homebrew/bin/fish" }
        )

        XCTAssertThrowsError(try installer.installationPlan()) { error in
            guard case .unsupportedShell(let shellPath) = error as? ProfileShellIntegrationInstallerError else {
                return XCTFail("Expected unsupported shell error, got \(error)")
            }
            XCTAssertEqual(shellPath, "/opt/homebrew/bin/fish")
        }
    }
}

private func makeTemporaryHomeDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("toastty-shell-integration-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private func writeFile(_ contents: String, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}
