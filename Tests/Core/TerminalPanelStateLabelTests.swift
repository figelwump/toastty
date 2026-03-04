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
    func customTitleIsPreferredWithoutDirectoryContext() {
        let state = TerminalPanelState(
            title: "Dev Server",
            shell: "zsh",
            cwd: "/tmp/api"
        )

        #expect(state.displayPanelLabel == "Dev Server")
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
    func pathCustomTitleMatchingCWDCompactsToDirectoryLabel() {
        let cwd = NSHomeDirectory() + "/GiantThings/repos/toastty"
        let state = TerminalPanelState(
            title: cwd,
            shell: "zsh",
            cwd: cwd
        )

        #expect(state.displayPanelLabel == ".../GiantThings/repos/toastty")
    }

    @Test
    func compactPathTitleIsTreatedAsDirectoryContext() {
        let state = TerminalPanelState(
            title: ".../GiantThings/repos/toastty",
            shell: "zsh",
            cwd: NSHomeDirectory() + "/GiantThings/repos/toastty"
        )

        #expect(state.displayPanelLabel == ".../GiantThings/repos/toastty")
    }

    @Test
    func unicodeEllipsisPathTitleIsTreatedAsDirectoryContext() {
        let state = TerminalPanelState(
            title: "…/GiantThings/repos/toastty",
            shell: "zsh",
            cwd: NSHomeDirectory() + "/GiantThings/repos/toastty"
        )

        #expect(state.displayPanelLabel == ".../GiantThings/repos/toastty")
    }

    @Test
    func pathLikeCustomTitleUsesDirectoryLabelWhenCWDPresent() {
        let state = TerminalPanelState(
            title: "/tmp/other",
            shell: "zsh",
            cwd: "/tmp/current"
        )

        #expect(state.displayPanelLabel == "tmp/current")
    }

    @Test
    func fileURLCustomTitleUsesDirectoryLabelWhenCWDPresent() {
        let state = TerminalPanelState(
            title: "file:///tmp/other",
            shell: "zsh",
            cwd: "/tmp/current"
        )

        #expect(state.displayPanelLabel == "tmp/current")
    }

    @Test
    func pathLikeCustomTitleWithoutDirectoryContextFallsBackToCustomTitle() {
        let state = TerminalPanelState(
            title: "/tmp/other",
            shell: "zsh",
            cwd: "   "
        )

        #expect(state.displayPanelLabel == "/tmp/other")
    }

    @Test
    func decoratedCustomTitleIncludingDirectoryIsPreserved() {
        let state = TerminalPanelState(
            title: "Codex · .../GiantThings/repos/toastty",
            shell: "zsh",
            cwd: NSHomeDirectory() + "/GiantThings/repos/toastty"
        )

        #expect(state.displayPanelLabel == "Codex · .../GiantThings/repos/toastty")
    }

    @Test
    func relativeCWDExactTitleMatchDoesNotDuplicate() {
        let state = TerminalPanelState(
            title: "repo",
            shell: "zsh",
            cwd: "repo"
        )

        #expect(state.displayPanelLabel == "repo")
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
