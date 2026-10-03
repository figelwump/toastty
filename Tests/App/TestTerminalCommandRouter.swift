import Foundation
@testable import ToasttyApp

@MainActor
final class TestTerminalCommandRouter: TerminalCommandRouting {
    var sendSucceeds = true
    /// What a failed send reports. A send that fails before any text
    /// reaches the terminal is `unavailable`.
    var sendFailure: TerminalInputDeliveryResult = .unavailable
    /// How many of the next sends fail before sends follow `sendSucceeds`.
    var failingSendCount = 0
    private(set) var sendAttemptCount = 0
    var defaultVisibleText: String?
    var defaultPromptState: TerminalPromptState = .unavailable
    var visibleTextByPanelID: [UUID: String] = [:]
    var promptStateByPanelID: [UUID: TerminalPromptState] = [:]
    private(set) var sentTextByPanelID: [UUID: String] = [:]
    private(set) var focusPolicyByPanelID: [UUID: TerminalInputFocusPolicy] = [:]

    @discardableResult
    func sendManagedAgentCommand(
        _ commandLine: String,
        panelID: UUID,
        focusPolicy: TerminalInputFocusPolicy
    ) -> Bool {
        sentTextByPanelID[panelID] = commandLine + "\n"
        focusPolicyByPanelID[panelID] = focusPolicy
        return sendSucceeds
    }

    func sendManagedAgentCommandResult(
        _ commandLine: String,
        panelID: UUID,
        focusPolicy: TerminalInputFocusPolicy
    ) -> TerminalInputDeliveryResult {
        sendAttemptCount += 1
        if failingSendCount > 0 {
            failingSendCount -= 1
            return sendFailure
        }
        return sendManagedAgentCommand(commandLine, panelID: panelID, focusPolicy: focusPolicy)
            ? .delivered
            : sendFailure
    }

    func readVisibleText(panelID: UUID) -> String? {
        visibleTextByPanelID[panelID] ?? defaultVisibleText
    }

    func promptState(panelID: UUID) -> TerminalPromptState {
        promptStateByPanelID[panelID] ?? defaultPromptState
    }
}
