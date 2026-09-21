@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerBrowserPanelTargetingTests: AutomationSocketServerWindowTargetingTestCase {
    func testBrowserReloadTargetsUnselectedRightPanelTabWithoutChangingFocus() async throws {
        let fixture = makeTwoWindowFixture()
        var state = fixture.state
        let reducer = AppReducer()
        XCTAssertTrue(reducer.send(.createWebPanel(
            workspaceID: fixture.secondWorkspaceID,
            panel: WebPanelState(definition: .browser, initialURL: "data:text/html,<title>Reloaded</title>"),
            placement: .rightPanel
        ), state: &state))
        let panelID = try XCTUnwrap(state.workspacesByID[fixture.secondWorkspaceID]?.rightAuxPanel.activePanelID)
        XCTAssertTrue(reducer.send(.createWorkspaceTab(workspaceID: fixture.secondWorkspaceID, seed: nil), state: &state))
        let expectedWindows = state.windows
        let expectedWorkspace = try XCTUnwrap(state.workspacesByID[fixture.secondWorkspaceID])
        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(command: "app_control.run_action", payload: [
                "id": "panel.browser.reload", "args": ["panelID": panelID.uuidString],
            ], socketPath: harness.socketPath)
            XCTAssertTrue(response.ok, response.errorMessage ?? "reload failed")
            XCTAssertEqual(response.result["panelID"] as? String, panelID.uuidString)
            XCTAssertEqual(response.result["workspaceID"] as? String, fixture.secondWorkspaceID.uuidString)
            let current = await MainActor.run { harness.store.state }
            XCTAssertEqual(current.windows, expectedWindows)
            XCTAssertEqual(current.workspacesByID[fixture.secondWorkspaceID]?.selectedTabID, expectedWorkspace.selectedTabID)
            XCTAssertEqual(current.workspacesByID[fixture.secondWorkspaceID]?.focusedPanelID, expectedWorkspace.focusedPanelID)
            XCTAssertEqual(current.workspacesByID[fixture.secondWorkspaceID]?.rightAuxPanel, expectedWorkspace.rightAuxPanel)
        }
    }

    func testBrowserReloadRejectsMissingWrongTypeAndUnknownPanel() async throws {
        let fixture = makeSingleWindowFixture()
        let terminalID = try XCTUnwrap(fixture.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)
        try await withAutomationHarness(state: fixture.state) { harness in
            for (args, message) in [
                ([:], "panelID is required"),
                (["panelID": terminalID.uuidString], "panelID is not a browser panel"),
                (["panelID": UUID().uuidString], "panelID does not exist"),
            ] {
                let response = try sendRequest(command: "app_control.run_action", payload: [
                    "id": "panel.browser.reload", "args": args,
                ], socketPath: harness.socketPath)
                XCTAssertFalse(response.ok)
                XCTAssertTrue(response.errorMessage?.contains(message) == true, response.errorMessage ?? "missing error")
            }
        }
    }

    func testBrowserReloadRejectsStartPageAndOutOfScopeCaller() async throws {
        let fixture = makeTwoWindowFixture()
        var state = fixture.state
        let reducer = AppReducer()
        XCTAssertTrue(reducer.send(.createWebPanel(
            workspaceID: fixture.secondWorkspaceID,
            panel: WebPanelState(definition: .browser),
            placement: .rightPanel
        ), state: &state))
        let browserID = try XCTUnwrap(state.workspacesByID[fixture.secondWorkspaceID]?.rightAuxPanel.activePanelID)
        let callerPanelID = try XCTUnwrap(state.workspacesByID[fixture.firstWorkspaceID]?.focusedPanelID)
        try await withAutomationHarness(state: state) { harness in
            let payload: [String: Any] = [
                "id": "panel.browser.reload", "args": ["panelID": browserID.uuidString],
            ]
            let blank = try sendRequest(command: "app_control.run_action", payload: payload, socketPath: harness.socketPath)
            XCTAssertFalse(blank.ok)
            XCTAssertTrue(blank.errorMessage?.contains("no URL to reload") == true)
            await MainActor.run {
                harness.sessionRuntimeStore.startSession(
                    sessionID: "reload-scoped-caller", agent: .codex, panelID: callerPanelID,
                    windowID: fixture.firstWindowID, workspaceID: fixture.firstWorkspaceID,
                    cwd: nil, repoRoot: nil, scopedWorkspaceIDs: [], at: Date()
                )
            }
            let denied = try sendEnvelope([
                "kind": "request", "protocolVersion": "1.0", "requestID": UUID().uuidString,
                "command": "app_control.run_action", "callerSessionID": "reload-scoped-caller",
                "payload": payload,
            ], socketPath: harness.socketPath)
            XCTAssertFalse(denied.ok)
            XCTAssertTrue(denied.errorMessage?.contains("scope") == true, denied.errorMessage ?? "missing scope error")
        }
    }

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
            XCTAssertEqual(response.result["navigationState"] as? String, "loading")
            XCTAssertNotNil(response.result["isLoading"] as? Bool)
            XCTAssertTrue(response.result["navigationError"] is NSNull)
            XCTAssertNotNil(response.result["observedURL"])
            XCTAssertNotNil(response.result["title"])
        }
    }

    func testBrowserPanelStateSerializesInvalidURLErrorWithoutSelectingWorkspace() async throws {
        let fixture = makeTwoWindowFixture()
        var state = fixture.state
        let reducer = AppReducer()
        XCTAssertTrue(reducer.send(
            .createWebPanel(
                workspaceID: fixture.secondWorkspaceID,
                panel: WebPanelState(definition: .browser, initialURL: "http://[invalid"),
                placement: .rightPanel
            ), state: &state
        ))
        let browserPanelID = try XCTUnwrap(state.workspacesByID[fixture.secondWorkspaceID]?.selectedTab?.rightAuxPanel.activePanelID)
        let expectedWindows = state.windows
        try await withAutomationHarness(state: state) { harness in
            for _ in 0..<2 {
                let response = try sendRequest(
                    command: "automation.browser_panel_state",
                    payload: ["panelID": browserPanelID.uuidString],
                    socketPath: harness.socketPath
                )
                XCTAssertTrue(response.ok)
                XCTAssertEqual(response.result["navigationState"] as? String, "failed")
                let error = try XCTUnwrap(response.result["navigationError"] as? [String: Any])
                XCTAssertEqual(error["domain"] as? String, NSURLErrorDomain)
                XCTAssertEqual(error["code"] as? Int, NSURLErrorBadURL)
                XCTAssertFalse(try XCTUnwrap(error["message"] as? String).isEmpty)
                XCTAssertEqual(response.result["hostLifecycleState"] as? String, "detached")
            }
            let windows = await MainActor.run { harness.store.state.windows }
            XCTAssertEqual(windows, expectedWindows)
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
