@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

@MainActor
final class FocusedPanelCommandControllerTests: XCTestCase {
    func testNonInteractiveCloseRejectsRunningTerminalWithoutPresentingAlert() throws {
        let fixture = try makeTerminalFixture(
            terminalAssessment: TerminalCloseConfirmationAssessment(
                requiresConfirmation: true,
                runningCommand: "sleep 30"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: false)
        )

        XCTAssertEqual(result, .confirmationRequired(.runningTerminal(command: "sleep 30")))
        XCTAssertEqual(fixture.presentations.runningTerminalCount, 0)
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testNonInteractiveCloseTerminatesRunningTerminalWhenExplicitlyRequested() throws {
        let fixture = try makeTerminalFixture(
            terminalAssessment: TerminalCloseConfirmationAssessment(
                requiresConfirmation: true,
                runningCommand: "sleep 30"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: true)
        )

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(fixture.presentations.runningTerminalCount, 0)
        XCTAssertNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testInteractiveCloseStillPresentsRunningTerminalConfirmation() throws {
        let fixture = try makeTerminalFixture(
            terminalAssessment: TerminalCloseConfirmationAssessment(
                requiresConfirmation: true,
                runningCommand: "sleep 30"
            ),
            runningTerminalConfirmationResponse: false
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .interactive
        )

        XCTAssertEqual(result, .canceled)
        XCTAssertEqual(fixture.presentations.runningTerminalCount, 1)
        XCTAssertEqual(fixture.presentations.lastRunningTerminalAssessment?.runningCommand, "sleep 30")
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testNonInteractiveCloseClosesIdleTerminalWithoutPresentingAlert() throws {
        let fixture = try makeTerminalFixture(
            terminalAssessment: TerminalCloseConfirmationAssessment(
                requiresConfirmation: false,
                runningCommand: nil
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: false)
        )

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(fixture.presentations.runningTerminalCount, 0)
        XCTAssertNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testNonInteractiveCloseFailsClosedWhenTerminalAssessmentIsUnavailable() throws {
        let fixture = try makeTerminalFixture(terminalAssessment: nil)

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: false)
        )

        XCTAssertEqual(result, .blocked(.terminalAssessmentUnavailable))
        XCTAssertEqual(fixture.presentations.runningTerminalCount, 0)
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testLaunchTimeBypassRemainsCompatibleWithNonInteractiveClose() throws {
        let fixture = try makeTerminalFixture(
            shouldConfirmClose: false,
            terminalAssessment: TerminalCloseConfirmationAssessment(
                requiresConfirmation: true,
                runningCommand: "sleep 30"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: false)
        )

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(fixture.presentations.runningTerminalCount, 0)
        XCTAssertNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testNonInteractiveTerminalForceDoesNotDiscardDirtyLocalDocument() throws {
        let fixture = try makeLocalDocumentFixture(
            confirmationState: LocalDocumentCloseConfirmationState(
                kind: .dirtyDraft,
                displayName: "README.md"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: true)
        )

        XCTAssertEqual(
            result,
            .confirmationRequired(.dirtyLocalDocument(displayName: "README.md"))
        )
        XCTAssertEqual(fixture.presentations.discardDraftCount, 0)
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testNonInteractiveCloseIsBlockedWhileLocalDocumentSaveIsInProgress() throws {
        let fixture = try makeLocalDocumentFixture(
            confirmationState: LocalDocumentCloseConfirmationState(
                kind: .saveInProgress,
                displayName: "README.md"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: true)
        )

        XCTAssertEqual(
            result,
            .blocked(.localDocumentSaveInProgress(displayName: "README.md"))
        )
        XCTAssertEqual(fixture.presentations.saveInProgressCount, 0)
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testLaunchTimeTerminalBypassDoesNotDiscardDirtyLocalDocument() throws {
        let fixture = try makeLocalDocumentFixture(
            shouldConfirmClose: false,
            confirmationState: LocalDocumentCloseConfirmationState(
                kind: .dirtyDraft,
                displayName: "README.md"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: true)
        )

        XCTAssertEqual(
            result,
            .confirmationRequired(.dirtyLocalDocument(displayName: "README.md"))
        )
        XCTAssertEqual(fixture.presentations.discardDraftCount, 0)
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    func testLaunchTimeTerminalBypassDoesNotInterruptLocalDocumentSave() throws {
        let fixture = try makeLocalDocumentFixture(
            shouldConfirmClose: false,
            confirmationState: LocalDocumentCloseConfirmationState(
                kind: .saveInProgress,
                displayName: "README.md"
            )
        )

        let result = fixture.controller.closeFocusedPanel(
            in: fixture.workspaceID,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: true)
        )

        XCTAssertEqual(
            result,
            .blocked(.localDocumentSaveInProgress(displayName: "README.md"))
        )
        XCTAssertEqual(fixture.presentations.saveInProgressCount, 0)
        XCTAssertNotNil(fixture.store.state.workspaceSelection(containingPanelID: fixture.panelID))
    }

    private func makeTerminalFixture(
        shouldConfirmClose: Bool = true,
        terminalAssessment: TerminalCloseConfirmationAssessment?,
        runningTerminalConfirmationResponse: Bool = false
    ) throws -> CloseFixture {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        let presentations = ClosePresentationRecorder()
        let runtimeRegistry = TerminalRuntimeRegistry()
        let controller = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            shouldConfirmClose: shouldConfirmClose,
            terminalCloseAssessmentProvider: { requestedPanelID in
                XCTAssertEqual(requestedPanelID, panelID)
                return terminalAssessment
            },
            runningTerminalCloseConfirmationPresenter: { assessment in
                presentations.runningTerminalCount += 1
                presentations.lastRunningTerminalAssessment = assessment
                return runningTerminalConfirmationResponse
            }
        )
        return CloseFixture(
            store: store,
            controller: controller,
            workspaceID: workspace.id,
            panelID: panelID,
            presentations: presentations
        )
    }

    private func makeLocalDocumentFixture(
        shouldConfirmClose: Bool = true,
        confirmationState: LocalDocumentCloseConfirmationState
    ) throws -> CloseFixture {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        XCTAssertTrue(
            store.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .localDocument,
                        title: confirmationState.displayName,
                        filePath: "/tmp/\(confirmationState.displayName)"
                    ),
                    placement: .newTab
                )
            )
        )
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let presentations = ClosePresentationRecorder()
        let runtimeRegistry = TerminalRuntimeRegistry()
        let controller = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            shouldConfirmClose: shouldConfirmClose,
            localDocumentCloseConfirmationStateProvider: { requestedPanelID in
                XCTAssertEqual(requestedPanelID, panelID)
                return confirmationState
            },
            discardLocalDocumentDraftConfirmationPresenter: { _ in
                presentations.discardDraftCount += 1
                return false
            },
            localDocumentSaveInProgressPresenter: { _ in
                presentations.saveInProgressCount += 1
            }
        )
        return CloseFixture(
            store: store,
            controller: controller,
            workspaceID: workspaceID,
            panelID: panelID,
            presentations: presentations
        )
    }
}

@MainActor
private struct CloseFixture {
    let store: AppStore
    let controller: FocusedPanelCommandController
    let workspaceID: UUID
    let panelID: UUID
    let presentations: ClosePresentationRecorder
}

@MainActor
private final class ClosePresentationRecorder {
    var runningTerminalCount = 0
    var discardDraftCount = 0
    var saveInProgressCount = 0
    var lastRunningTerminalAssessment: TerminalCloseConfirmationAssessment?
}
