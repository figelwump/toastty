@testable import ToasttyApp
import CoreState
import Darwin
import Foundation
import XCTest

final class AutomationSocketServerWindowTargetingTests: XCTestCase {
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

    func testFocusNextUnreadActionUsesSoleWindowFallbackWhenSingleWindowExists() async throws {
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

    func testFocusNextUnreadActionRequiresExplicitWindowWhenMultipleWindowsExist() async throws {
        let fixture = makeTwoWindowUnreadFixture()

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
                    "action": "workspace.focus-next-unread",
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
            XCTAssertEqual(response.result["profileID"] as? String, "smoke-profile")
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
            XCTAssertEqual(response.result["workspaceID"] as? String, workspaceID.uuidString)
            XCTAssertEqual(response.result["panelID"] as? String, panelID.uuidString)
            XCTAssertEqual(response.result["title"] as? String, "Background Agent")
            XCTAssertEqual(response.result["profileID"] as? String, "background-profile")
        }
    }

    private func withAutomationHarness(
        state: AppState,
        file: StaticString = #filePath,
        line: UInt = #line,
        body: (AutomationHarness) async throws -> Void
    ) async throws {
        var harness: AutomationHarness? = try await MainActor.run {
            try Self.makeAutomationHarness(state: state)
        }
        do {
            try await body(try XCTUnwrap(harness, file: file, line: line))
            await MainActor.run { harness = nil }
        } catch {
            await MainActor.run { harness = nil }
            throw error
        }
    }

    @MainActor
    private static func makeAutomationHarness(state: AppState) throws -> AutomationHarness {
        let socketDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = socketDirectory.appendingPathComponent("events-v1.sock", isDirectory: false).path
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        registry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        registry.bind(store: store)
        let agentCatalogProvider = TestAgentCatalogProvider()
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: registry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
        let config = AutomationConfig(
            runID: UUID().uuidString,
            fixtureName: nil,
            artifactsDirectory: nil,
            socketPath: socketPath,
            disableAnimations: true,
            fixedLocaleIdentifier: nil,
            fixedTimeZoneIdentifier: nil
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { socketPath }
        )
        let server = try AutomationSocketServer(
            socketPath: socketPath,
            automationConfig: config,
            store: store,
            terminalRuntimeRegistry: registry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService
        )
        return AutomationHarness(store: store, server: server, socketPath: socketPath)
    }

    private func sendRequest(
        command: String,
        payload: [String: Any],
        socketPath: String
    ) throws -> AutomationSocketTestResponse {
        let request: [String: Any] = [
            "kind": "request",
            "protocolVersion": "1.0",
            "requestID": UUID().uuidString,
            "command": command,
            "payload": payload,
        ]
        return try sendEnvelope(request, socketPath: socketPath)
    }

    private func sendEnvelope(
        _ envelope: [String: Any],
        socketPath: String
    ) throws -> AutomationSocketTestResponse {
        let requestData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let responseData = try withConnectedSocket(socketPath: socketPath) { fileDescriptor in
            try writeAll(data: requestData + Data([0x0A]), to: fileDescriptor)
            return try readLine(from: fileDescriptor)
        }

        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            XCTFail("expected response envelope")
            return AutomationSocketTestResponse(ok: false, result: [:], errorMessage: "invalid response")
        }

