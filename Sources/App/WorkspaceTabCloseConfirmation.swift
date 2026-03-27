import CoreState
import Foundation

struct WorkspaceTabCloseConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let terminalsRequiringConfirmationCount: Int
    let hasUnavailableTerminalAssessment: Bool
    let detectedRunningCommand: String?

    static let noConfirmation = WorkspaceTabCloseConfirmationAssessment(
        requiresConfirmation: false,
        terminalsRequiringConfirmationCount: 0,
        hasUnavailableTerminalAssessment: false,
        detectedRunningCommand: nil
    )

    var confirmationMessage: String {
        if hasUnavailableTerminalAssessment && terminalsRequiringConfirmationCount == 0 {
            return "Toastty couldn't confirm that every terminal in this tab is idle. Closing the tab may terminate running processes."
        }

        let baseMessage: String
        if terminalsRequiringConfirmationCount == 1,
           hasUnavailableTerminalAssessment == false {
            baseMessage = "A process is still running in this tab. Closing the tab will terminate it."
        } else {
            baseMessage = "One or more processes are still running in this tab. Closing the tab will terminate them."
        }

        if hasUnavailableTerminalAssessment {
            return baseMessage + "\n\nToastty couldn't assess every terminal in this tab."
        }

        guard terminalsRequiringConfirmationCount == 1,
              let detectedRunningCommand else {
            return baseMessage
        }

        return baseMessage + "\n\nDetected command: \(detectedRunningCommand)"
    }
}

enum WorkspaceTabCloseConfirmation {
    static func assess(
        tab: WorkspaceTabState,
        shouldBypassConfirmation: Bool,
        terminalAssessment: (UUID) -> TerminalCloseConfirmationAssessment?
    ) -> WorkspaceTabCloseConfirmationAssessment {
        guard shouldBypassConfirmation == false else {
            return .noConfirmation
        }

        var terminalsRequiringConfirmationCount = 0
        var hasUnavailableTerminalAssessment = false
        var detectedRunningCommand: String?

        for slot in tab.layoutTree.allSlotInfos {
            let panelID = slot.panelID
            guard case .terminal = tab.panels[panelID] else {
                continue
            }

            // Bulk tab close is destructive across multiple terminals, so fall
            // back to confirmation when any individual runtime assessment is unavailable.
            guard let assessment = terminalAssessment(panelID) else {
                hasUnavailableTerminalAssessment = true
                continue
            }

            guard assessment.requiresConfirmation else {
                continue
            }

            terminalsRequiringConfirmationCount += 1
            if detectedRunningCommand == nil {
                detectedRunningCommand = assessment.runningCommand
            }
        }

        let requiresConfirmation = terminalsRequiringConfirmationCount > 0 || hasUnavailableTerminalAssessment
        return WorkspaceTabCloseConfirmationAssessment(
            requiresConfirmation: requiresConfirmation,
            terminalsRequiringConfirmationCount: terminalsRequiringConfirmationCount,
            hasUnavailableTerminalAssessment: hasUnavailableTerminalAssessment,
            detectedRunningCommand: detectedRunningCommand
        )
    }
}
