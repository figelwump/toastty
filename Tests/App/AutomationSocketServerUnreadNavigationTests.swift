@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerUnreadNavigationTests: AutomationSocketServerWindowTargetingTestCase {
    func testFocusNextUnreadActionUsesSoleWindowFallbackWhenSingleWindowExists() async throws {
        let fixture = makeSingleWindowUnreadFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.focus-next-unread-or-active",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            let workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            let unreadTab = try XCTUnwrap(workspace.tabsByID[fixture.targetTabID])
            XCTAssertEqual(state.selectedWindowID, fixture.windowID)
            XCTAssertEqual(workspace.resolvedSelectedTabID, fixture.targetTabID)
            XCTAssertEqual(workspace.focusedPanelID, fixture.targetPanelID)
            XCTAssertFalse(unreadTab.unreadPanelIDs.contains(fixture.targetPanelID))
        }
    }

    func testFocusNextUnreadActionPrefersUnreadBeforeActiveFallback() async throws {
        let fixture = makeSingleWindowUnreadAndActiveFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let startedAt = Date(timeIntervalSince1970: 1_700_000_200)
            await MainActor.run {
                harness.sessionRuntimeStore.startSession(
                    sessionID: "sess-working-priority",
                    agent: .codex,
                    panelID: fixture.activePanelID,
                    windowID: fixture.windowID,
                    workspaceID: fixture.workspaceID,
                    cwd: "/repo",
                    repoRoot: "/repo",
                    at: startedAt
                )
                harness.sessionRuntimeStore.updateStatus(
                    sessionID: "sess-working-priority",
                    status: SessionStatus(kind: .working, summary: "Working", detail: "Earlier active target"),
                    at: startedAt.addingTimeInterval(1)
                )
            }

            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.focus-next-unread-or-active",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            let workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            let unreadTab = try XCTUnwrap(workspace.tabsByID[fixture.targetTabID])
            XCTAssertEqual(state.selectedWindowID, fixture.windowID)
            XCTAssertEqual(workspace.resolvedSelectedTabID, fixture.targetTabID)
            XCTAssertEqual(workspace.focusedPanelID, fixture.targetPanelID)
            XCTAssertFalse(unreadTab.unreadPanelIDs.contains(fixture.targetPanelID))
        }
    }

    func testFocusNextUnreadActionFallsBackToActivePanelWhenNoUnreadExists() async throws {
        let fixture = makeSingleWindowActiveFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let startedAt = Date(timeIntervalSince1970: 1_700_000_220)
            await MainActor.run {
                harness.sessionRuntimeStore.startSession(
                    sessionID: "sess-active-fallback",
                    agent: .codex,
                    panelID: fixture.targetPanelID,
                    windowID: fixture.windowID,
                    workspaceID: fixture.workspaceID,
                    cwd: "/repo",
                    repoRoot: "/repo",
                    at: startedAt
                )
                harness.sessionRuntimeStore.updateStatus(
                    sessionID: "sess-active-fallback",
                    status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Review command"),
                    at: startedAt.addingTimeInterval(1)
                )
            }

            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.focus-next-unread-or-active",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            let workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            XCTAssertEqual(state.selectedWindowID, fixture.windowID)
            XCTAssertEqual(workspace.resolvedSelectedTabID, fixture.targetTabID)
            XCTAssertEqual(workspace.focusedPanelID, fixture.targetPanelID)
        }
    }

    func testRemovedFocusNextUnreadActionIsRejected() async throws {
        let fixture = makeSingleWindowUnreadFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.focus-next-unread",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "unsupported action: workspace.focus-next-unread")
        }
    }

    func testFocusNextUnreadActionRequiresExplicitWindowWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowUnreadFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.focus-next-unread-or-active",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "windowID is required when multiple windows exist")

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
        }
    }

    func testFocusNextUnreadActionUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowUnreadFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.focus-next-unread-or-active",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            let workspace = try XCTUnwrap(state.workspacesByID[fixture.secondWorkspaceID])
            let unreadTab = try XCTUnwrap(workspace.tabsByID[fixture.targetTabID])
            XCTAssertEqual(state.selectedWindowID, fixture.secondWindowID)
            XCTAssertEqual(workspace.resolvedSelectedTabID, fixture.targetTabID)
            XCTAssertEqual(workspace.focusedPanelID, fixture.targetPanelID)
            XCTAssertFalse(unreadTab.unreadPanelIDs.contains(fixture.targetPanelID))
        }
    }

}
