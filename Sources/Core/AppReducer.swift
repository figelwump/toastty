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
            markWorkspaceScopedNotificationsRead(workspaceID: workspaceID, state: &state)
            return true

        case .createWorkspace(let windowID, let title):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }

            let resolvedTitle = title ?? nextWorkspaceTitle(in: state.windows[windowIndex], state: state)
            let workspace = WorkspaceState.bootstrap(title: resolvedTitle)

            state.workspacesByID[workspace.id] = workspace
            state.windows[windowIndex].workspaceIDs.append(workspace.id)
            state.windows[windowIndex].selectedWorkspaceID = workspace.id
            return true

        case .renameWorkspace(let workspaceID, let title):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedTitle.isEmpty == false else { return false }
            guard workspace.title != trimmedTitle else { return false }
            workspace.title = trimmedTitle
            state.workspacesByID[workspaceID] = workspace
            return true

        case .closeWorkspace(let workspaceID):
            guard let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) else { return false }
            return removeWorkspace(workspaceID, windowID: windowID, state: &state)

        case .focusPanel(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.panels[panelID] != nil else { return false }
            workspace.focusedPanelID = panelID
            _ = workspace.unreadPanelIDs.remove(panelID)
            workspace.unreadWorkspaceNotificationCount = 0
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
            let didTransferUnreadBadge = sourceWorkspace.unreadPanelIDs.remove(panelID) != nil
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
            if didTransferUnreadBadge {
                targetWorkspace.unreadPanelIDs.insert(panelID)
            }

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

            let didTransferUnreadBadge = sourceWorkspace.unreadPanelIDs.remove(panelID) != nil
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
                focusedPanelID: panelID,
                unreadPanelIDs: didTransferUnreadBadge ? [panelID] : []
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

        case .closePanel(let panelID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard let panelState = workspace.panels[panelID] else { return false }
            let wasFocusedPanel = workspace.focusedPanelID == panelID
            let previousPaneIDBeforeRemoval = wasFocusedPanel
                ? targetPaneID(from: sourceLocation.paneID, direction: .previous, paneTree: workspace.paneTree)
                : nil

            workspace.recentlyClosedPanels.append(
                ClosedPanelRecord(
                    panelState: panelState,
                    closedAt: Date(),
                    sourceLeafPaneID: sourceLocation.paneID
                )
            )
            if workspace.recentlyClosedPanels.count > 10 {
                workspace.recentlyClosedPanels.removeFirst(workspace.recentlyClosedPanels.count - 10)
            }

            let removal = workspace.paneTree.removingPanel(panelID)
            guard removal.removed else { return false }

            workspace.panels.removeValue(forKey: panelID)
            workspace.unreadPanelIDs.remove(panelID)
            workspace.auxPanelVisibility.remove(panelState.kind)

            if let updatedTree = removal.node {
                workspace.paneTree = updatedTree
                workspace.focusedPanelID = resolveFocusedPanelAfterClose(
                    in: workspace,
                    closedPanelID: panelID,
                    closedPanelWasFocused: wasFocusedPanel,
                    sourcePaneID: sourceLocation.paneID,
                    previousPaneIDBeforeRemoval: previousPaneIDBeforeRemoval
                )
                state.workspacesByID[sourceLocation.workspaceID] = workspace
            } else {
                state.workspacesByID[sourceLocation.workspaceID] = workspace
                removeWorkspace(sourceLocation.workspaceID, windowID: sourceLocation.windowID, state: &state)
            }
            return true

        case .reopenLastClosedPanel(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let closedRecord = workspace.recentlyClosedPanels.last else { return false }

            if closedRecord.panelState.kind != .terminal,
               let existingAuxPanelID = workspace.panels.first(where: { $0.value.kind == closedRecord.panelState.kind })?.key {
                workspace.focusedPanelID = existingAuxPanelID
                workspace.recentlyClosedPanels.removeLast()
                state.workspacesByID[workspaceID] = workspace
                return true
            }

            guard let targetPaneID = resolveReopenPaneID(
                in: workspace,
                preferredPaneID: closedRecord.sourceLeafPaneID
            ) else {
                return false
            }

            let panelID = UUID()
            workspace.panels[panelID] = closedRecord.panelState

            guard workspace.paneTree.insertPanel(panelID, toPane: targetPaneID, at: nil, select: true) else {
                workspace.panels.removeValue(forKey: panelID)
                return false
            }

            workspace.focusedPanelID = panelID
            if closedRecord.panelState.kind != .terminal {
                workspace.auxPanelVisibility.insert(closedRecord.panelState.kind)
            }
            workspace.recentlyClosedPanels.removeLast()

            state.workspacesByID[workspaceID] = workspace
            return true

        case .toggleAuxPanel(let workspaceID, let kind):
            guard kind != .terminal else { return false }
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.focusedPanelModeActive == false else { return false }

            if let existingPanelID = workspace.panels.first(where: { $0.value.kind == kind })?.key {
                let removal = workspace.paneTree.removingPanel(existingPanelID)
                guard removal.removed else { return false }

                workspace.panels.removeValue(forKey: existingPanelID)
                workspace.unreadPanelIDs.remove(existingPanelID)
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
            let existingAuxPanelIDs = auxPanelIDs(in: workspace)
            let panelID = UUID()
            workspace.panels[panelID] = auxPanelState

            if existingAuxPanelIDs.isEmpty {
                // First aux panel always gets a dedicated right column regardless of terminal pane layout.
                let terminalTree = workspace.paneTree
                let auxLeaf = PaneNode.leaf(
                    paneID: UUID(),
                    tabPanelIDs: [panelID],
                    selectedIndex: 0
                )
                workspace.paneTree = .split(
                    nodeID: UUID(),
                    orientation: .horizontal,
                    ratio: 0.7,
                    first: terminalTree,
                    second: auxLeaf
                )
            } else {
                guard let auxColumnPaneID = resolveAuxColumnPaneID(in: workspace, auxPanelIDs: existingAuxPanelIDs) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }
                guard let existingAuxLeaf = workspace.paneTree.leafNode(paneID: auxColumnPaneID) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }

                let auxLeaf = PaneNode.leaf(
                    paneID: UUID(),
                    tabPanelIDs: [panelID],
                    selectedIndex: 0
                )
                let splitRightColumn = PaneNode.split(
                    nodeID: UUID(),
                    orientation: .vertical,
                    ratio: 0.5,
                    first: existingAuxLeaf,
                    second: auxLeaf
                )

                guard workspace.paneTree.replaceLeaf(paneID: auxColumnPaneID, with: splitRightColumn) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }
            }

            workspace.auxPanelVisibility.insert(kind)
            state.workspacesByID[workspaceID] = workspace
            return true

        case .toggleFocusedPanelMode(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let focusResolution = resolveFocusedPanel(in: workspace) else {
                return false
            }

            workspace.focusedPanelID = focusResolution.panelID
            workspace.focusedPanelModeActive.toggle()
            state.workspacesByID[workspaceID] = workspace
            return true

        case .setConfiguredTerminalFont(let points):
            let clampedConfiguredPoints = points.map(AppState.clampedTerminalFontPoints)
            guard state.configuredTerminalFontPoints != clampedConfiguredPoints else { return false }
            state.configuredTerminalFontPoints = clampedConfiguredPoints
            return true

        case .setGlobalTerminalFont(let points):
            let clampedPoints = AppState.clampedTerminalFontPoints(points)
            guard abs(state.globalTerminalFontPoints - clampedPoints) >= AppState.terminalFontComparisonEpsilon else {
                return false
            }
            state.globalTerminalFontPoints = clampedPoints
            return true

        case .increaseGlobalTerminalFont:
            let nextPoints = AppState.clampedTerminalFontPoints(
                state.globalTerminalFontPoints + AppState.terminalFontStepPoints
            )
            guard abs(nextPoints - state.globalTerminalFontPoints) >= AppState.terminalFontComparisonEpsilon else {
                return false
            }
            state.globalTerminalFontPoints = nextPoints
            return true

        case .decreaseGlobalTerminalFont:
            let nextPoints = AppState.clampedTerminalFontPoints(
                state.globalTerminalFontPoints - AppState.terminalFontStepPoints
            )
            guard abs(nextPoints - state.globalTerminalFontPoints) >= AppState.terminalFontComparisonEpsilon else {
                return false
            }
            state.globalTerminalFontPoints = nextPoints
            return true

        case .resetGlobalTerminalFont:
            let configuredBaseline = state.configuredTerminalFontPoints ?? AppState.defaultTerminalFontPoints
            guard abs(state.globalTerminalFontPoints - configuredBaseline) >= AppState.terminalFontComparisonEpsilon else {
                return false
            }
            state.globalTerminalFontPoints = configuredBaseline
            return true

        case .splitFocusedPane(let workspaceID, let orientation):
            let direction: PaneSplitDirection = orientation == .horizontal ? .right : .down
            return splitFocusedPane(workspaceID: workspaceID, direction: direction, state: &state)

        case .splitFocusedPaneInDirection(let workspaceID, let direction):
            return splitFocusedPane(workspaceID: workspaceID, direction: direction, state: &state)

        case .focusPane(let workspaceID, let direction):
            return focusPane(workspaceID: workspaceID, direction: direction, state: &state)

        case .resizeFocusedPaneSplit(let workspaceID, let direction, let amount):
            return resizeFocusedPaneSplit(
                workspaceID: workspaceID,
                direction: direction,
                amount: amount,
                state: &state
            )

        case .equalizePaneSplits(let workspaceID):
            return equalizePaneSplits(workspaceID: workspaceID, state: &state)

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

        case .updateTerminalPanelMetadata(let panelID, let title, let cwd):
            guard let location = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[location.workspaceID] else { return false }
            guard case .terminal(var terminalState) = workspace.panels[panelID] else { return false }

            var didMutate = false

            if let normalizedTitle = normalizedMetadataValue(title),
               terminalState.title != normalizedTitle {
                terminalState.title = normalizedTitle
                didMutate = true
            }

            if let normalizedCWD = normalizedMetadataValue(cwd),
               terminalState.cwd != normalizedCWD {
                terminalState.cwd = normalizedCWD
                didMutate = true
            }

            guard didMutate else { return false }
            workspace.panels[panelID] = .terminal(terminalState)
            state.workspacesByID[location.workspaceID] = workspace
            return true

        case .recordDesktopNotification(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            if let panelID {
                guard workspace.panels[panelID] != nil else { return false }
                workspace.unreadPanelIDs.insert(panelID)
            } else {
                workspace.unreadWorkspaceNotificationCount += 1
            }
            state.workspacesByID[workspaceID] = workspace
            return true

        case .markPanelNotificationsRead(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.panels[panelID] != nil else { return false }
            if workspace.unreadPanelIDs.remove(panelID) != nil {
                state.workspacesByID[workspaceID] = workspace
            }
            return true
        }
    }

    @discardableResult
    private static func splitFocusedPane(
        workspaceID: UUID,
        direction: PaneSplitDirection,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard workspace.focusedPanelModeActive == false else { return false }
        guard let focusResolution = resolveFocusedPanel(in: workspace) else {
            return false
        }
        workspace.focusedPanelID = focusResolution.panelID

        let sourceLeaf = focusResolution.leaf
        let inheritedCWD: String
        if case .terminal(let focusedTerminalState) = workspace.panels[focusResolution.panelID] {
            inheritedCWD = focusedTerminalState.cwd
        } else {
            inheritedCWD = NSHomeDirectory()
        }

        let newPanelID = UUID()
        let newPaneID = UUID()

        workspace.panels[newPanelID] = .terminal(
            TerminalPanelState(
                title: nextTerminalTitle(in: workspace),
                shell: "zsh",
                cwd: inheritedCWD
            )
        )

        let newLeaf = PaneNode.leaf(paneID: newPaneID, tabPanelIDs: [newPanelID], selectedIndex: 0)
        let originalLeaf = PaneNode.leaf(
            paneID: sourceLeaf.paneID,
            tabPanelIDs: sourceLeaf.tabPanelIDs,
            selectedIndex: sourceLeaf.selectedIndex
        )

        let orientation: SplitOrientation = switch direction {
        case .left, .right:
            .horizontal
        case .up, .down:
            .vertical
        }

        let firstNode: PaneNode
        let secondNode: PaneNode
        switch direction {
        case .right, .down:
            firstNode = originalLeaf
            secondNode = newLeaf
        case .left, .up:
            firstNode = newLeaf
            secondNode = originalLeaf
        }

        let split = PaneNode.split(
            nodeID: UUID(),
            orientation: orientation,
            ratio: 0.5,
            first: firstNode,
            second: secondNode
        )

        guard workspace.paneTree.replaceLeaf(paneID: sourceLeaf.paneID, with: split) else {
            return false
        }

        workspace.focusedPanelID = newPanelID
        state.workspacesByID[workspaceID] = workspace
        return true

    }

    @discardableResult
    private static func focusPane(
        workspaceID: UUID,
        direction: PaneFocusDirection,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard workspace.focusedPanelModeActive == false else { return false }
        guard let focusResolution = resolveFocusedPanel(in: workspace) else {
            return false
        }

        let sourcePaneID = focusResolution.leaf.paneID
        guard let targetPaneID = targetPaneID(
            from: sourcePaneID,
            direction: direction,
            paneTree: workspace.paneTree
        ) else {
            return false
        }
        guard targetPaneID != sourcePaneID else {
            return false
        }
        guard let targetLeaf = workspace.paneTree.leafNode(paneID: targetPaneID) else {
            return false
        }
        guard let targetPanelID = selectedPanelID(in: targetLeaf, workspace: workspace) else {
            return false
        }
        guard targetPanelID != workspace.focusedPanelID else {
            return false
        }

        workspace.focusedPanelID = targetPanelID
        _ = workspace.unreadPanelIDs.remove(targetPanelID)
        workspace.unreadWorkspaceNotificationCount = 0
        state.workspacesByID[workspaceID] = workspace
        return true
    }

    private static func markWorkspaceScopedNotificationsRead(workspaceID: UUID, state: inout AppState) {
        guard var workspace = state.workspacesByID[workspaceID] else { return }
        guard workspace.unreadWorkspaceNotificationCount > 0 else { return }
        workspace.unreadWorkspaceNotificationCount = 0
        state.workspacesByID[workspaceID] = workspace
    }

    private static func resizeFocusedPaneSplit(
        workspaceID: UUID,
        direction: PaneResizeDirection,
        amount: Int,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else {
            ToasttyLog.debug(
                "Resize split rejected: workspace missing",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }
        guard workspace.focusedPanelModeActive == false else {
            ToasttyLog.debug(
                "Resize split rejected: focused panel mode active",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }
        guard let focusResolution = resolveFocusedPanel(in: workspace) else {
            ToasttyLog.debug(
                "Resize split rejected: no focused panel",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }
        workspace.focusedPanelID = focusResolution.panelID

        let delta = splitResizeDelta(direction: direction, amount: amount)
        let result = resizeNearestMatchingSplit(
            in: workspace.paneTree,
            focusedPaneID: focusResolution.leaf.paneID,
            direction: direction,
            delta: delta
        )
        guard result.didResize else {
            ToasttyLog.debug(
                "Resize split rejected: no matching split orientation",
                category: .reducer,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "direction": direction.rawValue,
                    "amount": String(amount),
                ]
            )
            return false
        }

        workspace.paneTree = result.node
        state.workspacesByID[workspaceID] = workspace
        ToasttyLog.debug(
            "Resize split applied",
            category: .reducer,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "direction": direction.rawValue,
                "amount": String(amount),
            ]
        )
        return true
    }

    private static func equalizePaneSplits(workspaceID: UUID, state: inout AppState) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else {
            ToasttyLog.debug(
                "Equalize splits rejected: workspace missing",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }
        guard workspace.focusedPanelModeActive == false else {
            ToasttyLog.debug(
                "Equalize splits rejected: focused panel mode active",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        let result = equalizeSplitRatios(in: workspace.paneTree)
        guard result.didMutate else {
            ToasttyLog.debug(
                "Equalize splits rejected: tree already equalized",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        workspace.paneTree = result.node
        state.workspacesByID[workspaceID] = workspace
        ToasttyLog.debug(
            "Equalized pane splits",
            category: .reducer,
            metadata: ["workspace_id": workspaceID.uuidString]
        )
        return true
    }

    private struct SplitResizeResult {
        let node: PaneNode
        let containsFocusedPane: Bool
        let didResize: Bool
    }

    private struct SplitEqualizeResult {
        let node: PaneNode
        let didMutate: Bool
        let leafCount: Int
    }

    // Suppresses floating-point noise near clamp bounds; this must stay well below the
    // minimum intentional resize step (0.005) so real resizes always apply.
    private static let splitRatioChangeEpsilon: Double = 0.0001

    private static func splitResizeDelta(direction: PaneResizeDirection, amount: Int) -> Double {
        // Keep headroom for large shortcut-supplied amounts while clamping pathological values.
        let clampedAmount = max(1, min(amount, 60))
        let magnitude = Double(clampedAmount) * 0.005
        switch direction {
        case .left, .up:
            return -magnitude
        case .right, .down:
            return magnitude
        }
    }

    private static func resizeNearestMatchingSplit(
        in node: PaneNode,
        focusedPaneID: UUID,
        direction: PaneResizeDirection,
        delta: Double
    ) -> SplitResizeResult {
        switch node {
        case .leaf(let paneID, _, _):
            return SplitResizeResult(node: node, containsFocusedPane: paneID == focusedPaneID, didResize: false)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = resizeNearestMatchingSplit(
                in: first,
                focusedPaneID: focusedPaneID,
                direction: direction,
                delta: delta
            )
            if firstResult.containsFocusedPane {
                if firstResult.didResize {
                    return SplitResizeResult(
                        node: .split(
                            nodeID: nodeID,
                            orientation: orientation,
                            ratio: ratio,
                            first: firstResult.node,
                            second: second
                        ),
                        containsFocusedPane: true,
                        didResize: true
                    )
                }

                if splitOrientation(contains: direction, orientation: orientation) {
                    let nextRatio = clampedSplitRatio(ratio + delta)
                    if hasMeaningfulSplitRatioChange(from: ratio, to: nextRatio) {
                        return SplitResizeResult(
                            node: .split(
                                nodeID: nodeID,
                                orientation: orientation,
                                ratio: nextRatio,
                                first: firstResult.node,
                                second: second
                            ),
                            containsFocusedPane: true,
                            didResize: true
                        )
                    }
                }

                return SplitResizeResult(
                    node: .split(
                        nodeID: nodeID,
                        orientation: orientation,
                        ratio: ratio,
                        first: firstResult.node,
                        second: second
                    ),
                    containsFocusedPane: true,
                    didResize: false
                )
            }

            let secondResult = resizeNearestMatchingSplit(
                in: second,
                focusedPaneID: focusedPaneID,
                direction: direction,
                delta: delta
            )
            if secondResult.containsFocusedPane {
                if secondResult.didResize {
                    return SplitResizeResult(
                        node: .split(
                            nodeID: nodeID,
                            orientation: orientation,
                            ratio: ratio,
                            first: first,
                            second: secondResult.node
                        ),
                        containsFocusedPane: true,
                        didResize: true
                    )
                }

                if splitOrientation(contains: direction, orientation: orientation) {
                    let nextRatio = clampedSplitRatio(ratio + delta)
                    if hasMeaningfulSplitRatioChange(from: ratio, to: nextRatio) {
                        return SplitResizeResult(
                            node: .split(
                                nodeID: nodeID,
                                orientation: orientation,
                                ratio: nextRatio,
                                first: first,
                                second: secondResult.node
                            ),
                            containsFocusedPane: true,
                            didResize: true
                        )
                    }
                }

                return SplitResizeResult(
                    node: .split(
                        nodeID: nodeID,
                        orientation: orientation,
                        ratio: ratio,
                        first: first,
                        second: secondResult.node
                    ),
                    containsFocusedPane: true,
                    didResize: false
                )
            }

            return SplitResizeResult(node: node, containsFocusedPane: false, didResize: false)
        }
    }

    private static func equalizeSplitRatios(in node: PaneNode) -> SplitEqualizeResult {
        switch node {
        case .leaf:
            return SplitEqualizeResult(node: node, didMutate: false, leafCount: 1)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = equalizeSplitRatios(in: first)
            let secondResult = equalizeSplitRatios(in: second)
            let totalLeafCount = firstResult.leafCount + secondResult.leafCount
            let targetRatio = Double(firstResult.leafCount) / Double(totalLeafCount)
            let didMutate = firstResult.didMutate
                || secondResult.didMutate
                || ratio != targetRatio
            guard didMutate else {
                return SplitEqualizeResult(node: node, didMutate: false, leafCount: totalLeafCount)
            }

            return SplitEqualizeResult(
                node: .split(
                    nodeID: nodeID,
                    orientation: orientation,
                    ratio: targetRatio,
                    first: firstResult.node,
                    second: secondResult.node
                ),
                didMutate: didMutate,
                leafCount: totalLeafCount
            )
        }
    }

    private static func splitOrientation(contains direction: PaneResizeDirection, orientation: SplitOrientation) -> Bool {
        switch (direction, orientation) {
        case (.left, .horizontal), (.right, .horizontal), (.up, .vertical), (.down, .vertical):
            return true
        default:
            return false
        }
    }

    private static func clampedSplitRatio(_ value: Double) -> Double {
        min(max(value, 0.1), 0.9)
    }

    private static func hasMeaningfulSplitRatioChange(from oldValue: Double, to newValue: Double) -> Bool {
        abs(newValue - oldValue) > splitRatioChangeEpsilon
    }

    private static func targetPaneID(
        from sourcePaneID: UUID,
        direction: PaneFocusDirection,
        paneTree: PaneNode
    ) -> UUID? {
        let leaves = paneTree.allLeafInfos
        guard let sourceLeafIndex = leaves.firstIndex(where: { $0.paneID == sourcePaneID }) else {
            return nil
        }

        switch direction {
        case .previous:
            guard leaves.count > 1 else { return nil }
            let previousIndex = (sourceLeafIndex - 1 + leaves.count) % leaves.count
            return leaves[previousIndex].paneID
        case .next:
            guard leaves.count > 1 else { return nil }
            let nextIndex = (sourceLeafIndex + 1) % leaves.count
            return leaves[nextIndex].paneID
        case .up, .down, .left, .right:
            let frames = paneFrames(for: paneTree)
            guard let sourceFrame = frames.first(where: { $0.paneID == sourcePaneID }) else {
                return nil
            }
            return closestPaneID(to: sourceFrame, direction: direction, frames: frames)
        }
    }

    private static func selectedPanelID(in leafNode: PaneNode, workspace: WorkspaceState) -> UUID? {
        guard case .leaf(_, let tabPanelIDs, let selectedIndex) = leafNode else {
            return nil
        }
        guard tabPanelIDs.isEmpty == false else {
            return nil
        }
        let resolvedIndex = min(max(selectedIndex, 0), tabPanelIDs.count - 1)
        let panelID = tabPanelIDs[resolvedIndex]
        guard workspace.panels[panelID] != nil else {
            return nil
        }
        return panelID
    }

    private struct PaneFrame {
        let paneID: UUID
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
        let centerX: Double
        let centerY: Double
    }

    private static func paneFrames(for paneTree: PaneNode) -> [PaneFrame] {
        struct NormalizedRect {
            let minX: Double
            let minY: Double
            let width: Double
            let height: Double

            var maxX: Double { minX + width }
            var maxY: Double { minY + height }
            var centerX: Double { minX + (width * 0.5) }
            var centerY: Double { minY + (height * 0.5) }
        }

        func walk(_ node: PaneNode, rect: NormalizedRect) -> [PaneFrame] {
            switch node {
            case .leaf(let paneID, _, _):
                return [
                    PaneFrame(
                        paneID: paneID,
                        minX: rect.minX,
                        minY: rect.minY,
                        maxX: rect.maxX,
                        maxY: rect.maxY,
                        centerX: rect.centerX,
                        centerY: rect.centerY
                    ),
                ]
            case .split(_, let orientation, let ratio, let first, let second):
                if orientation == .horizontal {
                    let firstWidth = rect.width * ratio
                    let secondWidth = max(rect.width - firstWidth, 0)
                    let firstRect = NormalizedRect(minX: rect.minX, minY: rect.minY, width: firstWidth, height: rect.height)
                    let secondRect = NormalizedRect(minX: rect.minX + firstWidth, minY: rect.minY, width: secondWidth, height: rect.height)
                    return walk(first, rect: firstRect) + walk(second, rect: secondRect)
                }

                let firstHeight = rect.height * ratio
                let secondHeight = max(rect.height - firstHeight, 0)
                let firstRect = NormalizedRect(minX: rect.minX, minY: rect.minY, width: rect.width, height: firstHeight)
                let secondRect = NormalizedRect(minX: rect.minX, minY: rect.minY + firstHeight, width: rect.width, height: secondHeight)
                return walk(first, rect: firstRect) + walk(second, rect: secondRect)
            }
        }

        return walk(
            paneTree,
            rect: NormalizedRect(minX: 0, minY: 0, width: 1, height: 1)
        )
    }

    private static func closestPaneID(
        to source: PaneFrame,
        direction: PaneFocusDirection,
        frames: [PaneFrame]
    ) -> UUID? {
        let directionalCandidates: [(frame: PaneFrame, primaryDistance: Double, secondaryDistance: Double)] = frames.compactMap { candidate in
            guard candidate.paneID != source.paneID else {
                return nil
            }

            switch direction {
            case .left:
                guard candidate.centerX < source.centerX else { return nil }
                return (candidate, source.centerX - candidate.centerX, abs(candidate.centerY - source.centerY))
            case .right:
                guard candidate.centerX > source.centerX else { return nil }
                return (candidate, candidate.centerX - source.centerX, abs(candidate.centerY - source.centerY))
            case .up:
                guard candidate.centerY < source.centerY else { return nil }
                return (candidate, source.centerY - candidate.centerY, abs(candidate.centerX - source.centerX))
            case .down:
                guard candidate.centerY > source.centerY else { return nil }
                return (candidate, candidate.centerY - source.centerY, abs(candidate.centerX - source.centerX))
            case .previous, .next:
                return nil
            }
        }

        let sorted = directionalCandidates.sorted { lhs, rhs in
            if lhs.primaryDistance != rhs.primaryDistance {
                return lhs.primaryDistance < rhs.primaryDistance
            }
            if lhs.secondaryDistance != rhs.secondaryDistance {
                return lhs.secondaryDistance < rhs.secondaryDistance
            }
            return lhs.frame.paneID.uuidString < rhs.frame.paneID.uuidString
        }
        return sorted.first?.frame.paneID
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

    private static func resolveFocusedPanelAfterClose(
        in workspace: WorkspaceState,
        closedPanelID: UUID,
        closedPanelWasFocused: Bool,
        sourcePaneID: UUID,
        previousPaneIDBeforeRemoval: UUID?
    ) -> UUID? {
        guard closedPanelWasFocused else {
            return resolveFocusedPanel(in: workspace)?.panelID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           focusedPanelID != closedPanelID,
           workspace.panels[focusedPanelID] != nil,
           workspace.paneTree.leafContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        if let sourceLeaf = workspace.paneTree.leafNode(paneID: sourcePaneID),
           let selectedSourcePanelID = selectedPanelID(in: sourceLeaf, workspace: workspace) {
            return selectedSourcePanelID
        }

        if let previousPaneIDBeforeRemoval,
           let previousLeaf = workspace.paneTree.leafNode(paneID: previousPaneIDBeforeRemoval),
           let selectedPreviousPanelID = selectedPanelID(in: previousLeaf, workspace: workspace) {
            return selectedPreviousPanelID
        }

        return resolveFocusedPanel(in: workspace)?.panelID
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

    private static func resolveReopenPaneID(in workspace: WorkspaceState, preferredPaneID: UUID) -> UUID? {
        if workspace.paneTree.allLeafInfos.contains(where: { $0.paneID == preferredPaneID }) {
            return preferredPaneID
        }
        if let focusedPanelID = workspace.focusedPanelID,
           let focusedLeaf = workspace.paneTree.leafContaining(panelID: focusedPanelID) {
            return focusedLeaf.paneID
        }
        return workspace.paneTree.allLeafInfos.first?.paneID
    }

    private static func auxPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        Set(
            workspace.panels.compactMap { panelID, panelState in
                auxiliaryPanelKinds.contains(panelState.kind) ? panelID : nil
            }
        )
    }

    private static func resolveAuxColumnPaneID(in workspace: WorkspaceState, auxPanelIDs: Set<UUID>) -> UUID? {
        guard auxPanelIDs.isEmpty == false else { return nil }
        return workspace.paneTree.allLeafInfos.last(where: { leaf in
            leaf.tabPanelIDs.contains(where: { auxPanelIDs.contains($0) })
        })?.paneID
    }

    @discardableResult
    private static func removeWorkspace(_ workspaceID: UUID, windowID: UUID, state: inout AppState) -> Bool {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        var window = state.windows[windowIndex]
        guard let workspaceIndex = window.workspaceIDs.firstIndex(of: workspaceID) else { return false }

        state.workspacesByID.removeValue(forKey: workspaceID)
        window.workspaceIDs.remove(at: workspaceIndex)

        if window.workspaceIDs.isEmpty {
            let removedWindowID = window.id
            state.windows.remove(at: windowIndex)
            if state.selectedWindowID == removedWindowID {
                state.selectedWindowID = state.windows.first?.id
            }
            return true
        }

        if window.selectedWorkspaceID == workspaceID {
            let nextIndex = min(workspaceIndex, window.workspaceIDs.count - 1)
            window.selectedWorkspaceID = window.workspaceIDs[nextIndex]
        }

        state.windows[windowIndex] = window
        if state.selectedWindowID == nil {
            state.selectedWindowID = window.id
        }
        return true
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

    private static func normalizedMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
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

    private static let auxiliaryPanelKinds: Set<PanelKind> = [.diff, .markdown, .scratchpad]
}

private struct PanelLocation {
    let windowID: UUID
    let workspaceID: UUID
    let paneID: UUID
}
