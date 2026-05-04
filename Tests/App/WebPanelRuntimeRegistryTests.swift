@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class WebPanelRuntimeRegistryTests: XCTestCase {
    func testLiveScratchpadPanelIDsIncludesRightAuxPanelScratchpads() {
        let workspaceID = UUID()
        let windowID = UUID()
        let mainPanelID = UUID()
        let rightPanelID = UUID()
        let rightTabID = UUID()

        let rightAuxPanel = RightAuxPanelState(
            isVisible: true,
            activeTabID: rightTabID,
            tabIDs: [rightTabID],
            tabsByID: [
                rightTabID: RightAuxPanelTabState(
                    id: rightTabID,
                    identity: .scratchpad(id: rightPanelID),
                    panelID: rightPanelID,
                    panelState: .web(
                        WebPanelState(
                            definition: .scratchpad,
                            scratchpad: ScratchpadState(documentID: UUID(), revision: 0)
                        )
                    )
                ),
            ],
            focusedPanelID: rightPanelID
        )
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace",
            layoutTree: .slot(slotID: UUID(), panelID: mainPanelID),
            panels: [
                mainPanelID: .web(
                    WebPanelState(
                        definition: .scratchpad,
                        scratchpad: ScratchpadState(documentID: UUID(), revision: 0)
                    )
                ),
            ],
            focusedPanelID: mainPanelID,
            rightAuxPanel: rightAuxPanel
        )
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1_200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )

        let registry = WebPanelRuntimeRegistry()

        XCTAssertEqual(
            registry.liveScratchpadPanelIDsForTesting(in: state),
            Set([mainPanelID, rightPanelID])
        )
    }
}
