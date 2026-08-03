import CoreState
import Foundation
import Testing

extension AppReducerTests {
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

}
