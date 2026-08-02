@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreWorkspaceCommandTests: AppStoreCommandTestCase {
    func testSelectWorkspaceTabFromCommandUsesFocusedWindowOverGlobalSelection() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let firstWindowID = try XCTUnwrap(state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(reducer.send(.createWindow(seed: nil, initialFrame: nil), state: &state))
        let secondWindowID = try XCTUnwrap(state.windows.last?.id)
        let secondWorkspaceID = try XCTUnwrap(state.windows.last?.selectedWorkspaceID)
        XCTAssertTrue(reducer.send(.createWorkspaceTab(workspaceID: secondWorkspaceID, seed: nil), state: &state))
        XCTAssertTrue(reducer.send(.selectWorkspace(windowID: firstWindowID, workspaceID: firstWorkspaceID), state: &state))
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.selectWorkspaceTabFromCommand(preferredWindowID: secondWindowID, shortcutNumber: 2))

        let firstWorkspace = try XCTUnwrap(store.state.workspacesByID[firstWorkspaceID])
        let secondWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspaceID])
        XCTAssertEqual(firstWorkspace.tabIDs.count, 1)
        XCTAssertEqual(secondWorkspace.tabIDs.count, 2)
        XCTAssertEqual(secondWorkspace.resolvedSelectedTabID, secondWorkspace.tabIDs[1])
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
    }

    func testSelectAdjacentWorkspaceTabDoesNotRequestPanelFlash() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let createdTabID = try XCTUnwrap(state.workspacesByID[workspaceID]?.tabIDs.last)
        let originalTabID = try XCTUnwrap(state.workspacesByID[workspaceID]?.tabIDs.first)
        XCTAssertTrue(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID), state: &state))
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.selectAdjacentWorkspaceTab(
                preferredWindowID: windowID,
                direction: .next
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.resolvedSelectedTabID, createdTabID)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testRenameSelectedWorkspaceFromCommandSetsPendingRenameRequest() throws {
        let workspace = WorkspaceState.bootstrap(title: "Dev")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.pendingRenameWorkspaceRequest)
        XCTAssertTrue(store.renameSelectedWorkspaceFromCommand(preferredWindowID: windowID))
        XCTAssertEqual(
            store.pendingRenameWorkspaceRequest,
            PendingWorkspaceRenameRequest(windowID: windowID, workspaceID: workspace.id)
        )
    }

    func testRenameSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(store.renameSelectedWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertNil(store.pendingRenameWorkspaceRequest)
    }

    func testConsumePendingRenameWorkspaceRequestOnlyReturnsMatchingWindow() {
        let request = PendingWorkspaceRenameRequest(windowID: UUID(), workspaceID: UUID())
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.pendingRenameWorkspaceRequest = request

        XCTAssertNil(store.consumePendingWorkspaceRenameRequest(windowID: UUID()))
        XCTAssertEqual(store.pendingRenameWorkspaceRequest, request)
        XCTAssertEqual(store.consumePendingWorkspaceRenameRequest(windowID: request.windowID), request)
        XCTAssertNil(store.pendingRenameWorkspaceRequest)
    }

    func testRenameSelectedWorkspaceTabFromCommandSetsPendingRenameRequest() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let selectedTabID = try XCTUnwrap(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        XCTAssertNil(store.pendingRenameWorkspaceTabRequest)
        XCTAssertTrue(store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: windowID))
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(windowID: windowID, workspaceID: workspaceID, tabID: selectedTabID)
        )
    }

    func testRenameSelectedWorkspaceTabFromCommandSupportsSingleTabWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let selectedTabID = try XCTUnwrap(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        XCTAssertTrue(store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: windowID))
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(windowID: windowID, workspaceID: workspaceID, tabID: selectedTabID)
        )
    }

    func testConsumePendingRenameWorkspaceTabRequestOnlyReturnsMatchingWindow() {
        let request = PendingWorkspaceTabRenameRequest(windowID: UUID(), workspaceID: UUID(), tabID: UUID())
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.pendingRenameWorkspaceTabRequest = request

        XCTAssertNil(store.consumePendingWorkspaceTabRenameRequest(windowID: UUID()))
        XCTAssertEqual(store.pendingRenameWorkspaceTabRequest, request)
        XCTAssertEqual(store.consumePendingWorkspaceTabRenameRequest(windowID: request.windowID), request)
        XCTAssertNil(store.pendingRenameWorkspaceTabRequest)
    }

    func testConsumePendingBrowserLocationFocusRequestOnlyReturnsMatchingWindow() {
        let request = PendingBrowserLocationFocusRequest(
            requestID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            panelID: UUID()
        )
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        store.pendingBrowserLocationFocusRequest = request

        XCTAssertNil(store.consumePendingBrowserLocationFocusRequest(windowID: UUID()))
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest, request)
        XCTAssertEqual(
            store.consumePendingBrowserLocationFocusRequest(windowID: request.windowID),
            request
        )
        XCTAssertNil(store.pendingBrowserLocationFocusRequest)
    }

    func testCloseSelectedWorkspaceFromCommandRequestsFocusedWorkspaceClose() throws {
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
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.closeSelectedWorkspaceFromCommand(preferredWindowID: secondWindowID))
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: secondWindowID, workspaceID: secondWorkspace.id)
        )
        XCTAssertNotNil(store.window(id: firstWindowID))
        XCTAssertNotNil(store.window(id: secondWindowID))
        XCTAssertNotNil(store.state.workspacesByID[secondWorkspace.id])
    }

    func testCloseSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(store.closeSelectedWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
    }

    func testConfirmWorkspaceCloseClosesRequestedWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: "Second", activate: true)))
        let secondWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: secondWorkspaceID))

        XCTAssertTrue(store.confirmWorkspaceClose(windowID: windowID, workspaceID: secondWorkspaceID))

        let window = try XCTUnwrap(store.window(id: windowID))
        XCTAssertEqual(window.workspaceIDs, [firstWorkspaceID])
        XCTAssertEqual(window.selectedWorkspaceID, firstWorkspaceID)
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
        XCTAssertNil(store.state.workspacesByID[secondWorkspaceID])
    }

    func testConfirmWorkspaceCloseKeepsEmptyWindowWhenClosingLastWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: workspaceID))

        XCTAssertTrue(store.confirmWorkspaceClose(windowID: windowID, workspaceID: workspaceID))

        let window = try XCTUnwrap(store.window(id: windowID))
        XCTAssertTrue(window.workspaceIDs.isEmpty)
        XCTAssertNil(window.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, windowID)
        XCTAssertEqual(store.state.windows.count, 1)
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
        XCTAssertNil(store.state.workspacesByID[workspaceID])
    }

    func testRequestWorkspaceCloseDoesNotOverwriteDifferentPendingRequest() throws {
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
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.requestWorkspaceClose(workspaceID: firstWorkspace.id))
        XCTAssertFalse(store.requestWorkspaceClose(workspaceID: secondWorkspace.id))
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: firstWindowID, workspaceID: firstWorkspace.id)
        )
    }

    func testCreateWorkspaceFromCommandDoesNotRerouteMissingFocusedWindow() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = store.state.windows[0].id
        let originalWorkspaceIDs = store.state.windows[0].workspaceIDs

        XCTAssertFalse(store.canCreateWorkspaceFromCommand(preferredWindowID: UUID()))
        XCTAssertFalse(store.createWorkspaceFromCommand(preferredWindowID: UUID()))

        XCTAssertEqual(store.state.windows[0].id, windowID)
        XCTAssertEqual(store.state.windows[0].workspaceIDs, originalWorkspaceIDs)
    }

    func testSelectWorkspacePrefersMostRecentUnreadSessionPanelWhenSwitchingWorkspaces() throws {
        let windowID = UUID()
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondLayout = makeTwoPanelWorkspace(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondLayout.workspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondLayout.workspace.id: secondLayout.workspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-left",
            agent: .codex,
            panelID: secondLayout.leftPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/left",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-left",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Left"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .claude,
            panelID: secondLayout.rightPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Right"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.id, secondLayout.workspace.id)
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.rightPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.leftPanelID])
    }

    func testSelectWorkspaceDoesNotOverrideFocusWhenWorkspaceIsAlreadySelected() throws {
        let windowID = UUID()
        let secondLayout = makeTwoPanelWorkspace(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [secondLayout.workspace.id],
                    selectedWorkspaceID: secondLayout.workspace.id
                )
            ],
            workspacesByID: [secondLayout.workspace.id: secondLayout.workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .codex,
            panelID: secondLayout.rightPanelID,
            windowID: windowID,
            workspaceID: secondLayout.workspace.id,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Right"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.leftPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.rightPanelID])
    }

    func testSelectWorkspaceIgnoresUnreadPanelsWithoutSessionStatus() throws {
        let windowID = UUID()
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        var secondLayout = makeTwoPanelWorkspace(title: "Two")
        secondLayout.workspace.unreadPanelIDs = [secondLayout.rightPanelID]
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondLayout.workspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondLayout.workspace.id: secondLayout.workspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)

        XCTAssertTrue(
            store.selectWorkspace(
                windowID: windowID,
                workspaceID: secondLayout.workspace.id,
                preferringUnreadSessionPanelIn: sessionStore
            )
        )

        let selectedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))
        XCTAssertEqual(selectedWorkspace.focusedPanelID, secondLayout.leftPanelID)
        XCTAssertEqual(selectedWorkspace.unreadPanelIDs, [secondLayout.rightPanelID])
    }

}
