@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerWorkspaceTabTests: AutomationSocketServerWindowTargetingTestCase {
    func testWorkspaceActionUsesSoleWindowFallbackWhenSingleWindowExists() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.windowID)
            XCTAssertEqual(state.workspacesByID[fixture.workspaceID]?.panels.count, 2)
        }
    }

    func testWorkspaceSnapshotIncludesTabMetadata() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.new",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let snapshotResponse = try sendRequest(
                command: "automation.workspace_snapshot",
                payload: [:],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(snapshotResponse.ok)
            XCTAssertEqual(snapshotResponse.result["tabCount"] as? Int, 2)
            XCTAssertEqual(snapshotResponse.result["selectedTabIndex"] as? Int, 2)
            let tabIDs = try XCTUnwrap(snapshotResponse.result["tabIDs"] as? [String])
            XCTAssertEqual(tabIDs.count, 2)
            XCTAssertEqual(snapshotResponse.result["selectedTabID"] as? String, tabIDs[1])
        }
    }

    func testRightPanelBrowserActionPreservesMainLayoutFocusAndFocusesRightPanel() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let initialWorkspace = try await MainActor.run {
                try XCTUnwrap(harness.store.state.workspacesByID[fixture.workspaceID])
            }
            let initialFocusedPanelID = initialWorkspace.focusedPanelID
            let initialLayoutTree = initialWorkspace.layoutTree

            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.create.browser",
                    "args": [
                        "placement": "rightPanel",
                        "url": "https://example.com/docs",
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let workspace = try await MainActor.run {
                try XCTUnwrap(harness.store.state.workspacesByID[fixture.workspaceID])
            }
            XCTAssertEqual(workspace.layoutTree, initialLayoutTree)
            XCTAssertEqual(workspace.focusedPanelID, initialFocusedPanelID)
            let focusedRightPanelID = try XCTUnwrap(workspace.rightAuxPanel.focusedPanelID)
            XCTAssertEqual(focusedRightPanelID, workspace.rightAuxPanel.activePanelID)
            XCTAssertTrue(workspace.rightAuxPanel.isVisible)
            XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
            XCTAssertEqual(workspace.panels.count, 1)

            let snapshotResponse = try sendRequest(
                command: "automation.workspace_snapshot",
                payload: [:],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(snapshotResponse.ok)
            XCTAssertEqual(snapshotResponse.result["layoutPanelCount"] as? Int, 1)
            XCTAssertEqual(snapshotResponse.result["panelCount"] as? Int, 2)

            let rightPanel = try XCTUnwrap(snapshotResponse.result["rightPanel"] as? [String: Any])
            XCTAssertEqual(rightPanel["isVisible"] as? Bool, true)
            XCTAssertEqual(rightPanel["hasCustomWidth"] as? Bool, false)
            XCTAssertEqual(rightPanel["tabCount"] as? Int, 1)
            XCTAssertEqual((rightPanel["panelIDs"] as? [String])?.count, 1)
            XCTAssertEqual((rightPanel["tabIDs"] as? [String])?.count, 1)
            XCTAssertEqual(rightPanel["focusedPanelID"] as? String, focusedRightPanelID.uuidString)
        }
    }

    func testWorkspaceCreateCanCreateBackgroundWorkspaceAndReturnCreatedWorkspaceID() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "app_control.run_action",
                payload: [
                    "id": "workspace.create",
                    "args": [
                        "windowID": fixture.windowID.uuidString,
                        "title": "Background",
                        "activate": false,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["windowID"] as? String, fixture.windowID.uuidString)
            let workspaceIDString = try XCTUnwrap(response.result["workspaceID"] as? String)
            let createdWorkspaceID = try XCTUnwrap(UUID(uuidString: workspaceIDString))
            XCTAssertNotEqual(createdWorkspaceID, fixture.workspaceID)

            let state = await MainActor.run { harness.store.state }
            let window = try XCTUnwrap(state.window(id: fixture.windowID))
            XCTAssertEqual(window.selectedWorkspaceID, fixture.workspaceID)
            XCTAssertEqual(window.workspaceIDs.last, createdWorkspaceID)
            XCTAssertFalse(try XCTUnwrap(state.workspacesByID[createdWorkspaceID]).hasBeenVisited)
        }
    }

    func testWorkspaceTabActionsCreateSelectAndCloseTabsByIndex() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let firstCreateResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.new",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(firstCreateResponse.ok)

            let secondCreateResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.new",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(secondCreateResponse.ok)

            let selectResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.select",
                    "args": [
                        "index": 1,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(selectResponse.ok)

            var state = await MainActor.run { harness.store.state }
            let workspaceAfterSelect = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            XCTAssertEqual(workspaceAfterSelect.tabIDs.count, 3)
            XCTAssertEqual(workspaceAfterSelect.resolvedSelectedTabID, workspaceAfterSelect.tabIDs[0])

            let closeResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.close",
                    "args": [
                        "index": 3,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(closeResponse.ok)

            state = await MainActor.run { harness.store.state }
            let workspaceAfterClose = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            XCTAssertEqual(workspaceAfterClose.tabIDs.count, 2)
            XCTAssertEqual(workspaceAfterClose.resolvedSelectedTabID, workspaceAfterClose.tabIDs[0])
        }
    }

    func testWorkspaceTabActionsSupportTabIDTargetingAndSelectedTabCloseFallback() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            for _ in 0 ..< 2 {
                let createResponse = try sendRequest(
                    command: "automation.perform_action",
                    payload: [
                        "action": "workspace.tab.new",
                        "args": [:],
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(createResponse.ok)
            }

            let initialSnapshotResponse = try sendRequest(
                command: "automation.workspace_snapshot",
                payload: [:],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(initialSnapshotResponse.ok)
            let initialTabIDs = try XCTUnwrap(initialSnapshotResponse.result["tabIDs"] as? [String])
            XCTAssertEqual(initialTabIDs.count, 3)

            let selectByTabIDResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.select",
                    "args": [
                        "tabID": initialTabIDs[0],
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(selectByTabIDResponse.ok)

            var state = await MainActor.run { harness.store.state }
            var workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            XCTAssertEqual(workspace.resolvedSelectedTabID?.uuidString, initialTabIDs[0])

            let closeByTabIDResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.close",
                    "args": [
                        "tabID": initialTabIDs[2],
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(closeByTabIDResponse.ok)

            state = await MainActor.run { harness.store.state }
            workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            XCTAssertEqual(workspace.tabIDs.count, 2)
            XCTAssertEqual(workspace.resolvedSelectedTabID?.uuidString, initialTabIDs[0])
            XCTAssertFalse(workspace.tabIDs.map(\.uuidString).contains(initialTabIDs[2]))

            let closeSelectedTabResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.select",
                    "args": [
                        "tabID": initialTabIDs[1],
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(closeSelectedTabResponse.ok)

            let closeFallbackResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.close",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(closeFallbackResponse.ok)

            state = await MainActor.run { harness.store.state }
            workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            XCTAssertEqual(workspace.tabIDs.count, 1)
            XCTAssertEqual(workspace.resolvedSelectedTabID?.uuidString, initialTabIDs[0])
            XCTAssertEqual(workspace.tabIDs.map(\.uuidString), [initialTabIDs[0]])
        }
    }

    func testWorkspaceTabMoveReordersTabIDsAndKeepsSelectedTabID() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            for _ in 0 ..< 2 {
                let createResponse = try sendRequest(
                    command: "automation.perform_action",
                    payload: [
                        "action": "workspace.tab.new",
                        "args": [:],
                    ],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(createResponse.ok)
            }

            let selectResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.select",
                    "args": [
                        "index": 2,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(selectResponse.ok)

            let initialSnapshot = try sendRequest(
                command: "automation.workspace_snapshot",
                payload: [:],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(initialSnapshot.ok)
            let initialTabIDs = try XCTUnwrap(initialSnapshot.result["tabIDs"] as? [String])
            XCTAssertEqual(initialSnapshot.result["selectedTabID"] as? String, initialTabIDs[1])

            let moveResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.move",
                    "args": [
                        "index": 2,
                        "toIndex": 3,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(moveResponse.ok)

            let snapshot = try sendRequest(
                command: "automation.workspace_snapshot",
                payload: [:],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(snapshot.ok)
            XCTAssertEqual(snapshot.result["tabIDs"] as? [String], [initialTabIDs[0], initialTabIDs[2], initialTabIDs[1]])
            XCTAssertEqual(snapshot.result["selectedTabID"] as? String, initialTabIDs[1])
            XCTAssertEqual(snapshot.result["selectedTabIndex"] as? Int, 3)
        }
    }

    func testWorkspaceTabMoveRejectsInvalidIndices() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.new",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let zeroIndexResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.move",
                    "args": [
                        "index": 0,
                        "toIndex": 1,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertFalse(zeroIndexResponse.ok)
            XCTAssertEqual(zeroIndexResponse.errorMessage, "index must be greater than zero")

            let outOfBoundsResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.tab.move",
                    "args": [
                        "index": 1,
                        "toIndex": 3,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertFalse(outOfBoundsResponse.ok)
            XCTAssertEqual(outOfBoundsResponse.errorMessage, "toIndex does not exist")
        }
    }

    func testWorkspaceMoveReordersWindowWorkspaceIDsAndKeepsSelectedWorkspaceID() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let firstCreateResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.create",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(firstCreateResponse.ok)

            let secondCreateResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.create",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(secondCreateResponse.ok)

            let selectResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.select",
                    "args": [
                        "index": 2,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(selectResponse.ok)

            let stateBeforeMove = await MainActor.run { harness.store.state }
            let windowBeforeMove = try XCTUnwrap(stateBeforeMove.window(id: fixture.windowID))
            let originalWorkspaceIDs = windowBeforeMove.workspaceIDs
            XCTAssertEqual(windowBeforeMove.selectedWorkspaceID, originalWorkspaceIDs[1])

            let moveResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.move",
                    "args": [
                        "index": 2,
                        "toIndex": 1,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(moveResponse.ok)

            let stateAfterMove = await MainActor.run { harness.store.state }
            let windowAfterMove = try XCTUnwrap(stateAfterMove.window(id: fixture.windowID))
            XCTAssertEqual(windowAfterMove.workspaceIDs, [originalWorkspaceIDs[1], originalWorkspaceIDs[0], originalWorkspaceIDs[2]])
            XCTAssertEqual(windowAfterMove.selectedWorkspaceID, originalWorkspaceIDs[1])
        }
    }

    func testWorkspaceMoveRejectsInvalidIndices() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.create",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let zeroIndexResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.move",
                    "args": [
                        "index": 0,
                        "toIndex": 1,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertFalse(zeroIndexResponse.ok)
            XCTAssertEqual(zeroIndexResponse.errorMessage, "index must be greater than zero")

            let outOfBoundsResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.move",
                    "args": [
                        "index": 1,
                        "toIndex": 3,
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertFalse(outOfBoundsResponse.ok)
            XCTAssertEqual(outOfBoundsResponse.errorMessage, "toIndex does not exist")
        }
    }

    func testReopenLastClosedPanelRestoresClosedBrowserTabAsTab() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let createResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "panel.create.browser",
                    "args": [
                        "placement": "newTab",
                        "url": "https://example.com/docs",
                    ],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(createResponse.ok)

            let initialWorkspace = await MainActor.run {
                harness.store.state.workspacesByID[fixture.workspaceID]
            }
            var workspace = try XCTUnwrap(initialWorkspace)
            let browserTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
            let browserPanelID = try XCTUnwrap(workspace.focusedPanelID)
            XCTAssertEqual(workspace.tabIDs.count, 2)

            let closeResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.close-focused-panel",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(closeResponse.ok)

            let closedWorkspace = await MainActor.run {
                harness.store.state.workspacesByID[fixture.workspaceID]
            }
            workspace = try XCTUnwrap(closedWorkspace)
            XCTAssertEqual(workspace.tabIDs.count, 1)
            XCTAssertEqual(workspace.recentlyClosedPanels.count, 1)

            let reopenResponse = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.reopen-last-closed-panel",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )
            XCTAssertTrue(reopenResponse.ok)

            let reopenedWorkspace = await MainActor.run {
                harness.store.state.workspacesByID[fixture.workspaceID]
            }
            workspace = try XCTUnwrap(reopenedWorkspace)
            XCTAssertEqual(workspace.tabIDs.count, 2)
            XCTAssertEqual(workspace.resolvedSelectedTabID, browserTabID)
            XCTAssertTrue(workspace.recentlyClosedPanels.isEmpty)

            let reopenedTab = try XCTUnwrap(workspace.tab(id: browserTabID))
            XCTAssertEqual(reopenedTab.panels.count, 1)
            XCTAssertNotEqual(reopenedTab.focusedPanelID, browserPanelID)
            let reopenedPanelID = try XCTUnwrap(reopenedTab.focusedPanelID)
            guard case .web(let webState) = reopenedTab.panels[reopenedPanelID] else {
                XCTFail("expected reopened tab to contain a web panel")
                return
            }
            XCTAssertEqual(webState.definition, .browser)
            XCTAssertEqual(webState.initialURL, "https://example.com/docs")
        }
    }

}
