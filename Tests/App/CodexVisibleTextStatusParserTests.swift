import CoreState
import Testing
@testable import ToasttyApp

struct CodexVisibleTextStatusParserTests {
    @Test
    func parsesUsageLimitBannerAsError() {
        let status = CodexVisibleTextStatusParser.fatalErrorStatus(
            from: """
            You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
            """
        )

        #expect(
            status == SessionStatus(
                kind: .error,
                summary: "Error",
                detail: "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM."
            )
        )
    }

    @Test
    func parsesExecutingShellCommandsStatusLine() {
        let status = CodexVisibleTextStatusParser.workingStatus(
            from: "Executing shell commands (7s • esc to interrupt)"
        )

        #expect(status == SessionStatus(kind: .working, summary: "Working", detail: "Executing shell commands"))
    }

    @Test
    func prefersLatestActionableBulletAndIgnoresReasoningBullets() {
        let status = CodexVisibleTextStatusParser.workingStatus(
            from: """
            • I need to answer the user by using shell commands like pwd.
            • Counting modified entries
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            • Ran git status --short
            """
        )

        #expect(status == SessionStatus(kind: .working, summary: "Working", detail: "Ran git status --short"))
    }

    @Test
    func ignoresGenericWorkingSpinner() {
        let status = CodexVisibleTextStatusParser.workingStatus(
            from: "Working (7s • esc to interrupt)"
        )

        #expect(status == nil)
    }

    @Test
    func ignoresGenericErrorTextWithoutKnownFatalBanner() {
        let status = CodexVisibleTextStatusParser.fatalErrorStatus(
            from: """
            error: command exited with code 1
            """
        )

        #expect(status == nil)
    }
}
