import Testing
@testable import CoreState

struct DesktopNotificationContentResolverTests {
    @Test
    func preservesProvidedTitleAndBody() {
        let resolved = DesktopNotificationContentResolver.resolve(
            title: "Build Complete",
            body: "All checks passed."
        )

        #expect(resolved.title == "Build Complete")
        #expect(resolved.body == "All checks passed.")
    }

    @Test
    func usesContextWhenTitleMissing() {
        let resolved = DesktopNotificationContentResolver.resolve(
            title: "   ",
            body: "Agent response ready",
            context: DesktopNotificationContext(
                workspaceTitle: "Workspace 2",
                panelLabel: "repo/toastty · zsh"
            )
        )

        #expect(resolved.title == "repo/toastty · zsh")
        #expect(resolved.body == "Agent response ready")
    }

    @Test
    func usesContextWhenBodyMissing() {
        let resolved = DesktopNotificationContentResolver.resolve(
            title: "Codex",
            body: "",
            context: DesktopNotificationContext(
                workspaceTitle: "Workspace 2",
                panelLabel: "repo/toastty · zsh"
            )
        )

        #expect(resolved.title == "Codex")
        #expect(resolved.body == "Workspace 2 · repo/toastty · zsh")
    }

    @Test
    func fallsBackToActionableBodyWithoutContext() {
        let resolved = DesktopNotificationContentResolver.resolve(
            title: "Claude Code",
            body: " \n "
        )

        #expect(resolved.title == "Claude Code")
        #expect(resolved.body == "Open Toastty for details.")
    }

    @Test
    func fallsBackToDefaultsWhenPayloadAndContextMissing() {
        let resolved = DesktopNotificationContentResolver.resolve(
            title: " ",
            body: " "
        )

        #expect(resolved.title == "Toastty")
        #expect(resolved.body == "Notification")
    }
}
