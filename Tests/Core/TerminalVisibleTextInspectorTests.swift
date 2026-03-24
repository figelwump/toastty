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
        #expect(TerminalVisibleTextInspector.appearsBusy("\u{0007}\n") == false)
    }

    @Test
    func busyAssessmentTreatsBlankPaneAsIdle() {
        #expect(TerminalVisibleTextInspector.appearsBusy("") == false)
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
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
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
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
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
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
        #expect(
            TerminalVisibleTextInspector.inferredRunningCommand(
                visibleText,
                includeAgentLaunchCommands: true
            ) == "codex --model gpt-5"
        )
    }

    @Test
    func closeAssessmentTreatsEnvPrefixedAgentLaunchAsAgentCommand() {
        let visibleText = """
        vishal@toastty ~/repo % TOASTTY_SESSION_ID=abc123 TOASTTY_PANEL_ID=def456 codex --model gpt-5
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(
            assessment.runningCommand ==
                "TOASTTY_SESSION_ID=abc123 TOASTTY_PANEL_ID=def456 codex --model gpt-5"
        )
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == "codex")
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
        #expect(
            TerminalVisibleTextInspector.inferredRunningCommand(
                visibleText,
                includeAgentLaunchCommands: true
            ) == "TOASTTY_SESSION_ID=abc123 TOASTTY_PANEL_ID=def456 codex --model gpt-5"
        )
    }

    @Test
    func closeAssessmentTreatsAssignmentOnlyPromptAsInteractive() {
        let visibleText = """
        vishal@toastty ~/repo % FOO=bar BAZ=qux
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation == false)
        #expect(assessment.runningCommand == nil)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
    }

    @Test
    func closeAssessmentTreatsEnvPrefixedNonAgentCommandsAsForegroundCommands() {
        let visibleText = """
        vishal@toastty ~/repo % FOO=bar npm run dev
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(assessment.runningCommand == "FOO=bar npm run dev")
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == "npm")
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == "FOO=bar npm run dev")
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
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
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
    }

    @Test
    func closeAssessmentTreatsTwoLineHostPromptAsInteractive() {
        let visibleText = """
        /Users/j/Documents/Code/conductor/workspaces/pop/san-antonio
        mac:san-antonio j$
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation == false)
        #expect(assessment.runningCommand == nil)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
    }

    @Test
    func closeAssessmentTreatsTwoLineHostPromptCommandAsForegroundCommand() {
        let visibleText = """
        /Users/j/Documents/Code/conductor/workspaces/pop/san-antonio
        mac:san-antonio j$ npm run dev
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(assessment.runningCommand == "npm run dev")
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == "npm")
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == "npm run dev")
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
    }

    @Test
    func closeAssessmentIgnoresHostLikeLineWhenPreviousLineIsNotSinglePathToken() {
        let visibleText = """
        /Users/j/project is missing
        mac:san-antonio j$ npm run dev
        """

        let assessment = TerminalVisibleTextInspector.assessCloseConfirmation(for: visibleText)

        #expect(assessment.requiresConfirmation)
        #expect(assessment.runningCommand == nil)
        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText) == false)
        #expect(TerminalVisibleTextInspector.recentPromptCommandToken(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.inferredRunningCommand(visibleText) == nil)
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText))
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
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText))
    }

    @Test
    func busyAssessmentTreatsOutputAfterPromptAsBusy() {
        let visibleText = """
        vishal@toastty ~/repo % claude
        Claude Code v2.1.72
        Thinking...
        """

        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText))
    }

    @Test
    func busyAssessmentUsesMostRecentPromptNearBottom() {
        let visibleText = """
        vishal@toastty ~/repo % ls
        AGENTS.md
        Sources
        vishal@toastty ~/repo %
        """

        #expect(TerminalVisibleTextInspector.showsInteractiveShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.showsIdleShellPrompt(visibleText))
        #expect(TerminalVisibleTextInspector.appearsBusy(visibleText) == false)
    }
}
