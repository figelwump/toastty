@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreUnreadNavigationSpatialOrderTests: AppStoreCommandTestCase {
    func testWorkingCycleFollowsSessionCreationOrderAcrossTabs() throws {
        let first = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let second = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [first, second], selectedTabIndex: 0)
        let fixture = makeSpatialFixture(workspaces: [workspace])
        let order = [first.panelIDs[0], second.panelIDs[2], first.panelIDs[1]]
        startSpatialSessions(order, workspace: workspace, fixture: fixture)

        for panelID in [order[1], order[2], order[0], order[1]] {
            try assertSpatialJump(to: panelID, fixture: fixture)
        }
    }

    func testWorkingCycleFollowsCustomSidebarOrderAndWraps() throws {
        let tab = makeUnreadCommandTab(focusedPanelIndex: 1, unreadPanelIndices: [])
        var workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
        workspace.sidebarSessionPanelOrder = [tab.panelIDs[2], tab.panelIDs[1], tab.panelIDs[0]]
        let fixture = makeSpatialFixture(workspaces: [workspace])
        startSpatialSessions(tab.panelIDs, workspace: workspace, fixture: fixture)

        for panelID in [tab.panelIDs[0], tab.panelIDs[2], tab.panelIDs[1]] {
            try assertSpatialJump(to: panelID, fixture: fixture)
        }
    }

    func testJumpVisitsSubspaceBelowParentBeforeNextTopLevelWorkspace() throws {
        let parentTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let siblingTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let childTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let parent = makeUnreadCommandWorkspace(title: "Parent", tabs: [parentTab], selectedTabIndex: 0)
        let sibling = makeUnreadCommandWorkspace(title: "Sibling", tabs: [siblingTab], selectedTabIndex: 0)
        var child = makeUnreadCommandWorkspace(title: "Child", tabs: [childTab], selectedTabIndex: 0)
        child.parentWorkspaceID = parent.id
        let fixture = makeSpatialFixture(workspaces: [parent, sibling, child])
        startSpatialSessions([parentTab.panelIDs[0]], workspace: parent, fixture: fixture)
        startSpatialSessions([siblingTab.panelIDs[0]], workspace: sibling, fixture: fixture)
        startSpatialSessions([childTab.panelIDs[0]], workspace: child, fixture: fixture)

        try assertSpatialJump(to: childTab.panelIDs[0], fixture: fixture)
        try assertSpatialJump(to: siblingTab.panelIDs[0], fixture: fixture)
        try assertSpatialJump(to: parentTab.panelIDs[0], fixture: fixture)
    }

    func testUnreadBelowCurrentWorkspacePrecedesWrappedNonSessionUnread() throws {
        let currentTab = makeUnreadCommandTab(focusedPanelIndex: 1, unreadPanelIndices: [0])
        let belowTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [2])
        let current = makeUnreadCommandWorkspace(title: "Current", tabs: [currentTab], selectedTabIndex: 0)
        let below = makeUnreadCommandWorkspace(title: "Below", tabs: [belowTab], selectedTabIndex: 0)
        let fixture = makeSpatialFixture(workspaces: [current, below])

        try assertSpatialJump(to: belowTab.panelIDs[2], fixture: fixture)
        try assertSpatialJump(to: currentTab.panelIDs[0], fixture: fixture)
        XCTAssertTrue(fixture.store.state.workspacesByID[current.id]?.unreadPanelIDs.isEmpty == true)
        XCTAssertTrue(fixture.store.state.workspacesByID[below.id]?.unreadPanelIDs.isEmpty == true)
    }

    func testJumpUsesDisplayedSubspaceOrderWhileRowsArePinnedOrFrozen() throws {
        let parentTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let firstTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let secondTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let parent = makeUnreadCommandWorkspace(title: "Parent", tabs: [parentTab], selectedTabIndex: 0)
        var first = makeUnreadCommandWorkspace(title: "First", tabs: [firstTab], selectedTabIndex: 0)
        var second = makeUnreadCommandWorkspace(title: "Second", tabs: [secondTab], selectedTabIndex: 0)
        first.parentWorkspaceID = parent.id
        second.parentWorkspaceID = parent.id
        let fixture = makeSpatialFixture(workspaces: [parent, first, second])
        startSpatialSessions([parentTab.panelIDs[0]], workspace: parent, fixture: fixture)
        startSpatialSessions([firstTab.panelIDs[0]], workspace: first, fixture: fixture)
        startSpatialSessions([secondTab.panelIDs[0]], workspace: second, fixture: fixture)
        fixture.store.recordSidebarSubspaceOrder([UUID(), second.id, second.id], parentWorkspaceID: parent.id)

        try assertSpatialJump(to: secondTab.panelIDs[0], fixture: fixture)
        try assertSpatialJump(to: firstTab.panelIDs[0], fixture: fixture)
        try assertSpatialJump(to: parentTab.panelIDs[0], fixture: fixture)
        fixture.store.clearSidebarSubspaceOrder(parentWorkspaceID: parent.id)
        try assertSpatialJump(to: firstTab.panelIDs[0], fixture: fixture)
    }

    func testUnreadSessionsFollowCustomOrderBeforeReadWorkingSession() throws {
        let tab = makeUnreadCommandTab(focusedPanelIndex: 1, unreadPanelIndices: [])
        var workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
        workspace.sidebarSessionPanelOrder = [tab.panelIDs[2], tab.panelIDs[1], tab.panelIDs[0]]
        let fixture = makeSpatialFixture(workspaces: [workspace])
        startSpatialSessions(tab.panelIDs, workspace: workspace, fixture: fixture)
        fixture.store.send(.recordDesktopNotification(workspaceID: workspace.id, panelID: tab.panelIDs[0]))
        fixture.store.send(.recordDesktopNotification(workspaceID: workspace.id, panelID: tab.panelIDs[2]))

        try assertSpatialJump(to: tab.panelIDs[0], fixture: fixture)
        try assertSpatialJump(to: tab.panelIDs[2], fixture: fixture)
    }

    func testCycleRebuildsAfterSidebarSessionReorder() throws {
        let tab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
        let fixture = makeSpatialFixture(workspaces: [workspace])
        startSpatialSessions(tab.panelIDs, workspace: workspace, fixture: fixture)
        try assertSpatialJump(to: tab.panelIDs[1], fixture: fixture)

        fixture.store.send(.moveSidebarSession(
            workspaceID: workspace.id,
            panelID: tab.panelIDs[0],
            targetPanelID: tab.panelIDs[1],
            placeAfter: true,
            visiblePanelIDs: tab.panelIDs
        ))

        try assertSpatialJump(to: tab.panelIDs[0], fixture: fixture)
        try assertSpatialJump(to: tab.panelIDs[2], fixture: fixture)
    }

    func testReadApprovalAndLaterSessionsEachFollowSidebarOrder() throws {
        for kind in [SessionStatusKind.needsApproval, .idle] {
            let tab = makeUnreadCommandTab(focusedPanelIndex: 1, unreadPanelIndices: [])
            var workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
            workspace.sidebarSessionPanelOrder = [tab.panelIDs[2], tab.panelIDs[1], tab.panelIDs[0]]
            let fixture = makeSpatialFixture(workspaces: [workspace])
            startSpatialSessions(tab.panelIDs, workspace: workspace, fixture: fixture, kind: kind)
            if kind == .idle {
                for panelID in tab.panelIDs {
                    fixture.sessions.setLaterFlag(sessionID: panelID.uuidString, isFlagged: true)
                }
            }

            try assertSpatialJump(to: tab.panelIDs[0], fixture: fixture)
            try assertSpatialJump(to: tab.panelIDs[2], fixture: fixture)
        }
    }

    func testPlainTerminalStartsAtFirstSessionRowAndRetainsNonSessionUnread() throws {
        let tab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [1])
        let workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
        let fixture = makeSpatialFixture(workspaces: [workspace])
        startSpatialSessions([tab.panelIDs[2]], workspace: workspace, fixture: fixture)

        try assertSpatialJump(to: tab.panelIDs[1], fixture: fixture)
        try assertSpatialJump(to: tab.panelIDs[2], fixture: fixture)
    }

    func testNavigationUsesSidebarRowsAndKeepsNonSessionPanelsWhenRowsAreStale() throws {
        let tab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [1])
        var workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
        let stalePanelID = UUID()
        workspace.sidebarSessionPanelOrder = [stalePanelID, tab.panelIDs[2], tab.panelIDs[0]]
        let fixture = makeSpatialFixture(workspaces: [workspace])
        startSpatialSessions([tab.panelIDs[0], tab.panelIDs[2]], workspace: workspace, fixture: fixture)
        var registry = fixture.sessions.sessionRegistry
        registry.startSession(
            sessionID: "stale",
            agent: .codex,
            panelID: stalePanelID,
            windowID: fixture.windowID,
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Date()
        )
        let order = SidebarPanelNavigationOrder(
            state: fixture.store.state,
            sessionRegistry: registry,
            displayedSubspaceOrderByParentID: [:],
            windowID: fixture.windowID,
            workspaceID: workspace.id,
            focusedPanelID: nil
        ).all.map(\.panelID)
        let sidebarRows = SidebarSessionPresentation.orderedStatuses(
            fixture.sessions.workspaceStatuses(for: workspace.id),
            panelOrder: workspace.sidebarSessionPanelOrder
        ).map(\.panelID)

        XCTAssertEqual(Array(order.prefix(sidebarRows.count)), sidebarRows)
        XCTAssertEqual(Set(order), Set(tab.panelIDs))
        XCTAssertEqual(order.count, tab.panelIDs.count)
        try assertSpatialJump(to: tab.panelIDs[1], fixture: fixture)
    }

    func testMenuAvailabilityAgreesForSessionAndNonSessionUnreadTargets() throws {
        let tab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [1])
        let workspace = makeUnreadCommandWorkspace(title: "Sessions", tabs: [tab], selectedTabIndex: 0)
        let fixture = makeSpatialFixture(workspaces: [workspace])
        startSpatialSessions([tab.panelIDs[2]], workspace: workspace, fixture: fixture)

        for (expectedAvailability, targetPanelID) in [(true, tab.panelIDs[1]), (true, tab.panelIDs[2]), (false, tab.panelIDs[2])] {
            // Compare presence checks from a fresh cycle. A retained cycle
            // can return its sole entry again after reaching that entry.
            fixture.store.replaceState(fixture.store.state)
            let state = fixture.store.state
            let selection = WindowCommandSelection(
                windowID: fixture.windowID,
                window: try XCTUnwrap(state.window(id: fixture.windowID)),
                workspace: try XCTUnwrap(state.workspacesByID[workspace.id])
            )
            XCTAssertEqual(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
                state: state,
                commandSelection: selection,
                activePanelIDs: [tab.panelIDs[2]]
            ), expectedAvailability)
            XCTAssertEqual(fixture.store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: fixture.windowID,
                sessionRuntimeStore: fixture.sessions
            ), expectedAvailability)
            if expectedAvailability {
                try assertSpatialJump(to: targetPanelID, fixture: fixture)
            }
        }
    }

    func testOtherWindowsFollowStoredWindowOrderBeforeCurrentWindowWrap() throws {
        let tabs = (0 ..< 3).map { _ in makeUnreadCommandTab(focusedPanelIndex: 1, unreadPanelIndices: []) }
        let workspaces = tabs.enumerated().map { index, tab in
            makeUnreadCommandWorkspace(title: "Window \(index)", tabs: [tab], selectedTabIndex: 0)
        }
        let windows = workspaces.map { workspace in
            WindowState(
                id: UUID(),
                frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                workspaceIDs: [workspace.id],
                selectedWorkspaceID: workspace.id
            )
        }
        let state = AppState(
            windows: windows,
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            selectedWindowID: windows[1].id
        )
        let targets = SidebarPanelNavigationOrder(
            state: state,
            sessionRegistry: nil,
            displayedSubspaceOrderByParentID: [:],
            windowID: windows[1].id,
            workspaceID: workspaces[1].id,
            focusedPanelID: tabs[1].panelIDs[1]
        )

        XCTAssertEqual(targets.forward.map(\.panelID), [tabs[1].panelIDs[2]] + tabs[2].panelIDs + tabs[0].panelIDs)
        XCTAssertEqual(targets.wrapped.map(\.panelID), [tabs[1].panelIDs[0]])
    }

    func testEmptyFocusedWorkspaceStartsBelowItBeforeWrapping() throws {
        let aboveTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        var emptyTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        emptyTab.tab.panels.removeAll()
        emptyTab.tab.focusedPanelID = nil
        let belowTab = makeUnreadCommandTab(focusedPanelIndex: 0, unreadPanelIndices: [])
        let workspaces = [aboveTab, emptyTab, belowTab].enumerated().map { index, tab in
            makeUnreadCommandWorkspace(title: "Workspace \(index)", tabs: [tab], selectedTabIndex: 0)
        }
        let fixture = makeSpatialFixture(workspaces: workspaces)
        let order = SidebarPanelNavigationOrder(
            state: fixture.store.state,
            sessionRegistry: nil,
            displayedSubspaceOrderByParentID: [:],
            windowID: fixture.windowID,
            workspaceID: workspaces[1].id,
            focusedPanelID: nil
        )

        XCTAssertEqual(order.forward.map(\.panelID), belowTab.panelIDs)
        XCTAssertEqual(order.wrapped.map(\.panelID), aboveTab.panelIDs)
    }

    private struct SpatialFixture {
        let store: AppStore
        let sessions: SessionRuntimeStore
        let windowID: UUID
    }

    private func makeSpatialFixture(workspaces: [WorkspaceState]) -> SpatialFixture {
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: workspaces.map(\.id),
                    selectedWorkspaceID: workspaces[0].id
                )],
                workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let sessions = SessionRuntimeStore()
        sessions.bind(store: store)
        return SpatialFixture(store: store, sessions: sessions, windowID: windowID)
    }

    private func startSpatialSessions(
        _ panelIDs: [UUID],
        workspace: WorkspaceState,
        fixture: SpatialFixture,
        kind: SessionStatusKind = .working
    ) {
        for (index, panelID) in panelIDs.enumerated() {
            let startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            fixture.sessions.startSession(
                sessionID: panelID.uuidString,
                agent: .codex,
                panelID: panelID,
                windowID: fixture.windowID,
                workspaceID: workspace.id,
                cwd: "/repo",
                repoRoot: "/repo",
                at: startedAt
            )
            fixture.sessions.updateStatus(
                sessionID: panelID.uuidString,
                status: SessionStatus(kind: kind, summary: "Session", detail: "Navigation fixture"),
                at: startedAt.addingTimeInterval(0.5)
            )
            fixture.store.send(.markPanelNotificationsRead(workspaceID: workspace.id, panelID: panelID))
        }
    }

    private func assertSpatialJump(
        to panelID: UUID,
        fixture: SpatialFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(fixture.store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: fixture.windowID,
            sessionRuntimeStore: fixture.sessions
        ), file: file, line: line)
        let selection = try XCTUnwrap(fixture.store.state.selectedWorkspaceSelection(), file: file, line: line)
        XCTAssertEqual(selection.workspace.focusedPanelID, panelID, file: file, line: line)
        XCTAssertEqual(selection.workspace.resolvedSelectedTabID, selection.workspace.tabID(containingPanelID: panelID), file: file, line: line)
    }
}
