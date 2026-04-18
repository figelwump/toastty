import CoreState
import Foundation

struct WorkspaceTabCloseConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let terminalsRequiringConfirmationCount: Int
    let hasUnavailableTerminalAssessment: Bool
    let detectedRunningCommand: String?
    let unsavedLocalDocumentDraftCount: Int
    let firstUnsavedLocalDocumentDisplayName: String?
    let localDocumentSaveInProgressCount: Int
    let firstLocalDocumentSaveInProgressDisplayName: String?

    static let noConfirmation = WorkspaceTabCloseConfirmationAssessment(
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

    var confirmationMessage: String {
        let paragraphs = [
            localDocumentSaveInProgressMessage,
            localDocumentConfirmationMessage,
            terminalConfirmationMessage,
        ].compactMap { $0 }

        return paragraphs.joined(separator: "\n\n")
    }

    private var localDocumentConfirmationMessage: String? {
        guard unsavedLocalDocumentDraftCount > 0 else {
            return nil
        }

        if unsavedLocalDocumentDraftCount == 1,
           let firstUnsavedLocalDocumentDisplayName {
            return "\"\(firstUnsavedLocalDocumentDisplayName)\" has unsaved markdown changes. Closing the tab will discard them."
        }

        return "This tab has unsaved markdown changes. Closing the tab will discard them."
    }

    private var localDocumentSaveInProgressMessage: String? {
        guard localDocumentSaveInProgressCount > 0 else {
            return nil
        }

        if localDocumentSaveInProgressCount == 1,
           let firstLocalDocumentSaveInProgressDisplayName {
            return "\"\(firstLocalDocumentSaveInProgressDisplayName)\" is still saving. Wait for the save to finish before closing this tab."
        }

        return "This tab still has markdown saves in progress. Wait for them to finish before closing the tab."
    }

    private var terminalConfirmationMessage: String? {
        guard terminalsRequiringConfirmationCount > 0 || hasUnavailableTerminalAssessment else {
            return nil
        }

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
        terminalAssessment: (UUID) -> TerminalCloseConfirmationAssessment?,
        localDocumentCloseConfirmationState: (UUID) -> LocalDocumentCloseConfirmationState? = { _ in nil }
    ) -> WorkspaceTabCloseConfirmationAssessment {
        guard shouldBypassConfirmation == false else {
            return .noConfirmation
        }

        var terminalsRequiringConfirmationCount = 0
        var hasUnavailableTerminalAssessment = false
        var detectedRunningCommand: String?
        var unsavedLocalDocumentDraftCount = 0
        var firstUnsavedLocalDocumentDisplayName: String?
        var localDocumentSaveInProgressCount = 0
        var firstLocalDocumentSaveInProgressDisplayName: String?

        for slot in tab.layoutTree.allSlotInfos {
            let panelID = slot.panelID
            switch tab.panels[panelID] {
            case .some(.terminal):
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

            case .some(.web(let webState)) where webState.definition == .localDocument:
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

            default:
                continue
            }
        }

        let requiresConfirmation =
            terminalsRequiringConfirmationCount > 0 ||
            hasUnavailableTerminalAssessment ||
            unsavedLocalDocumentDraftCount > 0 ||
            localDocumentSaveInProgressCount > 0
        return WorkspaceTabCloseConfirmationAssessment(
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
