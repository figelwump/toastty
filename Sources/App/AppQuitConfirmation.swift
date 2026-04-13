import CoreState
import Foundation

struct AppQuitConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let terminalsRequiringConfirmationCount: Int
    let hasUnavailableTerminalAssessment: Bool
    let detectedRunningCommand: String?

    static let noConfirmation = AppQuitConfirmationAssessment(
        requiresConfirmation: false,
        terminalsRequiringConfirmationCount: 0,
        hasUnavailableTerminalAssessment: false,
        detectedRunningCommand: nil
    )

    var informativeText: String {
        if hasUnavailableTerminalAssessment && terminalsRequiringConfirmationCount == 0 {
            return "Toastty couldn't confirm that every terminal is idle. Quitting may terminate running processes."
        }

        let baseMessage: String
        if terminalsRequiringConfirmationCount == 1,
           hasUnavailableTerminalAssessment == false {
            baseMessage = "A process is still running in Toastty. Quitting will terminate it."
        } else {
            baseMessage = "One or more processes are still running in Toastty. Quitting will terminate them."
        }

        if hasUnavailableTerminalAssessment {
            return baseMessage + "\n\nToastty couldn't assess every terminal in the app."
        }

        guard terminalsRequiringConfirmationCount == 1,
              let detectedRunningCommand else {
            return baseMessage
        }

        return baseMessage + "\n\nDetected command: \(detectedRunningCommand)"
    }
}

enum AppQuitConfirmation {
    static func assess(
        state: AppState,
        terminalAssessment: (UUID) -> TerminalCloseConfirmationAssessment?
    ) -> AppQuitConfirmationAssessment {
        // Sort so any surfaced running-command detail is deterministic across
        // runs and tests instead of depending on Set iteration order.
        let terminalPanelIDs = state.allTerminalPanelIDs.sorted { lhs, rhs in
            lhs.uuidString < rhs.uuidString
        }
        guard terminalPanelIDs.isEmpty == false else {
            return .noConfirmation
        }

        var terminalsRequiringConfirmationCount = 0
        var hasUnavailableTerminalAssessment = false
        var detectedRunningCommand: String?

        for panelID in terminalPanelIDs {
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
        return AppQuitConfirmationAssessment(
            requiresConfirmation: requiresConfirmation,
            terminalsRequiringConfirmationCount: terminalsRequiringConfirmationCount,
            hasUnavailableTerminalAssessment: hasUnavailableTerminalAssessment,
            detectedRunningCommand: detectedRunningCommand
        )
    }
}
