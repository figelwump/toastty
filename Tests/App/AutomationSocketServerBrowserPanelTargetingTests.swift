@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerBrowserPanelTargetingTests: AutomationSocketServerWindowTargetingTestCase {
    func testBrowserPanelStateReportsPersistedAndRuntimeZoom() async throws {
        let fixture = makeSingleWindowFixture()
        var state = fixture.state
        let reducer = AppReducer()

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: fixture.workspaceID,
                    panel: WebPanelState(
                        definition: .browser,
                        title: "Docs",
                        initialURL: "https://example.com/docs",
                        browserPageZoom: 1.25
                    ),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let browserPanelID = try XCTUnwrap(state.workspacesByID[fixture.workspaceID]?.focusedPanelID)

        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(
                command: "automation.browser_panel_state",
                payload: [
                    "panelID": browserPanelID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["workspaceID"] as? String, fixture.workspaceID.uuidString)
            XCTAssertEqual(response.result["panelID"] as? String, browserPanelID.uuidString)
            XCTAssertEqual(response.result["stateTitle"] as? String, "Docs")
            XCTAssertEqual(response.result["stateRestorableURL"] as? String, "https://example.com/docs")
            XCTAssertEqual(response.result["statePageZoom"] as? Double, 1.25)
            XCTAssertEqual(response.result["statePageZoomOverride"] as? Double, 1.25)
            XCTAssertEqual(response.result["runtimePageZoom"] as? Double, 1.25)
            XCTAssertEqual(response.result["hostLifecycleState"] as? String, "detached")
        }
    }

    func testBrowserZoomActionUsesExplicitPanelSelection() async throws {
        let fixture = makeTwoWindowFixture()
        var state = fixture.state
        let reducer = AppReducer()

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: fixture.firstWorkspaceID,
                    panel: WebPanelState(definition: .browser, initialURL: "https://example.com/one"),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let firstBrowserPanelID = try XCTUnwrap(state.workspacesByID[fixture.firstWorkspaceID]?.focusedPanelID)

        XCTAssertTrue(
            reducer.send(
                .createWebPanel(
                    workspaceID: fixture.secondWorkspaceID,
                    panel: WebPanelState(definition: .browser, initialURL: "https://example.com/two"),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let secondBrowserPanelID = try XCTUnwrap(state.workspacesByID[fixture.secondWorkspaceID]?.focusedPanelID)

        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "app.browser_zoom.increase",
                    "args": [
                        "panelID": secondBrowserPanelID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            guard case .web(let firstWebState) = state.workspacesByID[fixture.firstWorkspaceID]?.panels[firstBrowserPanelID],
                  case .web(let secondWebState) = state.workspacesByID[fixture.secondWorkspaceID]?.panels[secondBrowserPanelID] else {
                XCTFail("expected browser panels in both windows")
                return
            }
            XCTAssertEqual(firstWebState.effectiveBrowserPageZoom, WebPanelState.defaultBrowserPageZoom)
            XCTAssertEqual(secondWebState.effectiveBrowserPageZoom, 1.1, accuracy: 0.0001)
        }
    }

}
