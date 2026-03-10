import CoreState
import Testing

struct TerminalVisibleTextInspectorTests {
    @Test
    func closeAssessmentSkipsConfirmationForEmptyVisibleText() {
        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: "\u{0007}\n")

        #expect(assessment.requiresConfirmation == false)
        #expect(assessment.runningCommand == nil)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt("\u{0007}\n") == false)
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt("\u{0007}\n") == false)
    }

    @Test
    func closeAssessmentSkipsConfirmationForInteractivePrompt() {
        let visibleText = """
        vishal@toastty ~/repo %
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation == false)
        #expect(assessment.runningCommand == nil)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == nil)
    }

    @Test
    func closeAssessmentRequiresConfirmationForForegroundPromptCommand() {
        let visibleText = """
        vishal@toastty ~/repo % npm run dev
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(assessment.runningCommand == "npm run dev")
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == "npm")
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == "npm run dev")
    }

    @Test
    func closeAssessmentRequiresConfirmationForAgentLaunchCommand() {
        let visibleText = """
        vishal@toastty ~/repo % codex --model gpt-5
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(assessment.runningCommand == "codex --model gpt-5")
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == "codex")
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == nil)
        #expect(
            TerminalVisibleTextInspector.inferredRunningCommand(
                visibleText,
                includeAgentLaunchCommands: true
            ) == "codex --model gpt-5"
        )
    }

    @Test
    func closeAssessmentUsesLoosePromptParsing() {
        let visibleText = """
        ~/repo % 
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation == false)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText))
    }

    @Test
    func closeAssessmentFallsBackToConfirmationWhenNoPromptIsVisible() {
        let visibleText = """
        [1]  + running    sleep 30
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(assessment.runningCommand == nil)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
    }
}
