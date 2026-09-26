@testable import ToasttyApp
import Foundation
import Testing

struct TerminalSurfaceLaunchConfigurationTests {
    @Test
    func normalizedInitialInputAppendsTrailingNewlineWhenNeeded() {
        let configuration = TerminalSurfaceLaunchConfiguration(initialInput: "zmx attach toastty.$TOASTTY_PANEL_ID")

        #expect(configuration.normalizedInitialInput == "zmx attach toastty.$TOASTTY_PANEL_ID\n")
    }

    @Test
    func normalizedInitialInputPreservesExistingTrailingNewline() {
        let configuration = TerminalSurfaceLaunchConfiguration(initialInput: "ssh prod\n")

        #expect(configuration.normalizedInitialInput == "ssh prod\n")
    }

    @Test
    func normalizedInitialInputTreatsBlankCommandsAsEmpty() {
        let configuration = TerminalSurfaceLaunchConfiguration(initialInput: "\n\n")

        #expect(configuration.normalizedInitialInput == nil)
        #expect(configuration.isEmpty)
    }

    @Test
    func launchWorkingDirectoryFallsBackToTheNearestExistingParentOrHome() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-launch-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let root = (rootURL.path as NSString).standardizingPath

        #expect(TerminalLaunchWorkingDirectory.existing(root, homeDirectory: "/home") == root)
        #expect(TerminalLaunchWorkingDirectory.existing(root + "/removed/worktree", homeDirectory: "/home") == root)
        // Only `/` is left, which is no better a start than home.
        #expect(
            TerminalLaunchWorkingDirectory.existing("/toastty-missing-\(UUID().uuidString)/a", homeDirectory: "/home")
                == "/home"
        )
    }
}
