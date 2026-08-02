import CoreState
import Foundation
import Testing

extension AppReducerTests {
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
    func windowMarkdownTextActionsAdjustAndResetScale() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)
        let defaultScale = AppState.defaultMarkdownTextScale
        let step = AppState.markdownTextScaleStep

        #expect(reducer.send(.increaseWindowMarkdownTextScale(windowID: windowID), state: &state))
        #expect(state.effectiveMarkdownTextScale(for: windowID) == defaultScale + step)
        #expect(state.window(id: windowID)?.markdownTextScaleOverride == defaultScale + step)

        #expect(reducer.send(.decreaseWindowMarkdownTextScale(windowID: windowID), state: &state))
        #expect(state.effectiveMarkdownTextScale(for: windowID) == defaultScale)
        #expect(state.window(id: windowID)?.markdownTextScaleOverride == nil)

        #expect(reducer.send(.setWindowMarkdownTextScale(windowID: windowID, scale: 1.4), state: &state))
        #expect(state.effectiveMarkdownTextScale(for: windowID) == 1.4)

        #expect(reducer.send(.resetWindowMarkdownTextScale(windowID: windowID), state: &state))
        #expect(state.effectiveMarkdownTextScale(for: windowID) == defaultScale)
        #expect(state.window(id: windowID)?.markdownTextScaleOverride == nil)

        #expect(reducer.send(.setWindowMarkdownTextScale(windowID: windowID, scale: AppState.maxMarkdownTextScale + 1), state: &state))
        #expect(state.effectiveMarkdownTextScale(for: windowID) == AppState.maxMarkdownTextScale)
        #expect(reducer.send(.increaseWindowMarkdownTextScale(windowID: windowID), state: &state) == false)

        #expect(reducer.send(.setWindowMarkdownTextScale(windowID: windowID, scale: AppState.minMarkdownTextScale), state: &state))
        #expect(state.effectiveMarkdownTextScale(for: windowID) == AppState.minMarkdownTextScale)
        #expect(reducer.send(.decreaseWindowMarkdownTextScale(windowID: windowID), state: &state) == false)
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
    func toggleFocusedPanelModePreservesVisibleRightPanelState() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser),
                    placement: .rightPanel
                ),
                state: &state
            )
        )
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        #expect(workspaceBefore.rightAuxPanel.isVisible)

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let focusedModeWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(focusedModeWorkspace.focusedPanelModeActive)
        #expect(focusedModeWorkspace.rightAuxPanel.isVisible)

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let restoredWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(restoredWorkspace.focusedPanelModeActive == false)
        #expect(restoredWorkspace.rightAuxPanel.isVisible)

        try StateValidator.validate(state)
    }

    @Test
    func toggleFocusedPanelModePreservesHiddenRightPanelState() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let focusedModeWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(focusedModeWorkspace.focusedPanelModeActive)
        #expect(focusedModeWorkspace.rightAuxPanel.isVisible == false)

        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let restoredWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(restoredWorkspace.focusedPanelModeActive == false)
        #expect(restoredWorkspace.rightAuxPanel.isVisible == false)

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
    func splitInFocusModeUpdatesFocusModeRootNodeIDWhileWebPanelCreationStillWorks() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let workspaceInFocusMode = try #require(state.workspacesByID[workspaceID])
        let previousRootNodeID = workspaceInFocusMode.focusModeRootNodeID

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
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

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.panels.count == 3)
        #expect(updatedWorkspace.focusModeRootNodeID != previousRootNodeID)
        guard case .split(let splitNodeID, _, _, _, _) = updatedWorkspace.layoutTree else {
            Issue.record("expected bootstrap workspace to split in focus mode")
            return
        }
        #expect(updatedWorkspace.focusModeRootNodeID == splitNodeID)

        try StateValidator.validate(state)
    }

    @Test
    func rightPanelWebPanelCreationInFocusModeDoesNotPromoteNewRoot() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()

        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        #expect(reducer.send(.toggleFocusedPanelMode(workspaceID: workspaceID), state: &state))
        let workspaceBefore = try #require(state.workspacesByID[workspaceID])
        let focusedPanelIDBefore = workspaceBefore.focusedPanelID
        let focusModeRootNodeIDBefore = workspaceBefore.focusModeRootNodeID
        let layoutTreeBefore = workspaceBefore.layoutTree

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        let workspace = try #require(state.workspacesByID[workspaceID])
        #expect(workspace.focusedPanelModeActive)
        #expect(workspace.layoutTree == layoutTreeBefore)
        #expect(workspace.focusModeRootNodeID == focusModeRootNodeIDBefore)
        #expect(workspace.focusedPanelID == focusedPanelIDBefore)
        #expect(workspace.rightAuxPanel.tabIDs.count == 1)

        try StateValidator.validate(state)
    }

    @Test
    func rightPanelWebPanelCreationDoesNotExpandFocusedSubtree() throws {
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
                leftPanelID: .terminal(TerminalPanelState(title: "Left", shell: "zsh", cwd: "/tmp/left")),
                topRightPanelID: .terminal(TerminalPanelState(title: "Top Right", shell: "zsh", cwd: "/tmp/top-right")),
                bottomRightPanelID: .terminal(TerminalPanelState(title: "Bottom Right", shell: "zsh", cwd: "/tmp/bottom-right")),
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

        #expect(
            reducer.send(
                .createWebPanel(
                    workspaceID: workspaceID,
                    panel: WebPanelState(definition: .browser),
                    placement: .rightPanel
                ),
                state: &state
            )
        )

        let updatedWorkspace = try #require(state.workspacesByID[workspaceID])
        #expect(updatedWorkspace.focusedPanelModeActive)
        #expect(updatedWorkspace.layoutTree == workspace.layoutTree)
        #expect(updatedWorkspace.focusModeRootNodeID == rightBranchNodeID)
        #expect(updatedWorkspace.focusedPanelID == topRightPanelID)
        #expect(updatedWorkspace.rightAuxPanel.tabIDs.count == 1)

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

}
