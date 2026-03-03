import CoreState
import Foundation
import Testing

struct TerminalPanelStateLabelTests {
    @Test
    func defaultTitleUsesDirectoryOnly() {
        let state = TerminalPanelState(
            title: "Terminal 1",
            shell: "/bin/zsh",
            cwd: "/tmp/toastty"
        )

        #expect(state.displayPanelLabel == "tmp/toastty")
    }

    @Test
    func defaultTitleCompactsHomeDirectory() {
        let state = TerminalPanelState(
            title: "Terminal 2",
            shell: "zsh",
            cwd: NSHomeDirectory()
        )

        #expect(state.displayPanelLabel == "~")
    }

    @Test
    func defaultTitleCompactsChildrenOfHomeDirectory() {
        let state = TerminalPanelState(
            title: "Terminal 3",
            shell: "zsh",
            cwd: NSHomeDirectory() + "/projects/toastty"
        )

        #expect(state.displayPanelLabel == "~/projects/toastty")
    }

    @Test
    func defaultTitleCompactsDeepChildrenOfHomeDirectory() {
        let state = TerminalPanelState(
            title: "Terminal 5",
            shell: "zsh",
            cwd: NSHomeDirectory() + "/projects/toastty/backend/api"
        )

        #expect(state.displayPanelLabel == ".../toastty/backend/api")
    }

    @Test
    func defaultTitleMatchesGhosttyStyleForHomeDescendantPath() {
        let state = TerminalPanelState(
            title: "Terminal 6",
            shell: "zsh",
            cwd: NSHomeDirectory() + "/GiantThings/repos/toastty"
        )

        #expect(state.displayPanelLabel == ".../GiantThings/repos/toastty")
    }

    @Test
    func customTitleIsPreferredAndIncludesDirectoryContext() {
        let state = TerminalPanelState(
            title: "Dev Server",
            shell: "zsh",
            cwd: "/tmp/api"
        )

        #expect(state.displayPanelLabel == "Dev Server · tmp/api")
    }

    @Test
    func customTitleSkipsDuplicateDirectoryContext() {
        let state = TerminalPanelState(
            title: "api",
            shell: "zsh",
            cwd: "/api"
        )

        #expect(state.displayPanelLabel == "api")
    }

    @Test
    func bareTerminalTitleIsTreatedAsDefault() {
        let state = TerminalPanelState(
            title: "Terminal",
            shell: "zsh",
            cwd: "/tmp/repo"
        )

        #expect(state.displayPanelLabel == "tmp/repo")
    }

    @Test
    func fallsBackToShellWhenDirectoryIsUnavailable() {
        let state = TerminalPanelState(
            title: "Terminal 4",
            shell: "/bin/zsh",
            cwd: "   "
        )

        #expect(state.displayPanelLabel == "zsh")
    }
}
