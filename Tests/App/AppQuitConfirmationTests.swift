@testable import ToasttyApp
import CoreState
import XCTest

final class AppQuitConfirmationTests: XCTestCase {
    func testAssessDoesNotRequireConfirmationWhenAppHasNoTerminalPanels() {
        let state = makeWebOnlyAppState()

        let assessment = AppQuitConfirmation.assess(state: state) { _ in
            XCTFail("web-only app should not request terminal assessments")
            return nil
        }

        XCTAssertEqual(assessment, .noConfirmation)
    }

    func testAssessDoesNotRequireConfirmationWhenAllTerminalsAreIdle() {
        let workspace = WorkspaceState.bootstrap(title: "Workspace")
        let state = makeAppState(workspaces: [workspace])

        let assessment = AppQuitConfirmation.assess(state: state) { _ in
            TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }

        XCTAssertEqual(assessment, .noConfirmation)
    }

    func testAssessRequiresConfirmationWhenTerminalIsBusy() {
        let workspace = WorkspaceState.bootstrap(title: "Workspace")
        guard let panelID = workspace.allTerminalPanelIDs.first else {
            return XCTFail("expected bootstrap workspace to contain a terminal panel")
        }
        let state = makeAppState(workspaces: [workspace])

        let assessment = AppQuitConfirmation.assess(state: state) { requestedPanelID in
            guard requestedPanelID == panelID else {
                return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
            }
            return TerminalCloseConfirmationAssessment(
                requiresConfirmation: true,
                runningCommand: "npm run dev"
            )
        }

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.terminalsRequiringConfirmationCount, 1)
        XCTAssertFalse(assessment.hasUnavailableTerminalAssessment)
        XCTAssertEqual(assessment.detectedRunningCommand, "npm run dev")
        XCTAssertEqual(
            assessment.informativeText,
            "A process is still running in Toastty. Quitting will terminate it.\n\nDetected command: npm run dev"
        )
    }

    func testAssessRequiresConfirmationWhenTerminalAssessmentIsUnavailable() {
        let workspace = WorkspaceState.bootstrap(title: "Workspace")
        let state = makeAppState(workspaces: [workspace])

        let assessment = AppQuitConfirmation.assess(state: state) { _ in
            nil
        }

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.terminalsRequiringConfirmationCount, 0)
        XCTAssertTrue(assessment.hasUnavailableTerminalAssessment)
        XCTAssertNil(assessment.detectedRunningCommand)
        XCTAssertEqual(
            assessment.informativeText,
            "Toastty couldn't confirm that every terminal is idle. Quitting may terminate running processes."
        )
    }

    func testAssessRequiresConfirmationWhenAnyTerminalIsBusy() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        guard let busyPanelID = secondWorkspace.allTerminalPanelIDs.first else {
            return XCTFail("expected bootstrap workspace to contain a terminal panel")
        }
        let state = makeAppState(workspaces: [firstWorkspace, secondWorkspace])

        let assessment = AppQuitConfirmation.assess(state: state) { requestedPanelID in
            if requestedPanelID == busyPanelID {
                return TerminalCloseConfirmationAssessment(
                    requiresConfirmation: true,
                    runningCommand: "ssh prod"
                )
            }
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        }

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.terminalsRequiringConfirmationCount, 1)
        XCTAssertEqual(assessment.detectedRunningCommand, "ssh prod")
    }

    func testAssessRequiresConfirmationWhenBusyAndUnavailableTerminalsAreMixed() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let panelIDs = Array(firstWorkspace.allTerminalPanelIDs.union(secondWorkspace.allTerminalPanelIDs))
        guard let busyPanelID = panelIDs.min(by: { $0.uuidString < $1.uuidString }) else {
            return XCTFail("expected bootstrap workspaces to contain terminal panels")
        }
        let state = makeAppState(workspaces: [firstWorkspace, secondWorkspace])

        let assessment = AppQuitConfirmation.assess(state: state) { requestedPanelID in
            if requestedPanelID == busyPanelID {
                return TerminalCloseConfirmationAssessment(
                    requiresConfirmation: true,
                    runningCommand: "make test"
                )
            }
            return nil
        }

        XCTAssertTrue(assessment.requiresConfirmation)
        XCTAssertEqual(assessment.terminalsRequiringConfirmationCount, 1)
        XCTAssertTrue(assessment.hasUnavailableTerminalAssessment)
        XCTAssertEqual(
            assessment.informativeText,
            """
            One or more processes are still running in Toastty. Quitting will terminate them.

            Toastty couldn't assess every terminal in the app.
            """
        )
    }

    private func makeAppState(workspaces: [WorkspaceState]) -> AppState {
        let windowID = UUID()
        let workspaceIDs = workspaces.map(\.id)
        let selectedWorkspaceID = workspaceIDs.first
        return AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: workspaceIDs,
                    selectedWorkspaceID: selectedWorkspaceID
                ),
            ],
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            selectedWindowID: windowID
        )
    }

    private func makeWebOnlyAppState() -> AppState {
        let panelID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Browser",
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [
                panelID: .web(WebPanelState(definition: .browser, initialURL: "https://example.com")),
            ],
            focusedPanelID: panelID
        )
        return makeAppState(workspaces: [workspace])
    }
}
