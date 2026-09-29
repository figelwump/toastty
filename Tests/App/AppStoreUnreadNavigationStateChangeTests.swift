@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreUnreadNavigationStateChangeTests: AppStoreCommandTestCase {
    func testJumpFromDoneSubspaceSkipsItsQuietUnreadPanelAcrossWindows() throws {
        let parentTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let doneTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [1])
        let otherTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [1])
        let parent = makeUnreadCommandWorkspace(title: "Parent", tabs: [parentTab], selectedTabIndex: 0)
        let done = makeUnreadCommandWorkspace(title: "Done", tabs: [doneTab], selectedTabIndex: 0)
        let other = makeUnreadCommandWorkspace(title: "Other", tabs: [otherTab], selectedTabIndex: 0)
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: firstWindowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [parent.id, done.id],
                        selectedWorkspaceID: done.id
                    ),
                    WindowState(
                        id: secondWindowID,
                        frame: CGRectCodable(x: 40, y: 40, width: 800, height: 600),
                        workspaceIDs: [other.id],
                        selectedWorkspaceID: other.id
                    ),
                ],
                workspacesByID: [parent.id: parent, done.id: done, other.id: other],
                selectedWindowID: firstWindowID
            ),
            persistTerminalFontPreference: false
        )
        XCTAssertTrue(store.send(.setWorkspaceParent(
            workspaceID: done.id,
            parentWorkspaceID: parent.id,
            spawningSessionID: nil
        )))
        XCTAssertTrue(store.send(.setWorkspaceDone(workspaceID: done.id, doneAt: Date())))

        XCTAssertTrue(store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: firstWindowID,
            sessionRuntimeStore: nil
        ))
        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(store.state.workspacesByID[other.id]?.focusedPanelID, otherTab.panelIDs[1])
        XCTAssertTrue(store.state.workspacesByID[done.id]?.unreadPanelIDs.contains(doneTab.panelIDs[1]) == true)
    }

    func testJumpSkipsUnreadReadySessionInDoneSubspaceButReachesItsError() throws {
        let parentTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let doneTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let otherTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let parent = makeUnreadCommandWorkspace(title: "Parent", tabs: [parentTab], selectedTabIndex: 0)
        let done = makeUnreadCommandWorkspace(title: "Done", tabs: [doneTab], selectedTabIndex: 0)
        let other = makeUnreadCommandWorkspace(title: "Other", tabs: [otherTab], selectedTabIndex: 0)
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [parent.id, done.id, other.id],
                    selectedWorkspaceID: parent.id
                )],
                workspacesByID: [parent.id: parent, done.id: done, other.id: other],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_300)
        let donePanelID = doneTab.panelIDs[1]
        let otherPanelID = otherTab.panelIDs[1]

        XCTAssertTrue(store.send(.setWorkspaceParent(
            workspaceID: done.id,
            parentWorkspaceID: parent.id,
            spawningSessionID: nil
        )))
        sessionStore.startSession(
            sessionID: "done-agent",
            agent: .codex,
            panelID: donePanelID,
            windowID: windowID,
            workspaceID: done.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "done-agent",
            status: SessionStatus(kind: .working, summary: "Finishing", detail: nil),
            at: startedAt.addingTimeInterval(1)
        )
        XCTAssertTrue(store.send(.setWorkspaceDone(workspaceID: done.id, doneAt: startedAt.addingTimeInterval(2))))
        sessionStore.updateStatus(
            sessionID: "done-agent",
            status: SessionStatus(kind: .ready, summary: "Finished", detail: nil),
            at: startedAt.addingTimeInterval(3)
        )
        XCTAssertTrue(store.state.workspacesByID[done.id]?.unreadPanelIDs.contains(donePanelID) == true)
        XCTAssertFalse(store.canFocusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID,
            sessionRuntimeStore: sessionStore
        ))
        XCTAssertFalse(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
            state: store.state,
            commandSelection: store.commandSelection(preferredWindowID: windowID),
            activePanelIDs: []
        ))
        XCTAssertTrue(store.send(.recordDesktopNotification(workspaceID: other.id, panelID: otherPanelID)))

        XCTAssertTrue(store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID,
            sessionRuntimeStore: sessionStore
        ))
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), other.id)
        XCTAssertEqual(store.state.workspacesByID[other.id]?.focusedPanelID, otherPanelID)
        XCTAssertTrue(store.state.workspacesByID[done.id]?.unreadPanelIDs.contains(donePanelID) == true)

        sessionStore.updateStatus(
            sessionID: "done-agent",
            status: SessionStatus(kind: .error, summary: "Failed", detail: nil),
            at: startedAt.addingTimeInterval(4)
        )
        XCTAssertNotNil(store.state.workspacesByID[done.id]?.doneAt)
        XCTAssertTrue(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
            state: store.state,
            commandSelection: store.commandSelection(preferredWindowID: windowID),
            activePanelIDs: [donePanelID],
            unreadPriorityPanelIDs: [donePanelID]
        ))
        XCTAssertTrue(store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID,
            sessionRuntimeStore: sessionStore
        ))
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), done.id)
        XCTAssertEqual(store.state.workspacesByID[done.id]?.focusedPanelID, donePanelID)
        XCTAssertNotNil(store.state.workspacesByID[done.id]?.doneAt)
    }

    func testFocusNextUnreadOrActivePanelFromCommandKeepsFreshErrorUnreadPreemptionDuringActiveCycle() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstWorkingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondWorkingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let errorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, firstWorkingTab, secondWorkingTab, errorTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_103.5)

        sessionStore.startSession(
            sessionID: "sess-working-first",
            agent: .codex,
            panelID: firstWorkingTab.panelIDs[1],
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
            panelID: secondWorkingTab.panelIDs[1],
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

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, firstWorkingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, firstWorkingTab.panelIDs[1])

        sessionStore.startSession(
            sessionID: "sess-error-new",
            agent: .codex,
            panelID: errorTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-error-new",
            status: SessionStatus(kind: .error, summary: "Error", detail: "New failure"),
            at: startedAt.addingTimeInterval(5)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, errorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, errorTab.panelIDs[1])
        XCTAssertFalse(
            try XCTUnwrap(updatedWorkspace.tabsByID[errorTab.tab.id])
                .unreadPanelIDs
                .contains(errorTab.panelIDs[1])
        )
    }

    func testFocusNextUnreadOrActivePanelFromCommandRebuildsCycleWhenReadErrorSessionStops() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstErrorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let stoppedErrorTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, firstErrorTab, stoppedErrorTab, workingTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_103.75)

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
            sessionID: "sess-error-stopped",
            agent: .claude,
            panelID: stoppedErrorTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-error-stopped",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Will stop"),
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
        XCTAssertTrue(store.send(.focusPanel(workspaceID: workspace.id, panelID: stoppedErrorTab.panelIDs[1])))
        XCTAssertTrue(store.send(.focusPanel(workspaceID: workspace.id, panelID: currentTab.panelIDs[0])))

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, firstErrorTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, firstErrorTab.panelIDs[1])

        sessionStore.stopSession(
            sessionID: "sess-error-stopped",
            at: startedAt.addingTimeInterval(6)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(updatedWorkspace.selectedTabID, workingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, workingTab.panelIDs[1])
    }

    func testFocusNextUnreadOrActivePanelFromCommandFlashesAfterVisitedReadyPanelsBecomeIdle() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let firstReadyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let secondReadyTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab, firstReadyTab, secondReadyTab],
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
        let startedAt = Date(timeIntervalSince1970: 1_700_000_105)

        sessionStore.startSession(
            sessionID: "sess-ready-first",
            agent: .codex,
            panelID: firstReadyTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-first",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "First"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-ready-second",
            agent: .claude,
            panelID: secondReadyTab.panelIDs[1],
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-ready-second",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Second"),
            at: startedAt.addingTimeInterval(3)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(sessionStore.panelStatus(for: firstReadyTab.panelIDs[1])?.status.kind, .idle)

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        XCTAssertEqual(sessionStore.panelStatus(for: secondReadyTab.panelIDs[1])?.status.kind, .idle)

        sessionStore.stopSession(
            sessionID: "sess-ready-first",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.stopSession(
            sessionID: "sess-ready-second",
            at: startedAt.addingTimeInterval(5)
        )
        XCTAssertNil(sessionStore.panelStatus(for: firstReadyTab.panelIDs[1]))
        XCTAssertNil(sessionStore.panelStatus(for: secondReadyTab.panelIDs[1]))

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
        XCTAssertEqual(try XCTUnwrap(flashRequest.panelID), secondReadyTab.panelIDs[1])
        XCTAssertNil(store.pendingSidebarSessionFlashRequest)
    }

    func testFocusNextUnreadOrActivePanelCyclesBeyondCurrentWorkspace() throws {
        let currentTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentTab],
            selectedTabIndex: 0
        )

        let siblingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let siblingWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [siblingTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id, siblingWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                )
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                siblingWorkspace.id: siblingWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_200)

        sessionStore.startSession(
            sessionID: "sess-current-first",
            agent: .codex,
            panelID: currentTab.panelIDs[0],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-first",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-first",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current first"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-current-second",
            agent: .claude,
            panelID: currentTab.panelIDs[1],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-second",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-second",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current second"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-sibling",
            agent: .codex,
            panelID: siblingTab.panelIDs[0],
            windowID: windowID,
            workspaceID: siblingWorkspace.id,
            cwd: "/repo/sibling",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-sibling",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Sibling"),
            at: startedAt.addingTimeInterval(5)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let currentWorkspaceAfterFirstJump = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), currentWorkspace.id)
        XCTAssertEqual(currentWorkspaceAfterFirstJump.focusedPanelID, currentTab.panelIDs[1])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )

        let siblingWorkspaceAfterSecondJump = try XCTUnwrap(store.state.workspacesByID[siblingWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), siblingWorkspace.id)
        XCTAssertEqual(siblingWorkspaceAfterSecondJump.focusedPanelID, siblingTab.panelIDs[0])
    }

    func testFocusNextUnreadOrActivePanelEventuallyReachesEarlierTabInSiblingWorkspaceCycle() throws {
        let currentEarlierTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentSelectedTab = makeUnreadCommandTab(
            focusedPanelIndex: 1,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let currentWorkspace = makeUnreadCommandWorkspace(
            title: "One",
            tabs: [currentEarlierTab, currentSelectedTab],
            selectedTabIndex: 1
        )

        let siblingTab = makeUnreadCommandTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [],
            panelCount: 2
        )
        let siblingWorkspace = makeUnreadCommandWorkspace(
            title: "Two",
            tabs: [siblingTab],
            selectedTabIndex: 0
        )

        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id, siblingWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                )
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                siblingWorkspace.id: siblingWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: store)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_201)

        sessionStore.startSession(
            sessionID: "sess-current-earlier",
            agent: .codex,
            panelID: currentEarlierTab.panelIDs[0],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-earlier",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-earlier",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current earlier"),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.startSession(
            sessionID: "sess-current-selected-first",
            agent: .claude,
            panelID: currentSelectedTab.panelIDs[0],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-selected-first",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-selected-first",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current selected first"),
            at: startedAt.addingTimeInterval(3)
        )

        sessionStore.startSession(
            sessionID: "sess-current-selected-second",
            agent: .codex,
            panelID: currentSelectedTab.panelIDs[1],
            windowID: windowID,
            workspaceID: currentWorkspace.id,
            cwd: "/repo/current-selected-second",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(4)
        )
        sessionStore.updateStatus(
            sessionID: "sess-current-selected-second",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Current selected second"),
            at: startedAt.addingTimeInterval(5)
        )

        sessionStore.startSession(
            sessionID: "sess-sibling",
            agent: .claude,
            panelID: siblingTab.panelIDs[0],
            windowID: windowID,
            workspaceID: siblingWorkspace.id,
            cwd: "/repo/sibling",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(6)
        )
        sessionStore.updateStatus(
            sessionID: "sess-sibling",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Sibling"),
            at: startedAt.addingTimeInterval(7)
        )

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        var updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[siblingWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), siblingWorkspace.id)
        XCTAssertEqual(updatedWorkspace.selectedTabID, siblingTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, siblingTab.panelIDs[0])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionStore
            )
        )
        updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[currentWorkspace.id])
        XCTAssertEqual(store.state.selectedWorkspaceID(in: windowID), currentWorkspace.id)
        XCTAssertEqual(updatedWorkspace.selectedTabID, currentEarlierTab.tab.id)
        XCTAssertEqual(updatedWorkspace.focusedPanelID, currentEarlierTab.panelIDs[0])
    }

}
