import CoreState
import Foundation
import Testing

struct BackgroundTerminalCreationTests {
    // Failure modes: selecting a hidden tab, changing its focus, inheriting the
    // wrong source CWD, losing focus-mode roots, and writing a mismatched target.
    @Test(arguments: [SlotSplitDirection.right, .down, .left, .up])
    func backgroundSplitPreservesSelectionAndFocus(direction: SlotSplitDirection) throws {
        var state = AppState.bootstrap(defaultTerminalProfileID: "default")
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let source = try #require(state.workspacesByID[workspaceID]?.selectedTab)
        let sourcePanelID = try #require(source.focusedPanelID)
        #expect(AppReducer.reduce(action: .updateTerminalPanelMetadata(panelID: sourcePanelID, title: nil, cwd: "/tmp/source"), state: &state))
        #expect(AppReducer.reduce(action: .toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        state.workspacesByID[workspaceID]?.selectedPanelIDs = [sourcePanelID]
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let before = try #require(state.workspacesByID[workspaceID])
        let sourceBefore = try #require(before.tab(id: source.id))

        #expect(AppReducer.reduce(action: .splitPanel(
            workspaceID: workspaceID, tabID: source.id, panelID: sourcePanelID,
            direction: direction, profileBinding: nil, activate: false
        ), state: &state))

        let after = try #require(state.workspacesByID[workspaceID])
        let tab = try #require(after.tab(id: source.id))
        #expect(after.selectedTabID == before.selectedTabID)
        #expect(after.selectedTab == before.selectedTab)
        #expect(tab.focusedPanelID == sourceBefore.focusedPanelID)
        #expect(tab.rightAuxPanel == sourceBefore.rightAuxPanel)
        #expect(tab.selectedPanelIDs == sourceBefore.selectedPanelIDs)
        #expect(tab.focusModeRootNodeID == sourceBefore.focusModeRootNodeID)
        #expect(tab.focusedPanelModeActive == sourceBefore.focusedPanelModeActive)
        let createdID = try #require(Set(tab.panels.keys).subtracting(sourceBefore.panels.keys).first)
        guard case .terminal(let terminal) = tab.panels[createdID] else {
            Issue.record("Expected a new terminal")
            return
        }
        #expect(terminal.cwd == "/tmp/source")
        #expect(terminal.profileBinding == TerminalProfileBinding(profileID: "default"))
        try StateValidator.validate(state)

        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(restored.workspacesByID[workspaceID]?.selectedTabID == after.selectedTabID)
        #expect(restored.workspacesByID[workspaceID]?.tab(id: source.id)?.layoutTree == tab.layoutTree)
    }

    @Test(arguments: [false, true])
    func explicitSourceOutsideFocusModeRoot(activate: Bool) throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let firstPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(AppReducer.reduce(action: .splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        #expect(AppReducer.reduce(action: .toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let before = try #require(state.workspacesByID[workspaceID])
        let tabID = try #require(before.selectedTabID)
        #expect(before.focusedPanelID != firstPanelID)

        #expect(AppReducer.reduce(action: .splitPanel(
            workspaceID: workspaceID, tabID: tabID, panelID: firstPanelID,
            direction: .down, profileBinding: TerminalProfileBinding(profileID: "explicit"), activate: activate
        ), state: &state))

        let after = try #require(state.workspacesByID[workspaceID])
        let createdID = try #require(Set(after.panels.keys).subtracting(before.panels.keys).first)
        if activate {
            #expect(after.focusedPanelID == createdID)
            #expect(after.panelIsVisibleInFocusMode(createdID))
        } else {
            #expect(after.focusedPanelID == before.focusedPanelID)
            #expect(after.focusModeRootNodeID == before.focusModeRootNodeID)
        }
        guard case .terminal(let terminal) = after.panels[createdID] else {
            Issue.record("Expected a new terminal")
            return
        }
        #expect(terminal.profileBinding == TerminalProfileBinding(profileID: "explicit"))
        try StateValidator.validate(state)
    }

    @Test
    func splitRejectsPanelFromAnotherTabWithoutMutation() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let panelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))
        let tabID = try #require(state.workspacesByID[workspaceID]?.selectedTabID)
        let before = state

        #expect(!AppReducer.reduce(action: .splitPanel(
            workspaceID: workspaceID, tabID: tabID, panelID: panelID,
            direction: .right, profileBinding: nil, activate: false
        ), state: &state))
        #expect(state == before)
    }

    @Test
    func backgroundTabHasItsOwnInitialFocusWithoutSelectingIt() throws {
        var state = AppState.bootstrap()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let before = try #require(state.workspacesByID[workspaceID])
        #expect(AppReducer.reduce(action: .createWorkspaceTab(workspaceID: workspaceID, seed: nil, activate: false), state: &state))
        let after = try #require(state.workspacesByID[workspaceID])
        #expect(after.selectedTab == before.selectedTab)
        let createdID = try #require(Set(after.tabIDs).subtracting(before.tabIDs).first)
        let createdTab = try #require(after.tab(id: createdID))
        let panelID = try #require(createdTab.focusedPanelID)
        #expect(createdTab.layoutTree.slotContaining(panelID: panelID) != nil)
        try StateValidator.validate(state)
    }
}
