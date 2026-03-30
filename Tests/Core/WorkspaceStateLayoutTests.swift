@testable import CoreState
import Foundation
import Testing

struct WorkspaceStateLayoutTests {
    @Test
    func unreadPanelCountTracksPanelsSeparatelyFromWorkspaceLevelNotifications() {
        var workspace = WorkspaceState.bootstrap(title: "Workspace")
        let unreadPanelID = UUID()
        let unreadTab = WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: UUID(), panelID: unreadPanelID),
            panels: [
                unreadPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: unreadPanelID,
            unreadPanelIDs: [unreadPanelID]
        )

        workspace.appendTab(unreadTab, select: false)
        workspace.unreadWorkspaceNotificationCount = 2

        #expect(workspace.unreadPanelCount == 1)
        #expect(workspace.unreadNotificationCount == 3)
    }

    @Test
    func synchronizeFocusedPanelToLayoutRepairsStaleFocus() throws {
        let panelID = UUID()
        let slotID = UUID()
        var workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: UUID()
        )

        let resolution = workspace.synchronizeFocusedPanelToLayout()
        let resolvedFocus = try #require(resolution)

        #expect(resolvedFocus.panelID == panelID)
        #expect(resolvedFocus.slot == SlotInfo(slotID: slotID, panelID: panelID))
        #expect(workspace.focusedPanelID == panelID)
    }

    @Test
    func insertionSlotIDUsesFocusedSlotAndRejectsUnknownPreferredSlot() {
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let firstSlotID = UUID()
        let secondSlotID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: firstSlotID, panelID: firstPanelID),
                second: .slot(slotID: secondSlotID, panelID: secondPanelID)
            ),
            panels: [
                firstPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                secondPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: secondPanelID
        )

        #expect(workspace.insertionSlotID(preferred: nil) == secondSlotID)
        #expect(workspace.insertionSlotID(preferred: UUID()) == nil)
    }

    @Test
    func panelIDForSlotIDIgnoresOrphanedPanelsInLayoutTree() {
        let orphanedPanelID = UUID()
        let livePanelID = UUID()
        let orphanedSlotID = UUID()
        let liveSlotID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: orphanedSlotID, panelID: orphanedPanelID),
                second: .slot(slotID: liveSlotID, panelID: livePanelID)
            ),
            panels: [
                livePanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: livePanelID
        )

        #expect(workspace.panelID(forSlotID: orphanedSlotID) == nil)
        #expect(workspace.panelID(forSlotID: liveSlotID) == livePanelID)
    }

    @Test
    func focusedPanelIDAfterClosingUsesPreviousTraversalFallback() {
        let closedPanelID = UUID()
        let previousPanelID = UUID()
        let remainingPanelID = UUID()
        let previousSlotID = UUID()
        let remainingSlotID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: previousSlotID, panelID: previousPanelID),
                second: .slot(slotID: remainingSlotID, panelID: remainingPanelID)
            ),
            panels: [
                previousPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
                remainingPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: closedPanelID
        )

        let restoredPanelID = workspace.focusedPanelIDAfterClosing(
            closedPanelID: closedPanelID,
            closedPanelWasFocused: true,
            previousSlotIDBeforeRemoval: previousSlotID
        )

        #expect(restoredPanelID == previousPanelID)
    }

    @Test
    func focusedPanelIDAfterClosingFallsBackToResolvedPanelWhenPreviousSlotIsMissing() {
        let closedPanelID = UUID()
        let remainingPanelID = UUID()
        let remainingSlotID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            layoutTree: .slot(slotID: remainingSlotID, panelID: remainingPanelID),
            panels: [
                remainingPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: closedPanelID
        )

        let restoredPanelID = workspace.focusedPanelIDAfterClosing(
            closedPanelID: closedPanelID,
            closedPanelWasFocused: true,
            previousSlotIDBeforeRemoval: UUID()
        )

        #expect(restoredPanelID == remainingPanelID)
    }

    @Test
    func focusedPanelIDAfterClosingFallsBackToResolvedPanelWhenPreviousSlotPanelIsOrphaned() {
        let closedPanelID = UUID()
        let orphanedPanelID = UUID()
        let remainingPanelID = UUID()
        let orphanedSlotID = UUID()
        let remainingSlotID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "Workspace",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: orphanedSlotID, panelID: orphanedPanelID),
                second: .slot(slotID: remainingSlotID, panelID: remainingPanelID)
            ),
            panels: [
                remainingPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/tmp")),
            ],
            focusedPanelID: closedPanelID
        )

        let restoredPanelID = workspace.focusedPanelIDAfterClosing(
            closedPanelID: closedPanelID,
            closedPanelWasFocused: true,
            previousSlotIDBeforeRemoval: orphanedSlotID
        )

        #expect(restoredPanelID == remainingPanelID)
    }
}
