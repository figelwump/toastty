import CoreState
import Foundation

struct WorkspaceTabCloseConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let terminalsRequiringConfirmationCount: Int
    let hasUnavailableTerminalAssessment: Bool
    let detectedRunningCommand: String?
    let unsavedMarkdownDraftCount: Int
    let firstUnsavedMarkdownDisplayName: String?
    let markdownSaveInProgressCount: Int
    let firstMarkdownSaveInProgressDisplayName: String?

    static let noConfirmation = WorkspaceTabCloseConfirmationAssessment(
        requiresConfirmation: false,
        terminalsRequiringConfirmationCount: 0,
        hasUnavailableTerminalAssessment: false,
        detectedRunningCommand: nil,
        unsavedMarkdownDraftCount: 0,
        firstUnsavedMarkdownDisplayName: nil,
        markdownSaveInProgressCount: 0,
        firstMarkdownSaveInProgressDisplayName: nil
    )

    var allowsDestructiveConfirmation: Bool {
        markdownSaveInProgressCount == 0
    }

    var confirmationMessage: String {
        let paragraphs = [
            markdownSaveInProgressMessage,
            markdownConfirmationMessage,
            terminalConfirmationMessage,
        ].compactMap { $0 }

        return paragraphs.joined(separator: "\n\n")
    }

    private var markdownConfirmationMessage: String? {
        guard unsavedMarkdownDraftCount > 0 else {
            return nil
        }

        if unsavedMarkdownDraftCount == 1,
           let firstUnsavedMarkdownDisplayName {
            return "\"\(firstUnsavedMarkdownDisplayName)\" has unsaved markdown changes. Closing the tab will discard them."
        }

        return "This tab has unsaved markdown changes. Closing the tab will discard them."
    }

    private var markdownSaveInProgressMessage: String? {
        guard markdownSaveInProgressCount > 0 else {
            return nil
        }

        if markdownSaveInProgressCount == 1,
           let firstMarkdownSaveInProgressDisplayName {
            return "\"\(firstMarkdownSaveInProgressDisplayName)\" is still saving. Wait for the save to finish before closing this tab."
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
        markdownCloseConfirmationState: (UUID) -> MarkdownCloseConfirmationState? = { _ in nil }
    ) -> WorkspaceTabCloseConfirmationAssessment {
        guard shouldBypassConfirmation == false else {
            return .noConfirmation
        }

        var terminalsRequiringConfirmationCount = 0
        var hasUnavailableTerminalAssessment = false
        var detectedRunningCommand: String?
        var unsavedMarkdownDraftCount = 0
        var firstUnsavedMarkdownDisplayName: String?
        var markdownSaveInProgressCount = 0
        var firstMarkdownSaveInProgressDisplayName: String?

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
                guard let closeConfirmationState = markdownCloseConfirmationState(panelID) else {
                    continue
                }

                switch closeConfirmationState.kind {
                case .dirtyDraft:
                    unsavedMarkdownDraftCount += 1
                    if firstUnsavedMarkdownDisplayName == nil {
                        firstUnsavedMarkdownDisplayName = closeConfirmationState.displayName
                    }

                case .saveInProgress:
                    markdownSaveInProgressCount += 1
                    if firstMarkdownSaveInProgressDisplayName == nil {
                        firstMarkdownSaveInProgressDisplayName = closeConfirmationState.displayName
                    }
                }

            default:
                continue
            }
        }

        let requiresConfirmation =
            terminalsRequiringConfirmationCount > 0 ||
            hasUnavailableTerminalAssessment ||
            unsavedMarkdownDraftCount > 0 ||
            markdownSaveInProgressCount > 0
        return WorkspaceTabCloseConfirmationAssessment(
            requiresConfirmation: requiresConfirmation,
            terminalsRequiringConfirmationCount: terminalsRequiringConfirmationCount,
            hasUnavailableTerminalAssessment: hasUnavailableTerminalAssessment,
            detectedRunningCommand: detectedRunningCommand,
            unsavedMarkdownDraftCount: unsavedMarkdownDraftCount,
            firstUnsavedMarkdownDisplayName: firstUnsavedMarkdownDisplayName,
            markdownSaveInProgressCount: markdownSaveInProgressCount,
            firstMarkdownSaveInProgressDisplayName: firstMarkdownSaveInProgressDisplayName
        )
    }
}
