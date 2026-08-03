@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
extension AppStoreCommandTestCase {
    func makeTwoPanelWorkspace(title: String) -> (workspace: WorkspaceState, leftPanelID: UUID, rightPanelID: UUID) {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: title,
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: leftPanelID),
                second: .slot(slotID: UUID(), panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo/left")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo/right")),
            ],
            focusedPanelID: leftPanelID
        )
        return (workspace, leftPanelID, rightPanelID)
    }

    func makeUnreadCommandTab(
        focusedPanelIndex: Int,
        unreadPanelIndices: Set<Int>,
        panelCount: Int = 3
    ) -> (tab: WorkspaceTabState, panelIDs: [UUID]) {
        let panelIDs = (0 ..< panelCount).map { _ in UUID() }
        let panels = Dictionary(uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
            (
                panelID,
                PanelState.terminal(
                    TerminalPanelState(
                        title: "Terminal \(index + 1)",
                        shell: "zsh",
                        cwd: NSHomeDirectory()
                    )
                )
            )
        })

        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: makeUnreadCommandLayout(panelIDs: panelIDs),
            panels: panels,
            focusedPanelID: panelIDs[focusedPanelIndex],
            unreadPanelIDs: Set(unreadPanelIndices.map { panelIDs[$0] })
        )

        return (tab, panelIDs)
    }

    func makeUnreadCommandWorkspace(
        title: String,
        tabs: [(tab: WorkspaceTabState, panelIDs: [UUID])],
        selectedTabIndex: Int
    ) -> WorkspaceState {
        let tabIDs = tabs.map { $0.tab.id }
        return WorkspaceState(
            id: UUID(),
            title: title,
            selectedTabID: tabIDs[selectedTabIndex],
            tabIDs: tabIDs,
            tabsByID: Dictionary(uniqueKeysWithValues: tabs.map { ($0.tab.id, $0.tab) })
        )
    }

    func makeUnreadCommandLayout(panelIDs: [UUID]) -> LayoutNode {
        var iterator = panelIDs.makeIterator()
        let firstPanelID = iterator.next()!
        var layout = LayoutNode.slot(slotID: UUID(), panelID: firstPanelID)

        while let panelID = iterator.next() {
            layout = .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: layout,
                second: .slot(slotID: UUID(), panelID: panelID)
            )
        }

        return layout
    }

    func slotID(
        in tab: WorkspaceTabState,
        for panelID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        try XCTUnwrap(
            tab.layoutTree.slotContaining(panelID: panelID)?.slotID,
            file: file,
            line: line
        )
    }

    func lowestCommonAncestorNodeID(
        in tab: WorkspaceTabState,
        containing panelIDs: [UUID],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        let slotIDs = try Set(
            panelIDs.map { panelID in
                try slotID(in: tab, for: panelID, file: file, line: line)
            }
        )
        return try XCTUnwrap(
            tab.layoutTree.lowestCommonAncestor(containing: slotIDs),
            file: file,
            line: line
        )
    }
}
