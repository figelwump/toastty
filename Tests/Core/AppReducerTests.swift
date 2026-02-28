import CoreState
import Foundation
import Testing

struct AppReducerTests {
    @Test
    func splitFocusedPaneCreatesSplitAndNewTerminalPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let oldPanelCount = workspaceBefore.panels.count

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.panels.count == oldPanelCount + 1)

        if case .split(_, .horizontal, _, _, _) = workspaceAfter.paneTree {
            // expected shape after first split
        } else {
            Issue.record("expected split root after first split")
        }

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedPaneInDirectionSupportsLeadingPlacements() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let sourcePanelID = try #require(workspaceBefore.focusedPanelID)

        #expect(reducer.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .left), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, let orientation, _, let first, let second) = workspaceAfter.paneTree else {
            Issue.record("expected split root after directional split")
            return
        }

        #expect(orientation == .horizontal)
        guard case .leaf(_, let firstTabs, _ ) = first,
              case .leaf(_, let secondTabs, _ ) = second else {
            Issue.record("expected leaf children in split root")
            return
        }
        #expect(firstTabs.contains(sourcePanelID) == false)
        #expect(secondTabs.contains(sourcePanelID))
        #expect(workspaceAfter.focusedPanelID != sourcePanelID)

        try StateValidator.validate(state)
    }

    @Test
    func focusPaneMovesToNextAndPreviousLeaf() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let initialWorkspace = try #require(state.workspacesByID[workspaceID])
        let sourcePanelID = try #require(initialWorkspace.focusedPanelID)

        #expect(reducer.send(.focusPane(workspaceID: workspaceID, direction: .next), state: &state))
        let nextWorkspace = try #require(state.workspacesByID[workspaceID])
        let nextPanelID = try #require(nextWorkspace.focusedPanelID)
        #expect(nextPanelID != sourcePanelID)

        #expect(reducer.send(.focusPane(workspaceID: workspaceID, direction: .previous), state: &state))
        let previousWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(previousWorkspace.focusedPanelID == sourcePanelID)

        try StateValidator.validate(state)
    }

    @Test
    func focusPaneDirectionalMovesToSpatialNeighbor() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .vertical), state: &state))
        let workspaceAfterSplit = try #require(state.workspacesByID[workspaceID])
        let panelAfterSplit = try #require(workspaceAfterSplit.focusedPanelID)

        #expect(reducer.send(.focusPane(workspaceID: workspaceID, direction: .up), state: &state))
        let workspaceAfterMove = try #require(state.workspacesByID[workspaceID])
        let movedPanelID = try #require(workspaceAfterMove.focusedPanelID)
        #expect(movedPanelID != panelAfterSplit)
        #expect(
            reducer.send(.focusPane(workspaceID: workspaceID, direction: .down), state: &state),
            "downward move should return to lower pane"
        )
        let workspaceAfterReturn = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterReturn.focusedPanelID == panelAfterSplit)

        try StateValidator.validate(state)
    }

    @Test
    func createTerminalPanelAppendsToTargetPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let paneID = try #require(workspace.paneTree.allLeafInfos.first?.paneID)
        let existingCount = workspace.paneTree.allLeafInfos.first?.tabPanelIDs.count ?? 0

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedLeaf = try #require(updatedWorkspace.paneTree.allLeafInfos.first)
        #expect(updatedLeaf.tabPanelIDs.count == existingCount + 1)

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedPaneRecoversFromStaleFocusedPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        workspace.focusedPanelID = UUID()
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .vertical), state: &state))

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
        let paneID = try #require(workspace.paneTree.allLeafInfos.first?.paneID)

        let panelOne = UUID()
        let panelThree = UUID()
        workspace.panels = [
            panelOne: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            panelThree: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
        ]
        workspace.paneTree = .leaf(paneID: paneID, tabPanelIDs: [panelOne, panelThree], selectedIndex: 1)
        workspace.focusedPanelID = panelThree
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))

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
    func reorderPanelRepositionsTabWithinPane() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let paneID = try #require(workspace.paneTree.allLeafInfos.first?.paneID)

        let panelA = UUID()
        let panelB = UUID()
        let panelC = UUID()
        workspace.panels = [
            panelA: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            panelB: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            panelC: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
        ]
        workspace.paneTree = .leaf(paneID: paneID, tabPanelIDs: [panelA, panelB, panelC], selectedIndex: 1)
        workspace.focusedPanelID = panelB
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.reorderPanel(panelID: panelA, toIndex: 2, inPaneID: paneID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedLeaf = try #require(updatedWorkspace.paneTree.allLeafInfos.first)
        #expect(updatedLeaf.tabPanelIDs == [panelB, panelC, panelA])
        #expect(updatedLeaf.selectedIndex == 0)

        try StateValidator.validate(state)
    }

    @Test
    func movePanelToPaneCollapsesEmptySourceLeaf() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let leaves = workspace.paneTree.allLeafInfos
        let sourceLeaf = try #require(leaves.first)
        let targetLeaf = try #require(leaves.last)
        let panelToMove = try #require(sourceLeaf.tabPanelIDs.first)

        #expect(reducer.send(.movePanelToPane(panelID: panelToMove, targetPaneID: targetLeaf.paneID, index: nil), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        let updatedLeaves = updatedWorkspace.paneTree.allLeafInfos
        #expect(updatedLeaves.count == 1)
        #expect(updatedLeaves[0].paneID == targetLeaf.paneID)
        #expect(updatedLeaves[0].tabPanelIDs.contains(panelToMove))
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

        #expect(reducer.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetPaneID: nil), state: &state))

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
    func detachPanelToNewWindowCreatesDetachedWorkspace() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let paneID = try #require(state.workspacesByID[workspaceID]?.paneTree.allLeafInfos.first?.paneID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))
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
    func movePanelToWorkspaceWithUnknownTargetPaneDoesNotMutateSource() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "two-workspaces"))
        let reducer = AppReducer()

        let sourceWorkspaceID = try #require(state.windows.first?.workspaceIDs.first)
        let targetWorkspaceID = try #require(state.windows.first?.workspaceIDs.last)
        let panelID = try #require(state.workspacesByID[sourceWorkspaceID]?.focusedPanelID)

        let sourceWorkspaceBefore = try #require(state.workspacesByID[sourceWorkspaceID])
        let sourcePanelCountBefore = sourceWorkspaceBefore.panels.count
        let targetWorkspaceBefore = try #require(state.workspacesByID[targetWorkspaceID])
        let targetPanelCountBefore = targetWorkspaceBefore.panels.count

        #expect(reducer.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetPaneID: UUID()), state: &state) == false)

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

        if case .split(_, .horizontal, _, _, _) = workspace.paneTree {
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
        #expect(workspace.paneTree.allLeafInfos.count == 1)

        try StateValidator.validate(state)
    }

    @Test
    func toggleAuxPanelAddsSeparatePaneInRightColumn() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let rightPaneIDBefore = try #require(workspaceBefore.paneTree.rightColumnPaneID())

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.paneTree.allLeafInfos.count == 3)
        let rightPaneAfter = try #require(workspaceAfter.paneTree.allLeafInfos.first(where: { $0.paneID == rightPaneIDBefore }))
        let markdownPanelIDs = workspaceAfter.panels.filter { $0.value.kind == .markdown }.map(\.key)
        #expect(markdownPanelIDs.count == 1)
        #expect(rightPaneAfter.tabPanelIDs.contains(markdownPanelIDs[0]) == false)
        let markdownPane = try #require(
            workspaceAfter.paneTree.allLeafInfos.first(where: { $0.tabPanelIDs.contains(markdownPanelIDs[0]) })
        )
        #expect(markdownPane.tabPanelIDs.count == 1)

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
        #expect(workspace.paneTree.allLeafInfos.count == 3)

        let diffPanelID = try #require(workspace.panels.first(where: { $0.value.kind == .diff })?.key)
        let markdownPanelID = try #require(workspace.panels.first(where: { $0.value.kind == .markdown })?.key)
        let diffPane = try #require(workspace.paneTree.allLeafInfos.first(where: { $0.tabPanelIDs.contains(diffPanelID) }))
        let markdownPane = try #require(workspace.paneTree.allLeafInfos.first(where: { $0.tabPanelIDs.contains(markdownPanelID) }))

        #expect(diffPane.paneID != markdownPane.paneID)
        #expect(diffPane.tabPanelIDs.count == 1)
        #expect(markdownPane.tabPanelIDs.count == 1)

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
        #expect(workspace.paneTree.allLeafInfos.count == 2)
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

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .vertical), state: &state))
        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .vertical), state: &state))

        let workspaceBeforeAux = try #require(state.workspacesByID[workspaceID])
        let terminalPanelIDs = Set(workspaceBeforeAux.panels.compactMap { panelID, panelState in
            panelState.kind == .terminal ? panelID : nil
        })
        let leafCountBeforeAux = workspaceBeforeAux.paneTree.allLeafInfos.count

        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state))
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .markdown), state: &state))

        let workspaceAfterAux = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterAux.paneTree.allLeafInfos.count == leafCountBeforeAux + 2)

        let auxPanelIDs = Set(workspaceAfterAux.panels.compactMap { panelID, panelState in
            panelState.kind == .terminal ? nil : panelID
        })
        #expect(auxPanelIDs.count == 2)

        let auxLeaves = workspaceAfterAux.paneTree.allLeafInfos.filter { leaf in
            leaf.tabPanelIDs.contains(where: { auxPanelIDs.contains($0) })
        }
        #expect(auxLeaves.count == 2)
        if case .split(_, .horizontal, _, let terminalSubtree, let auxSubtree) = workspaceAfterAux.paneTree {
            let terminalSubtreePanelIDs = Set(terminalSubtree.allLeafInfos.flatMap(\.tabPanelIDs))
            let auxSubtreePanelIDs = Set(auxSubtree.allLeafInfos.flatMap(\.tabPanelIDs))
            #expect(auxSubtreePanelIDs.isSuperset(of: auxPanelIDs))
            #expect(terminalSubtreePanelIDs.isDisjoint(with: auxPanelIDs))
        } else {
            Issue.record("expected root horizontal split with dedicated aux subtree")
        }

        for leaf in auxLeaves {
            #expect(leaf.tabPanelIDs.count == 1)
            #expect(leaf.tabPanelIDs.contains(where: { terminalPanelIDs.contains($0) }) == false)
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
        #expect(workspace.paneTree.allLeafInfos.count == 4)

        let auxPanelIDs = Set(workspace.panels.compactMap { panelID, panelState in
            panelState.kind == .terminal ? nil : panelID
        })
        #expect(auxPanelIDs.count == 3)

        if case .split(_, .horizontal, _, let terminalSubtree, let auxSubtree) = workspace.paneTree {
            let terminalSubtreePanelIDs = Set(terminalSubtree.allLeafInfos.flatMap(\.tabPanelIDs))
            let auxSubtreePanelIDs = Set(auxSubtree.allLeafInfos.flatMap(\.tabPanelIDs))
            #expect(auxSubtreePanelIDs.isSuperset(of: auxPanelIDs))
            #expect(terminalSubtreePanelIDs.isDisjoint(with: auxPanelIDs))
        } else {
            Issue.record("expected root horizontal split with dedicated aux subtree")
        }

        let auxLeaves = workspace.paneTree.allLeafInfos.filter { leaf in
            leaf.tabPanelIDs.contains(where: { auxPanelIDs.contains($0) })
        }
        #expect(auxLeaves.count == 3)
        for leaf in auxLeaves {
            #expect(leaf.tabPanelIDs.count == 1)
        }

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
        let paneID = try #require(state.workspacesByID[workspaceID]?.paneTree.allLeafInfos.first?.paneID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))
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
    func reopenFallsBackToFocusedPaneWhenOriginalPaneWasRemoved() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let sourcePane = try #require(workspace.paneTree.allLeafInfos.first)
        let panelToClose = try #require(sourcePane.tabPanelIDs.first)

        #expect(reducer.send(.closePanel(panelID: panelToClose), state: &state))
        let collapsedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(collapsedWorkspace.paneTree.allLeafInfos.count == 1)

        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))
        let reopenedWorkspace = try #require(state.workspacesByID[workspaceID])
        let onlyLeaf = try #require(reopenedWorkspace.paneTree.allLeafInfos.first)
        #expect(onlyLeaf.tabPanelIDs.count == 2)

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
    func resizeFocusedPaneSplitAdjustsNearestMatchingRatio() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let initialWorkspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(_, let orientation, let initialRatio, _, _) = initialWorkspace.paneTree else {
            Issue.record("expected split-workspace fixture to have split root")
            return
        }
        #expect(orientation == .horizontal)

        #expect(
            reducer.send(
                .resizeFocusedPaneSplit(workspaceID: workspaceID, direction: .right, amount: 2),
                state: &state
            )
        )

        let resizedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let resizedRatio, _, _) = resizedWorkspace.paneTree else {
            Issue.record("expected split root after resize")
            return
        }

        #expect(resizedRatio > initialRatio)
        #expect(abs(resizedRatio - (initialRatio + 0.04)) < 0.0001)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedPaneSplitReturnsFalseWhenNoMatchingSplitOrientationExists() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])

        #expect(
            reducer.send(
                .resizeFocusedPaneSplit(workspaceID: workspaceID, direction: .up, amount: 1),
                state: &state
            ) == false
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.paneTree == workspaceBefore.paneTree)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedPaneSplitUsesNearestMatchingAncestor() throws {
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

        let focusedPaneID = UUID()
        let siblingPaneID = UUID()
        let rightPaneID = UUID()
        let nestedSplitNodeID = UUID()
        let rootSplitNodeID = UUID()
        workspace.paneTree = .split(
            nodeID: rootSplitNodeID,
            orientation: .horizontal,
            ratio: 0.5,
            first: .split(
                nodeID: nestedSplitNodeID,
                orientation: .horizontal,
                ratio: 0.6,
                first: .leaf(paneID: focusedPaneID, tabPanelIDs: [focusedPanelID], selectedIndex: 0),
                second: .leaf(paneID: siblingPaneID, tabPanelIDs: [siblingPanelID], selectedIndex: 0)
            ),
            second: .leaf(paneID: rightPaneID, tabPanelIDs: [rightPanelID], selectedIndex: 0)
        )
        workspace.focusedPanelID = focusedPanelID
        state.workspacesByID[workspaceID] = workspace

        #expect(
            reducer.send(
                .resizeFocusedPaneSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            )
        )

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let rootRatio, let firstNode, _) = updatedWorkspace.paneTree,
              case .split(_, _, let nestedRatio, _, _) = firstNode else {
            Issue.record("expected nested horizontal split tree after resize")
            return
        }

        #expect(rootRatio == 0.5)
        #expect(abs(nestedRatio - 0.62) < 0.0001)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedPaneSplitClampsAtUpperBound() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .resizeFocusedPaneSplit(workspaceID: workspaceID, direction: .right, amount: Int.max),
                state: &state
            )
        )

        let workspaceAfterFirstResize = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let ratioAfterFirstResize, _, _) = workspaceAfterFirstResize.paneTree else {
            Issue.record("expected split tree after clamped resize")
            return
        }
        #expect(ratioAfterFirstResize == 0.9)

        #expect(
            reducer.send(
                .resizeFocusedPaneSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            ) == false
        )
        let workspaceAfterSecondResize = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterSecondResize.paneTree == workspaceAfterFirstResize.paneTree)
        try StateValidator.validate(state)
    }

    @Test
    func equalizePaneSplitsNormalizesNestedRatios() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(_, _, _, let first, let second) = workspace.paneTree,
              case .leaf(let leftPaneID, let leftTabs, let leftSelectedIndex) = first,
              case .leaf(let rightPaneID, let rightTabs, let rightSelectedIndex) = second,
              let leftPanelID = leftTabs.first,
              let rightPanelID = rightTabs.first else {
            Issue.record("expected split-workspace fixture to expose two terminal leaves")
            return
        }

        let extraPanelID = UUID()
        let extraPaneID = UUID()
        workspace.panels[extraPanelID] = .terminal(
            TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")
        )
        let nestedSecond = PaneNode.split(
            nodeID: UUID(),
            orientation: .vertical,
            ratio: 0.8,
            first: .leaf(paneID: rightPaneID, tabPanelIDs: [rightPanelID], selectedIndex: rightSelectedIndex),
            second: .leaf(paneID: extraPaneID, tabPanelIDs: [extraPanelID], selectedIndex: 0)
        )
        workspace.paneTree = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.7,
            first: .leaf(paneID: leftPaneID, tabPanelIDs: [leftPanelID], selectedIndex: leftSelectedIndex),
            second: nestedSecond
        )
        workspace.focusedPanelID = leftPanelID
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.equalizePaneSplits(workspaceID: workspaceID), state: &state))

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let rootRatio, _, let updatedSecond) = updatedWorkspace.paneTree,
              case .split(_, _, let nestedRatio, _, _) = updatedSecond else {
            Issue.record("expected nested split tree after equalize")
            return
        }

        #expect(rootRatio == 0.5)
        #expect(nestedRatio == 0.5)
        #expect(reducer.send(.equalizePaneSplits(workspaceID: workspaceID), state: &state) == false)
        try StateValidator.validate(state)
    }

    @Test
    func globalFontActionsAdjustAndResetFontSize() {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let defaultPoints = AppState.defaultTerminalFontPoints
        let step = AppState.terminalFontStepPoints

        #expect(reducer.send(.increaseGlobalTerminalFont, state: &state))
        #expect(state.globalTerminalFontPoints == defaultPoints + step)

        #expect(reducer.send(.decreaseGlobalTerminalFont, state: &state))
        #expect(state.globalTerminalFontPoints == defaultPoints)

        #expect(reducer.send(.increaseGlobalTerminalFont, state: &state))
        #expect(reducer.send(.increaseGlobalTerminalFont, state: &state))
        #expect(state.globalTerminalFontPoints == defaultPoints + (step * 2))

        #expect(reducer.send(.resetGlobalTerminalFont, state: &state))
        #expect(state.globalTerminalFontPoints == defaultPoints)
    }

    @Test
    func globalFontActionsClampAtBounds() {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let defaultPoints = AppState.defaultTerminalFontPoints

        state.globalTerminalFontPoints = AppState.maxTerminalFontPoints
        #expect(reducer.send(.increaseGlobalTerminalFont, state: &state) == false)
        #expect(state.globalTerminalFontPoints == AppState.maxTerminalFontPoints)

        state.globalTerminalFontPoints = AppState.minTerminalFontPoints
        #expect(reducer.send(.decreaseGlobalTerminalFont, state: &state) == false)
        #expect(state.globalTerminalFontPoints == AppState.minTerminalFontPoints)

        state.globalTerminalFontPoints = defaultPoints
        #expect(reducer.send(.resetGlobalTerminalFont, state: &state) == false)
        #expect(state.globalTerminalFontPoints == defaultPoints)
    }

    @Test
    func toggleFocusedPanelModeRoundTripPreservesLayoutAndFocus() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let focusedModeWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(focusedModeWorkspace.focusedPanelModeActive)
        #expect(focusedModeWorkspace.paneTree == workspaceBefore.paneTree)
        #expect(focusedModeWorkspace.focusedPanelID == workspaceBefore.focusedPanelID)

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let restoredWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(restoredWorkspace.focusedPanelModeActive == false)
        #expect(restoredWorkspace.paneTree == workspaceBefore.paneTree)
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

        try StateValidator.validate(state)
    }

    @Test
    func splitAndAuxToggleAreBlockedWhileFocusedModeActive() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let workspaceInFocusMode = try #require(state.workspacesByID[workspaceID])

        #expect(reducer.send(.splitFocusedPane(workspaceID: workspaceID, orientation: .horizontal), state: &state) == false)
        #expect(reducer.send(.toggleAuxPanel(workspaceID: workspaceID, kind: .diff), state: &state) == false)

        let workspaceAfterBlockedActions = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterBlockedActions == workspaceInFocusMode)

        try StateValidator.validate(state)
    }

    @Test
    func closePanelKeepsFocusedModeActive() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let paneID = try #require(state.workspacesByID[workspaceID]?.paneTree.allLeafInfos.first?.paneID)

        #expect(reducer.send(.createTerminalPanel(workspaceID: workspaceID, paneID: paneID), state: &state))
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
    func resizeAndEqualizeAreBlockedWhileFocusedModeActive() throws {
        var state = try #require(AutomationFixtureLoader.load(named: "split-workspace"))
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        guard case .split(let nodeID, let orientation, _, let first, let second) = workspace.paneTree else {
            Issue.record("expected split-workspace fixture to have split root")
            return
        }
        workspace.paneTree = .split(
            nodeID: nodeID,
            orientation: orientation,
            ratio: 0.7,
            first: first,
            second: second
        )
        state.workspacesByID[workspaceID] = workspace

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let focusedModeWorkspace = try #require(state.workspacesByID[workspaceID])

        #expect(
            reducer.send(
                .resizeFocusedPaneSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            ) == false
        )
        #expect(reducer.send(.equalizePaneSplits(workspaceID: workspaceID), state: &state) == false)

        let workspaceAfterBlockedActions = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfterBlockedActions == focusedModeWorkspace)

        try StateValidator.validate(state)
    }
}
