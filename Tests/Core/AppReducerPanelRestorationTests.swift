import CoreState
import Foundation
import Testing

extension AppReducerTests {
    @Test
    func closeAndReopenPanelRestoresPanelState() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let slotID = try #require(state.workspacesByID[workspaceID]?.layoutTree.allSlotInfos.first?.slotID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))
        let panelToClose = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let panelStateBeforeClose = try #require(state.workspacesByID[workspaceID]?.panels[panelToClose])

        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))
        let afterCloseWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(afterCloseWorkspace.panels[panelToClose] == nil)
        #expect(afterCloseWorkspace.recentlyClosedPanels.count == 1)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))
        let reopenedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(reopenedWorkspace.recentlyClosedPanels.isEmpty)
        let reopenedPanelID = try #require(reopenedWorkspace.focusedPanelID)
        let reopenedPanelState = try #require(reopenedWorkspace.panels[reopenedPanelID])
        #expect(reopenedPanelState == panelStateBeforeClose)

        try StateValidator.validate(state)
    }

    @Test
    func closeFocusedPanelSelectsPreviousSlotInTraversalOrder() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))

        let workspaceBeforeClose = try #require(state.workspacesByID[workspaceID])
        let leavesBeforeClose = workspaceBeforeClose.layoutTree.allSlotInfos
        #expect(leavesBeforeClose.count == 3)
        let focusedPanelID = try #require(workspaceBeforeClose.focusedPanelID)
        let lastLeafPanelID = try #require(leavesBeforeClose.last?.panelID)
        let expectedFocusedPanelID = leavesBeforeClose[1].panelID
        #expect(focusedPanelID == lastLeafPanelID)

        #expect(reducer.send(.closePanel(panelID: focusedPanelID), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.panels[focusedPanelID] == nil)
        #expect(workspaceAfterClose.focusedPanelID == expectedFocusedPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func closeFocusedPanelInFirstSlotWrapsToLastSlot() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))

        let workspaceBeforeFocus = try #require(state.workspacesByID[workspaceID])
        let leavesBeforeClose = workspaceBeforeFocus.layoutTree.allSlotInfos
        #expect(leavesBeforeClose.count == 3)

        let panelToClose = try #require(leavesBeforeClose.first?.panelID)
        let expectedFocusedPanelID = try #require(leavesBeforeClose.last?.panelID)
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: panelToClose), state: &state))
        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.panels[panelToClose] == nil)
        #expect(workspaceAfterClose.focusedPanelID == expectedFocusedPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func closeFocusedPanelCreatedBySplitReturnsFocusToSiblingPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let slotID = try #require(state.workspacesByID[workspaceID]?.layoutTree.allSlotInfos.first?.slotID)
        let originalFocusedPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))
        let panelToClose = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.focusedPanelID == originalFocusedPanelID)
        #expect(workspaceAfterClose.panels[panelToClose] == nil)

        try StateValidator.validate(state)
    }

    @Test
    func closeNonFocusedPanelPreservesCurrentFocus() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let slotID = try #require(state.workspacesByID[workspaceID]?.layoutTree.allSlotInfos.first?.slotID)
        let focusedPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))
        let panelToClose = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: focusedPanelID), state: &state))
        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.focusedPanelID == focusedPanelID)
        #expect(workspaceAfterClose.panels[panelToClose] == nil)

        try StateValidator.validate(state)
    }

    @Test
    func closeAndReopenWebPanelRestoresPanelState() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .browser,
                        title: "Review",
                        initialURL: "https://example.com/review",
                        browserPageZoom: 1.25
                    ),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let browserPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let panelStateBeforeClose = try #require(state.workspacesByID[workspaceID]?.panels[browserPanelID])

        #expect(reducer.send(.closePanel(panelID: browserPanelID), state: &state))
        let afterClose = try #require(state.workspacesByID[workspaceID])
        #expect(afterClose.recentlyClosedPanels.count == 1)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))
        let afterReopen = try #require(state.workspacesByID[workspaceID])
        let reopenedPanelID = try #require(afterReopen.focusedPanelID)
        let reopenedPanelState = try #require(afterReopen.panels[reopenedPanelID])
        #expect(reopenedPanelState == panelStateBeforeClose)

        try StateValidator.validate(state)
    }

    @Test
    func closeSinglePanelWebTabReopensAsRestoredTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let originalTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .browser,
                        title: "Docs",
                        initialURL: "https://example.com/docs",
                        browserPageZoom: 1.5
                    ),
                    placement: .newTab
                ),
                state: &state
            )
        )

        let browserTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(
                    workspaceID: workspaceID,
                    tabID: browserTabID,
                    title: "Pinned Docs"
                ),
                state: &state
            )
        )
        let browserPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let browserState = try #require(state.workspacesByID[workspaceID]?.panels[browserPanelID])

        #expect(reducer.send(.closePanel(panelID: browserPanelID), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.tabIDs == [originalTabID])
        #expect(workspaceAfterClose.recentlyClosedPanels.count == 1)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))

        let workspaceAfterReopen = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterReopen.tabIDs.count == 2)
        #expect(workspaceAfterReopen.tabIDs == [originalTabID, browserTabID])
        #expect(workspaceAfterReopen.resolvedSelectedTabID == browserTabID)

        let reopenedTab = try #require(workspaceAfterReopen.tab(id: browserTabID))
        #expect(reopenedTab.customTitle == "Pinned Docs")
        let reopenedPanelID = try #require(reopenedTab.focusedPanelID)
        let reopenedPanelState = try #require(reopenedTab.panels[reopenedPanelID])
        #expect(reopenedPanelState == browserState)
        #expect(workspaceAfterReopen.recentlyClosedPanels.isEmpty)

        try StateValidator.validate(state)
    }

    @Test
    func reopenRestoredTabInsertsBeforeRecordedSuccessorWhenOriginalIndexIsStale() throws {
        let workspaceID = UUID()
        let sourceTabID = UUID()
        let predecessorTabID = UUID()
        let successorTabID = UUID()
        let successorPanelID = UUID()
        let successorSlotID = UUID()
        let reopenedSlotID = UUID()

        let successorTab = WorkspaceTabState(
            id: successorTabID,
            customTitle: "Workspace C",
            layoutTree: .slot(slotID: successorSlotID, panelID: successorPanelID),
            panels: [
                successorPanelID: .terminal(
                    TerminalPanelState(title: "Terminal C", shell: "zsh", cwd: "/tmp/c")
                ),
            ],
            focusedPanelID: successorPanelID,
            recentlyClosedPanels: [
                ClosedPanelRecord(
                    panelState: .web(
                        WebPanelState(
                            definition: .browser,
                            title: "Workspace B",
                            initialURL: "https://example.com/b"
                        )
                    ),
                    closedAt: Date(timeIntervalSince1970: 1_710_000_001),
                    sourceSlotID: reopenedSlotID,
                    sourceTabID: sourceTabID,
                    sourceTabIndex: 1,
                    sourceTabPredecessorID: predecessorTabID,
                    sourceTabSuccessorID: successorTabID,
                    sourceTabCustomTitle: "Workspace B"
                ),
            ]
        )

        var state = AppState(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: WorkspaceState(
                    id: workspaceID,
                    title: "Docs",
                    selectedTabID: successorTabID,
                    tabIDs: [successorTabID],
                    tabsByID: [successorTabID: successorTab]
                ),
            ],
            selectedWindowID: nil,
            configuredTerminalFontPoints: nil
        )
        let reducer = AppReducer()

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.tabIDs == [sourceTabID, successorTabID])
        let restoredTab = try #require(workspace.tab(id: sourceTabID))
        #expect(restoredTab.customTitle == "Workspace B")
        let restoredPanelID = try #require(restoredTab.focusedPanelID)
        guard case .web(let webState) = restoredTab.panels[restoredPanelID] else {
            Issue.record("Expected reopened tab to contain the closed browser panel")
            return
        }
        #expect(webState.initialURL == "https://example.com/b")

        try StateValidator.validate(state)
    }

    @Test
    func reopenFallsBackToFocusedSlotWhenOriginalSlotWasRemoved() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let sourcePane = try #require(workspace.layoutTree.allSlotInfos.first)
        let panelToClose = sourcePane.panelID

        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))
        let collapsedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(collapsedWorkspace.layoutTree.allSlotInfos.count == 1)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))
        let reopenedWorkspace = try #require(state.workspacesByID[workspaceID])
        let reopenedLeaves = reopenedWorkspace.layoutTree.allSlotInfos
        #expect(reopenedLeaves.count == 2)
        let reopenedPanelID = try #require(reopenedWorkspace.focusedPanelID)
        #expect(reopenedLeaves.contains(where: { $0.panelID == reopenedPanelID }))

        try StateValidator.validate(state)
    }

    @Test
    func reopenClosedBrowserCreatesSeparateInstanceWhenAnotherBrowserIsVisible() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Original Browser"),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let originalBrowserID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.closePanel(panelID: originalBrowserID), state: &state))
        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "New Browser"),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        let visibleBrowserID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        let browserPanelIDs = workspace.panels.compactMap { panelID, panelState -> UUID? in
            if case .web = panelState {
                return panelID
            }
            return nil
        }
        #expect(browserPanelIDs.count == 2)
        #expect(browserPanelIDs.contains(visibleBrowserID))
        #expect(workspace.recentlyClosedPanels.isEmpty)

        try StateValidator.validate(state)
    }

}
