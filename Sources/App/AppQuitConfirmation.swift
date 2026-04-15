import CoreState
import Foundation

struct AppQuitConfirmationAssessment: Equatable, Sendable {
    let requiresConfirmation: Bool
    let terminalsRequiringConfirmationCount: Int
    let hasUnavailableTerminalAssessment: Bool
    let detectedRunningCommand: String?
    let unsavedMarkdownDraftCount: Int
    let firstUnsavedMarkdownDisplayName: String?
    let markdownSaveInProgressCount: Int
    let firstMarkdownSaveInProgressDisplayName: String?

    static let noConfirmation = AppQuitConfirmationAssessment(
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

    var informativeText: String {
        let paragraphs = [
            markdownSaveInProgressInformativeText,
            markdownInformativeText,
            terminalInformativeText,
        ].compactMap { $0 }

        return paragraphs.joined(separator: "\n\n")
    }

    private var markdownInformativeText: String? {
        guard unsavedMarkdownDraftCount > 0 else {
            return nil
        }

        if unsavedMarkdownDraftCount == 1,
           let firstUnsavedMarkdownDisplayName {
            return "\"\(firstUnsavedMarkdownDisplayName)\" has unsaved markdown changes. Quitting Toastty will discard them."
        }

        return "Toastty has unsaved markdown changes. Quitting will discard them."
    }

    private var markdownSaveInProgressInformativeText: String? {
        guard markdownSaveInProgressCount > 0 else {
            return nil
        }

        if markdownSaveInProgressCount == 1,
           let firstMarkdownSaveInProgressDisplayName {
            return "\"\(firstMarkdownSaveInProgressDisplayName)\" is still saving. Wait for the save to finish before quitting Toastty."
        }

        return "Toastty still has markdown saves in progress. Wait for them to finish before quitting."
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
        markdownCloseConfirmationState: (UUID) -> MarkdownCloseConfirmationState? = { _ in nil }
    ) -> AppQuitConfirmationAssessment {
        // Sort so any surfaced running-command detail is deterministic across
        // runs and tests instead of depending on Set iteration order.
        let terminalPanelIDs = state.allTerminalPanelIDs.sorted { lhs, rhs in
            lhs.uuidString < rhs.uuidString
        }
        let markdownPanelIDs = state.workspacesByID.values
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
        guard terminalPanelIDs.isEmpty == false || markdownPanelIDs.isEmpty == false else {
            return .noConfirmation
        }

        var terminalsRequiringConfirmationCount = 0
        var hasUnavailableTerminalAssessment = false
        var detectedRunningCommand: String?
        var unsavedMarkdownDraftCount = 0
        var firstUnsavedMarkdownDisplayName: String?
        var markdownSaveInProgressCount = 0
        var firstMarkdownSaveInProgressDisplayName: String?

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

        for panelID in markdownPanelIDs {
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
        }

        let requiresConfirmation =
            terminalsRequiringConfirmationCount > 0 ||
            hasUnavailableTerminalAssessment ||
            unsavedMarkdownDraftCount > 0 ||
            markdownSaveInProgressCount > 0
        return AppQuitConfirmationAssessment(
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
