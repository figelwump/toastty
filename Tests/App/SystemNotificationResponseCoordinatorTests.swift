@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class SystemNotificationResponseCoordinatorTests: XCTestCase {
    func testHandleResponseFlashesPanelForPanelTargetedRoute() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let coordinator = SystemNotificationResponseCoordinator(
            store: store,
            terminalRuntimeRegistry: TerminalRuntimeRegistry()
        )

        coordinator.handleResponse(
            hint: DesktopNotificationSelectionHint(
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspace.id])
        XCTAssertEqual(store.state.selectedWindowID, windowID)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, fixture.rightPanelID)
        XCTAssertEqual(store.pendingPanelFlashRequest?.windowID, windowID)
        XCTAssertEqual(store.pendingPanelFlashRequest?.workspaceID, fixture.workspace.id)
        XCTAssertEqual(store.pendingPanelFlashRequest?.panelID, fixture.rightPanelID)
    }

    func testHandleResponseDoesNotFlashPanelForWorkspaceOnlyRoute() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [firstWorkspace.id, secondWorkspace.id],
                        selectedWorkspaceID: firstWorkspace.id
                    )
                ],
                workspacesByID: [
                    firstWorkspace.id: firstWorkspace,
                    secondWorkspace.id: secondWorkspace,
                ],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let coordinator = SystemNotificationResponseCoordinator(
            store: store,
            terminalRuntimeRegistry: TerminalRuntimeRegistry()
        )

        coordinator.handleResponse(
            hint: DesktopNotificationSelectionHint(
                workspaceID: secondWorkspace.id,
                panelID: nil
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, windowID)
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), secondWorkspace.id)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    private func makeTwoPanelWorkspace(title: String) -> (workspace: WorkspaceState, leftPanelID: UUID, rightPanelID: UUID) {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: title,
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: leftPanelID),
                second: .slot(slotID: UUID(), panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo/left")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo/right")),
            ],
            focusedPanelID: leftPanelID
        )
        return (workspace, leftPanelID, rightPanelID)
    }
}
