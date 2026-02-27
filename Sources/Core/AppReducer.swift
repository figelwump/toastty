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

        case .reorderPanel(let panelID, let toIndex, let paneID):
            guard let location = locatePanel(panelID, in: state) else { return false }
            guard location.paneID == paneID else { return false }
            guard var workspace = state.workspacesByID[location.workspaceID] else { return false }

            guard workspace.paneTree.reorderPanel(panelID, inPane: paneID, toIndex: toIndex) else {
                return false
            }

            workspace.focusedPanelID = panelID
            state.workspacesByID[location.workspaceID] = workspace
            return true

        case .movePanelToPane(let panelID, let targetPaneID, let index):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard let targetWorkspaceID = locateWorkspaceID(containingPaneID: targetPaneID, in: state) else { return false }
            guard sourceLocation.workspaceID == targetWorkspaceID else { return false }
            guard var workspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }

            if sourceLocation.paneID == targetPaneID {
                if let index {
                    guard workspace.paneTree.reorderPanel(panelID, inPane: targetPaneID, toIndex: index) else {
                        return false
                    }
                }
            } else {
                let removal = workspace.paneTree.removingPanel(panelID)
                guard removal.removed, var updatedTree = removal.node else { return false }
                guard updatedTree.insertPanel(panelID, toPane: targetPaneID, at: index, select: true) else { return false }
                workspace.paneTree = updatedTree
            }

            workspace.focusedPanelID = panelID
            state.workspacesByID[sourceLocation.workspaceID] = workspace
            return true

        case .movePanelToWorkspace(let panelID, let targetWorkspaceID, let targetPaneID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var sourceWorkspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard var targetWorkspace = state.workspacesByID[targetWorkspaceID] else { return false }
            guard let panelState = sourceWorkspace.panels[panelID] else { return false }

            if sourceLocation.workspaceID == targetWorkspaceID {
                let paneDestination = targetPaneID ?? sourceLocation.paneID
                return reduce(
                    action: .movePanelToPane(panelID: panelID, targetPaneID: paneDestination, index: nil),
                    state: &state
                )
            }

            guard let insertionPaneID = resolveInsertionPaneID(in: targetWorkspace, preferredPaneID: targetPaneID) else {
                return false
            }

            let sourceRemoval = sourceWorkspace.paneTree.removingPanel(panelID)
            guard sourceRemoval.removed else { return false }

            var updatedSourceWorkspace: WorkspaceState?
            sourceWorkspace.panels.removeValue(forKey: panelID)
            if let updatedSourceTree = sourceRemoval.node {
                sourceWorkspace.paneTree = updatedSourceTree
                sourceWorkspace.focusedPanelID = resolveFocusedPanel(in: sourceWorkspace)?.panelID
                updatedSourceWorkspace = sourceWorkspace
            } else {
                updatedSourceWorkspace = nil
            }

            targetWorkspace.panels[panelID] = panelState
            var targetTree = targetWorkspace.paneTree
            guard targetTree.insertPanel(panelID, toPane: insertionPaneID, at: nil, select: true) else {
                return false
            }
            targetWorkspace.paneTree = targetTree
            targetWorkspace.focusedPanelID = panelID

            if let updatedSourceWorkspace {
                state.workspacesByID[sourceLocation.workspaceID] = updatedSourceWorkspace
            } else {
                removeWorkspace(sourceLocation.workspaceID, windowID: sourceLocation.windowID, state: &state)
            }
            state.workspacesByID[targetWorkspaceID] = targetWorkspace
            return true

        case .detachPanelToNewWindow(let panelID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var sourceWorkspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard let panelState = sourceWorkspace.panels[panelID] else { return false }

            let sourceRemoval = sourceWorkspace.paneTree.removingPanel(panelID)
            guard sourceRemoval.removed else { return false }

            sourceWorkspace.panels.removeValue(forKey: panelID)
            if let updatedSourceTree = sourceRemoval.node {
                sourceWorkspace.paneTree = updatedSourceTree
                sourceWorkspace.focusedPanelID = resolveFocusedPanel(in: sourceWorkspace)?.panelID
                state.workspacesByID[sourceLocation.workspaceID] = sourceWorkspace
            } else {
                removeWorkspace(sourceLocation.workspaceID, windowID: sourceLocation.windowID, state: &state)
            }

            let detachedWorkspaceID = UUID()
            let detachedPaneID = UUID()
            let detachedWorkspace = WorkspaceState(
                id: detachedWorkspaceID,
                title: "Workspace 1",
                paneTree: .leaf(paneID: detachedPaneID, tabPanelIDs: [panelID], selectedIndex: 0),
                panels: [panelID: panelState],
                focusedPanelID: panelID
            )

            let detachedWindowID = UUID()
            let detachedWindow = WindowState(
                id: detachedWindowID,
                frame: CGRectCodable(x: 160, y: 160, width: 1000, height: 680),
                workspaceIDs: [detachedWorkspaceID],
                selectedWorkspaceID: detachedWorkspaceID
            )

            state.workspacesByID[detachedWorkspaceID] = detachedWorkspace
            state.windows.append(detachedWindow)
            state.selectedWindowID = detachedWindowID
            return true

        case .toggleAuxPanel(let workspaceID, let kind):
            guard kind != .terminal else { return false }
            guard var workspace = state.workspacesByID[workspaceID] else { return false }

            if let existingPanelID = workspace.panels.first(where: { $0.value.kind == kind })?.key {
                let removal = workspace.paneTree.removingPanel(existingPanelID)
                guard removal.removed else { return false }

                workspace.panels.removeValue(forKey: existingPanelID)
                workspace.auxPanelVisibility.remove(kind)

                if let updatedTree = removal.node {
                    workspace.paneTree = updatedTree
                    if workspace.focusedPanelID == existingPanelID {
                        workspace.focusedPanelID = resolveFocusedPanel(in: workspace)?.panelID
                    }
                    state.workspacesByID[workspaceID] = workspace
                } else if let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) {
                    removeWorkspace(workspaceID, windowID: windowID, state: &state)
                }
                return true
            }

            guard let auxPanelState = makeAuxPanelState(for: kind) else { return false }
            let panelID = UUID()
            workspace.panels[panelID] = auxPanelState

            if workspace.paneTree.allLeafInfos.count == 1,
               let sourceLeaf = workspace.paneTree.allLeafInfos.first {
                let leftLeaf = PaneNode.leaf(
                    paneID: sourceLeaf.paneID,
                    tabPanelIDs: sourceLeaf.tabPanelIDs,
                    selectedIndex: sourceLeaf.selectedIndex
                )
                let rightLeaf = PaneNode.leaf(
                    paneID: UUID(),
                    tabPanelIDs: [panelID],
                    selectedIndex: 0
                )
                workspace.paneTree = .split(
                    nodeID: UUID(),
                    orientation: .horizontal,
                    ratio: 0.65,
                    first: leftLeaf,
                    second: rightLeaf
                )
            } else {
                guard let rightColumnPaneID = workspace.paneTree.rightColumnPaneID() else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }
                guard workspace.paneTree.insertPanel(panelID, toPane: rightColumnPaneID, at: nil, select: false) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }
            }

            workspace.auxPanelVisibility.insert(kind)
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

    private static func locatePanel(_ panelID: UUID, in state: AppState) -> PanelLocation? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard let sourceLeaf = workspace.paneTree.leafContaining(panelID: panelID) else { continue }

                return PanelLocation(
                    windowID: window.id,
                    workspaceID: workspaceID,
                    paneID: sourceLeaf.paneID
                )
            }
        }

        return nil
    }

    private static func locateWorkspaceID(containingPaneID paneID: UUID, in state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.paneTree.allLeafInfos.contains(where: { $0.paneID == paneID }) {
                    return workspaceID
                }
            }
        }
        return nil
    }

    private static func locateWindowID(containingWorkspaceID workspaceID: UUID, in state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }

    private static func resolveInsertionPaneID(in workspace: WorkspaceState, preferredPaneID: UUID?) -> UUID? {
        if let preferredPaneID {
            guard workspace.paneTree.allLeafInfos.contains(where: { $0.paneID == preferredPaneID }) else {
                return nil
            }
            return preferredPaneID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           let focusedLeaf = workspace.paneTree.leafContaining(panelID: focusedPanelID) {
            return focusedLeaf.paneID
        }

        return workspace.paneTree.allLeafInfos.first?.paneID
    }

    private static func removeWorkspace(_ workspaceID: UUID, windowID: UUID, state: inout AppState) {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return }
        var window = state.windows[windowIndex]
        guard let workspaceIndex = window.workspaceIDs.firstIndex(of: workspaceID) else { return }

        state.workspacesByID.removeValue(forKey: workspaceID)
        window.workspaceIDs.remove(at: workspaceIndex)

        if window.workspaceIDs.isEmpty {
            let removedWindowID = window.id
            state.windows.remove(at: windowIndex)
            if state.selectedWindowID == removedWindowID {
                state.selectedWindowID = state.windows.first?.id
            }
            return
        }

        if window.selectedWorkspaceID == workspaceID {
            let nextIndex = min(workspaceIndex, window.workspaceIDs.count - 1)
            window.selectedWorkspaceID = window.workspaceIDs[nextIndex]
        }

        state.windows[windowIndex] = window
        if state.selectedWindowID == nil {
            state.selectedWindowID = window.id
        }
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

    private static func makeAuxPanelState(for kind: PanelKind) -> PanelState? {
        switch kind {
        case .terminal:
            return nil
        case .diff:
            return .diff(DiffPanelState())
        case .markdown:
            return .markdown(MarkdownPanelState())
        case .scratchpad:
            return .scratchpad(ScratchpadPanelState())
        }
    }
}

private struct PanelLocation {
    let windowID: UUID
    let workspaceID: UUID
    let paneID: UUID
}
