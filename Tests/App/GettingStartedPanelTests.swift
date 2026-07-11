@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class GettingStartedPanelTests: XCTestCase {
    func testOpenGettingStartedPanelCreatesThenFocusesExistingRightPanelTab() throws {
        let initialState = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(initialState.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: initialState, persistTerminalFontPreference: false)

        XCTAssertTrue(store.openGettingStartedPanel(workspaceID: workspaceID, anchor: "codex-hooks"))

        let createdWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let gettingStartedTab = try XCTUnwrap(createdWorkspace.rightAuxPanel.activeTab)
        guard case .web(let createdPanel) = gettingStartedTab.panelState else {
            return XCTFail("Expected a browser-backed Getting Started tab")
        }
        XCTAssertEqual(createdPanel.initialURL, "toastty://getting-started/#codex-hooks")

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com")
            )
        )
        XCTAssertTrue(store.openGettingStartedPanel(workspaceID: workspaceID))

        let focusedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let matchingTabs = focusedWorkspace.rightAuxPanel.orderedTabs.filter { tab in
            guard case .web(let webPanel) = tab.panelState else { return false }
            return webPanel.initialURL?.hasPrefix("toastty://getting-started/") == true
        }
        XCTAssertEqual(matchingTabs.map(\.id), [gettingStartedTab.id])
        XCTAssertEqual(focusedWorkspace.rightAuxPanel.activeTabID, gettingStartedTab.id)
        XCTAssertEqual(focusedWorkspace.rightAuxPanel.focusedPanelID, gettingStartedTab.panelID)
        XCTAssertTrue(focusedWorkspace.rightAuxPanel.isVisible)
    }

    func testOpenGettingStartedPanelRecognizesCurrentToasttyURLWhenAlreadyActiveAndFocused() throws {
        let initialState = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(initialState.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: initialState, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com")
            )
        )
        let browserPanelID = try XCTUnwrap(
            store.state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID
        )
        XCTAssertTrue(
            store.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: nil,
                    url: "toastty://getting-started/#shortcuts"
                )
            )
        )

        let activeWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(activeWorkspace.rightAuxPanel.activePanelID, browserPanelID)
        XCTAssertEqual(activeWorkspace.rightAuxPanel.focusedPanelID, browserPanelID)
        XCTAssertTrue(activeWorkspace.rightAuxPanel.isVisible)

        XCTAssertTrue(store.openGettingStartedPanel(workspaceID: workspaceID))

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
        XCTAssertEqual(workspace.rightAuxPanel.activePanelID, browserPanelID)
    }
}
