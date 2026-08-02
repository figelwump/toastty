import CoreState
import Foundation
import Testing

extension AppReducerTests {
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
    func setLayoutSplitRatioCommitsSelectedTabRatio() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        guard case .split(let nodeID, _, _, _, _) = workspaceBefore.layoutTree else {
            Issue.record("expected split root before setting ratio")
            return
        }

        #expect(
            reducer.send(
                .setLayoutSplitRatio(workspaceID: workspaceID, nodeID: nodeID, ratio: 0.72),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let ratio, _, _) = workspaceAfter.layoutTree else {
            Issue.record("expected split root after setting ratio")
            return
        }

        #expect(ratio == 0.72)
        try StateValidator.validate(state)
    }

    @Test
    func setLayoutSplitRatioReturnsFalseForMissingNode() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])

        #expect(
            reducer.send(
                .setLayoutSplitRatio(workspaceID: workspaceID, nodeID: UUID(), ratio: 0.72),
                state: &state
            ) == false
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree == workspaceBefore.layoutTree)
        try StateValidator.validate(state)
    }

    @Test
    func setLayoutSplitRatioIsRejectedInFocusedPanelMode() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))

        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        guard case .split(let nodeID, _, _, _, _) = workspaceBefore.layoutTree else {
            Issue.record("expected split root before setting ratio")
            return
        }
        #expect(workspaceBefore.focusedPanelModeActive)

        #expect(
            reducer.send(
                .setLayoutSplitRatio(workspaceID: workspaceID, nodeID: nodeID, ratio: 0.72),
                state: &state
            ) == false
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree == workspaceBefore.layoutTree)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitAdjustsFocusedRightPanelWidth() throws {
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

        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let initialWidth = workspaceBefore.rightAuxPanel.width
        let initialLayoutTree = workspaceBefore.layoutTree
        #expect(workspaceBefore.rightAuxPanel.focusedPanelID != nil)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .left, amount: 2),
                state: &state
            )
        )

        var workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.rightAuxPanel.width == initialWidth + 10)
        #expect(workspaceAfter.rightAuxPanel.hasCustomWidth)
        #expect(workspaceAfter.layoutTree == initialLayoutTree)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 1),
                state: &state
            )
        )

        workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.rightAuxPanel.width == initialWidth + 5)
        #expect(workspaceAfter.layoutTree == initialLayoutTree)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitDoesNotResizeMainLayoutVerticallyWhenRightPanelFocused() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .vertical), state: &state))
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

        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceBefore.rightAuxPanel.focusedPanelID != nil)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .up, amount: 2),
                state: &state
            ) == false
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.layoutTree == workspaceBefore.layoutTree)
        #expect(workspaceAfter.rightAuxPanel.width == workspaceBefore.rightAuxPanel.width)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitIgnoresPreservedRightPanelFocusInFocusedPanelMode() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])

        let focusedPanelID = UUID()
        let siblingPanelID = UUID()
        let focusedSlotID = UUID()
        let siblingSlotID = UUID()
        let rootNodeID = UUID()
        workspace.panels = [
            focusedPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            siblingPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
        ]
        workspace.layoutTree = .split(
            nodeID: rootNodeID,
            orientation: .vertical,
            ratio: 0.5,
            first: .slot(slotID: focusedSlotID, panelID: focusedPanelID),
            second: .slot(slotID: siblingSlotID, panelID: siblingPanelID)
        )
        workspace.focusedPanelID = focusedPanelID
        workspace.focusedPanelModeActive = true
        workspace.focusModeRootNodeID = rootNodeID

        let rightAuxPanelID = UUID()
        let rightAuxTabID = UUID()
        let webState = WebPanelState(definition: .browser, title: "Docs")
        workspace.rightAuxPanel = RightAuxPanelState(
            isVisible: true,
            activeTabID: rightAuxTabID,
            tabIDs: [rightAuxTabID],
            tabsByID: [
                rightAuxTabID: RightAuxPanelTabState(
                    id: rightAuxTabID,
                    identity: RightAuxPanelTabIdentity.identity(for: webState, panelID: rightAuxPanelID),
                    panelID: rightAuxPanelID,
                    panelState: .web(webState)
                ),
            ],
            focusedPanelID: rightAuxPanelID
        )
        state.workspacesByID[workspaceID] = workspace

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .down, amount: 2),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let resizedRatio, _, _) = workspaceAfter.layoutTree else {
            Issue.record("expected vertical split root after resize")
            return
        }
        #expect(resizedRatio > 0.5)
        #expect(workspaceAfter.rightAuxPanel.width == workspace.rightAuxPanel.width)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitAdjustsRightPanelWidthFromSingleAdjacentMainPanel() throws {
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
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: mainPanelID), state: &state))

        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let initialWidth = workspaceBefore.rightAuxPanel.width
        let initialLayoutTree = workspaceBefore.layoutTree
        #expect(workspaceBefore.rightAuxPanel.focusedPanelID == nil)

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 2),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceAfter.rightAuxPanel.width == initialWidth - 10)
        #expect(workspaceAfter.rightAuxPanel.hasCustomWidth)
        #expect(workspaceAfter.layoutTree == initialLayoutTree)
        try StateValidator.validate(state)
    }

    @Test
    func resizeFocusedSlotSplitPrefersRightPanelBoundaryForRightEdgeMainPanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        let mainRightPanelID = try #require(state.workspacesByID[workspaceID]?.focusedPanelID)
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
        #expect(reducer.send(.focusPanel(workspaceID: workspaceID, panelID: mainRightPanelID), state: &state))

        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let initialWidth = workspaceBefore.rightAuxPanel.width
        guard case .split(_, _, let initialRatio, _, _) = workspaceBefore.layoutTree else {
            Issue.record("expected horizontal split root before resize")
            return
        }

        #expect(
            reducer.send(
                .resizeFocusedSlotSplit(workspaceID: workspaceID, direction: .right, amount: 2),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        guard case .split(_, _, let resizedRatio, _, _) = workspaceAfter.layoutTree else {
            Issue.record("expected horizontal split root after resize")
            return
        }

        #expect(workspaceAfter.rightAuxPanel.width == initialWidth - 10)
        #expect(workspaceAfter.rightAuxPanel.hasCustomWidth)
        #expect(resizedRatio == initialRatio)
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

}