        let ok = (object["ok"] as? Bool) ?? false
        let errorMessage = (object["error"] as? [String: Any])?["message"] as? String
        let result = object["result"] as? [String: Any] ?? [:]
        return AutomationSocketTestResponse(ok: ok, result: result, errorMessage: errorMessage)
    }

    private func withConnectedSocket<T>(
        socketPath: String,
        body: (Int32) throws -> T
    ) throws -> T {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AutomationSocketTestError.socketFailure("socket", errno)
        }

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8CString)
            let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= maxPathLength else {
                throw AutomationSocketTestError.socketPathTooLong
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                pathBytes.withUnsafeBytes { source in
                    if let destinationAddress = buffer.baseAddress,
                       let sourceAddress = source.baseAddress {
                        memcpy(destinationAddress, sourceAddress, pathBytes.count)
                    }
                }
            }

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                throw AutomationSocketTestError.socketFailure("connect", errno)
            }

            defer { close(fileDescriptor) }
            return try body(fileDescriptor)
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private func writeAll(data: Data, to fileDescriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                write(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }

            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw AutomationSocketTestError.socketFailure("write", errno)
            }

            offset += written
        }
    }

    private func readLine(from fileDescriptor: Int32) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(fileDescriptor, &chunk, chunk.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw AutomationSocketTestError.socketFailure("read", errno)
            }

            buffer.append(contentsOf: chunk[..<count])
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return buffer.prefix(upTo: newlineIndex)
            }
        }

        throw AutomationSocketTestError.missingResponse
    }

    private func makeTwoWindowFixture() -> TwoWindowFixture {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 48, y: 48, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        return TwoWindowFixture(
            state: state,
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            firstWorkspaceID: firstWorkspace.id,
            secondWorkspaceID: secondWorkspace.id
        )
    }

    private func makeSingleWindowFixture() -> SingleWindowFixture {
        let workspace = WorkspaceState.bootstrap(title: "One")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [
                workspace.id: workspace,
            ],
            selectedWindowID: windowID
        )
        return SingleWindowFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id
        )
    }

    private func makeSingleWindowUnreadFixture() -> SingleWindowUnreadFixture {
        let currentTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let unreadTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let workspace = makeUnreadNavigationWorkspace(
            title: "One",
            tabs: [currentTab, unreadTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        return SingleWindowUnreadFixture(
            state: state,
            windowID: windowID,
            workspaceID: workspace.id,
            targetTabID: unreadTab.tab.id,
            targetPanelID: unreadTab.panelIDs[2]
        )
    }

    private func makeTwoWindowUnreadFixture() -> TwoWindowUnreadFixture {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondCurrentTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondUnreadTab = makeUnreadNavigationTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let secondWorkspace = makeUnreadNavigationWorkspace(
            title: "Two",
            tabs: [secondCurrentTab, secondUnreadTab],
            selectedTabIndex: 0
        )
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 48, y: 48, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        return TwoWindowUnreadFixture(
            state: state,
            firstWindowID: firstWindowID,
            secondWindowID: secondWindowID,
            secondWorkspaceID: secondWorkspace.id,
            targetTabID: secondUnreadTab.tab.id,
            targetPanelID: secondUnreadTab.panelIDs[1]
        )
    }
}

private struct AutomationHarness {
    let store: AppStore
    let server: AutomationSocketServer
    let socketPath: String
}

private struct AutomationSocketTestResponse {
    let ok: Bool
    let result: [String: Any]
    let errorMessage: String?
}

private struct TwoWindowFixture {
    let state: AppState
    let firstWindowID: UUID
    let secondWindowID: UUID
    let firstWorkspaceID: UUID
    let secondWorkspaceID: UUID
}

private struct SingleWindowFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
}

private struct SingleWindowUnreadFixture {
    let state: AppState
    let windowID: UUID
    let workspaceID: UUID
    let targetTabID: UUID
    let targetPanelID: UUID
}

private struct TwoWindowUnreadFixture {
    let state: AppState
    let firstWindowID: UUID
    let secondWindowID: UUID
    let secondWorkspaceID: UUID
    let targetTabID: UUID
    let targetPanelID: UUID
}

private struct UnreadNavigationTabFixture {
    let tab: WorkspaceTabState
    let panelIDs: [UUID]
}

private enum AutomationSocketTestError: Error {
    case missingResponse
    case socketFailure(String, Int32)
    case socketPathTooLong
}

private func makeUnreadNavigationTab(
    focusedPanelIndex: Int,
    unreadPanelIndices: Set<Int>,
    panelCount: Int = 3
) -> UnreadNavigationTabFixture {
    let panelIDs = (0 ..< panelCount).map { _ in UUID() }
    let panels = Dictionary(uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
        (
            panelID,
            PanelState.terminal(
                TerminalPanelState(
                    title: "Terminal \(index + 1)",
                    shell: "zsh",
                    cwd: NSHomeDirectory()
                )
            )
        )
    })

    let tab = WorkspaceTabState(
        id: UUID(),
        layoutTree: makeUnreadNavigationLayout(panelIDs: panelIDs),
        panels: panels,
        focusedPanelID: panelIDs[focusedPanelIndex],
        unreadPanelIDs: Set(unreadPanelIndices.map { panelIDs[$0] })
    )

    return UnreadNavigationTabFixture(tab: tab, panelIDs: panelIDs)
}

private func makeUnreadNavigationWorkspace(
    title: String,
    tabs: [UnreadNavigationTabFixture],
    selectedTabIndex: Int
) -> WorkspaceState {
    let tabIDs = tabs.map(\.tab.id)
    return WorkspaceState(
        id: UUID(),
        title: title,
        selectedTabID: tabIDs[selectedTabIndex],
        tabIDs: tabIDs,
        tabsByID: Dictionary(uniqueKeysWithValues: tabs.map { ($0.tab.id, $0.tab) })
    )
}

private func makeUnreadNavigationLayout(panelIDs: [UUID]) -> LayoutNode {
    precondition(panelIDs.isEmpty == false)

    var iterator = panelIDs.makeIterator()
    let firstPanelID = iterator.next()!
    var layout = LayoutNode.slot(slotID: UUID(), panelID: firstPanelID)

    while let panelID = iterator.next() {
        layout = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: layout,
            second: .slot(slotID: UUID(), panelID: panelID)
        )
    }

    return layout
}
