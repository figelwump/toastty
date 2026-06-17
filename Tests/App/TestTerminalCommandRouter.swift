import Foundation
@testable import ToasttyApp

@MainActor
final class TestTerminalCommandRouter: TerminalCommandRouting {
    var sendSucceeds = true
    var defaultVisibleText: String?
    var defaultPromptState: TerminalPromptState = .unavailable
    var visibleTextByPanelID: [UUID: String] = [:]
    var promptStateByPanelID: [UUID: TerminalPromptState] = [:]
    private(set) var sentTextByPanelID: [UUID: String] = [:]
    private(set) var focusPolicyByPanelID: [UUID: TerminalInputFocusPolicy] = [:]

    @discardableResult
    func sendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        sendText(text, submit: submit, panelID: panelID, focusPolicy: .focusTarget)
    }

    @discardableResult
    func sendText(
        _ text: String,
        submit: Bool,
        panelID: UUID,
        focusPolicy: TerminalInputFocusPolicy
    ) -> Bool {
        sentTextByPanelID[panelID] = submit ? text + "\n" : text
        focusPolicyByPanelID[panelID] = focusPolicy
        return sendSucceeds
    }

    func readVisibleText(panelID: UUID) -> String? {
        visibleTextByPanelID[panelID] ?? defaultVisibleText
    }

    func promptState(panelID: UUID) -> TerminalPromptState {
        promptStateByPanelID[panelID] ?? defaultPromptState
    }
}
