import CoreState
import Foundation
import Testing

extension AppReducerTests {
    @Test
    func createWorkspaceAppendsWorkspaceAndSelectsIt() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let windowID = try #require(state.windows.first?.id)
        let originalWorkspaceCount = state.windows.first?.workspaceIDs.count ?? 0

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: nil, activate: true), state: &state))

        let window = try #require(state.windows.first(where: { $0.id == windowID }))
        #expect(window.workspaceIDs.count == originalWorkspaceCount + 1)

        let selectedWorkspaceID = try #require(window.selectedWorkspaceID)
        let selectedWorkspace = try #require(state.workspacesByID[selectedWorkspaceID])
        #expect(selectedWorkspace.title == "Workspace 2")
        #expect(selectedWorkspace.hasBeenVisited == true)

        try StateValidator.validate(state)
    }

    @Test
    func createWorkspaceWithoutActivationKeepsCurrentSelectionAndStartsUnvisited() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let originalWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Background", activate: false), state: &state))

        let window = try #require(state.window(id: windowID))
        #expect(window.selectedWorkspaceID == originalWorkspaceID)
        let backgroundWorkspaceID = try #require(window.workspaceIDs.last)
        #expect(backgroundWorkspaceID != originalWorkspaceID)
        let backgroundWorkspace = try #require(state.workspacesByID[backgroundWorkspaceID])
        #expect(backgroundWorkspace.title == "Background")
        #expect(backgroundWorkspace.hasBeenVisited == false)

        try StateValidator.validate(state)
    }

    @Test
    func selectingBackgroundWorkspaceMarksItVisited() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Background", activate: false), state: &state))

        let backgroundWorkspaceID = try #require(state.window(id: windowID)?.workspaceIDs.last)
        #expect(reducer.send(.selectWorkspace(windowID: windowID, workspaceID: backgroundWorkspaceID), state: &state))

        let backgroundWorkspace = try #require(state.workspacesByID[backgroundWorkspaceID])
        #expect(backgroundWorkspace.hasBeenVisited == true)
        try StateValidator.validate(state)
    }

    @Test
    func closingSelectedWorkspaceMarksFallbackWorkspaceVisited() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let originalWorkspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let originalPanelID = try #require(state.workspacesByID[originalWorkspaceID]?.focusedPanelID)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: "Background", activate: false), state: &state))

        let backgroundWorkspaceID = try #require(state.window(id: windowID)?.workspaceIDs.last)
        #expect(state.workspacesByID[backgroundWorkspaceID]?.hasBeenVisited == false)
        #expect(reducer.send(.closePanel(panelID: originalPanelID), state: &state))

        let window = try #require(state.window(id: windowID))
        #expect(window.selectedWorkspaceID == backgroundWorkspaceID)
        #expect(state.workspacesByID[backgroundWorkspaceID]?.hasBeenVisited == true)
        try StateValidator.validate(state)
    }

    @Test
    func createWorkspaceUsesConfiguredDefaultTerminalProfileForInitialPane() throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "zmx")
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.createWorkspace(windowID: windowID, title: nil, activate: true), state: &state))

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

        #expect(reducer.send(.createWorkspace(windowID: secondWindowID, title: nil, activate: true), state: &state))

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
            windowTerminalFontSizePointsOverride: 15,
            windowMarkdownTextScaleOverride: 1.2
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
        #expect(window.markdownTextScaleOverride == 1.2)
        #expect(state.effectiveTerminalFontPoints(for: window.id) == 15)
        #expect(state.effectiveMarkdownTextScale(for: window.id) == 1.2)
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

}
