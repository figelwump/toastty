@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreUnreadNavigationAvailabilityTests: AppStoreCommandTestCase {
    func testCanFocusNextUnreadOrActivePanelFromCommandSkipsFocusedUnreadOnlyTarget() {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )
    }

    func testCanFocusNextUnreadOrActivePanelFromCommandSkipsFocusedWorkingOnlyTarget() {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_050)
        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
    }

    func testCanFocusNextUnreadOrActivePanelFromCommandFallsBackToReadyPanels() {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let readyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, readyTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_057)
        sessionStore.startSession(
            sessionID: "sess-ready-target",
            agent: .codex,
            panelID: readyTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-target",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Next target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
    }

    func testFocusNextUnreadOrActivePanelFromCommandSkipsFocusedWorkingOnlyTarget() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_055)
        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, windowID)
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, tab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, tab.panelIDs[0])
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashForFocusedWorkingOnlyTarget() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_056)
        sessionStore.startSession(
            sessionID: "sess-working-flash",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-flash",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)

        let panelFlashRequest = try XCTUnwrap(
            store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(panelFlashRequest.windowID, windowID)
        XCTAssertEqual(panelFlashRequest.workspaceID, workspace.id)
        XCTAssertEqual(panelFlashRequest.panelID, tab.panelIDs[0])
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashForFocusedReadyOnlyTarget() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_057)
        sessionStore.startSession(
            sessionID: "sess-ready-flash",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-flash",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testConsumePendingSidebarSessionFlashRequestIgnoresStaleRequestID() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_056)
        sessionStore.startSession(
            sessionID: "sess-working-flash-stale-id",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-flash-stale-id",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Only target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let currentRequestID = try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
        XCTAssertNil(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: UUID()
            )
        )
        XCTAssertEqual(store.pendingSidebarSessionFlashRequest?.requestID, currentRequestID)
    }

    func testFocusExplicitlyNavigatedPanelEnqueuesPanelFlashRequest() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertTrue(
            store.focusExplicitlyNavigatedPanel(
                windowID: windowID,
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspace.id])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, fixture.rightPanelID)

        let flashRequest = try XCTUnwrap(
            store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, fixture.workspace.id)
        XCTAssertEqual(flashRequest.panelID, fixture.rightPanelID)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusDroppedFilePanelActivatesCurrentWindowWithoutPanelFlash() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )

        XCTAssertTrue(
            store.focusDroppedFilePanel(
                windowID: windowID,
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspace.id])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, fixture.rightPanelID)
        XCTAssertEqual(activatedWindowIDs, [windowID])
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testConsumePendingPanelFlashRequestIgnoresStaleRequestID() throws {
        let fixture = makeTwoPanelWorkspace(title: "One")
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [fixture.workspace.id],
                        selectedWorkspaceID: fixture.workspace.id
                    )
                ],
                workspacesByID: [fixture.workspace.id: fixture.workspace],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertTrue(
            store.focusExplicitlyNavigatedPanel(
                windowID: windowID,
                workspaceID: fixture.workspace.id,
                panelID: fixture.rightPanelID
            )
        )

        let currentRequestID = try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
        XCTAssertNil(
            store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: UUID()
            )
        )
        XCTAssertEqual(store.pendingPanelFlashRequest?.requestID, currentRequestID)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashForFocusedIdleSessionWithoutOtherActiveTargets() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_058)
        sessionStore.startSession(
            sessionID: "sess-idle-flash",
            agent: .codex,
            panelID: tab.panelIDs[0],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-idle-flash",
            status: SessionStatus(kind: .idle, summary: "Idle", detail: nil),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsSidebarFlashWithoutFocusedSessionRow() throws {
        let tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), tab.panelIDs[0])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandRequestsWorkspaceFlashWithoutFocusedPanel() throws {
        var tab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        tab.tab.focusedPanelID = nil
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [tab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
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
            ),
            persistTerminalFontPreference: false
        )

        XCTAssertFalse(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: nil
            )
        )

        let flashRequest = try XCTUnwrap(
            store.consumePendingSidebarSessionFlashRequest(
                windowID: windowID,
                requestID: try XCTUnwrap(store.pendingSidebarSessionFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, windowID)
        XCTAssertEqual(flashRequest.workspaceID, workspace.id)
        XCTAssertNil(flashRequest.panelID)
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

}
