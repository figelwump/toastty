@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreUnreadNavigationPriorityTests: AppStoreCommandTestCase {
    func testFocusNextUnreadOrActivePanelFromCommandUsesFocusedWindowOverGlobalSelection() throws {
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
        let secondUnreadTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondUnreadTab],
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: nil
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: secondWindowID,
                sessionRuntimeStore: nil
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondUnreadTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondUnreadTab.panelIDs[2])
        XCTAssertTrue(updatedWorkspace.tabsByID[secondUnreadTab.tab.id]?.unreadPanelIDs.isEmpty == true)

        let flashRequest = try XCTUnwrap(
            store.consumePendingPanelFlashRequest(
                windowID: secondWindowID,
                requestID: try XCTUnwrap(store.pendingPanelFlashRequest?.requestID)
            )
        )
        XCTAssertEqual(flashRequest.windowID, secondWindowID)
        XCTAssertEqual(flashRequest.workspaceID, secondWorkspace.id)
        XCTAssertEqual(flashRequest.panelID, secondUnreadTab.panelIDs[2])
        XCTAssertNil(store.pendingPanelFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelFromCommandActivatesRaisedWindow() throws {
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
        let secondUnreadTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [1]
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondUnreadTab],
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

        XCTAssertTrue(
            store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: nil
            )
        )
        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: nil
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondUnreadTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondUnreadTab.panelIDs[1])
        XCTAssertTrue(updatedWorkspace.tabsByID[secondUnreadTab.tab.id]?.unreadPanelIDs.isEmpty == true)
    }

    func testFocusNextUnreadOrActivePanelFromCommandPrefersUnreadBeforeWorkingFallback() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let activeTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let unreadTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [2]
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, activeTab, unreadTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_090)
        sessionStore.startSession(
            sessionID: "sess-working-priority",
            agent: .codex,
            panelID: activeTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-priority",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Earlier active target"),
            at: startedAt.addingTimeInterval(1)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, unreadTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, unreadTab.panelIDs[2])
        XCTAssertTrue(updatedWorkspace.tabsByID[unreadTab.tab.id]?.unreadPanelIDs.isEmpty == true)
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToWorkingPanels() throws {
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
        let secondWorkingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondWorkingTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .codex,
            panelID: secondWorkingTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Applying patch"),
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
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondWorkingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondWorkingTab.panelIDs[2])
    }

    func testFocusNextUnreadOrActivePanelFromCommandFallsBackToLaterFlaggedPanels() throws {
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
        let secondLaterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [secondSelectedTab, secondLaterTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100.5)
        sessionStore.startSession(
            sessionID: "sess-later",
            agent: .codex,
            panelID: secondLaterTab.panelIDs[2],
            windowID: secondWindowID,
            workspaceID: secondWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Follow up later"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later", isFlagged: true)

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
        XCTAssertEqual(updatedWorkspace.selectedTabID, secondLaterTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, secondLaterTab.panelIDs[2])
        XCTAssertTrue(sessionStore.isLaterFlagged(sessionID: "sess-later"))
    }

    func testFocusNextUnreadOrActivePanelFromCommandPrefersWorkingBeforeLaterFlaggedPanels() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, workingTab, laterTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100.75)

        sessionStore.startSession(
            sessionID: "sess-working-priority-over-later",
            agent: .claude,
            panelID: workingTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-priority-over-later",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Applying review"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-later-secondary",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-secondary",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Circle back"),
            at: startedAt.addingTimeInterval(3)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-secondary", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandReachesLaterFlaggedBeforeWrappedWorking() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingFirstTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingSecondTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, workingFirstTab, workingSecondTab, laterTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100.9)

        sessionStore.startSession(
            sessionID: "sess-working-first",
            agent: .codex,
            panelID: workingFirstTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-first",
            status: SessionStatus(kind: .working, summary: "Working", detail: "First"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-working-second",
            agent: .claude,
            panelID: workingSecondTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-second",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Second"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-later-third",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-third",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Follow up"),
            at: startedAt.addingTimeInterval(5)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-third", isFlagged: true)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingFirstTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingFirstTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingSecondTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingSecondTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, laterTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, laterTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingFirstTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingFirstTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandKeepsForwardWorkingAheadOfEarlierLaterFlagged() throws {
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [laterTab, currentTab, workingTab],
            selectedTabIndex: 1
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100.95)

        sessionStore.startSession(
            sessionID: "sess-later-earlier",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-earlier",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Earlier later"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-earlier", isFlagged: true)

        sessionStore.startSession(
            sessionID: "sess-working-ahead",
            agent: .claude,
            panelID: workingTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-working-ahead",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Ahead"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, laterTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, laterTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandPrefersForwardWorkingInLaterWindowBeforeWrappedLaterFlaggedPanels() throws {
        let laterTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [laterTab, currentTab],
            selectedTabIndex: 1
        )

        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [workingTab],
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
                    workspaceIDs: [workingWorkspace.id],
                    selectedWorkspaceID: workingWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                workingWorkspace.id: workingWorkspace,
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
            sessionID: "sess-current-window-later",
            agent: .codex,
            panelID: laterTab.panelIDs[1],
            windowID: firstWindowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-window-later",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Current window later"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-current-window-later", isFlagged: true)

        sessionStore.startSession(
            sessionID: "sess-later-window-working",
            agent: .claude,
            panelID: workingTab.panelIDs[1],
            windowID: secondWindowID,
            workspaceID: workingWorkspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-window-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Later window working"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: firstWindowID,
                sessionRuntimeStore: sessionStore
            )
        )

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workingWorkspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingTab.panelIDs[1])

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
    }

}
