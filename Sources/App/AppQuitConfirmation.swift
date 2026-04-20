import CoreState
import Foundation

struct AppQuitConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let terminalsRequiringConfirmationCount: Int
    let hasUnavailableTerminalAssessment: Bool
    let detectedRunningCommand: String?
    let unsavedLocalDocumentDraftCount: Int
    let firstUnsavedLocalDocumentDisplayName: String?
    let localDocumentSaveInProgressCount: Int
    let firstLocalDocumentSaveInProgressDisplayName: String?

    static let noConfirmation = AppQuitConfirmationAssessment(
        requiresConfirmation: false,
        terminalsRequiringConfirmationCount: 0,
        hasUnavailableTerminalAssessment: false,
        detectedRunningCommand: nil,
        unsavedLocalDocumentDraftCount: 0,
        firstUnsavedLocalDocumentDisplayName: nil,
        localDocumentSaveInProgressCount: 0,
        firstLocalDocumentSaveInProgressDisplayName: nil
    )

    var allowsDestructiveConfirmation: Bool {
        localDocumentSaveInProgressCount == 0
    }

    var informativeText: String {
        let paragraphs = [
            localDocumentSaveInProgressInformativeText,
            localDocumentInformativeText,
            terminalInformativeText,
        ].compactMap { $0 }

        return paragraphs.joined(separator: "\n\n")
    }

    private var localDocumentInformativeText: String? {
        guard unsavedLocalDocumentDraftCount > 0 else {
            return nil
        }

        if unsavedLocalDocumentDraftCount == 1,
           let firstUnsavedLocalDocumentDisplayName {
            return "\"\(firstUnsavedLocalDocumentDisplayName)\" has unsaved document changes. Quitting Toastty will discard them."
        }

        return "Toastty has unsaved document changes. Quitting will discard them."
    }

    private var localDocumentSaveInProgressInformativeText: String? {
        guard localDocumentSaveInProgressCount > 0 else {
            return nil
        }

        if localDocumentSaveInProgressCount == 1,
           let firstLocalDocumentSaveInProgressDisplayName {
            return "\"\(firstLocalDocumentSaveInProgressDisplayName)\" is still saving. Wait for the save to finish before quitting Toastty."
        }

        return "Toastty still has document saves in progress. Wait for them to finish before quitting."
    }

    private var terminalInformativeText: String? {
        guard terminalsRequiringConfirmationCount > 0 || hasUnavailableTerminalAssessment else {
            return nil
        }

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
        terminalAssessment: (UUID) -> TerminalCloseConfirmationAssessment?,
        localDocumentCloseConfirmationState: (UUID) -> LocalDocumentCloseConfirmationState? = { _ in nil }
    ) -> AppQuitConfirmationAssessment {
        // Sort so any surfaced running-command detail is deterministic across
        // runs and tests instead of depending on Set iteration order.
        let terminalPanelIDs = state.allTerminalPanelIDs.sorted { lhs, rhs in
            lhs.uuidString < rhs.uuidString
        }
        let localDocumentPanelIDs = state.workspacesByID.values
            .reduce(into: Set<UUID>()) { result, workspace in
                for tab in workspace.orderedTabs {
                    for (panelID, panelState) in tab.panels {
                        guard case .web(let webState) = panelState,
                              webState.definition == .localDocument else {
                            continue
                        }
                        result.insert(panelID)
                    }
                }
            }
            .sorted { lhs, rhs in
                lhs.uuidString < rhs.uuidString
            }
        guard terminalPanelIDs.isEmpty == false || localDocumentPanelIDs.isEmpty == false else {
            return .noConfirmation
        }

        var terminalsRequiringConfirmationCount = 0
        var hasUnavailableTerminalAssessment = false
        var detectedRunningCommand: String?
        var unsavedLocalDocumentDraftCount = 0
        var firstUnsavedLocalDocumentDisplayName: String?
        var localDocumentSaveInProgressCount = 0
        var firstLocalDocumentSaveInProgressDisplayName: String?

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

        for panelID in localDocumentPanelIDs {
            guard let closeConfirmationState = localDocumentCloseConfirmationState(panelID) else {
                continue
            }

            switch closeConfirmationState.kind {
            case .dirtyDraft:
                unsavedLocalDocumentDraftCount += 1
                if firstUnsavedLocalDocumentDisplayName == nil {
                    firstUnsavedLocalDocumentDisplayName = closeConfirmationState.displayName
                }

            case .saveInProgress:
                localDocumentSaveInProgressCount += 1
                if firstLocalDocumentSaveInProgressDisplayName == nil {
                    firstLocalDocumentSaveInProgressDisplayName = closeConfirmationState.displayName
                }
            }
        }

        let requiresConfirmation =
            terminalsRequiringConfirmationCount > 0 ||
            hasUnavailableTerminalAssessment ||
            unsavedLocalDocumentDraftCount > 0 ||
            localDocumentSaveInProgressCount > 0
        return AppQuitConfirmationAssessment(
            requiresConfirmation: requiresConfirmation,
            terminalsRequiringConfirmationCount: terminalsRequiringConfirmationCount,
            hasUnavailableTerminalAssessment: hasUnavailableTerminalAssessment,
            detectedRunningCommand: detectedRunningCommand,
            unsavedLocalDocumentDraftCount: unsavedLocalDocumentDraftCount,
            firstUnsavedLocalDocumentDisplayName: firstUnsavedLocalDocumentDisplayName,
            localDocumentSaveInProgressCount: localDocumentSaveInProgressCount,
            firstLocalDocumentSaveInProgressDisplayName: firstLocalDocumentSaveInProgressDisplayName
        )
    }
}
