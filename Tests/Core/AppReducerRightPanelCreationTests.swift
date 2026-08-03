import CoreState
import Foundation
import Testing

extension AppReducerTests {
    @Test
    func createWebPanelInNewTabCreatesSelectedTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let tabCountBefore = workspaceBefore.tabIDs.count

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, initialURL: "https://example.com"),
                    placement: .newTab
                ),
                state: &state
            )
        )

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.tabIDs.count == tabCountBefore + 1)
        let selectedTabID = try #require(workspace.selectedTabID)
        let selectedTab = try #require(workspace.tab(id: selectedTabID))
        #expect(selectedTab.panels.count == 1)

        let panelID = try #require(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            Issue.record("expected selected tab panel to be web")
            return
        }
        #expect(webState.definition == .browser)
        #expect(webState.initialURL == "https://example.com")
        #expect(webState.currentURL == nil)

        try StateValidator.validate(state)
    }

    @Test
    func createWebPanelSplitRightAddsPaneAndFocusesIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let originalPanelID = try #require(workspaceBefore.focusedPanelID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, initialURL: "https://example.com/docs"),
                    placement: .splitRight
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree.allSlotInfos.count == 2)
        let focusedPanelID = try #require(workspaceAfter.focusedPanelID)
        #expect(focusedPanelID != originalPanelID)
        guard case .web(let webState) = workspaceAfter.panels[focusedPanelID] else {
            Issue.record("expected focused panel to be web")
            return
        }

        #expect(webState.definition == .browser)
        #expect(webState.initialURL == "https://example.com/docs")
        #expect(webState.currentURL == nil)

        try StateValidator.validate(state)
    }

    @Test
    func createWebPanelRightPanelDoesNotMutateMainLayoutOrFocus() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let selectedTabIDBefore = workspaceBefore.selectedTabID
        let focusedPanelIDBefore = workspaceBefore.focusedPanelID
        let layoutTreeBefore = workspaceBefore.layoutTree
        let leafCountBefore = workspaceBefore.layoutTree.allSlotInfos.count
        let mainPanelCountBefore = workspaceBefore.panels.count

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, initialURL: "https://example.com/root"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.selectedTabID == selectedTabIDBefore)
        #expect(workspaceAfter.focusedPanelID == focusedPanelIDBefore)
        #expect(workspaceAfter.layoutTree == layoutTreeBefore)
        #expect(workspaceAfter.layoutTree.allSlotInfos.count == leafCountBefore)
        #expect(workspaceAfter.panels.count == mainPanelCountBefore)
        #expect(workspaceAfter.rightAuxPanel.isVisible)
        #expect(workspaceAfter.rightAuxPanel.tabIDs.count == 1)

        let rightPanelTab = try #require(workspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            Issue.record("expected right-panel tab to contain the browser panel")
            return
        }

        #expect(webState.initialURL == "https://example.com/root")
        #expect(webState.currentURL == nil)
        #expect(workspaceAfter.panelState(for: rightPanelTab.panelID) == rightPanelTab.panelState)
        #expect(workspaceAfter.slotID(containingPanelID: rightPanelTab.panelID) == nil)

        try StateValidator.validate(state)
    }

    @Test
    func createRightAuxWebPanelRevealTargetsBackgroundTabWithoutChangingSelectionOrFocus() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let sourceTabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Existing"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let sourceTabBeforeSwitch = try #require(state.workspacesByID[workspaceID]?.tab(id: sourceTabID))
        let existingRightAuxPanelID = try #require(sourceTabBeforeSwitch.rightAuxPanel.activePanelID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let selectedTabIDBefore = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        #expect(selectedTabIDBefore != sourceTabID)
        let selectedTabBefore = try #require(state.workspacesByID[workspaceID]?.tab(id: selectedTabIDBefore))
        let focusedPanelIDBefore = selectedTabBefore.focusedPanelID
        let backgroundPanelID = UUID()

        #expect(
            reducer.send(
                .createRightAuxWebPanel(
                    workspaceID: workspaceID,
                    tabID: sourceTabID,
                    panelID: backgroundPanelID,
                    panel: WebPanelState(definition: .browser, title: "Background"),
                    activation: .reveal
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let sourceTabAfter = try #require(workspaceAfter.tab(id: sourceTabID))
        let selectedTabAfter = try #require(workspaceAfter.tab(id: selectedTabIDBefore))
        let backgroundPanelState = try #require(sourceTabAfter.rightAuxPanel.panelState(for: backgroundPanelID))
        guard case .web(let webState) = backgroundPanelState else {
            Issue.record("expected targeted right-aux panel to be web")
            return
        }

        #expect(workspaceAfter.selectedTabID == selectedTabIDBefore)
        #expect(selectedTabAfter.focusedPanelID == focusedPanelIDBefore)
        #expect(sourceTabAfter.rightAuxPanel.isVisible)
        #expect(sourceTabAfter.rightAuxPanel.activePanelID == backgroundPanelID)
        #expect(sourceTabAfter.rightAuxPanel.focusedPanelID == nil)
        #expect(sourceTabAfter.rightAuxPanel.panelState(for: existingRightAuxPanelID) != nil)
        #expect(webState.title == "Background")

        try StateValidator.validate(state)
    }

    @Test
    func revealRightAuxPanelTargetsBackgroundTabWithoutChangingSelectionOrFocus() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let sourceTabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .scratchpad, title: "Scratchpad"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let sourceTabBeforeSwitch = try #require(state.workspacesByID[workspaceID]?.tab(id: sourceTabID))
        let scratchpadPanelID = try #require(sourceTabBeforeSwitch.rightAuxPanel.activePanelID)
        #expect(reducer.send(.setRightAuxPanelVisibility(workspaceID: workspaceID, isVisible: false), state: &state))

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let selectedTabIDBefore = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        #expect(selectedTabIDBefore != sourceTabID)
        let selectedTabBefore = try #require(state.workspacesByID[workspaceID]?.tab(id: selectedTabIDBefore))
        let focusedPanelIDBefore = selectedTabBefore.focusedPanelID

        #expect(
            reducer.send(
                .revealRightAuxPanel(
                    workspaceID: workspaceID,
                    panelID: scratchpadPanelID
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let sourceTabAfter = try #require(workspaceAfter.tab(id: sourceTabID))
        let selectedTabAfter = try #require(workspaceAfter.tab(id: selectedTabIDBefore))

        #expect(workspaceAfter.selectedTabID == selectedTabIDBefore)
        #expect(selectedTabAfter.focusedPanelID == focusedPanelIDBefore)
        #expect(sourceTabAfter.rightAuxPanel.isVisible)
        #expect(sourceTabAfter.rightAuxPanel.activePanelID == scratchpadPanelID)
        #expect(sourceTabAfter.rightAuxPanel.focusedPanelID == nil)

        try StateValidator.validate(state)
    }

    @Test
    func legacyRootRightPlacementAliasesRightPanel() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Legacy Browser"),
                    placement: .rootRight
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree == workspaceBefore.layoutTree)
        #expect(workspaceAfter.rightAuxPanel.tabIDs.count == 1)
        let rightPanelTab = try #require(workspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            Issue.record("expected right-panel tab to contain the browser panel")
            return
        }
        #expect(webState.title == "Legacy Browser")

        try StateValidator.validate(state)
    }

    @Test
    func repeatedRightPanelBrowserCreationAddsScopedTabsWithoutChangingLayout() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let layoutTreeBefore = try #require(state.workspacesByID[workspaceID]?.layoutTree)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "First Browser"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser, title: "Second Browser"),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree == layoutTreeBefore)
        #expect(workspaceAfter.rightAuxPanel.tabIDs.count == 2)
        #expect(workspaceAfter.rightAuxPanel.orderedTabs.compactMap { tab -> String? in
            guard case .web(let webState) = tab.panelState else { return nil }
            return webState.title
        } == ["First Browser", "Second Browser"])

        try StateValidator.validate(state)
    }

    @Test
    func rightPanelLocalDocumentCreationDedupesByNormalizedPath() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .localDocument,
                        title: "README.md",
                        localDocument: LocalDocumentState(filePath: "/tmp/project/README.md")
                    ),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .localDocument,
                        title: "README Updated",
                        localDocument: LocalDocumentState(filePath: "/tmp/project/../project/README.md")
                    ),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.rightAuxPanel.tabIDs.count == 1)
        let tab = try #require(workspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = tab.panelState else {
            Issue.record("expected right-panel tab to contain local document panel")
            return
        }
        #expect(webState.title == "README Updated")

        try StateValidator.validate(state)
    }

    @Test
    func rightPanelStateIsScopedToSelectedWorkspaceTab() throws {
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
        #expect(reducer.send(.setRightAuxPanelWidth(workspaceID: workspaceID, width: 520), state: &state))
        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        let secondMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        #expect(secondMainTabID != firstMainTabID)
        var workspaceAfterNewTab = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterNewTab.rightAuxPanel.tabIDs.isEmpty)
        #expect(workspaceAfterNewTab.rightAuxPanel.hasCustomWidth == false)

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
        #expect(reducer.send(.setRightAuxPanelWidth(workspaceID: workspaceID, width: 310), state: &state))

        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: firstMainTabID), state: &state))
        let firstTabWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(firstTabWorkspace.rightAuxPanel.width == 520)
        #expect(firstTabWorkspace.rightAuxPanel.hasCustomWidth)
        #expect(firstTabWorkspace.rightAuxPanel.orderedTabs.count == 1)
        guard case .web(let firstWebState)? = firstTabWorkspace.rightAuxPanel.activeTab?.panelState else {
            Issue.record("expected first tab right panel to contain web panel")
            return
        }
        #expect(firstWebState.title == "First tab docs")

        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: secondMainTabID), state: &state))
        workspaceAfterNewTab = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterNewTab.rightAuxPanel.width == 310)
        #expect(workspaceAfterNewTab.rightAuxPanel.hasCustomWidth)
        #expect(workspaceAfterNewTab.rightAuxPanel.orderedTabs.count == 1)
        guard case .web(let secondWebState)? = workspaceAfterNewTab.rightAuxPanel.activeTab?.panelState else {
            Issue.record("expected second tab right panel to contain web panel")
            return
        }
        #expect(secondWebState.title == "Second tab docs")

        try StateValidator.validate(state)
    }

    @Test
    func rightPanelLocalDocumentDedupeIsScopedToSelectedWorkspaceTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let firstMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        let localDocument = WebPanelState(
            definition: .localDocument,
            title: "README.md",
            localDocument: LocalDocumentState(filePath: "/tmp/project/README.md")
        )

        #expect(reducer.send(.createWebPanel(workspaceID: workspaceID, panel: localDocument, placement: .rightPanel), state: &state))
        let firstPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let secondMainTabID = try #require(state.workspacesByID[workspaceID]?.resolvedSelectedTabID)
        #expect(secondMainTabID != firstMainTabID)

        #expect(reducer.send(.createWebPanel(workspaceID: workspaceID, panel: localDocument, placement: .rightPanel), state: &state))
        let secondPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

        #expect(secondPanelID != firstPanelID)
        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: firstMainTabID), state: &state))
        #expect(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID == firstPanelID)
        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: secondMainTabID), state: &state))
        #expect(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID == secondPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func creatingRightPanelWebPanelFocusesCreatedSubTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let mainFocusedPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

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
        var workspace = try #require(state.workspacesByID[workspaceID])
        let firstRightPanelID = try #require(workspace.rightAuxPanel.activePanelID)
        #expect(workspace.rightAuxPanel.focusedPanelID == firstRightPanelID)
        #expect(workspace.focusedPanelID == mainFocusedPanelID)

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
        let secondRightPanelID = try #require(workspace.rightAuxPanel.activePanelID)
        #expect(secondRightPanelID != firstRightPanelID)
        #expect(workspace.rightAuxPanel.tabIDs.count == 2)
        #expect(workspace.rightAuxPanel.focusedPanelID == secondRightPanelID)
        #expect(workspace.focusedPanelID == mainFocusedPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func focusingBackgroundRightPanelSelectsOwningWorkspaceTab() throws {
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
        let firstRightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        #expect(state.workspacesByID[workspaceID]?.resolvedSelectedTabID != firstMainTabID)

        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: firstRightPanelID), state: &state))

        let workspaceAfterFocus = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterFocus.resolvedSelectedTabID == firstMainTabID)
        #expect(workspaceAfterFocus.rightAuxPanel.focusedPanelID == firstRightPanelID)
        #expect(workspaceAfterFocus.rightAuxPanel.activePanelID == firstRightPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func selectingBackgroundRightPanelTabSelectsOwningWorkspaceTab() throws {
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
        let firstRightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

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

        #expect(
            reducer.send(
                .selectRightAuxPanelTab(
                    workspaceID: workspaceID,
                    tabID: firstRightTabID,
                    focus: true
                ),
                state: &state
            )
        )

        let workspaceAfterSelect = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterSelect.resolvedSelectedTabID == firstMainTabID)
        #expect(workspaceAfterSelect.rightAuxPanel.activeTabID == firstRightTabID)
        #expect(workspaceAfterSelect.rightAuxPanel.focusedPanelID == firstRightPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func closingFocusedRightPanelTabFocusesSuccessorSubTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

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
        let firstRightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

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
        let secondRightTabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)
        let secondRightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        #expect(secondRightTabID != firstRightTabID)
        #expect(secondRightPanelID != firstRightPanelID)

        #expect(
            reducer.send(
                .selectRightAuxPanelTab(
                    workspaceID: workspaceID,
                    tabID: firstRightTabID,
                    focus: true
                ),
                state: &state
            )
        )
        #expect(reducer.send(.closeRightAuxPanelTab(workspaceID: workspaceID, tabID: firstRightTabID), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.rightAuxPanel.activeTabID == secondRightTabID)
        #expect(workspaceAfterClose.rightAuxPanel.focusedPanelID == secondRightPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func closingUnfocusedRightPanelTabPreservesFocusedSubTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

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
        let firstRightPanelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)

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
        let secondRightTabID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activeTabID)

        #expect(
            reducer.send(
                .selectRightAuxPanelTab(
                    workspaceID: workspaceID,
                    tabID: firstRightTabID,
                    focus: true
                ),
                state: &state
            )
        )
        #expect(reducer.send(.closeRightAuxPanelTab(workspaceID: workspaceID, tabID: secondRightTabID), state: &state))

        let workspaceAfterClose = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterClose.rightAuxPanel.activeTabID == firstRightTabID)
        #expect(workspaceAfterClose.rightAuxPanel.focusedPanelID == firstRightPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func updateScratchpadPanelStateMutatesRightPanelScratchpad() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let sourcePanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        let initialScratchpad = ScratchpadState(documentID: UUID(), revision: 1)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(
                        definition: .scratchpad,
                        title: "Initial Scratchpad",
                        scratchpad: initialScratchpad
                    ),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let panelID = try #require(state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID)
        let nextScratchpad = ScratchpadState(
            documentID: initialScratchpad.documentID,
            sessionLink: ScratchpadSessionLink(
                sessionID: "session-1",
                agent: .codex,
                sourcePanelID: sourcePanelID,
                sourceWorkspaceID: workspaceID
            ),
            revision: 2
        )

        #expect(
            reducer.send(
                .updateScratchpadPanelState(
                    panelID: panelID,
                    scratchpad: nextScratchpad,
                    title: "Updated Scratchpad"
                ),
                state: &state
            )
        )

        let workspaceAfterUpdate = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterUpdate.panels[panelID] == nil)
        guard case .web(let webState)? = workspaceAfterUpdate.rightAuxPanel.panelState(for: panelID) else {
            Issue.record("expected right-panel scratchpad web state")
            return
        }
        #expect(webState.title == "Updated Scratchpad")
        #expect(webState.scratchpad == nextScratchpad)

        try StateValidator.validate(state)
    }

}
