@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreUnreadNavigationFocusModeTests: AppStoreCommandTestCase {
    func testFocusNextUnreadOrActiveRetargetsDestinationFocusRootWhenNeeded() throws {
        let sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        var destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let destinationVisibleRootNodeID = try lowestCommonAncestorNodeID(
            in: destinationTab.tab,
            containing: [destinationTab.panelIDs[0], destinationTab.panelIDs[1]]
        )
        destinationTab.tab.focusedPanelModeActive = true
        destinationTab.tab.focusModeRootNodeID = destinationVisibleRootNodeID
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[destinationWorkspace.id])
        let targetPanelID = destinationTab.panelIDs[2]
        let updatedSelectedTab = try XCTUnwrap(updatedWorkspace.selectedTab)
        let targetSlotID = try slotID(in: updatedSelectedTab, for: targetPanelID)
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, targetPanelID)
        XCTAssertTrue(updatedWorkspace.focusedPanelModeActive)
        XCTAssertEqual(updatedWorkspace.focusModeRootNodeID, targetSlotID)
    }

    func testFocusNextUnreadOrActivePreservesDestinationRootWhenTargetAlreadyVisible() throws {
        let sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        var destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let destinationVisibleRootNodeID = try lowestCommonAncestorNodeID(
            in: destinationTab.tab,
            containing: [destinationTab.panelIDs[0], destinationTab.panelIDs[1]]
        )
        destinationTab.tab.focusedPanelModeActive = true
        destinationTab.tab.focusModeRootNodeID = destinationVisibleRootNodeID
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[destinationWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, destinationTab.panelIDs[1])
        XCTAssertTrue(updatedWorkspace.focusedPanelModeActive)
        XCTAssertEqual(updatedWorkspace.focusModeRootNodeID, destinationVisibleRootNodeID)
    }

    func testFocusNextUnreadOrActiveDoesNotAutoEnterFocusModeOnNormalDestinationTab() throws {
        let sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        let destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[destinationWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, destinationTab.panelIDs[1])
        XCTAssertFalse(updatedWorkspace.focusedPanelModeActive)
        XCTAssertNil(updatedWorkspace.focusModeRootNodeID)
    }

    func testFocusNextUnreadOrActivePreservesSourceTabFocusRoot() throws {
        var sourceTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let sourceRootNodeID = try lowestCommonAncestorNodeID(
            in: sourceTab.tab,
            containing: [sourceTab.panelIDs[0], sourceTab.panelIDs[1]]
        )
        sourceTab.tab.focusedPanelModeActive = true
        sourceTab.tab.focusModeRootNodeID = sourceRootNodeID
        let sourceWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [sourceTab],
            selectedTabIndex: 0
        )

        let destinationTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let destinationWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [destinationTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [sourceWorkspace.id, destinationWorkspace.id],
                    selectedWorkspaceID: sourceWorkspace.id
                )
            ],
            workspacesByID: [
                sourceWorkspace.id: sourceWorkspace,
                destinationWorkspace.id: destinationWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let updatedSourceWorkspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspace.id])
        XCTAssertTrue(updatedSourceWorkspace.focusedPanelModeActive)
        XCTAssertEqual(updatedSourceWorkspace.focusModeRootNodeID, sourceRootNodeID)
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), destinationWorkspace.id)
    }

}
