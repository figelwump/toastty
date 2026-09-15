@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerTerminalTargetingTests: AutomationSocketServerWindowTargetingTestCase {
    func testTerminalStateIncludesProfileIDWhenTerminalIsProfileBound() async throws {
        let fixture = makeSingleWindowFixture()
        var state = fixture.state
        guard let panelID = state.workspacesByID[fixture.workspaceID]?.focusedPanelID,
              case .terminal(var terminalState)? = state.workspacesByID[fixture.workspaceID]?.panels[panelID] else {
            XCTFail("expected bootstrap fixture to include a focused terminal")
            return
        }
        terminalState.profileBinding = TerminalProfileBinding(profileID: "smoke-profile")
        state.workspacesByID[fixture.workspaceID]?.panels[panelID] = .terminal(terminalState)

        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(
                command: "automation.terminal_state",
                payload: [
                    "panelID": panelID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["windowID"] as? String, fixture.windowID.uuidString)
            XCTAssertEqual(response.result["workspaceID"] as? String, fixture.workspaceID.uuidString)
            XCTAssertEqual(response.result["panelID"] as? String, panelID.uuidString)
            XCTAssertEqual(response.result["profileID"] as? String, "smoke-profile")
        }
    }

    func testTerminalStateIncludesWindowIDWhenResolvedByWorkspaceID() async throws {
        let fixture = makeSingleWindowFixture()
        let expectedPanelID = try XCTUnwrap(fixture.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.terminal_state",
                payload: [
                    "workspaceID": fixture.workspaceID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["windowID"] as? String, fixture.windowID.uuidString)
            XCTAssertEqual(response.result["workspaceID"] as? String, fixture.workspaceID.uuidString)
            XCTAssertEqual(response.result["panelID"] as? String, expectedPanelID.uuidString)
        }
    }

    func testTerminalStateUsesLiveTitleWhenAvailable() async throws {
        let fixture = makeSingleWindowFixture()
        let panelID = try XCTUnwrap(fixture.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)

        try await withAutomationHarness(state: fixture.state) { harness in
            await MainActor.run {
                harness.terminalRuntimeRegistry.terminalLiveTitleStore.setTitle(
                    "Live Build",
                    for: panelID
                )
            }
            let response = try sendRequest(
                command: "automation.terminal_state",
                payload: [
                    "panelID": panelID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["title"] as? String, "Live Build")
            let state = await MainActor.run { harness.store.state }
            guard case .terminal(let terminalState)? = state.workspacesByID[fixture.workspaceID]?.panels[panelID] else {
                XCTFail("expected terminal panel")
                return
            }
            XCTAssertEqual(terminalState.title, "Terminal 1")
        }
    }

    func testTerminalStateTargetsBackgroundTabPanelByPanelID() async throws {
        var backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        guard let panelID = backgroundTab.focusedPanelID,
              case .terminal(var terminalState)? = backgroundTab.panels[panelID] else {
            XCTFail("expected bootstrap tab to include a focused terminal")
            return
        }
        terminalState.profileBinding = TerminalProfileBinding(profileID: "background-profile")
        backgroundTab.panels[panelID] = .terminal(terminalState)

        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )

        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(
                command: "automation.terminal_state",
                payload: [
                    "panelID": panelID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["windowID"] as? String, windowID.uuidString)
            XCTAssertEqual(response.result["workspaceID"] as? String, workspaceID.uuidString)
            XCTAssertEqual(response.result["panelID"] as? String, panelID.uuidString)
            XCTAssertEqual(response.result["title"] as? String, "Background Agent")
            XCTAssertEqual(response.result["profileID"] as? String, "background-profile")
        }
    }

    func testTerminalSendTextChecksExpectedSessionInUnselectedTabWithoutChangingSelection() async throws {
        var backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let backgroundPanelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [backgroundTab.id: backgroundTab, selectedTab.id: selectedTab]
        )
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID
        )

        try await withAutomationHarness(state: state) { harness in
            let sessionID = "background-session"
            await MainActor.run {
                harness.sessionRuntimeStore.startSession(
                    sessionID: sessionID,
                    agent: .codex,
                    panelID: backgroundPanelID,
                    windowID: windowID,
                    workspaceID: workspaceID,
                    cwd: "/tmp/repo",
                    repoRoot: "/tmp/repo",
                    at: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
            let capturedDelivery = await MainActor.run { CapturedTerminalDelivery() }
            await MainActor.run {
                harness.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting {
                    text, submit, panelID, focusPolicy in
                    MainActor.assumeIsolated {
                        capturedDelivery.record(
                            text: text,
                            submit: submit,
                            panelID: panelID,
                            focusPolicy: focusPolicy
                        )
                    }
                    return true
                }
            }

            let response = try sendRequest(
                command: "automation.terminal_send_text",
                payload: [
                    "panelID": backgroundPanelID.uuidString,
                    "text": "background command",
                    "submit": true,
                    "expectedSessionID": sessionID,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            let delivery = await MainActor.run { capturedDelivery.snapshot() }
            XCTAssertEqual(delivery.text, "background command")
            XCTAssertTrue(delivery.submit)
            XCTAssertEqual(delivery.panelID, backgroundPanelID)
            XCTAssertEqual(delivery.focusPolicy, .preserveFirstResponder)
            let finalState = await MainActor.run { harness.store.state }
            XCTAssertEqual(finalState.workspacesByID[workspaceID]?.selectedTabID, selectedTab.id)
            XCTAssertEqual(finalState.workspacesByID[workspaceID]?.focusedPanelID, selectedPanelID)
        }
    }

    func testTerminalSendTextRejectsStoppedExpectedSessionBeforeSocketDelivery() async throws {
        let fixture = makeSingleWindowFixture()
        let panelID = try XCTUnwrap(fixture.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)

        try await withAutomationHarness(state: fixture.state) { harness in
            let sessionID = "stopped-session"
            await MainActor.run {
                harness.sessionRuntimeStore.startSession(
                    sessionID: sessionID,
                    agent: .codex,
                    panelID: panelID,
                    windowID: fixture.windowID,
                    workspaceID: fixture.workspaceID,
                    cwd: "/tmp/repo",
                    repoRoot: "/tmp/repo",
                    at: Date(timeIntervalSince1970: 1_700_000_000)
                )
                harness.sessionRuntimeStore.stopSession(
                    sessionID: sessionID,
                    at: Date(timeIntervalSince1970: 1_700_000_001)
                )
            }
            let deliveryProbe = await MainActor.run { DeliveryCountProbe() }
            await MainActor.run {
                harness.terminalRuntimeRegistry.setAutomationSendTextHandlerForTesting { _, _, _, _ in
                    MainActor.assumeIsolated { deliveryProbe.increment() }
                    return true
                }
            }

            let response = try sendRequest(
                command: "automation.terminal_send_text",
                payload: [
                    "panelID": panelID.uuidString,
                    "text": "must not send",
                    "submit": true,
                    "expectedSessionID": sessionID,
                    "allowUnavailable": true,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "expectedSessionID does not match the active managed session for panelID \(panelID.uuidString)")
            let deliveryCount = await MainActor.run { deliveryProbe.value }
            XCTAssertEqual(deliveryCount, 0)
        }
    }

    func testTerminalStateReturnsOwningWindowForPanelInAnotherWindow() async throws {
        let firstFixture = makeSingleWindowFixture()
        var secondTab = WorkspaceTabState.bootstrap(terminalTitle: "Second Window Terminal")
        guard let secondPanelID = secondTab.focusedPanelID else {
            XCTFail("expected second window fixture to include a focused terminal")
            return
        }

        let secondWorkspaceID = UUID()
        let secondWindowID = UUID()
        let secondWorkspace = WorkspaceState(
            id: secondWorkspaceID,
            title: "Second",
            selectedTabID: secondTab.id,
            tabIDs: [secondTab.id],
            tabsByID: [secondTab.id: secondTab]
        )
        let state = AppState(
            windows: [
                WindowState(
                    id: firstFixture.windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstFixture.workspaceID],
                    selectedWorkspaceID: firstFixture.workspaceID
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 820, y: 0, width: 800, height: 600),
                    workspaceIDs: [secondWorkspaceID],
                    selectedWorkspaceID: secondWorkspaceID
                ),
            ],
            workspacesByID: [
                firstFixture.workspaceID: try XCTUnwrap(firstFixture.state.workspacesByID[firstFixture.workspaceID]),
                secondWorkspaceID: secondWorkspace,
            ],
            selectedWindowID: firstFixture.windowID
        )

        try await withAutomationHarness(state: state) { harness in
            let response = try sendRequest(
                command: "automation.terminal_state",
                payload: [
                    "panelID": secondPanelID.uuidString,
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.result["windowID"] as? String, secondWindowID.uuidString)
            XCTAssertEqual(response.result["workspaceID"] as? String, secondWorkspaceID.uuidString)
            XCTAssertEqual(response.result["panelID"] as? String, secondPanelID.uuidString)
            XCTAssertEqual(response.result["title"] as? String, "Second Window Terminal")
        }
    }

}

@MainActor
private final class CapturedTerminalDelivery {
    struct Value: Sendable {
        let text: String?
        let submit: Bool
        let panelID: UUID?
        let focusPolicy: TerminalInputFocusPolicy?
    }

    private var value = Value(text: nil, submit: false, panelID: nil, focusPolicy: nil)

    func record(
        text: String,
        submit: Bool,
        panelID: UUID,
        focusPolicy: TerminalInputFocusPolicy
    ) {
        value = Value(text: text, submit: submit, panelID: panelID, focusPolicy: focusPolicy)
    }

    func snapshot() -> Value {
        return value
    }
}

@MainActor
private final class DeliveryCountProbe {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int {
        return count
    }
}
