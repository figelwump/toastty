@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreUnreadNavigationCycleTests: AppStoreCommandTestCase {
    func testFocusNextUnreadOrActivePanelFromCommandCyclesCrossWindowLaterFlaggedSessionBeforeReturningToStartingWorkingPanel() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, laterTab],
            selectedTabIndex: 0
        )

        let remoteTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let remoteWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [remoteTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [remoteWorkspace.id],
                    selectedWorkspaceID: remoteWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                remoteWorkspace.id: remoteWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101.1)

        sessionStore.startSession(
            sessionID: "sess-current-working",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-remote-working",
            agent: .claude,
            panelID: remoteTab.panelIDs[1],
            windowID: secondWindowID,
            workspaceID: remoteWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-remote-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Remote"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-later",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Later"),
            at: startedAt.addingTimeInterval(5)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[remoteWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, remoteTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, remoteTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID, firstWindowID])
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, laterTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, laterTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, currentTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, currentTab.panelIDs[0])
    }

    func testFocusNextUnreadOrActivePanelFromCommandPreservesActiveCycleAcrossWorkingDetailUpdates() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, laterTab],
            selectedTabIndex: 0
        )

        let remoteTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let remoteWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [remoteTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [remoteWorkspace.id],
                    selectedWorkspaceID: remoteWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                remoteWorkspace.id: remoteWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101.2)

        sessionStore.startSession(
            sessionID: "sess-current-working",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-remote-working",
            agent: .claude,
            panelID: remoteTab.panelIDs[1],
            windowID: secondWindowID,
            workspaceID: remoteWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-remote-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Remote"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-later",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Later"),
            at: startedAt.addingTimeInterval(5)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)

        sessionStore.updateStatus(
            sessionID: "sess-current-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current updated"),
            at: startedAt.addingTimeInterval(6)
        )
        sessionStore.updateStatus(
            sessionID: "sess-remote-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Remote updated"),
            at: startedAt.addingTimeInterval(7)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
        XCTAssertEqual(updatedWorkspace.selectedTabID, laterTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, laterTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandResetsActiveCycleAfterManualFocusChange() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, laterTab],
            selectedTabIndex: 0
        )

        let remoteTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let remoteWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [remoteTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [remoteWorkspace.id],
                    selectedWorkspaceID: remoteWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                remoteWorkspace.id: remoteWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101.3)

        sessionStore.startSession(
            sessionID: "sess-current-working",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-remote-working",
            agent: .claude,
            panelID: remoteTab.panelIDs[1],
            windowID: secondWindowID,
            workspaceID: remoteWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-remote-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Remote"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-later",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Later"),
            at: startedAt.addingTimeInterval(5)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)

        XCTAssertTrue(store.focusPanel(containing: currentTab.panelIDs[0]))
        let resetWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
        XCTAssertEqual(resetWorkspace.selectedTabID, currentTab.tab.id)
        XCTAssertEqual(resetWorkspace.focusedPanelID, currentTab.panelIDs[0])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[remoteWorkspace.id])
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(updatedWorkspace.selectedTabID, remoteTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, remoteTab.panelIDs[1])
    }

    func testCanFocusNextUnreadOrActivePanelFromCommandDoesNotAdvanceActiveCycle() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, laterTab],
            selectedTabIndex: 0
        )

        let remoteTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let remoteWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [remoteTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [remoteWorkspace.id],
                    selectedWorkspaceID: remoteWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                remoteWorkspace.id: remoteWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101.4)

        sessionStore.startSession(
            sessionID: "sess-current-working",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-remote-working",
            agent: .claude,
            panelID: remoteTab.panelIDs[1],
            windowID: secondWindowID,
            workspaceID: remoteWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-remote-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Remote"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-later",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Later"),
            at: startedAt.addingTimeInterval(5)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
        XCTAssertEqual(updatedWorkspace.selectedTabID, laterTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, laterTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandResetsActiveCycleAfterLaterFlagClears() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, laterTab],
            selectedTabIndex: 0
        )

        let remoteTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let remoteWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [remoteTab],
            selectedTabIndex: 0
        )

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [remoteWorkspace.id],
                    selectedWorkspaceID: remoteWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                remoteWorkspace.id: remoteWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101.5)

        sessionStore.startSession(
            sessionID: "sess-current-working",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-remote-working",
            agent: .claude,
            panelID: remoteTab.panelIDs[1],
            windowID: secondWindowID,
            workspaceID: remoteWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-remote-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Remote"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-later",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Later"),
            at: startedAt.addingTimeInterval(5)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)

        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: false)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWindowID, firstWindowID)
        XCTAssertEqual(updatedWorkspace.selectedTabID, currentTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, currentTab.panelIDs[0])
    }

    func testFocusNextUnreadOrActivePanelFromCommandUsesUnreadReadyPanelsAndDemotesThemToIdle() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondReadyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondReadyTab],
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
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_101)
        sessionStore.startSession(
            sessionID: "sess-ready",
            agent: .codex,
            panelID: secondReadyTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Waiting for next prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondReadyTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondReadyTab.panelIDs[2])
        XCTAssertEqual(sessionStore.panelStatus(for: secondReadyTab.panelIDs[2])?.status.kind, .idle)
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToNeedsApprovalPanels() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondApprovalTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondApprovalTab],
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
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_102)
        sessionStore.startSession(
            sessionID: "sess-needs-approval",
            agent: .codex,
            panelID: secondApprovalTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-needs-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Review command"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondApprovalTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondApprovalTab.panelIDs[2])
    }

    func testFocusNextUnreadOrActivePanelFromCommandPrefersReadNeedsApprovalOverWorkingFallback() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let approvalTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, workingTab, approvalTab],
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_104)

        sessionStore.startSession(
            sessionID: "sess-working-priority",
            agent: .codex,
            panelID: workingTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-priority",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Streaming"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-needs-approval-priority",
            agent: .claude,
            panelID: approvalTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-needs-approval-priority",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.send(.focusPanel(workspaceID: workspace.id, panelID: approvalTab.panelIDs[1]))
        )
        XCTAssertTrue(
            store.send(.focusPanel(workspaceID: workspace.id, panelID: currentTab.panelIDs[0]))
        )
        XCTAssertEqual(sessionStore.panelStatus(for: approvalTab.panelIDs[1])?.status.kind, .needsApproval)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, approvalTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, approvalTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToErrorPanels() throws {
        let firstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [firstTab],
            selectedTabIndex: 0
        )

        let secondSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondErrorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondErrorTab],
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
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_103)
        sessionStore.startSession(
            sessionID: "sess-error",
            agent: .codex,
            panelID: secondErrorTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-error",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Command failed"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondErrorTab.panelIDs[2])
    }

    func testFocusNextUnreadOrActivePanelFromCommandCyclesReadErrorsBeforeWorkingPanel() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstErrorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondErrorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, firstErrorTab, secondErrorTab, workingTab],
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_103.25)

        sessionStore.startSession(
            sessionID: "sess-error-first",
            agent: .codex,
            panelID: firstErrorTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-error-first",
            status: SessionStatus(kind: .error, summary: "Error", detail: "First failed"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-error-second",
            agent: .claude,
            panelID: secondErrorTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-error-second",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Second failed"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: workingTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Still running"),
            at: startedAt.addingTimeInterval(5)
        )

        XCTAssertTrue(store.send(.focusPanel(workspaceID: workspace.id, panelID: firstErrorTab.panelIDs[1])))
        XCTAssertTrue(store.send(.focusPanel(workspaceID: workspace.id, panelID: secondErrorTab.panelIDs[1])))
        XCTAssertTrue(store.send(.focusPanel(workspaceID: workspace.id, panelID: currentTab.panelIDs[0])))

        var readWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertFalse(
            try XCTUnwrap(readWorkspace.tabsByID[firstErrorTab.tab.id])
                .unreadPanelIDs
                .contains(firstErrorTab.panelIDs[1])
        )
        XCTAssertFalse(
            try XCTUnwrap(readWorkspace.tabsByID[secondErrorTab.tab.id])
                .unreadPanelIDs
                .contains(secondErrorTab.panelIDs[1])
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, firstErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, firstErrorTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondErrorTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, firstErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, firstErrorTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondErrorTab.panelIDs[1])

        readWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertFalse(
            try XCTUnwrap(readWorkspace.tabsByID[firstErrorTab.tab.id])
                .unreadPanelIDs
                .contains(firstErrorTab.panelIDs[1])
        )
        XCTAssertFalse(
            try XCTUnwrap(readWorkspace.tabsByID[secondErrorTab.tab.id])
                .unreadPanelIDs
                .contains(secondErrorTab.panelIDs[1])
        )
    }

}
