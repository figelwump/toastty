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

        case .createWorkspace(let windowID, let title):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }

            let resolvedTitle = title ?? nextWorkspaceTitle(in: state.windows[windowIndex], state: state)
            let workspace = WorkspaceState.bootstrap(title: resolvedTitle)

            state.workspacesByID[workspace.id] = workspace
            state.windows[windowIndex].workspaceIDs.append(workspace.id)
            state.windows[windowIndex].selectedWorkspaceID = workspace.id
            return true

        case .focusPanel(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.panels[panelID] != nil else { return false }
            workspace.focusedPanelID = panelID
            state.workspacesByID[workspaceID] = workspace
            return true

        case .splitFocusedPane(let workspaceID, let orientation):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let focusResolution = resolveFocusedPanel(in: workspace) else {
                return false
            }
            workspace.focusedPanelID = focusResolution.panelID

            let sourceLeaf = focusResolution.leaf

            let newPanelID = UUID()
            let newPaneID = UUID()

            workspace.panels[newPanelID] = .terminal(
                TerminalPanelState(
                    title: nextTerminalTitle(in: workspace),
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
                    title: nextTerminalTitle(in: workspace),
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

    private static func resolveFocusedPanel(in workspace: WorkspaceState) -> (panelID: UUID, leaf: PaneLeafInfo)? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panels[focusedPanelID] != nil,
           let focusedLeaf = workspace.paneTree.leafContaining(panelID: focusedPanelID) {
            return (focusedPanelID, focusedLeaf)
        }

        for leaf in workspace.paneTree.allLeafInfos {
            for panelID in leaf.tabPanelIDs where workspace.panels[panelID] != nil {
                return (panelID, leaf)
            }
        }

        return nil
    }

    private static func nextTerminalTitle(in workspace: WorkspaceState) -> String {
        let prefix = "Terminal "
        let currentMax = workspace.panels.values.compactMap { panelState -> Int? in
            guard case .terminal(let terminalState) = panelState else { return nil }
            guard terminalState.title.hasPrefix(prefix) else { return nil }
            let suffix = terminalState.title.dropFirst(prefix.count)
            return Int(suffix)
        }.max() ?? 0

        return "Terminal \(currentMax + 1)"
    }

    private static func nextWorkspaceTitle(in window: WindowState, state: AppState) -> String {
        let prefix = "Workspace "
        let currentMax = window.workspaceIDs.compactMap { workspaceID -> Int? in
            guard let workspace = state.workspacesByID[workspaceID] else { return nil }
            guard workspace.title.hasPrefix(prefix) else { return nil }
            let suffix = workspace.title.dropFirst(prefix.count)
            return Int(suffix)
        }.max() ?? 0

        return "Workspace \(currentMax + 1)"
    }
}
