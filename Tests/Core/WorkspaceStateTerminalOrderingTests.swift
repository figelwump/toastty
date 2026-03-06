import CoreState
import Foundation
import Testing

struct WorkspaceStateTerminalOrderingTests {
    @Test
    func terminalPanelIDsInDisplayOrderUsesLeafTraversal() {
        let leftTerminalID = UUID()
        let topRightTerminalID = UUID()
        let bottomRightTerminalID = UUID()
        let hiddenDiffID = UUID()

        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.6,
                first: .slot(
                    slotID: UUID(),
                    panelID: leftTerminalID
                ),
                second: .split(
                    nodeID: UUID(),
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(
                        slotID: UUID(),
                        panelID: topRightTerminalID
                    ),
                    second: .slot(
                        slotID: UUID(),
                        panelID: hiddenDiffID
                    )
                )
            ),
            panels: [
                leftTerminalID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                topRightTerminalID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
                bottomRightTerminalID: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
                hiddenDiffID: .diff(DiffPanelState()),
            ],
            focusedPanelID: leftTerminalID
        )

        var workspaceWithTrailingTerminal = workspace
        workspaceWithTrailingTerminal.layoutTree = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.6,
            first: workspace.layoutTree,
            second: .slot(slotID: UUID(), panelID: bottomRightTerminalID)
        )

        #expect(
            workspaceWithTrailingTerminal.terminalPanelIDsInDisplayOrder ==
                [leftTerminalID, topRightTerminalID, bottomRightTerminalID]
        )
    }

    @Test
    func terminalPanelIDForDisplayShortcutNumberIsOneBased() {
        let workspace = makeThreeTerminalWorkspace()
        let orderedPanels = workspace.terminalPanelIDsInDisplayOrder

        #expect(workspace.terminalPanelID(forDisplayShortcutNumber: 1) == orderedPanels[0])
        #expect(workspace.terminalPanelID(forDisplayShortcutNumber: 2) == orderedPanels[1])
        #expect(workspace.terminalPanelID(forDisplayShortcutNumber: 3) == orderedPanels[2])
        #expect(workspace.terminalPanelID(forDisplayShortcutNumber: 0) == nil)
        #expect(workspace.terminalPanelID(forDisplayShortcutNumber: 4) == nil)
    }

    @Test
    func terminalShortcutNumbersByPanelIDHonorsLimit() {
        let workspace = makeThreeTerminalWorkspace()
        let orderedPanels = workspace.terminalPanelIDsInDisplayOrder

        let shortcuts = workspace.terminalShortcutNumbersByPanelID(limit: 2)
        #expect(shortcuts.count == 2)
        #expect(shortcuts[orderedPanels[0]] == 1)
        #expect(shortcuts[orderedPanels[1]] == 2)
        #expect(shortcuts[orderedPanels[2]] == nil)
    }

    @Test
    func terminalShortcutNumbersAlignWithShortcutLookup() {
        let workspace = makeThreeTerminalWorkspace()
        let shortcuts = workspace.terminalShortcutNumbersByPanelID(limit: 10)

        for (panelID, shortcutNumber) in shortcuts {
            #expect(workspace.terminalPanelID(forDisplayShortcutNumber: shortcutNumber) == panelID)
        }
    }

    @Test
    func terminalShortcutNumbersCompactAfterPanelRemoval() throws {
        var workspace = makeThreeTerminalWorkspace()
        let orderedBefore = workspace.terminalPanelIDsInDisplayOrder
        let removedPanelID = orderedBefore[1]

        let removal = workspace.layoutTree.removingPanel(removedPanelID)
        workspace.layoutTree = try #require(removal.node)
        workspace.panels.removeValue(forKey: removedPanelID)

        let orderedAfter = workspace.terminalPanelIDsInDisplayOrder
        #expect(orderedAfter == [orderedBefore[0], orderedBefore[2]])

        let shortcuts = workspace.terminalShortcutNumbersByPanelID(limit: 10)
        #expect(shortcuts[orderedBefore[0]] == 1)
        #expect(shortcuts[orderedBefore[2]] == 2)
    }

    private func makeThreeTerminalWorkspace() -> WorkspaceState {
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let thirdPanelID = UUID()

        return WorkspaceState(
            id: UUID(),
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: firstPanelID),
                second: .split(
                    nodeID: UUID(),
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: UUID(), panelID: secondPanelID),
                    second: .slot(slotID: UUID(), panelID: thirdPanelID)
                )
            ),
            panels: [
                firstPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                secondPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
                thirdPanelID: .terminal(TerminalPanelState(title: "Terminal 3", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: firstPanelID
        )
    }
}
