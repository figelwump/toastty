import RemoteProtocol
import CoreState
import Foundation
import Testing

extension AppReducerTests {
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
    func splitFocusedSlotDoesNotInheritResumeRecord() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)
        let resumeRecord = makeTestResumeRecord(cwd: "/tmp/toastty/split-cwd")

        #expect(
            reducer.send(
                .updateTerminalPanelResumeRecord(panelID: focusedPanelID, resumeRecord: resumeRecord),
                state: &state
            )
        )
        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let newFocusedPanelID = try #require(workspaceAfter.focusedPanelID)
        guard case .terminal(let splitTerminalState) = workspaceAfter.panels[newFocusedPanelID] else {
            Issue.record("expected split-created panel to be terminal")
            return
        }
        guard case .terminal(let sourceTerminalState) = workspaceAfter.panels[focusedPanelID] else {
            Issue.record("expected source panel to remain terminal")
            return
        }

        #expect(splitTerminalState.resumeRecord == nil)
        #expect(sourceTerminalState.resumeRecord == resumeRecord)

        try StateValidator.validate(state)
    }

    @Test
    func reopenLastClosedTerminalPanelDoesNotRestoreResumeRecord() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)
        let resumeRecord = makeTestResumeRecord(cwd: "/tmp/toastty/reopen-cwd")
        let remoteConversationID = RemoteConversationID()

        #expect(
            reducer.send(
                .updateTerminalPanelResumeRecord(panelID: focusedPanelID, resumeRecord: resumeRecord),
                state: &state
            )
        )
        #expect(
            reducer.send(
                .updateTerminalPanelRemoteConversationID(
                    panelID: focusedPanelID,
                    remoteConversationID: remoteConversationID
                ),
                state: &state
            )
        )
        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        #expect(reducer.send(.closePanel(panelID: focusedPanelID), state: &state))
        #expect(reducer.send(.reopenLastClosedPanel(workspaceID: workspaceID), state: &state))

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let reopenedPanelID = try #require(workspaceAfter.focusedPanelID)
        guard case .terminal(let reopenedTerminalState) = workspaceAfter.panels[reopenedPanelID] else {
            Issue.record("expected reopened panel to be terminal")
            return
        }

        #expect(reopenedPanelID != focusedPanelID)
        #expect(reopenedTerminalState.resumeRecord == nil)
        #expect(reopenedTerminalState.remoteConversationID == nil)

        try StateValidator.validate(state)
    }

    @Test
    func updateTerminalPanelResumeRecordKeepsNativeSessionOnOnePanel() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        let workspaceBeforeSplit = try #require(state.workspacesByID[workspaceID])
        let sourcePanelID = try #require(workspaceBeforeSplit.focusedPanelID)
        let olderRecord = makeTestResumeRecord(
            cwd: "/tmp/toastty/source",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newerRecord = makeTestResumeRecord(
            cwd: "/tmp/toastty/split",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )

        #expect(reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state))
        let workspaceAfterSplit = try #require(state.workspacesByID[workspaceID])
        let splitPanelID = try #require(workspaceAfterSplit.focusedPanelID)
        #expect(splitPanelID != sourcePanelID)

        #expect(
            reducer.send(
                .updateTerminalPanelResumeRecord(panelID: sourcePanelID, resumeRecord: olderRecord),
                state: &state
            )
        )
        #expect(
            reducer.send(
                .updateTerminalPanelResumeRecord(panelID: splitPanelID, resumeRecord: newerRecord),
                state: &state
            )
        )

        let workspaceAfterResumeUpdate = try #require(state.workspacesByID[workspaceID])
        guard case .terminal(let sourceTerminalState) = workspaceAfterResumeUpdate.panels[sourcePanelID] else {
            Issue.record("expected source panel to remain terminal")
            return
        }
        guard case .terminal(let splitTerminalState) = workspaceAfterResumeUpdate.panels[splitPanelID] else {
            Issue.record("expected split-created panel to remain terminal")
            return
        }

        #expect(sourceTerminalState.resumeRecord == nil)
        #expect(splitTerminalState.resumeRecord == newerRecord)

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotInDirectionWithWorkingDirectorySeedsNewPanelFromExplicitDirectory() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try #require(state.windows.first?.selectedWorkspaceID)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let focusedPanelID = try #require(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[focusedPanelID] else {
            Issue.record("expected focused panel to be terminal before split")
            return
        }
        terminalState.cwd = "/tmp/toastty/source"
        workspace.panels[focusedPanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        #expect(
            reducer.send(
                .splitFocusedSlotInDirectionWithWorkingDirectory(
                    workspaceID: workspaceID,
                    direction: .right,
                    workingDirectory: "/tmp/toastty/target/../target"
                ),
                state: &state
            )
        )

        let workspaceAfter = try #require(state.workspacesByID[workspaceID])
        let newFocusedPanelID = try #require(workspaceAfter.focusedPanelID)

        guard case .terminal(let splitTerminalState) = workspaceAfter.panels[newFocusedPanelID] else {
            Issue.record("expected split-created panel to be terminal")
            return
        }
        #expect(splitTerminalState.cwd == "/tmp/toastty/target")

        guard case .terminal(let sourceTerminalState) = workspaceAfter.panels[focusedPanelID] else {
            Issue.record("expected source panel to remain terminal")
            return
        }
        #expect(sourceTerminalState.cwd == "/tmp/toastty/source")

        try StateValidator.validate(state)
    }

    @Test
    func splitFocusedSlotFallsBackToHomeCWDWhenFocusedPanelIsWeb() throws {
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

}

private func makeTestResumeRecord(
    cwd: String,
    nativeSessionID: String = "019e2823-f520-7690-91b6-cd84eb52dd8a",
    sessionFilePath: String = "/tmp/codex-session.jsonl",
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ManagedAgentResumeRecord {
    ManagedAgentResumeRecord(
        agent: .codex,
        nativeSessionID: nativeSessionID,
        sessionFilePath: sessionFilePath,
        cwd: cwd,
        capturedAt: capturedAt
    )
}
