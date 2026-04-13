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

    @discardableResult
    func sendText(_ text: String, submit: Bool, panelID: UUID) -> Bool {
        sentTextByPanelID[panelID] = submit ? text + "\n" : text
        return sendSucceeds
    }

    func readVisibleText(panelID: UUID) -> String? {
        visibleTextByPanelID[panelID] ?? defaultVisibleText
    }

    func promptState(panelID: UUID) -> TerminalPromptState {
        promptStateByPanelID[panelID] ?? defaultPromptState
    }
}
