import CoreState
import Foundation
import Testing

struct AppReducerTests {
    @Test
    func splitFocusedSlotCreatesSplitAndNewTerminalPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let oldPanelCount = workspaceBefore.panels.count

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.panels.count == oldPanelCount + 1)

        if case .split(_, .horizontal, _, _, _) = workspaceAfter.layoutTree {
            // expected shape after first split
        } else {
            Issue.record("expected split root after first split")
        }

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotInheritsFocusedTerminalCWD() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[focusedPanelID] else {
            Issue.record("expected focused panel to be terminal before split")
            return
        }
        terminalState.cwd = "/tmp/toastty/split-cwd"
        workspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let newFocusedPanelID = try #require(workspaceAfter.focusedPanelID)

        guard case .terminal(let splitTerminalState) = workspaceAfter.panels[newFocusedPanelID] else {
            Issue.record("expected split-created panel to be terminal")
            return
        }
        #expect(splitTerminalState.cwd == "/tmp/toastty/split-cwd")

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotFallsBackToHomeCWDWhenFocusedPanelIsNonTerminal() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))

        let workspaceWithDiff = try #require(state.workspacesByID[workspaceID])
        let diffPanelID = try #require(workspaceWithDiff.panels.first(where: { $0.value.kind == .diff })?.key)
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: diffPanelID), state: &state))

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfterSplit = try #require(state.workspacesByID[workspaceID])
        let newFocusedPanelID = try #require(workspaceAfterSplit.focusedPanelID)
        guard case .terminal(let terminalState) = workspaceAfterSplit.panels[newFocusedPanelID] else {
            Issue.record("expected split-created panel to be terminal")
            return
        }

        #expect(terminalState.cwd == NSHomeDirectory())
        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotInDirectionSupportsLeadingPlacements() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let sourcePanelID = try #require(workspaceBefore.focusedPanelID)

        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .left), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, let orientation, _, let first, let second) = workspaceAfter.layoutTree else {
            Issue.record("expected split root after directional split")
            return
        }

        #expect(orientation == .horizontal)
        guard case .slot(_, let firstPanelID) = first,
              case .slot(_, let secondPanelID) = second else {
            Issue.record("expected leaf children in split root")
            return
        }
        #expect(firstPanelID != sourcePanelID)
        #expect(secondPanelID == sourcePanelID)
        #expect(workspaceAfter.focusedPanelID != sourcePanelID)

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotInDirectionWithTerminalProfileBindsNewPanelOnly() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let sourcePanelID = try #require(workspaceBefore.focusedPanelID)

        #expect(
            reducer.send(
                .splitFocusedSlotInDirectionWithTerminalProfile(
                    workspaceID: workspaceID,
                    direction: .right,
                    profileBinding: TerminalProfileBinding(profileID: "zmx")
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let newPanelID = try #require(workspaceAfter.focusedPanelID)
        guard case .terminal(let newTerminalState) = workspaceAfter.panels[newPanelID] else {
            Issue.record("Expected new focused panel to be terminal")
            return
        }
        #expect(newPanelID != sourcePanelID)
        #expect(newTerminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))

        guard case .terminal(let sourceTerminalState) = workspaceAfter.panels[sourcePanelID] else {
            Issue.record("Expected source panel to remain terminal")
            return
        }
        #expect(sourceTerminalState.profileBinding == nil)

        try StateValidator.validate(state)
    }

    @Test
    func ordinarySplitDoesNotInheritProfileBindingFromFocusedPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[focusedPanelID] else {
            Issue.record("Expected focused panel to be terminal before split")
            return
        }
        terminalState.profileBinding = TerminalProfileBinding(profileID: "zmx")
        workspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let newPanelID = try #require(workspaceAfter.focusedPanelID)
        guard case .terminal(let newTerminalState) = workspaceAfter.panels[newPanelID] else {
            Issue.record("Expected split-created panel to be terminal")
            return
        }

        #expect(newPanelID != focusedPanelID)
        #expect(newTerminalState.profileBinding == nil)
        try StateValidator.validate(state)
    }

    @Test
    func setDefaultTerminalProfileDoesNotRetagExistingTerminalPanels() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspaceBefore.focusedPanelID)

        #expect(reducer.send(.setDefaultTerminalProfile(profileID: "zmx"), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        guard case .terminal(let terminalState) = workspaceAfter.panels[panelID] else {
            Issue.record("Expected existing panel to remain terminal")
            return
        }

        #expect(state.defaultTerminalProfileID == "zmx")
        #expect(terminalState.profileBinding == nil)
        try StateValidator.validate(state)
    }

    @Test
    func ordinarySplitUsesConfiguredDefaultTerminalProfileForNewPane() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let newPanelID = try #require(workspaceAfter.focusedPanelID)
        guard case .terminal(let terminalState) = workspaceAfter.panels[newPanelID] else {
            Issue.record("Expected split-created panel to be terminal")
            return
        }

        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        try StateValidator.validate(state)
    }

    @Test
    func focusSlotMovesToNextAndPreviousLeaf() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let initialWorkspace = try #require(state.workspacesByID[workspaceID])
        let sourcePanelID = try #require(initialWorkspace.focusedPanelID)

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state))
        let nextWorkspace = try #require(state.workspacesByID[workspaceID])
        let nextPanelID = try #require(nextWorkspace.focusedPanelID)
        #expect(nextPanelID != sourcePanelID)

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .previous), state: &state))
        let previousWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(previousWorkspace.focusedPanelID == sourcePanelID)

        try StateValidator.validate(state)
    }

    @Test
    func focusSlotDirectionalMovesToSpatialNeighbor() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .vertical), state: &state))
        let workspaceAfterSplit = try #require(state.workspacesByID[workspaceID])
        let panelAfterSplit = try #require(workspaceAfterSplit.focusedPanelID)

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .up), state: &state))
        let workspaceAfterMove = try #require(state.workspacesByID[workspaceID])
        let movedPanelID = try #require(workspaceAfterMove.focusedPanelID)
        #expect(movedPanelID != panelAfterSplit)
        #expect(
            reducer.send(.focusSlot(workspaceID: workspaceID, direction: .down), state: &state),
            "downward move should return to lower pane"
        )
        let workspaceAfterReturn = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterReturn.focusedPanelID == panelAfterSplit)

        try StateValidator.validate(state)
    }

    @Test
    func createTerminalPanelSplitsTargetPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let slotID = try #require(workspace.layoutTree.allSlotInfos.first?.slotID)
        let originalPanelID = try #require(workspace.focusedPanelID)
        let originalLeafCount = workspace.layoutTree.allSlotInfos.count

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedLeaves = updatedWorkspace.layoutTree.allSlotInfos
        #expect(updatedLeaves.count == originalLeafCount + 1)
        #expect(updatedLeaves.contains(where: { $0.slotID == slotID && $0.panelID == originalPanelID }))
        let newFocusedPanelID = try #require(updatedWorkspace.focusedPanelID)
        #expect(newFocusedPanelID != originalPanelID)
        #expect(updatedLeaves.contains(where: { $0.panelID == newFocusedPanelID }))

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotRecoversFromStaleFocusedPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        workspace.focusedPanelID = UUID()
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .vertical), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(updatedWorkspace.focusedPanelID)
        #expect(updatedWorkspace.panels[focusedPanelID] != nil)

        try StateValidator.validate(state)
    }

    @Test
    func createTerminalPanelUsesMonotonicTerminalTitleNumbering() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let slotID = try #require(workspace.layoutTree.allSlotInfos.first?.slotID)

        let panelOne = UUID()
        let panelThree = UUID()
        workspace.panels = [
            panelOne: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            panelThree: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
        ]
        workspace.layoutTree = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: slotID, panelID: panelOne),
            second: .slot(slotID: UUID(), panelID: panelThree)
        )
        workspace.focusedPanelID = panelThree
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let newPanelIDs = Set(updatedWorkspace.panels.keys).subtracting([panelOne, panelThree])
        let newPanelID = try #require(newPanelIDs.first)
        let newPanel = try #require(updatedWorkspace.panels[newPanelID])

        guard case .terminal(let terminalState) = newPanel else {
            Issue.record("expected new panel to be terminal")
            return
        }

        #expect(terminalState.title == "Terminal 4")
        try StateValidator.validate(state)
    }

    @Test
    func updateTerminalPanelMetadataUpdatesTerminalTitleAndCWD() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)

        #expect(
            reducer.send(
                .updateTerminalPanelMetadata(
                    panelID: panelID,
                    title: "Dev Server",
                    cwd: "/tmp/toastty"
                ),
                state: &state
            )
        )

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .terminal(let terminalState) = try #require(updatedWorkspace.panels[panelID]) else {
            Issue.record("expected focused panel to remain terminal")
            return
        }

        #expect(terminalState.title == "Dev Server")
        #expect(terminalState.cwd == "/tmp/toastty")
        try StateValidator.validate(state)
    }

    @Test
    func updateTerminalPanelMetadataRejectsUnknownPanelAndNoOpPayload() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)

        #expect(
            reducer.send(
                .updateTerminalPanelMetadata(
                    panelID: UUID(),
                    title: "Dev Server",
                    cwd: "/tmp/toastty"
                ),
                state: &state
            ) == false
        )

        #expect(
            reducer.send(
                .updateTerminalPanelMetadata(
                    panelID: panelID,
                    title: "   ",
                    cwd: nil
                ),
                state: &state
            ) == false
        )

        #expect(
            reducer.send(
                .updateTerminalPanelMetadata(
                    panelID: panelID,
                    title: nil,
                    cwd: "   "
                ),
                state: &state
            ) == false
        )
    }

    @Test
    func createWorkspaceAppendsWorkspaceAndSelectsIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let windowID = try #require(state.windows.first?.id)
        let originalWorkspaceCount = state.windows.first?.workspaceIDs.count ?? 0

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: nil), state: &state))

        let window = try #require(state.windows.first(where: { $0.id == windowID }))
        #expect(window.workspaceIDs.count == originalWorkspaceCount + 1)

        let selectedWorkspaceID = try #require(window.selectedWorkspaceID)
        let selectedWorkspace = try #require(state.workspacesByID[selectedWorkspaceID])
        #expect(selectedWorkspace.title == "Workspace 2")

        try StateValidator.validate(state)
    }

    @Test
    func createWorkspaceUsesConfiguredDefaultTerminalProfileForInitialPane() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: nil), state: &state))

        let window = try #require(state.windows.first(where: { $0.id == windowID }))
        let selectedWorkspaceID = try #require(window.selectedWorkspaceID)
        let selectedWorkspace = try #require(state.workspacesByID[selectedWorkspaceID])
        let panelID = try #require(selectedWorkspace.focusedPanelID)
        guard case .terminal(let terminalState) = selectedWorkspace.panels[panelID] else {
            Issue.record("Expected workspace bootstrap panel to be terminal")
            return
        }

        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))
        try StateValidator.validate(state)
    }

    @Test
    func createWorkspaceTabAppendsTabAndSelectsIt() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])

        #expect(
            reducer.send(
                .createWorkspaceTab(
                    workspaceID: workspaceID,
                    seed: WindowLaunchSeed(
                        terminalCWD: "/tmp/workspace-tab",
                        terminalProfileBinding: TerminalProfileBinding(profileID: "ssh-prod")
                    )
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.tabIDs.count == workspaceBefore.tabIDs.count + 1)
        let selectedTabID = try #require(workspaceAfter.selectedTabID)
        let selectedTab = try #require(workspaceAfter.tab(id: selectedTabID))
        let panelID = try #require(selectedTab.focusedPanelID)
        guard case .terminal(let terminalState) = selectedTab.panels[panelID] else {
            Issue.record("Expected new tab bootstrap panel to be terminal")
            return
        }

        #expect(terminalState.cwd == "/tmp/workspace-tab")
        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        try StateValidator.validate(state)
    }

    @Test
    func selectWorkspaceTabChangesSelectedTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        let workspaceWithTwoTabs = try #require(state.workspacesByID[workspaceID])
        let originalTabID = try #require(workspaceWithTwoTabs.tabIDs.first)
        let newTabID = try #require(workspaceWithTwoTabs.tabIDs.last)
        #expect(newTabID != originalTabID)

        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.selectedTabID == originalTabID)
        try StateValidator.validate(state)
    }

    @Test
    func closeLastPanelInSelectedTabRemovesOnlyThatTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        let workspaceWithTwoTabs = try #require(state.workspacesByID[workspaceID])
        let originalTabID = try #require(workspaceWithTwoTabs.tabIDs.first)
        let selectedTabID = try #require(workspaceWithTwoTabs.selectedTabID)
        let selectedTab = try #require(workspaceWithTwoTabs.tab(id: selectedTabID))
        let panelID = try #require(selectedTab.focusedPanelID)

        #expect(reducer.send(.closePanel(panelID: panelID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.tabIDs == [originalTabID])
        #expect(updatedWorkspace.selectedTabID == originalTabID)
        try StateValidator.validate(state)
    }

    @Test
    func closeLastPanelInLastTabClosesWorkspaceAndKeepsEmptyWindow() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let originalPanelID = try #require(workspaceBefore.focusedPanelID)

        #expect(reducer.send(.closePanel(panelID: originalPanelID), state: &state))

        #expect(state.workspacesByID[workspaceID] == nil)
        let window = try #require(state.window(id: windowID))
        #expect(window.workspaceIDs.isEmpty)
        #expect(window.selectedWorkspaceID == nil)
        #expect(state.windows.count == 1)
        #expect(state.selectedWindowID == windowID)
        #expect(state.defaultTerminalProfileID == "zmx")
        try StateValidator.validate(state)
    }

    @Test
    func closeLastPanelInWorkspaceRemovesWorkspaceAndSelectsAdjacentWorkspace() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let secondWorkspaceID = try #require(state.windows.first?.workspaceIDs.last)
        let panelID = try #require(state.workspacesByID[firstWorkspaceID]?.focusedPanelID)

        #expect(reducer.send(.closePanel(panelID: panelID), state: &state))

        #expect(state.workspacesByID[firstWorkspaceID] == nil)
        let updatedWindow = try #require(state.window(id: windowID))
        #expect(updatedWindow.workspaceIDs == [secondWorkspaceID])
        #expect(updatedWindow.selectedWorkspaceID == secondWorkspaceID)
        try StateValidator.validate(state)
    }

    @Test
    func updateTerminalPanelMetadataMutatesBackgroundTabWithoutSelectingIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        var workspace = try #require(state.workspacesByID[workspaceID])
        let originalTabID = try #require(workspace.tabIDs.first)
        let backgroundTabID = try #require(workspace.tabIDs.last)
        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID), state: &state))

        workspace = try #require(state.workspacesByID[workspaceID])
        let backgroundTab = try #require(workspace.tab(id: backgroundTabID))
        let panelID = try #require(backgroundTab.focusedPanelID)

        #expect(
            reducer.send(
                .updateTerminalPanelMetadata(
                    panelID: panelID,
                    title: "Logs",
                    cwd: "/tmp/background"
                ),
                state: &state
            )
        )

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedBackgroundTab = try #require(updatedWorkspace.tab(id: backgroundTabID))
        guard case .terminal(let terminalState) = updatedBackgroundTab.panels[panelID] else {
            Issue.record("Expected background tab panel to remain terminal")
            return
        }

        #expect(updatedWorkspace.selectedTabID == originalTabID)
        #expect(terminalState.title == "Logs")
        #expect(terminalState.cwd == "/tmp/background")
        try StateValidator.validate(state)
    }

    @Test
    func focusPanelSelectsOwningBackgroundTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

        var workspace = try #require(state.workspacesByID[workspaceID])
        let originalTabID = try #require(workspace.tabIDs.first)
        let backgroundTabID = try #require(workspace.tabIDs.last)
        #expect(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID), state: &state))

        workspace = try #require(state.workspacesByID[workspaceID])
        let backgroundTab = try #require(workspace.tab(id: backgroundTabID))
        let panelID = try #require(backgroundTab.focusedPanelID)

        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: panelID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.selectedTabID == backgroundTabID)
        #expect(updatedWorkspace.focusedPanelID == panelID)
        try StateValidator.validate(state)
    }

    @Test
    func createWorkspaceDoesNotStealSelectedWindow() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let firstWindowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        let secondWorkspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let secondWindowID = UUID()
        let secondWindow = WindowState(
            id: secondWindowID,
            frame: CGRectCodable(x: 450, y: 120, width: 900, height: 640),
            workspaceIDs: [secondWorkspace.id],
            selectedWorkspaceID: secondWorkspace.id
        )
        state.windows.append(secondWindow)
        state.workspacesByID[secondWorkspace.id] = secondWorkspace
        state.selectedWindowID = firstWindowID

        #expect(reducer.send(.createWorkspace(windowID: secondWindowID, title: nil), state: &state))

        #expect(state.selectedWindowID == firstWindowID)
        let updatedFirstWindow = try #require(state.windows.first(where: { $0.id == firstWindowID }))
        #expect(updatedFirstWindow.selectedWorkspaceID == firstWorkspaceID)

        let updatedSecondWindow = try #require(state.windows.first(where: { $0.id == secondWindowID }))
        #expect(updatedSecondWindow.workspaceIDs.count == 2)

        try StateValidator.validate(state)
    }

    @Test
    func createWindowCreatesSelectedWindowAndInitialWorkspace() throws {
        var state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13
        )
        let reducer = AppReducer()
        let frame = CGRectCodable(x: 240, y: 180, width: 1440, height: 900)

        #expect(reducer.send(.createWindow(seed: nil, initialFrame: frame), state: &state))

        let window = try #require(state.windows.first)
        let workspaceID = try #require(window.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(state.selectedWindowID == window.id)
        #expect(window.workspaceIDs == [workspaceID])
        #expect(window.frame == frame)
        #expect(workspace.title == "Workspace 1")
        #expect(state.configuredTerminalFontPoints == 13)
        #expect(window.terminalFontSizePointsOverride == nil)
        #expect(state.effectiveTerminalFontPoints(for: window.id) == 13)

        try StateValidator.validate(state)
    }

    @Test
    func createWindowUsesConfiguredDefaultTerminalProfileForInitialPane() throws {
        var state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13,
            defaultTerminalProfileID: "zmx"
        )
        let reducer = AppReducer()

        #expect(reducer.send(.createWindow(seed: nil, initialFrame: nil), state: &state))

        let window = try #require(state.windows.first)
        let workspaceID = try #require(window.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        guard case .terminal(let terminalState) = workspace.panels[panelID] else {
            Issue.record("Expected initial window panel to be terminal")
            return
        }

        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))
        try StateValidator.validate(state)
    }

    @Test
    func createWindowUsesLaunchSeedForInitialWorkspaceAndPane() throws {
        var state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13,
            defaultTerminalProfileID: "ssh-prod"
        )
        let reducer = AppReducer()
        let seed = WindowLaunchSeed(
            workspaceTitle: "Client Logs",
            terminalCWD: "~/src/../tmp/toastty",
            terminalProfileBinding: TerminalProfileBinding(profileID: "zmx"),
            windowTerminalFontSizePointsOverride: 15
        )

        #expect(reducer.send(.createWindow(seed: seed, initialFrame: nil), state: &state))

        let window = try #require(state.windows.first)
        let workspaceID = try #require(window.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        guard case .terminal(let terminalState) = workspace.panels[panelID] else {
            Issue.record("Expected initial window panel to be terminal")
            return
        }

        #expect(workspace.title == "Client Logs")
        #expect(terminalState.cwd == ((NSHomeDirectory() + "/src/../tmp/toastty") as NSString).standardizingPath)
        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "zmx"))
        #expect(window.terminalFontSizePointsOverride == 15)
        #expect(state.effectiveTerminalFontPoints(for: window.id) == 15)
        try StateValidator.validate(state)
    }

    @Test
    func createWindowFallsBackToDefaultFrameWhenNoInitialFrameIsProvided() throws {
        var state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13
        )
        let reducer = AppReducer()

        #expect(reducer.send(.createWindow(seed: nil, initialFrame: nil), state: &state))

        let window = try #require(state.windows.first)
        #expect(window.frame == CGRectCodable(x: 120, y: 120, width: 1280, height: 760))

        try StateValidator.validate(state)
    }

    @Test
    func createTerminalPanelUsesConfiguredDefaultTerminalProfile() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "ssh-prod")
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let slotID = try #require(workspaceBefore.layoutTree.allSlotInfos.first?.slotID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspaceAfter.focusedPanelID)
        guard case .terminal(let terminalState) = workspaceAfter.panels[panelID] else {
            Issue.record("Expected created panel to be terminal")
            return
        }

        #expect(terminalState.profileBinding == TerminalProfileBinding(profileID: "ssh-prod"))
        try StateValidator.validate(state)
    }

    @Test
    func updateWindowFrameMutatesOnlyTheTargetWindow() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let firstWindowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        let secondWorkspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let secondWindowID = UUID()
        let secondWindow = WindowState(
            id: secondWindowID,
            frame: CGRectCodable(x: 450, y: 120, width: 900, height: 640),
            workspaceIDs: [secondWorkspace.id],
            selectedWorkspaceID: secondWorkspace.id
        )
        state.windows.append(secondWindow)
        state.workspacesByID[secondWorkspace.id] = secondWorkspace
        state.selectedWindowID = firstWindowID

        let updatedFrame = CGRectCodable(x: 80, y: 90, width: 1280, height: 720)
        #expect(reducer.send(.updateWindowFrame(windowID: secondWindowID, frame: updatedFrame), state: &state))

        let updatedFirstWindow = try #require(state.windows.first(where: { $0.id == firstWindowID }))
        let updatedSecondWindow = try #require(state.windows.first(where: { $0.id == secondWindowID }))
        #expect(updatedFirstWindow.selectedWorkspaceID == firstWorkspaceID)
        #expect(updatedSecondWindow.frame == updatedFrame)
        #expect(state.selectedWindowID == firstWindowID)

        try StateValidator.validate(state)
    }

    @Test
    func closeWindowRemovesItsWorkspacesAndFallsBackToAnotherWindow() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let firstWindowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        let secondWorkspace = WorkspaceState.bootstrap(title: "Workspace 1")
        let secondWindowID = UUID()
        let secondWindow = WindowState(
            id: secondWindowID,
            frame: CGRectCodable(x: 450, y: 120, width: 900, height: 640),
            workspaceIDs: [secondWorkspace.id],
            selectedWorkspaceID: secondWorkspace.id
        )
        state.windows.append(secondWindow)
        state.workspacesByID[secondWorkspace.id] = secondWorkspace
        state.selectedWindowID = secondWindowID

        #expect(reducer.send(.closeWindow(windowID: secondWindowID), state: &state))

        #expect(state.windows.count == 1)
        #expect(state.windows.first?.id == firstWindowID)
        #expect(state.workspacesByID[secondWorkspace.id] == nil)
        #expect(state.workspacesByID[firstWorkspaceID] != nil)
        #expect(state.selectedWindowID == firstWindowID)

        try StateValidator.validate(state)
    }

    @Test
    func closeLastWindowLeavesAnEmptyState() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.closeWindow(windowID: windowID), state: &state))

        #expect(state.windows.isEmpty)
        #expect(state.workspacesByID[workspaceID] == nil)
        #expect(state.selectedWindowID == nil)

        try StateValidator.validate(state)
    }

    @Test
    func renameWorkspaceUpdatesWorkspaceTitle() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.renameWorkspace(workspaceID: workspaceID, title: "Infra"), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.title == "Infra")
        try StateValidator.validate(state)
    }

    @Test
    func renameWorkspaceRejectsEmptyTitle() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let originalWorkspace = try #require(state.workspacesByID[workspaceID])

        #expect(reducer.send(.renameWorkspace(workspaceID: workspaceID, title: "   "), state: &state) == false)

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.title == originalWorkspace.title)
        try StateValidator.validate(state)
    }

    @Test
    func renameWorkspaceWithUnchangedTitleIsNoOp() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let title = try #require(state.workspacesByID[workspaceID]?.title)

        #expect(reducer.send(.renameWorkspace(workspaceID: workspaceID, title: title), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func setWorkspaceTabCustomTitleUpdatesTheTargetTab() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.last)

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "Deploy"),
                state: &state
            )
        )

        let updatedTab = try #require(state.workspacesByID[workspaceID]?.tab(id: tabID))
        #expect(updatedTab.customTitle == "Deploy")
        #expect(updatedTab.displayTitle == "Deploy")
        try StateValidator.validate(state)
    }

    @Test
    func setWorkspaceTabCustomTitleRejectsEmptyTitle() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.last)
        let originalTab = try #require(state.workspacesByID[workspaceID]?.tab(id: tabID))

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "   "),
                state: &state
            ) == false
        )

        let updatedTab = try #require(state.workspacesByID[workspaceID]?.tab(id: tabID))
        #expect(updatedTab.customTitle == originalTab.customTitle)
        try StateValidator.validate(state)
    }

    @Test
    func setWorkspaceTabCustomTitleWithUnchangedTitleIsNoOp() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.last)

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "Deploy"),
                state: &state
            )
        )

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "Deploy"),
                state: &state
            ) == false
        )
        try StateValidator.validate(state)
    }

    @Test
    func setWorkspaceTabCustomTitleClearsExistingOverride() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.last)

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "Deploy"),
                state: &state
            )
        )
        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: nil),
                state: &state
            )
        )

        let updatedTab = try #require(state.workspacesByID[workspaceID]?.tab(id: tabID))
        #expect(updatedTab.customTitle == nil)
        try StateValidator.validate(state)
    }

    @Test
    func setWorkspaceTabCustomTitleAllowsSingleTabWorkspace() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.first)

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "Deploy"),
                state: &state
            )
        )

        let updatedTab = try #require(state.workspacesByID[workspaceID]?.tab(id: tabID))
        #expect(updatedTab.customTitle == "Deploy")
        #expect(updatedTab.displayTitle == "Deploy")
        try StateValidator.validate(state)
    }

    @Test
    func closeWorkspaceTabOnLastTabClosesWorkspaceAndKeepsEmptyWindow() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.first)

        #expect(reducer.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID), state: &state))

        #expect(state.workspacesByID[workspaceID] == nil)
        let window = try #require(state.window(id: windowID))
        #expect(window.workspaceIDs.isEmpty)
        #expect(window.selectedWorkspaceID == nil)
        #expect(state.windows.count == 1)
        #expect(state.selectedWindowID == windowID)
        #expect(state.defaultTerminalProfileID == "zmx")
        try StateValidator.validate(state)
    }

    @Test
    func setWorkspaceTabCustomTitleTrimsWhitespaceBeforePersisting() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let tabID = try #require(state.workspacesByID[workspaceID]?.tabIDs.last)

        #expect(
            reducer.send(
                .setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: "  Deploy  "),
                state: &state
            )
        )

        let updatedTab = try #require(state.workspacesByID[workspaceID]?.tab(id: tabID))
        #expect(updatedTab.customTitle == "Deploy")
        #expect(updatedTab.displayTitle == "Deploy")
        try StateValidator.validate(state)
    }

    @Test
    func closeWorkspaceRemovesWorkspaceAndSelectsAdjacentWorkspace() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let secondWorkspaceID = try #require(state.windows.first?.workspaceIDs.last)

        #expect(reducer.send(.closeWorkspace(workspaceID: firstWorkspaceID), state: &state))

        #expect(state.workspacesByID[firstWorkspaceID] == nil)
        let updatedWindow = try #require(state.windows.first(where: { $0.id == windowID }))
        #expect(updatedWindow.workspaceIDs == [secondWorkspaceID])
        #expect(updatedWindow.selectedWorkspaceID == secondWorkspaceID)
        try StateValidator.validate(state)
    }

    @Test
    func closeLastWorkspaceKeepsEmptyWindow() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.closeWorkspace(workspaceID: workspaceID), state: &state))

        #expect(state.workspacesByID[workspaceID] == nil)
        let updatedWindow = try #require(state.window(id: windowID))
        #expect(updatedWindow.workspaceIDs.isEmpty)
        #expect(updatedWindow.selectedWorkspaceID == nil)
        #expect(state.windows.count == 1)
        #expect(state.selectedWindowID == windowID)
        try StateValidator.validate(state)
    }

    @Test
    func closeWorkspaceWithUnknownIDIsNoOp() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        #expect(reducer.send(.closeWorkspace(workspaceID: UUID()), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func movePanelToSlotCollapsesEmptySourceLeaf() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let leaves = workspace.layoutTree.allSlotInfos
        let sourceLeaf = try #require(leaves.first)
        let targetLeaf = try #require(leaves.last)
        let panelToMove = sourceLeaf.panelID

        #expect(reducer.send(.movePanelToSlot(panelID: panelToMove, targetSlotID: targetLeaf.slotID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedLeaves = updatedWorkspace.layoutTree.allSlotInfos
        #expect(updatedLeaves.count == 2)
        #expect(updatedLeaves.contains(where: { $0.slotID == targetLeaf.slotID && $0.panelID == targetLeaf.panelID }))
        #expect(updatedLeaves.contains(where: { $0.panelID == panelToMove }))
        #expect(updatedLeaves.contains(where: { $0.slotID == sourceLeaf.slotID }) == false)
        #expect(updatedWorkspace.focusedPanelID == panelToMove)

        try StateValidator.validate(state)
    }

    @Test
    func movePanelToWorkspaceRemovesEmptySourceWorkspace() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))
        let reducer = AppReducer()

        let windowID = try #require(state.windows.first?.id)
        let sourceWorkspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let targetWorkspaceID = try #require(state.windows.first?.workspaceIDs.last)
        let sourceWorkspace = try #require(state.workspacesByID[sourceWorkspaceID])
        let panelID = try #require(sourceWorkspace.focusedPanelID)

        #expect(reducer.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetSlotID: nil), state: &state))

        #expect(state.workspacesByID[sourceWorkspaceID] == nil)
        let window = try #require(state.windows.first(where: { $0.id == windowID }))
        #expect(window.workspaceIDs.count == 1)
        #expect(window.workspaceIDs.first == targetWorkspaceID)

        let targetWorkspace = try #require(state.workspacesByID[targetWorkspaceID])
        #expect(targetWorkspace.panels[panelID] != nil)
        #expect(targetWorkspace.focusedPanelID == panelID)

        try StateValidator.validate(state)
    }

    @Test
    func moveOnlyPanelToWorkspaceInDifferentWindowRemovesSourceWindow() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let sourceWindowID = try #require(state.windows.first?.id)
        let sourceWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[sourceWorkspaceID]?.focusedPanelID)

        let targetWorkspace = WorkspaceState.bootstrap(title: "Workspace 2")
        let targetWindowID = UUID()
        let targetWindow = WindowState(
            id: targetWindowID,
            frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
            workspaceIDs: [targetWorkspace.id],
            selectedWorkspaceID: targetWorkspace.id
        )
        state.workspacesByID[targetWorkspace.id] = targetWorkspace
        state.windows.append(targetWindow)

        #expect(
            reducer.send(
                .movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspace.id, targetSlotID: nil),
                state: &state
            )
        )

        #expect(state.workspacesByID[sourceWorkspaceID] == nil)
        #expect(state.windows.count == 1)
        #expect(state.windows.contains(where: { $0.id == sourceWindowID }) == false)
        #expect(state.selectedWindowID == targetWindowID)

        let survivingWindow = try #require(state.window(id: targetWindowID))
        #expect(survivingWindow.workspaceIDs == [targetWorkspace.id])
        #expect(survivingWindow.selectedWorkspaceID == targetWorkspace.id)

        let updatedTargetWorkspace = try #require(state.workspacesByID[targetWorkspace.id])
        #expect(updatedTargetWorkspace.panels[panelID] != nil)
        #expect(updatedTargetWorkspace.focusedPanelID == panelID)

        try StateValidator.validate(state)
    }

    @Test
    func detachPanelToNewWindowCreatesDetachedWorkspace() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let slotID = try #require(state.workspacesByID[workspaceID]?.layoutTree.allSlotInfos.first?.slotID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))
        let panelToDetach = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.detachPanelToNewWindow(panelID: panelToDetach), state: &state))

        #expect(state.windows.count == 2)
        let detachedWindowID = try #require(state.selectedWindowID)
        let detachedWindow = try #require(state.windows.first(where: { $0.id == detachedWindowID }))
        let detachedWorkspaceID = try #require(detachedWindow.selectedWorkspaceID)
        let detachedWorkspace = try #require(state.workspacesByID[detachedWorkspaceID])
        #expect(detachedWorkspace.panels[panelToDetach] != nil)
        #expect(detachedWorkspace.focusedPanelID == panelToDetach)

        let sourceWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(sourceWorkspace.panels[panelToDetach] == nil)

        try StateValidator.validate(state)
    }

    @Test
    func detachOnlyPanelToNewWindowRemovesEmptySourceWorkspaceAndWindow() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let sourceWindowID = try #require(state.windows.first?.id)
        let sourceWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelToDetach = try #require(state.workspacesByID[sourceWorkspaceID]?.focusedPanelID)

        #expect(reducer.send(.detachPanelToNewWindow(panelID: panelToDetach), state: &state))

        #expect(state.windows.count == 1)
        #expect(state.windows.contains(where: { $0.id == sourceWindowID }) == false)
        #expect(state.workspacesByID[sourceWorkspaceID] == nil)

        let detachedWindowID = try #require(state.selectedWindowID)
        let detachedWindow = try #require(state.windows.first(where: { $0.id == detachedWindowID }))
        let detachedWorkspaceID = try #require(detachedWindow.selectedWorkspaceID)
        let detachedWorkspace = try #require(state.workspacesByID[detachedWorkspaceID])
        #expect(detachedWorkspace.panels[panelToDetach] != nil)
        #expect(detachedWorkspace.focusedPanelID == panelToDetach)

        try StateValidator.validate(state)
    }

    @Test
    func movePanelToWorkspaceWithUnknownTargetSlotDoesNotMutateSource() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))
        let reducer = AppReducer()

        let sourceWorkspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let targetWorkspaceID = try #require(state.windows.first?.workspaceIDs.last)
        let panelID = try #require(state.workspacesByID[sourceWorkspaceID]?.focusedPanelID)

        let sourceWorkspaceBefore = try #require(state.workspacesByID[sourceWorkspaceID])
        let sourcePanelCountBefore = sourceWorkspaceBefore.panels.count
        let targetWorkspaceBefore = try #require(state.workspacesByID[targetWorkspaceID])
        let targetPanelCountBefore = targetWorkspaceBefore.panels.count

        #expect(reducer.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetSlotID: UUID()), state: &state) == false)

        let sourceWorkspaceAfter = try #require(state.workspacesByID[sourceWorkspaceID])
        let targetWorkspaceAfter = try #require(state.workspacesByID[targetWorkspaceID])
        #expect(sourceWorkspaceAfter.panels.count == sourcePanelCountBefore)
        #expect(sourceWorkspaceAfter.panels[panelID] != nil)
        #expect(targetWorkspaceAfter.panels.count == targetPanelCountBefore)
        #expect(targetWorkspaceAfter.panels[panelID] == nil)

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelCreatesRightColumnFromSingleLeaf() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let originalFocusedPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.auxPanelVisibility.contains(.diff))

        let diffPanels = workspace.panels.filter { $0.value.kind == .diff }
        #expect(diffPanels.count == 1)
        #expect(workspace.focusedPanelID == originalFocusedPanelID)

        if case .split(_, .horizontal, _, _, _) = workspace.layoutTree {
            // expected
        } else {
            Issue.record("expected horizontal split for first aux panel")
        }

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelOffRemovesPanelAndVisibility() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.auxPanelVisibility.contains(.markdown) == false)
        #expect(workspace.panels.values.contains(where: { $0.kind == .markdown }) == false)
        #expect(workspace.layoutTree.allSlotInfos.count == 1)

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelAddsSeparateSlotInRightColumn() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let rightSlotIDBefore = try #require(workspaceBefore.layoutTree.rightColumnSlotID())

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree.allSlotInfos.count == 3)
        let rightSlotAfter = try #require(workspaceAfter.layoutTree.allSlotInfos.first(where: { $0.slotID == rightSlotIDBefore }))
        let markdownPanelIDs = workspaceAfter.panels.filter { $0.value.kind == .markdown }.map(\.key)
        #expect(markdownPanelIDs.count == 1)
        #expect(rightSlotAfter.panelID != markdownPanelIDs[0])
        let markdownPane = try #require(
            workspaceAfter.layoutTree.allSlotInfos.first(where: { $0.panelID == markdownPanelIDs[0] })
        )
        #expect(markdownPane.panelID == markdownPanelIDs[0])

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelsUseSeparatePanesInsteadOfTabs() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.layoutTree.allSlotInfos.count == 3)

        let diffPanelID = try #require(workspace.panels.first(where: { $0.value.kind == .diff })?.key)
        let markdownPanelID = try #require(workspace.panels.first(where: { $0.value.kind == .markdown })?.key)
        let diffPane = try #require(workspace.layoutTree.allSlotInfos.first(where: { $0.panelID == diffPanelID }))
        let markdownPane = try #require(workspace.layoutTree.allSlotInfos.first(where: { $0.panelID == markdownPanelID }))

        #expect(diffPane.slotID != markdownPane.slotID)
        #expect(diffPane.panelID == diffPanelID)
        #expect(markdownPane.panelID == markdownPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelOffWithMultipleAuxPanesCollapsesOnlyTargetPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.layoutTree.allSlotInfos.count == 2)
        #expect(workspace.auxPanelVisibility.contains(.diff))
        #expect(workspace.auxPanelVisibility.contains(.markdown) == false)
        #expect(workspace.panels.values.contains(where: { $0.kind == .diff }))
        #expect(workspace.panels.values.contains(where: { $0.kind == .markdown }) == false)

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelsOnComplexTerminalLayoutDoNotSharePanesWithTerminals() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .vertical), state: &state))
        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .vertical), state: &state))

        let workspaceBeforeAux = try #require(state.workspacesByID[workspaceID])
        let terminalPanelIDs = Set(workspaceBeforeAux.panels.compactMap { panelID, panelState in
            panelState.kind == .terminal ? panelID : nil
        })
        let leafCountBeforeAux = workspaceBeforeAux.layoutTree.allSlotInfos.count

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspaceAfterAux = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterAux.layoutTree.allSlotInfos.count == leafCountBeforeAux + 2)

        let auxPanelIDs = Set(workspaceAfterAux.panels.compactMap { panelID, panelState in
            panelState.kind == .terminal ? nil : panelID
        })
        #expect(auxPanelIDs.count == 2)

        let auxLeaves = workspaceAfterAux.layoutTree.allSlotInfos.filter { leaf in
            auxPanelIDs.contains(leaf.panelID)
        }
        #expect(auxLeaves.count == 2)
        if case .split(_, .horizontal, _, let terminalSubtree, let auxSubtree) = workspaceAfterAux.layoutTree {
            let terminalSubtreePanelIDs = Set(terminalSubtree.allSlotInfos.map(\.panelID))
            let auxSubtreePanelIDs = Set(auxSubtree.allSlotInfos.map(\.panelID))
            #expect(auxSubtreePanelIDs.isSuperset(of: auxPanelIDs))
            #expect(terminalSubtreePanelIDs.isDisjoint(with: auxPanelIDs))
        } else {
            Issue.record("expected root horizontal split with dedicated aux subtree")
        }

        for leaf in auxLeaves {
            #expect(terminalPanelIDs.contains(leaf.panelID) == false)
        }

        try StateValidator.validate(state)
    }

    @Test
    func toggleThirdAuxPanelStacksInsideDedicatedAuxColumn() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .scratchpad), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.layoutTree.allSlotInfos.count == 4)

        let auxPanelIDs = Set(workspace.panels.compactMap { panelID, panelState in
            panelState.kind == .terminal ? nil : panelID
        })
        #expect(auxPanelIDs.count == 3)

        if case .split(_, .horizontal, _, let terminalSubtree, let auxSubtree) = workspace.layoutTree {
            let terminalSubtreePanelIDs = Set(terminalSubtree.allSlotInfos.map(\.panelID))
            let auxSubtreePanelIDs = Set(auxSubtree.allSlotInfos.map(\.panelID))
            #expect(auxSubtreePanelIDs.isSuperset(of: auxPanelIDs))
            #expect(terminalSubtreePanelIDs.isDisjoint(with: auxPanelIDs))
        } else {
            Issue.record("expected root horizontal split with dedicated aux subtree")
        }

        let auxLeaves = workspace.layoutTree.allSlotInfos.filter { leaf in
            auxPanelIDs.contains(leaf.panelID)
        }
        #expect(auxLeaves.count == 3)

        try StateValidator.validate(state)
    }

    @Test
    func togglingSameAuxPanelOnOffOnKeepsSingleInstance() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        let diffPanels = workspace.panels.values.filter { $0.kind == .diff }
        #expect(diffPanels.count == 1)
        #expect(workspace.auxPanelVisibility.contains(.diff))

        try StateValidator.validate(state)
    }

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
    func closeAuxPanelClearsVisibilityAndReopenRestoresIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        let diffPanelID = try #require(
            state.workspacesByID[workspaceID]?.panels.first(where: { $0.value.kind == .diff })?.key
        )

        #expect(reducer.send(.closePanel(panelID: diffPanelID), state: &state))
        let afterClose = try #require(state.workspacesByID[workspaceID])
        #expect(afterClose.auxPanelVisibility.contains(.diff) == false)
        #expect(afterClose.recentlyClosedPanels.count == 1)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))
        let afterReopen = try #require(state.workspacesByID[workspaceID])
        #expect(afterReopen.auxPanelVisibility.contains(.diff))
        #expect(afterReopen.panels.values.contains(where: { $0.kind == .diff }))

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
    func reopenAuxPanelDoesNotDuplicateWhenSameKindAlreadyVisible() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        let originalDiffID = try #require(
            state.workspacesByID[workspaceID]?.panels.first(where: { $0.value.kind == .diff })?.key
        )

        #expect(reducer.send(.closePanel(panelID: originalDiffID), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        let reopenedDiffID = try #require(
            state.workspacesByID[workspaceID]?.panels.first(where: { $0.value.kind == .diff })?.key
        )

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        let diffPanelIDs = workspace.panels.filter { $0.value.kind == .diff }.map(\.key)
        #expect(diffPanelIDs.count == 1)
        #expect(diffPanelIDs[0] == reopenedDiffID)
        #expect(workspace.focusedPanelID == reopenedDiffID)
        #expect(workspace.recentlyClosedPanels.isEmpty)

        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitAdjustsNearestMatchingRatio() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let initialWorkspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(_, let orientation, let initialRatio, _, _) = initialWorkspace.layoutTree else {
            Issue.record("expected split-workspace fixture to have split root")
            return
        }
        #expect(orientation == .horizontal)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 2),
                state: &state
            )
        )

        let resizedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let resizedRatio, _, _) = resizedWorkspace.layoutTree else {
            Issue.record("expected split root after resize")
            return
        }

        #expect(resizedRatio > initialRatio)
        #expect(abs(resizedRatio - (initialRatio + 0.01)) < 0.0001)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitReturnsFalseWhenNoMatchingSplitOrientationExists() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .up, amount: 1),
                state: &state
            ) == false
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree == workspaceBefore.layoutTree)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitUsesNearestMatchingAncestor() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        let focusedPanelID = UUID()
        let siblingPanelID = UUID()
        let rightPanelID = UUID()
        workspace.panels = [
            focusedPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            siblingPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            rightPanelID: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
        ]

        let focusedSlotID = UUID()
        let siblingSlotID = UUID()
        let rightSlotID = UUID()
        let nestedSplitNodeID = UUID()
        let rootSplitNodeID = UUID()
        workspace.layoutTree = .split(
            nodeID: rootSplitNodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .split(
                nodeID: nestedSplitNodeID,
                orientation: .horizontal,
                ratio: 0.6,
                first: .slot(slotID: focusedSlotID, panelID: focusedPanelID),
                second: .slot(slotID: siblingSlotID, panelID: siblingPanelID)
            ),
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )
        workspace.focusedPanelID = focusedPanelID
        state.workspacesByID[workspaceID] = workspace

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            )
        )

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let rootRatio, let firstNode, _) = updatedWorkspace.layoutTree,
              case .split(_, _, let nestedRatio, _, _) = firstNode else {
            Issue.record("expected nested horizontal split tree after resize")
            return
        }

        #expect(rootRatio == 0.5)
        #expect(abs(nestedRatio - 0.605) < 0.0001)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitClampsAtUpperBound() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: Int.max),
                state: &state
            )
        )

        let workspaceAfterFirstResize = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let ratioAfterFirstResize, _, _) = workspaceAfterFirstResize.layoutTree else {
            Issue.record("expected split tree after clamped resize")
            return
        }
        #expect(abs(ratioAfterFirstResize - 0.9) < 0.0001)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            ) == false
        )
        let workspaceAfterSecondResize = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterSecondResize.layoutTree == workspaceAfterFirstResize.layoutTree)
        try StateValidator.validate(state)
    }

    @Test
    func equalizeLayoutSplitsNormalizesNestedRatios() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(_, _, _, let first, let second) = workspace.layoutTree,
              case .slot(let leftSlotID, let leftPanelID) = first,
              case .slot(let rightSlotID, let rightPanelID) = second else {
            Issue.record("expected split-workspace fixture to expose two terminal leaves")
            return
        }

        let extraPanelID = UUID()
        let extraSlotID = UUID()
        workspace.panels[extraPanelID] = .terminal(
            TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")
        )
        let nestedSecond = LayoutNode.split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.8,
            first: .slot(slotID: rightSlotID, panelID: rightPanelID),
            second: .slot(slotID: extraSlotID, panelID: extraPanelID)
        )
        workspace.layoutTree = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.7,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: nestedSecond
        )
        workspace.focusedPanelID = leftPanelID
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let rootRatio, _, let updatedSecond) = updatedWorkspace.layoutTree,
              case .split(_, _, let nestedRatio, _, _) = updatedSecond else {
            Issue.record("expected nested split tree after equalize")
            return
        }

        // Horizontal root with a vertical child subtree uses Ghostty semantics:
        // opposite-orientation subtrees count as a single weight unit.
        #expect(abs(rootRatio - 0.5) < 0.0001)
        #expect(nestedRatio == 0.5)
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func equalizeLayoutSplitsBalancesRightSplitChainIntoThirds() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, .horizontal, let rootRatio, _, let second) = workspace.layoutTree,
              case .split(_, .horizontal, let nestedRatio, _, _) = second else {
            Issue.record("expected right-leaning horizontal split chain")
            return
        }

        #expect(abs(rootRatio - (1.0 / 3.0)) < 0.0001)
        #expect(abs(nestedRatio - 0.5) < 0.0001)
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func equalizeLayoutSplitsBalancesLeftSplitChainIntoThirds() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .left), state: &state))
        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .left), state: &state))
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, .horizontal, let rootRatio, let first, _) = workspace.layoutTree,
              case .split(_, .horizontal, let nestedRatio, _, _) = first else {
            Issue.record("expected left-leaning horizontal split chain")
            return
        }

        #expect(abs(rootRatio - (2.0 / 3.0)) < 0.0001)
        #expect(abs(nestedRatio - 0.5) < 0.0001)
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func equalizeLayoutSplitsBalancesDeepRightSplitChain() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right), state: &state))
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let workspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, .horizontal, let rootRatio, _, let secondNode) = workspace.layoutTree,
              case .split(_, .horizontal, let secondRatio, _, let thirdNode) = secondNode,
              case .split(_, .horizontal, let thirdRatio, _, _) = thirdNode else {
            Issue.record("expected deep right-leaning horizontal split chain")
            return
        }

        #expect(abs(rootRatio - 0.25) < 0.0001)
        #expect(abs(secondRatio - (1.0 / 3.0)) < 0.0001)
        #expect(abs(thirdRatio - 0.5) < 0.0001)
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func equalizeLayoutSplitsUsesOrientationAwareWeightsForMixedTree() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(_, _, _, let first, let second) = workspace.layoutTree,
              case .slot(let leftSlotID, let leftPanelID) = first,
              case .slot(let rightSlotID, let rightPanelID) = second else {
            Issue.record("expected split-workspace fixture to expose two terminal leaves")
            return
        }

        let leftSecondPanelID = UUID()
        let rightThirdPanelID = UUID()
        let rightFourthPanelID = UUID()
        workspace.panels[leftSecondPanelID] = .terminal(
            TerminalPanelState(title: "Terminal L2", shell: "zsh", cwd: "/tmp")
        )
        workspace.panels[rightThirdPanelID] = .terminal(
            TerminalPanelState(title: "Terminal R3", shell: "zsh", cwd: "/tmp")
        )
        workspace.panels[rightFourthPanelID] = .terminal(
            TerminalPanelState(title: "Terminal R4", shell: "zsh", cwd: "/tmp")
        )

        let leftSecondSlotID = UUID()
        let rightThirdSlotID = UUID()
        let rightFourthSlotID = UUID()

        let leftSubtree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.9,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: .slot(slotID: leftSecondSlotID, panelID: leftSecondPanelID)
        )
        let rightNestedSubtree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.9,
            first: .slot(slotID: rightThirdSlotID, panelID: rightThirdPanelID),
            second: .slot(slotID: rightFourthSlotID, panelID: rightFourthPanelID)
        )
        let rightSubtree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.9,
            first: .slot(slotID: rightSlotID, panelID: rightPanelID),
            second: rightNestedSubtree
        )
        workspace.layoutTree = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.9,
            first: leftSubtree,
            second: rightSubtree
        )
        workspace.focusedPanelID = leftPanelID
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, .horizontal, let rootRatio, let updatedLeft, let updatedRight) = updatedWorkspace.layoutTree,
              case .split(_, .horizontal, let leftRatio, _, _) = updatedLeft,
              case .split(_, .vertical, let rightRatio, _, let updatedRightNested) = updatedRight,
              case .split(_, .vertical, let rightNestedRatio, _, _) = updatedRightNested else {
            Issue.record("expected mixed-orientation split tree after equalize")
            return
        }

        #expect(abs(rootRatio - (2.0 / 3.0)) < 0.0001)
        #expect(abs(leftRatio - 0.5) < 0.0001)
        #expect(abs(rightRatio - (1.0 / 3.0)) < 0.0001)
        #expect(abs(rightNestedRatio - 0.5) < 0.0001)
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func equalizeLayoutSplitsTreatsOppositeOrientationSubtreeAsSingleWeight() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(_, _, _, let first, let second) = workspace.layoutTree,
              case .slot(let leftSlotID, let leftPanelID) = first,
              case .slot(let rightSlotID, let rightPanelID) = second else {
            Issue.record("expected split-workspace fixture to expose two terminal leaves")
            return
        }

        let topRightPanelID = UUID()
        workspace.panels[topRightPanelID] = .terminal(
            TerminalPanelState(title: "Terminal Top Right", shell: "zsh", cwd: "/tmp")
        )
        let topRightSlotID = UUID()

        let topSubtree = LayoutNode.split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.8,
            first: .slot(slotID: leftSlotID, panelID: leftPanelID),
            second: .slot(slotID: topRightSlotID, panelID: topRightPanelID)
        )
        workspace.layoutTree = .split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.8,
            first: topSubtree,
            second: .slot(slotID: rightSlotID, panelID: rightPanelID)
        )
        workspace.focusedPanelID = leftPanelID
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, .vertical, let rootRatio, let updatedFirst, _) = updatedWorkspace.layoutTree,
              case .split(_, .horizontal, let topRatio, _, _) = updatedFirst else {
            Issue.record("expected vertical root with horizontal top subtree after equalize")
            return
        }

        #expect(abs(rootRatio - 0.5) < 0.0001)
        #expect(abs(topRatio - 0.5) < 0.0001)
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func windowFontActionsAdjustAndResetFontSize() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let defaultPoints = AppState.defaultTerminalFontPoints
        let step = AppState.terminalFontStepPoints

        #expect(reducer.send(.increaseWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints + step)
        #expect(state.window(id: windowID)?.terminalFontSizePointsOverride == defaultPoints + step)

        #expect(reducer.send(.decreaseWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints)
        #expect(state.window(id: windowID)?.terminalFontSizePointsOverride == nil)

        #expect(reducer.send(.increaseWindowTerminalFont(windowID: windowID), state: &state))
        #expect(reducer.send(.increaseWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints + (step * 2))

        #expect(reducer.send(.resetWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints)
        #expect(state.window(id: windowID)?.terminalFontSizePointsOverride == nil)
    }

    @Test
    func configuredFontBaselineUpdatesConfiguredValueAndResetUsesIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.setConfiguredTerminalFont(points: 14), state: &state))
        #expect(state.configuredTerminalFontPoints == 14)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 14)
        #expect(reducer.send(.increaseWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 15)
        #expect(reducer.send(.resetWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 14)
    }

    @Test
    func configuredFontBaselineDoesNotOverrideUserAdjustedFont() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let defaultPoints = AppState.defaultTerminalFontPoints

        #expect(reducer.send(.increaseWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints + AppState.terminalFontStepPoints)

        #expect(reducer.send(.setConfiguredTerminalFont(points: 9), state: &state))
        #expect(state.configuredTerminalFontPoints == 9)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints + AppState.terminalFontStepPoints)

        #expect(reducer.send(.resetWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 9)
    }

    @Test
    func clearingConfiguredFontBaselineReturnsResetToDefault() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.setConfiguredTerminalFont(points: 15), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 15)
        #expect(reducer.send(.setWindowTerminalFont(windowID: windowID, points: 18), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 18)

        #expect(reducer.send(.setConfiguredTerminalFont(points: nil), state: &state))
        #expect(state.configuredTerminalFontPoints == nil)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == 18)
        #expect(reducer.send(.resetWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == AppState.defaultTerminalFontPoints)
    }

    @Test
    func windowFontActionsClampAtBounds() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let defaultPoints = AppState.defaultTerminalFontPoints

        #expect(reducer.send(.setWindowTerminalFont(windowID: windowID, points: AppState.maxTerminalFontPoints + 10), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == AppState.maxTerminalFontPoints)
        #expect(reducer.send(.increaseWindowTerminalFont(windowID: windowID), state: &state) == false)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == AppState.maxTerminalFontPoints)

        #expect(reducer.send(.setWindowTerminalFont(windowID: windowID, points: AppState.minTerminalFontPoints), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == AppState.minTerminalFontPoints)
        #expect(reducer.send(.decreaseWindowTerminalFont(windowID: windowID), state: &state) == false)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == AppState.minTerminalFontPoints)

        #expect(reducer.send(.resetWindowTerminalFont(windowID: windowID), state: &state))
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints)
        #expect(reducer.send(.resetWindowTerminalFont(windowID: windowID), state: &state) == false)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints)

        #expect(reducer.send(.setWindowTerminalFont(windowID: windowID, points: defaultPoints), state: &state) == false)
        #expect(state.effectiveTerminalFontPoints(for: windowID) == defaultPoints)
    }

    @Test
    func toggleFocusedPanelModeRoundTripPreservesLayoutAndFocus() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspaceBefore.focusedPanelID)
        let focusedSlotID = try #require(
            workspaceBefore.layoutTree.slotContaining(panelID: focusedPanelID)?.slotID
        )

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let focusedModeWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(focusedModeWorkspace.focusedPanelModeActive)
        #expect(focusedModeWorkspace.focusModeRootNodeID == focusedSlotID)
        #expect(focusedModeWorkspace.layoutTree == workspaceBefore.layoutTree)
        #expect(focusedModeWorkspace.focusedPanelID == workspaceBefore.focusedPanelID)

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let restoredWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(restoredWorkspace.focusedPanelModeActive == false)
        #expect(restoredWorkspace.focusModeRootNodeID == nil)
        #expect(restoredWorkspace.layoutTree == workspaceBefore.layoutTree)
        #expect(restoredWorkspace.focusedPanelID == workspaceBefore.focusedPanelID)

        try StateValidator.validate(state)
    }

    @Test
    func toggleFocusedPanelModeRecoversFromStaleFocusedPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        workspace.focusedPanelID = UUID()
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(updatedWorkspace.focusedPanelID)
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.panels[focusedPanelID] != nil)
        #expect(updatedWorkspace.focusModeRootNodeID == updatedWorkspace.layoutTree.slotContaining(panelID: focusedPanelID)?.slotID)

        try StateValidator.validate(state)
    }

    @Test
    func splitInFocusModeUpdatesFocusModeRootNodeIDWhileAuxToggleStaysBlocked() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let workspaceInFocusMode = try #require(state.workspacesByID[workspaceID])
        let previousRootNodeID = workspaceInFocusMode.focusModeRootNodeID

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state) == false)

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.panels.count == 2)
        #expect(updatedWorkspace.focusModeRootNodeID != previousRootNodeID)
        guard case .split(let splitNodeID, _, _, _, _) = updatedWorkspace.layoutTree else {
            Issue.record("expected bootstrap workspace to split in focus mode")
            return
        }
        #expect(updatedWorkspace.focusModeRootNodeID == splitNodeID)

        try StateValidator.validate(state)
    }

    @Test
    func closePanelKeepsFocusedModeActive() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let slotID = try #require(state.workspacesByID[workspaceID]?.layoutTree.allSlotInfos.first?.slotID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, slotID: slotID), state: &state))
        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))

        let panelToClose = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.panels.count == 1)
        let resolvedFocusedPanelID = try #require(updatedWorkspace.focusedPanelID)
        #expect(updatedWorkspace.panels[resolvedFocusedPanelID] != nil)

        try StateValidator.validate(state)
    }

    @Test
    func focusPanelInFocusModeRetargetsRootWhenTargetWouldBeHidden() throws {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp/left")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp/right")),
            ],
            focusedPanelID: leftPanelID,
            focusedPanelModeActive: true,
            focusModeRootNodeID: leftSlotID
        )
        var state = AppState(
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
        let reducer = AppReducer()

        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: rightPanelID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.focusedPanelID == rightPanelID)
        #expect(updatedWorkspace.focusModeRootNodeID == rightSlotID)

        try StateValidator.validate(state)
    }

    @Test
    func focusPanelInFocusModePreservesRootWhenTargetRemainsVisible() throws {
        let leftPanelID = UUID()
        let topRightPanelID = UUID()
        let bottomRightPanelID = UUID()
        let leftSlotID = UUID()
        let topRightSlotID = UUID()
        let bottomRightSlotID = UUID()
        let rightBranchNodeID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .split(
                    nodeID: rightBranchNodeID,
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: topRightSlotID, panelID: topRightPanelID),
                    second: .slot(slotID: bottomRightSlotID, panelID: bottomRightPanelID)
                )
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp/left")),
                topRightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp/top")),
                bottomRightPanelID: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp/bottom")),
            ],
            focusedPanelID: topRightPanelID,
            focusedPanelModeActive: true,
            focusModeRootNodeID: rightBranchNodeID
        )
        var state = AppState(
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
        let reducer = AppReducer()

        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: bottomRightPanelID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.focusedPanelID == bottomRightPanelID)
        #expect(updatedWorkspace.focusModeRootNodeID == rightBranchNodeID)

        try StateValidator.validate(state)
    }

    @Test
    func resizeAndEqualizeMutateFocusedSubtreeWhenFocusedModeIsActive() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(let nodeID, let orientation, _, let first, let second) = workspace.layoutTree else {
            Issue.record("expected split-workspace fixture to have split root")
            return
        }
        workspace.layoutTree = .split(
            nodeID: nodeID,
            orientation: orientation,
            ratio: 0.7,
            first: first,
            second: second
        )
        workspace.focusedPanelModeActive = true
        workspace.focusModeRootNodeID = workspace.layoutTree.resolvedNodeID
        state.workspacesByID[workspaceID] = workspace

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            )
        )
        #expect(reducer.send(.equalizeLayoutSplits(workspaceID: workspaceID), state: &state))

        let workspaceAfterMutations = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let equalizedRatio, _, _) = workspaceAfterMutations.layoutTree else {
            Issue.record("expected split root after focus-mode resize/equalize")
            return
        }
        #expect(abs(equalizedRatio - 0.5) < 0.0001)

        try StateValidator.validate(state)
    }

    @Test
    func recordDesktopNotificationMarksUnreadPanelOnlyOnce() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        let countBefore = try #require(state.workspacesByID[workspaceID]).unreadNotificationCount
        #expect(countBefore == 0)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )

        let workspaceAfterFirstNotification = try #require(state.workspacesByID[workspaceID])
        let countAfter = workspaceAfterFirstNotification.unreadNotificationCount
        #expect(countAfter == 1)
        #expect(workspaceAfterFirstNotification.unreadPanelIDs == [panelID])
        #expect(workspaceAfterFirstNotification.unreadWorkspaceNotificationCount == 0)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])

        try StateValidator.validate(state)
    }

    @Test
    func recordDesktopNotificationReturnsFalseForUnknownWorkspace() {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let bogusWorkspaceID = UUID()

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: bogusWorkspaceID, panelID: nil),
                state: &state
            ) == false
        )
    }

    @Test
    func focusPanelClearsOnlyFocusedPanelUnreadNotification() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)
        let otherPanelID = try #require(workspace.panels.keys.first(where: { $0 != focusedPanelID }))
        workspace.unreadPanelIDs = [focusedPanelID, otherPanelID]
        workspace.unreadWorkspaceNotificationCount = 2
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: focusedPanelID), state: &state))
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [otherPanelID])
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 0)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func focusPanelClearsUnreadCountAfterRecordingDesktopNotification() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)

        #expect(
            reducer.send(
                .focusPanel(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 0)
    }

    @Test
    func recordDesktopNotificationWithoutPanelIncrementsWorkspaceScopedUnreadCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: nil),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 1)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs.isEmpty)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: nil),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 2)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 2)
    }

    @Test
    func recordDesktopNotificationReturnsFalseForUnknownPanelID() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .recordDesktopNotification(workspaceID: workspaceID, panelID: UUID()),
                state: &state
            ) == false
        )
    }

    @Test
    func selectWorkspaceDoesNotClearPanelUnreadNotificationCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [panelID]
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID), state: &state))
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func selectWorkspaceClearsOnlyWorkspaceScopedUnreadNotificationCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [panelID]
        workspace.unreadWorkspaceNotificationCount = 2
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID), state: &state))
        #expect(try #require(state.workspacesByID[workspaceID]).unreadWorkspaceNotificationCount == 0)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == [panelID])
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func selectWorkspaceOnlyClearsSelectedWorkspaceScopedUnreadCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let firstWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Second Workspace"), state: &state))
        let secondWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        var firstWorkspace = try #require(state.workspacesByID[firstWorkspaceID])
        var secondWorkspace = try #require(state.workspacesByID[secondWorkspaceID])
        firstWorkspace.unreadWorkspaceNotificationCount = 5
        secondWorkspace.unreadWorkspaceNotificationCount = 3
        state.workspacesByID[firstWorkspaceID] = firstWorkspace
        state.workspacesByID[secondWorkspaceID] = secondWorkspace

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: firstWorkspaceID), state: &state))
        #expect(try #require(state.workspacesByID[firstWorkspaceID]).unreadWorkspaceNotificationCount == 0)
        #expect(try #require(state.workspacesByID[secondWorkspaceID]).unreadWorkspaceNotificationCount == 3)

        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: secondWorkspaceID), state: &state))
        #expect(try #require(state.workspacesByID[secondWorkspaceID]).unreadWorkspaceNotificationCount == 0)
    }

    @Test
    func focusSlotClearsUnreadNotificationForFocusedTargetPanel() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelIDs = Array(workspace.panels.keys)
        workspace.unreadPanelIDs = Set(panelIDs)
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state))
        let workspaceAfterFocus = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspaceAfterFocus.focusedPanelID)
        #expect(workspaceAfterFocus.unreadPanelIDs.contains(focusedPanelID) == false)
        #expect(workspaceAfterFocus.unreadNotificationCount == max(panelIDs.count - 1, 0))
    }

    @Test
    func focusSlotNoopDoesNotClearUnreadNotificationCount() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        workspace.unreadPanelIDs = [panelID]
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.focusSlot(workspaceID: workspaceID, direction: .next), state: &state) == false)
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 1)
    }

    @Test
    func markPanelNotificationsReadClearsOnlySpecifiedPanel() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelIDs = Array(workspace.panels.keys)
        guard panelIDs.count >= 2 else {
            Issue.record("expected split-workspace fixture to contain at least two panels")
            return
        }
        workspace.unreadPanelIDs = Set(panelIDs)
        state.workspacesByID[workspaceID] = workspace

        let panelToMarkRead = panelIDs[0]
        #expect(
            reducer.send(
                .markPanelNotificationsRead(workspaceID: workspaceID, panelID: panelToMarkRead),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadPanelIDs == Set(panelIDs.dropFirst()))
    }

    @Test
    func markPanelNotificationsReadIsIdempotentWhenPanelIsAlreadyRead() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(
            reducer.send(
                .markPanelNotificationsRead(workspaceID: workspaceID, panelID: panelID),
                state: &state
            )
        )
        #expect(try #require(state.workspacesByID[workspaceID]).unreadNotificationCount == 0)
    }

    // MARK: - Toggle Sidebar

    @Test
    func toggleSidebarHidesAndShowsSidebar() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(state.windows.first?.sidebarVisible == true)

        #expect(reducer.send(.toggleSidebar(windowID: windowID), state: &state))
        #expect(state.windows.first?.sidebarVisible == false)

        #expect(reducer.send(.toggleSidebar(windowID: windowID), state: &state))
        #expect(state.windows.first?.sidebarVisible == true)

        try StateValidator.validate(state)
    }

    @Test
    func toggleSidebarRejectsInvalidWindowID() {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        #expect(reducer.send(.toggleSidebar(windowID: UUID()), state: &state) == false)
    }
}
