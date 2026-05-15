@testable import ToasttyApp
import CoreState
import XCTest

final class TerminalPanelHostStateTests: XCTestCase {
    func testTitleOnlyChangeMapsToSameHostState() {
        var terminalState = TerminalPanelState(
            title: "Terminal",
            shell: "zsh",
            cwd: "/tmp/repo",
            launchWorkingDirectory: "/tmp/launch"
        )
        let originalHostState = TerminalPanelHostState(terminalState: terminalState)

        terminalState.title = "Spinner frame"

        XCTAssertEqual(TerminalPanelHostState(terminalState: terminalState), originalHostState)
    }

    func testShellOnlyChangeMapsToSameHostState() {
        var terminalState = TerminalPanelState(
            title: "Terminal",
            shell: "zsh",
            cwd: "/tmp/repo",
            launchWorkingDirectory: "/tmp/launch"
        )
        let originalHostState = TerminalPanelHostState(terminalState: terminalState)

        terminalState.shell = "bash"

        XCTAssertEqual(TerminalPanelHostState(terminalState: terminalState), originalHostState)
    }

    func testCWDChangeMapsToDifferentHostState() {
        let originalHostState = TerminalPanelHostState(
            terminalState: TerminalPanelState(
                title: "Terminal",
                shell: "zsh",
                cwd: "/tmp/repo",
                launchWorkingDirectory: "/tmp/launch"
            )
        )
        let nextHostState = TerminalPanelHostState(
            terminalState: TerminalPanelState(
                title: "Terminal",
                shell: "zsh",
                cwd: "/tmp/other",
                launchWorkingDirectory: "/tmp/launch"
            )
        )

        XCTAssertNotEqual(nextHostState, originalHostState)
    }

    func testLaunchWorkingDirectoryChangeMapsToDifferentHostState() {
        let originalHostState = TerminalPanelHostState(
            terminalState: TerminalPanelState(
                title: "Terminal",
                shell: "zsh",
                cwd: " ",
                launchWorkingDirectory: "/tmp/launch"
            )
        )
        let nextHostState = TerminalPanelHostState(
            terminalState: TerminalPanelState(
                title: "Terminal",
                shell: "zsh",
                cwd: " ",
                launchWorkingDirectory: "/tmp/restored"
            )
        )

        XCTAssertNotEqual(nextHostState, originalHostState)
        XCTAssertEqual(nextHostState.workingDirectorySeed, "/tmp/restored")
        XCTAssertNil(nextHostState.expectedProcessWorkingDirectory)
    }
}
