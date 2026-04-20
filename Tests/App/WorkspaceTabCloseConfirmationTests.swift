@testable import ToasttyApp
import CoreState
import XCTest

final class WorkspaceTabCloseConfirmationTests: XCTestCase {
    func testAssessmentDoesNotRequireConfirmationWhenAllTerminalsAreIdle() {
        let (tab, panelIDs) = makeTab(panelStates: [
            makeTerminalPanelState(title: "Terminal 1"),
            makeTerminalPanelState(title: "Terminal 2"),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false
        ) { panelID in
            guard panelIDs.contains(panelID) else { return nil }
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }

        XCTAssertEqual(assessment, .noConfirmation)
    }

    func testAssessmentRequiresConfirmationWhenAnyTerminalRequiresIt() {
        let (tab, panelIDs) = makeTab(panelStates: [
            makeTerminalPanelState(title: "Terminal 1"),
            makeTerminalPanelState(title: "Terminal 2"),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false
        ) { panelID in
            if panelID == panelIDs[0] {
                return TerminalCloseConfirmationAssessment(
                    requiresConfirmation: true,
                    runningCommand: "npm run dev"
                )
            }
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.terminalsRequiringConfirmationCount, 1)
        XCTAssertFalse(assessment.hasUnavailableTerminalAssessment)
        XCTAssertEqual(assessment.detectedRunningCommand, "npm run dev")
        XCTAssertTrue(assessment.confirmationMessage.contains("Detected command: npm run dev"))
    }

    func testAssessmentFallsBackToConfirmationWhenRuntimeAssessmentIsUnavailable() {
        let (tab, panelIDs) = makeTab(panelStates: [
            makeTerminalPanelState(title: "Terminal 1"),
            makeTerminalPanelState(title: "Terminal 2"),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false
        ) { panelID in
            if panelID == panelIDs[0] {
                return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
            }
            return nil
        }

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.terminalsRequiringConfirmationCount, 0)
        XCTAssertTrue(assessment.hasUnavailableTerminalAssessment)
        XCTAssertNil(assessment.detectedRunningCommand)
        XCTAssertTrue(assessment.confirmationMessage.contains("couldn't confirm"))
    }

    func testAssessmentIgnoresNonTerminalPanels() {
        let (tab, panelIDs) = makeTab(panelStates: [
            makeTerminalPanelState(title: "Terminal 1"),
            .web(WebPanelState(definition: .browser)),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false
        ) { panelID in
            if panelID == panelIDs[0] {
                return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
            }
            XCTFail("Non-terminal panels should not request close confirmation assessment")
            return nil
        }

        XCTAssertEqual(assessment, .noConfirmation)
    }

    func testAssessmentSkipsConfirmationWhenInteractivePromptsAreBypassed() {
        let (tab, _) = makeTab(panelStates: [
            makeTerminalPanelState(title: "Terminal 1"),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: true
        ) { _ in
            XCTFail("Bypassed confirmation should not query terminal assessments")
            return nil
        }

        XCTAssertEqual(assessment, .noConfirmation)
    }

    func testAssessmentRequiresConfirmationForUnsavedLocalDocumentDraft() {
        let (tab, panelIDs) = makeTab(panelStates: [
            .web(
                WebPanelState(
                    definition: .localDocument,
                    title: "README.md",
                    filePath: "/tmp/toastty/readme.md"
                )
            ),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false,
            terminalAssessment: { _ in
                XCTFail("local-document tab close should not request terminal assessments")
                return nil
            },
            localDocumentCloseConfirmationState: { panelID in
                guard panelID == panelIDs[0] else { return nil }
                return LocalDocumentCloseConfirmationState(kind: .dirtyDraft, displayName: "README.md")
            }
        )

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertTrue(assessment.allowsDestructiveConfirmation)
        XCTAssertEqual(assessment.unsavedLocalDocumentDraftCount, 1)
        XCTAssertEqual(
            assessment.confirmationMessage,
            "\"README.md\" has unsaved document changes. Closing the tab will discard them."
        )
    }

    func testAssessmentRequiresWaitingForLocalDocumentSaveInProgress() {
        let (tab, panelIDs) = makeTab(panelStates: [
            .web(
                WebPanelState(
                    definition: .localDocument,
                    title: "README.md",
                    filePath: "/tmp/toastty/readme.md"
                )
            ),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false,
            terminalAssessment: { _ in
                XCTFail("local-document tab close should not request terminal assessments")
                return nil
            },
            localDocumentCloseConfirmationState: { panelID in
                guard panelID == panelIDs[0] else { return nil }
                return LocalDocumentCloseConfirmationState(kind: .saveInProgress, displayName: "README.md")
            }
        )

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertFalse(assessment.allowsDestructiveConfirmation)
        XCTAssertEqual(assessment.localDocumentSaveInProgressCount, 1)
        XCTAssertEqual(
            assessment.confirmationMessage,
            "\"README.md\" is still saving. Wait for the save to finish before closing this tab."
        )
    }

    func testAssessmentCombinesLocalDocumentAndTerminalWarnings() {
        let (tab, panelIDs) = makeTab(panelStates: [
            makeTerminalPanelState(title: "Terminal 1"),
            .web(
                WebPanelState(
                    definition: .localDocument,
                    title: "README.md",
                    filePath: "/tmp/toastty/readme.md"
                )
            ),
        ])

        let assessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: false,
            terminalAssessment: { panelID in
                if panelID == panelIDs[0] {
                    return TerminalCloseConfirmationAssessment(
                        requiresConfirmation: true,
                        runningCommand: "npm run dev"
                    )
                }
                return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
            },
            localDocumentCloseConfirmationState: { panelID in
                guard panelID == panelIDs[1] else { return nil }
                return LocalDocumentCloseConfirmationState(kind: .dirtyDraft, displayName: "README.md")
            }
        )

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.unsavedLocalDocumentDraftCount, 1)
        XCTAssertEqual(
            assessment.confirmationMessage,
            """
            "README.md" has unsaved document changes. Closing the tab will discard them.

            A process is still running in this tab. Closing the tab will terminate it.

            Detected command: npm run dev
            """
        )
    }

    private func makeTab(panelStates: [PanelState]) -> (tab: WorkspaceTabState, panelIDs: [UUID]) {
        precondition(panelStates.isEmpty == false)

        let panelIDs = panelStates.map { _ in UUID() }
        var layoutTree = LayoutNode.slot(slotID: UUID(), panelID: panelIDs[0])

        for panelID in panelIDs.dropFirst() {
            layoutTree = .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: layoutTree,
                second: .slot(slotID: UUID(), panelID: panelID)
            )
        }

        let panels = Dictionary(uniqueKeysWithValues: zip(panelIDs, panelStates))
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: layoutTree,
            panels: panels,
            focusedPanelID: panelIDs[0]
        )
        return (tab, panelIDs)
    }

    private func makeTerminalPanelState(title: String) -> PanelState {
        .terminal(
            TerminalPanelState(
                title: title,
                shell: "zsh",
                cwd: NSHomeDirectory()
            )
        )
    }
}
