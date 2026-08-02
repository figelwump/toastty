import CoreState
import Foundation
import Testing

extension AppReducerTests {
    @Test
    func closingRightPanelTabClearsUnreadNotificationForPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let rightTabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])

        #expect(reducer.send(.closeRightAuxPanelTab(workspaceID: workspaceID, tabID: rightTabID), state: &state))
        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.unreadPanelIDs.isEmpty)

        try StateValidator.validate(state)
    }

    @Test
    func settingRightPanelWidthMarksWidthAsUserCustom() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .setRightAuxPanelWidth(
                    workspaceID: workspaceID,
                    width: RightAuxPanelState.defaultWidth
                ),
                state: &state
            )
        )

        let workspaceAfterResize = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterResize.rightAuxPanel.width == RightAuxPanelState.defaultWidth)
        #expect(workspaceAfterResize.rightAuxPanel.hasCustomWidth)
        #expect(
            reducer.send(
                .setRightAuxPanelWidth(
                    workspaceID: workspaceID,
                    width: RightAuxPanelState.defaultWidth
                ),
                state: &state
            ) == false
        )

        try StateValidator.validate(state)
    }

    @Test
    func togglingEmptyRightPanelShowsAndHidesPanelShell() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleRightAuxPanel(workspaceID: workspaceID), state: &state))
        var workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.isVisible)
        #expect(workspace.rightAuxPanel.tabIDs.isEmpty)

        #expect(reducer.send(.toggleRightAuxPanel(workspaceID: workspaceID), state: &state))
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.isVisible == false)
        #expect(workspace.rightAuxPanel.tabIDs.isEmpty)

        try StateValidator.validate(state)
    }

    @Test
    func settingEmptyRightPanelVisibilityShowsPanelShell() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.setRightAuxPanelVisibility(workspaceID: workspaceID, isVisible: true), state: &state))

        let workspaceAfterShow = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterShow.rightAuxPanel.isVisible)
        #expect(workspaceAfterShow.rightAuxPanel.tabIDs.isEmpty)

        try StateValidator.validate(state)
    }

    @Test
    func showingRightPanelFocusesActiveTabWhenPresent() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let rightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

        #expect(reducer.send(.toggleRightAuxPanel(workspaceID: workspaceID), state: &state))
        var workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.isVisible == false)
        #expect(workspace.rightAuxPanel.focusedPanelID == nil)

        #expect(reducer.send(.toggleRightAuxPanel(workspaceID: workspaceID), state: &state))
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.isVisible)
        #expect(workspace.rightAuxPanel.focusedPanelID == rightPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func focusSlotCyclesThroughVisibleRightPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let mainPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let rightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: mainPanelID), state: &state))

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state))
        var workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.focusedPanelID == mainPanelID)
        #expect(workspace.rightAuxPanel.focusedPanelID == rightPanelID)

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state))
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.focusedPanelID == mainPanelID)
        #expect(workspace.rightAuxPanel.focusedPanelID == nil)

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .previous), state: &state))
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.focusedPanelID == rightPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func directionalFocusMovesBetweenMainPaneAndRightPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let mainPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let rightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: mainPanelID), state: &state))

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .right), state: &state))
        var workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.focusedPanelID == rightPanelID)

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .left), state: &state))
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.focusedPanelID == mainPanelID)
        #expect(workspace.rightAuxPanel.focusedPanelID == nil)

        try StateValidator.validate(state)
    }

    @Test
    func selectingAdjacentRightPanelTabFocusesWrappedTarget() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "First docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let firstTabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)
        let firstPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Second docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let secondTabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)
        #expect(secondTabID != firstTabID)

        #expect(
            reducer.send(
                .selectAdjacentRightAuxPanelTab(workspaceID: workspaceID, direction: .previous),
                state: &state
            )
        )
        var workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.activeTabID == firstTabID)
        #expect(workspace.rightAuxPanel.focusedPanelID == firstPanelID)

        #expect(
            reducer.send(
                .selectAdjacentRightAuxPanelTab(workspaceID: workspaceID, direction: .previous),
                state: &state
            )
        )
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.activeTabID == secondTabID)

        try StateValidator.validate(state)
    }

    @Test
    func emptyRightPanelShellDoesNotLeakAcrossWorkspaceTabs() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let firstMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        #expect(reducer.send(.toggleRightAuxPanel(workspaceID: workspaceID), state: &state))
        var workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.resolvedSelectedTabID == firstMainTabID)
        #expect(workspace.rightAuxPanel.isVisible)
        #expect(workspace.rightAuxPanel.tabIDs.isEmpty)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let secondMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        #expect(secondMainTabID != firstMainTabID)
        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Second tab docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.resolvedSelectedTabID == secondMainTabID)
        #expect(workspace.rightAuxPanel.isVisible)
        #expect(workspace.rightAuxPanel.tabIDs.count == 1)

        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: firstMainTabID), state: &state))
        workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.rightAuxPanel.isVisible)
        #expect(workspace.rightAuxPanel.tabIDs.isEmpty)

        try StateValidator.validate(state)
    }

    @Test
    func closingFinalRightPanelTabKeepsPanelShellVisible() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        let tabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)
        #expect(reducer.send(.closeRightAuxPanelTab(workspaceID: workspaceID, tabID: tabID), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.rightAuxPanel.isVisible)
        #expect(workspaceAfter.rightAuxPanel.tabIDs.isEmpty)
        #expect(workspaceAfter.rightAuxPanel.activeTabID == nil)

        try StateValidator.validate(state)
    }

    @Test
    func closingBackgroundRightPanelTabClosesOwningWorkspaceTabPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let firstMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "First tab docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let firstRightTabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let secondMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        #expect(secondMainTabID != firstMainTabID)
        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Second tab docs"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        #expect(reducer.send(.closeRightAuxPanelTab(workspaceID: workspaceID, tabID: firstRightTabID), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.resolvedSelectedTabID == secondMainTabID)
        #expect(workspaceAfterClose.tab(id: firstMainTabID)?.rightAuxPanel.tabIDs.isEmpty == true)
        #expect(workspaceAfterClose.tab(id: firstMainTabID)?.rightAuxPanel.isVisible == true)
        #expect(workspaceAfterClose.tab(id: secondMainTabID)?.rightAuxPanel.tabIDs.count == 1)

        try StateValidator.validate(state)
    }

    @Test
    func repeatedSplitRightWebPanelCreationAddsDistinctPanes() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let leafCountBefore = try #require(state.workspacesByID[workspaceID]?.layoutTree.allSlotInfos.count)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "First Browser"),
                    placement: .splitRight
                ),
                state: &state
            )
        )
        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Second Browser"),
                    placement: .splitRight
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree.allSlotInfos.count == leafCountBefore + 2)
        let webPanelIDs = workspaceAfter.panels.compactMap { panelID, panelState -> UUID? in
            if case .web = panelState {
                return panelID
            }
            return nil
        }
        #expect(Set(webPanelIDs).count == 2)

        try StateValidator.validate(state)
    }

    @Test
    func updateWebPanelMetadataRefreshesTitleAndCurrentURLWithoutChangingInitialURL() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .browser,
                        initialURL: "https://example.com/original",
                        browserPageZoom: 1.25
                    ),
                    placement: .splitRight
                ),
                state: &state
            )
        )

        let browserPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(
            reducer.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: "Example Domain",
                    url: "https://example.com"
                ),
                state: &state
            )
        )

        let workspaceAfterUpdate = try #require(state.workspacesByID[workspaceID])
        guard case .web(let webState) = workspaceAfterUpdate.panels[browserPanelID] else {
            Issue.record("expected updated panel to remain web-backed")
            return
        }

        #expect(webState.title == "Example Domain")
        #expect(webState.initialURL == "https://example.com/original")
        #expect(webState.currentURL == "https://example.com")
        #expect(webState.restorableURL == "https://example.com")
        #expect(webState.browserPageZoom == 1.25)

        #expect(
            reducer.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: nil,
                    url: "https://example.com/no-title"
                ),
                state: &state
            )
        )

        let workspaceAfterUntitled = try #require(state.workspacesByID[workspaceID])
        guard case .web(let untitledWebState) = workspaceAfterUntitled.panels[browserPanelID] else {
            Issue.record("expected web panel after untitled-title update")
            return
        }

        #expect(untitledWebState.title == "Browser")
        #expect(untitledWebState.initialURL == "https://example.com/original")
        #expect(untitledWebState.currentURL == "https://example.com/no-title")
        #expect(untitledWebState.restorableURL == "https://example.com/no-title")
        #expect(untitledWebState.browserPageZoom == 1.25)

        #expect(
            reducer.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: nil,
                    url: "about:blank"
                ),
                state: &state
            )
        )

        let workspaceAfterBlank = try #require(state.workspacesByID[workspaceID])
        guard case .web(let blankWebState) = workspaceAfterBlank.panels[browserPanelID] else {
            Issue.record("expected web panel after blank-url normalization")
            return
        }

        #expect(blankWebState.title == "Browser")
        #expect(blankWebState.initialURL == "https://example.com/original")
        #expect(blankWebState.currentURL == "about:blank")
        #expect(blankWebState.restorableURL == "about:blank")
        #expect(blankWebState.browserPageZoom == 1.25)

        try StateValidator.validate(state)
    }

    @Test
    func browserPageZoomActionsAdjustAndResetPanelState() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser),
                    placement: .splitRight
                ),
                state: &state
            )
        )

        let browserPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.increaseBrowserPanelPageZoom(panelID: browserPanelID), state: &state))
        guard case .web(let increasedWebState) = state.workspacesByID[workspaceID]?.panels[browserPanelID] else {
            Issue.record("expected browser panel after zoom increase")
            return
        }
        #expect(increasedWebState.effectiveBrowserPageZoom == 1.1)

        #expect(reducer.send(.setBrowserPanelPageZoom(panelID: browserPanelID, zoom: 1.25), state: &state))
        guard case .web(let customZoomWebState) = state.workspacesByID[workspaceID]?.panels[browserPanelID] else {
            Issue.record("expected browser panel after custom zoom")
            return
        }
        #expect(customZoomWebState.browserPageZoom == 1.25)

        #expect(reducer.send(.decreaseBrowserPanelPageZoom(panelID: browserPanelID), state: &state))
        guard case .web(let decreasedWebState) = state.workspacesByID[workspaceID]?.panels[browserPanelID] else {
            Issue.record("expected browser panel after zoom decrease")
            return
        }
        #expect(decreasedWebState.effectiveBrowserPageZoom == 1.1)

        #expect(reducer.send(.resetBrowserPanelPageZoom(panelID: browserPanelID), state: &state))
        guard case .web(let resetWebState) = state.workspacesByID[workspaceID]?.panels[browserPanelID] else {
            Issue.record("expected browser panel after zoom reset")
            return
        }
        #expect(resetWebState.browserPageZoom == nil)
        #expect(resetWebState.effectiveBrowserPageZoom == WebPanelState.defaultBrowserPageZoom)

        try StateValidator.validate(state)
    }

}
