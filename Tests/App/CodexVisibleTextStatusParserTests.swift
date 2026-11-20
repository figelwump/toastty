import CoreState
import Testing
@testable import ToasttyApp

struct CodexVisibleTextStatusParserTests {
    @Test
    func recognizesComputerUseApprovalMenuAtTheBottomOfTheScreen() {
        #expect(CodexVisibleTextStatusParser.hasComputerUseApprovalPrompt(in: """
        • Hook failed
          hook timed out after 5s
        • Using computer · 1 action

          Field 1/1
          Allow Computer Use to use "Calculator"?

          App: Calculator

            1. Allow                   Run the tool and continue
          › 2. Allow for this session  Run the tool and remember this choice
                                       for this session
            3. Always allow            Run the tool and remember this choice
            4. Cancel                  Cancel this tool call
          enter to submit | esc to cancel
        """))
    }

    @Test(arguments: [
        "Allow Computer Use to use \"Safari\"?",
        """
        Field 1/1
        Allow Computer Use to use "Safari"?
        App: Safari
        › 1. Allow
          2. Allow for this session
          3. Always allow
          4. Cancel
        enter to submit | esc to cancel
        › Ask Codex to do anything
        """,
        """
        Field 1/1
        Do you want to run this command?
        › 1. Allow
          2. Allow for this session
          3. Always allow
          4. Cancel
        enter to submit | esc to cancel
        """,
    ])
    func ignoresOtherApprovalsAndPromptTextOutsideTheActiveMenu(screen: String) {
        #expect(CodexVisibleTextStatusParser.hasComputerUseApprovalPrompt(in: screen) == false)
    }

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
    func parsesStatusLineWorkingStatusOnlyFromLiveStatusLine() {
        let status = CodexVisibleTextStatusParser.statusLineWorkingStatus(
            from: """
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            Deciding on a test file (20s • esc to interrupt)
            """
        )

        #expect(status == SessionStatus(kind: .working, summary: "Working", detail: "Deciding on a test file"))
    }

    @Test
    func ignoresActionableBulletsForStatusLineWorkingStatus() {
        let status = CodexVisibleTextStatusParser.statusLineWorkingStatus(
            from: """
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            • Ran git status --short
            """
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
