@testable import ToasttyApp
import CoreState
import CryptoKit
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerWindowTargetingTests: AutomationSocketServerWindowTargetingTestCase {
    func testWorkspaceActionRequiresExplicitTargetWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(
                response.errorMessage,
                "workspaceID or windowID is required when multiple windows exist"
            )

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 1)
        }
    }

    func testWorkspaceActionUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 2)
        }
    }

    func testWorkspaceActionUsesExplicitWorkspaceSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [
                        "workspaceID": fixture.secondWorkspaceID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 2)
        }
    }

    func testWorkspaceProfileSplitBindsTheNewFocusedTerminalPanel() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right.with-profile",
                    "args": [
                        "profileID": "smoke-profile",
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            let workspace = try XCTUnwrap(state.workspacesByID[fixture.workspaceID])
            let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
            XCTAssertEqual(workspace.panels.count, 2)
            guard case .terminal(let terminalState) = workspace.panels[focusedPanelID] else {
                XCTFail("expected focused panel to remain terminal")
                return
            }
            XCTAssertEqual(terminalState.profileBinding?.profileID, "smoke-profile")
        }
    }

    func testWorkspaceProfileSplitRequiresProfileID() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right.with-profile",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "profileID is required")

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.workspacesByID[fixture.workspaceID]?.panels.count, 1)
        }
    }

    func testWorkspaceActionRejectsMismatchedWindowAndWorkspace() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "workspace.split.right",
                    "args": [
                        "windowID": fixture.firstWindowID.uuidString,
                        "workspaceID": fixture.secondWorkspaceID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "workspaceID does not belong to windowID")

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.workspacesByID[fixture.firstWorkspaceID]?.panels.count, 1)
            XCTAssertEqual(state.workspacesByID[fixture.secondWorkspaceID]?.panels.count, 1)
        }
    }

    func testCreateWorkspaceUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "sidebar.workspaces.new",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                        "title": "Detached",
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)

            let firstWindow = try XCTUnwrap(state.window(id: fixture.firstWindowID))
            let secondWindow = try XCTUnwrap(state.window(id: fixture.secondWindowID))
            XCTAssertEqual(firstWindow.workspaceIDs.count, 1)
            XCTAssertEqual(secondWindow.workspaceIDs.count, 2)
            XCTAssertNotEqual(secondWindow.selectedWorkspaceID, fixture.secondWorkspaceID)

            let createdWorkspaceID = try XCTUnwrap(secondWindow.selectedWorkspaceID)
            XCTAssertEqual(state.workspacesByID[createdWorkspaceID]?.title, "Detached")
        }
    }

    func testCreateWorkspaceRequiresExplicitWindowWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "sidebar.workspaces.new",
                    "args": [
                        "title": "Detached",
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "windowID is required when multiple windows exist")

            let state = await MainActor.run { harness.store.state }
            let firstWindow = try XCTUnwrap(state.window(id: fixture.firstWindowID))
            let secondWindow = try XCTUnwrap(state.window(id: fixture.secondWindowID))
            XCTAssertEqual(firstWindow.workspaceIDs.count, 1)
            XCTAssertEqual(secondWindow.workspaceIDs.count, 1)
        }
    }

    func testAppFontActionUsesSoleWindowFallbackWhenSingleWindowExists() async throws {
        let fixture = makeSingleWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "app.font.increase",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(
                state.effectiveTerminalFontPoints(for: fixture.windowID),
                AppState.defaultTerminalFontPoints + 1
            )
        }
    }

    func testAppFontActionRequiresExplicitWindowWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "app.font.increase",
                    "args": [:],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorMessage, "windowID is required when multiple windows exist")

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(
                state.effectiveTerminalFontPoints(for: fixture.firstWindowID),
                AppState.defaultTerminalFontPoints
            )
            XCTAssertEqual(
                state.effectiveTerminalFontPoints(for: fixture.secondWindowID),
                AppState.defaultTerminalFontPoints
            )
        }
    }

    func testAppFontActionUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "app.font.increase",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.selectedWindowID, fixture.firstWindowID)
            XCTAssertEqual(
                state.effectiveTerminalFontPoints(for: fixture.firstWindowID),
                AppState.defaultTerminalFontPoints
            )
            XCTAssertEqual(
                state.effectiveTerminalFontPoints(for: fixture.secondWindowID),
                AppState.defaultTerminalFontPoints + 1
            )
        }
    }

    func testMarkdownTextActionUsesExplicitWindowSelection() async throws {
        let fixture = makeTwoWindowFixture()

        try await withAutomationHarness(state: fixture.state) { harness in
            let response = try sendRequest(
                command: "automation.perform_action",
                payload: [
                    "action": "app.markdown_text.increase",
                    "args": [
                        "windowID": fixture.secondWindowID.uuidString,
                    ],
                ],
                socketPath: harness.socketPath
            )

            XCTAssertTrue(response.ok)

            let state = await MainActor.run { harness.store.state }
            XCTAssertEqual(state.effectiveMarkdownTextScale(for: fixture.firstWindowID), 1.0)
            XCTAssertEqual(state.effectiveMarkdownTextScale(for: fixture.secondWindowID), 1.1, accuracy: 0.0001)
        }
    }

}
