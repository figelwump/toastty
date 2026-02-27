import Foundation

public struct AppReducer {
    public init() {}

    @discardableResult
    public func send(_ action: AppAction, state: inout AppState) -> Bool {
        AppReducer.reduce(action: action, state: &state)
    }

    @discardableResult
    public static func reduce(action: AppAction, state: inout AppState) -> Bool {
        switch action {
        case .selectWindow(let windowID):
            guard state.windows.contains(where: { $0.id == windowID }) else { return false }
            state.selectedWindowID = windowID
            return true

        case .selectWorkspace(let windowID, let workspaceID):
            guard let index = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            guard state.windows[index].workspaceIDs.contains(workspaceID) else { return false }
            state.selectedWindowID = windowID
            state.windows[index].selectedWorkspaceID = workspaceID
            return true

        case .focusPanel(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.panels[panelID] != nil else { return false }
            workspace.focusedPanelID = panelID
            state.workspacesByID[workspaceID] = workspace
            return true

        case .splitFocusedPane(let workspaceID, let orientation):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }

            guard let focusedPanelID = workspace.focusedPanelID ?? workspace.paneTree.allLeafInfos.first?.tabPanelIDs.first else {
                return false
            }

            guard let sourceLeaf = workspace.paneTree.leafContaining(panelID: focusedPanelID) else {
                return false
            }

            let newPanelID = UUID()
            let newPaneID = UUID()

            workspace.panels[newPanelID] = .terminal(
                TerminalPanelState(
                    title: "Terminal \(workspace.panels.count + 1)",
                    shell: "zsh",
                    cwd: NSHomeDirectory()
                )
            )

            let newLeaf = PaneNode.leaf(paneID: newPaneID, tabPanelIDs: [newPanelID], selectedIndex: 0)
            let originalLeaf = PaneNode.leaf(
                paneID: sourceLeaf.paneID,
                tabPanelIDs: sourceLeaf.tabPanelIDs,
                selectedIndex: sourceLeaf.selectedIndex
            )

            let split = PaneNode.split(
                nodeID: UUID(),
                orientation: orientation,
                ratio: 0.5,
                first: originalLeaf,
                second: newLeaf
            )

            guard workspace.paneTree.replaceLeaf(paneID: sourceLeaf.paneID, with: split) else {
                return false
            }

            workspace.focusedPanelID = newPanelID
            state.workspacesByID[workspaceID] = workspace
            return true

        case .createTerminalPanel(let workspaceID, let paneID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }

            let panelID = UUID()
            workspace.panels[panelID] = .terminal(
                TerminalPanelState(
                    title: "Terminal \(workspace.panels.count + 1)",
                    shell: "zsh",
                    cwd: NSHomeDirectory()
                )
            )

            guard workspace.paneTree.appendPanel(panelID, toPane: paneID, select: true) else {
                workspace.panels.removeValue(forKey: panelID)
                return false
            }

            workspace.focusedPanelID = panelID
            state.workspacesByID[workspaceID] = workspace
            return true
        }
    }
}
