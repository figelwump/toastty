import Foundation

public struct AppReducer {
    private enum EmptyWorkspaceTabDisposition {
        case bootstrapReplacementTab
        case removeWorkspace(EmptyWindowDisposition)
    }

    private enum EmptyWindowDisposition {
        case keepWindow
        case removeWindow
    }

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

        case .updateWindowFrame(let windowID, let frame):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            guard state.windows[windowIndex].frame != frame else { return false }
            state.windows[windowIndex].frame = frame
            return true

        case .selectWorkspace(let windowID, let workspaceID):
            guard let index = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            guard state.windows[index].workspaceIDs.contains(workspaceID) else { return false }
            state.selectedWindowID = windowID
            state.windows[index].selectedWorkspaceID = workspaceID
            markWorkspaceScopedNotificationsRead(workspaceID: workspaceID, state: &state)
            return true

        case .selectWorkspaceTab(let workspaceID, let tabID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.tabsByID[tabID] != nil else { return false }
            guard workspace.selectedTabID != tabID else { return false }
            if let sourceTabID = workspace.resolvedSelectedTabID {
                _ = workspace.updateTab(id: sourceTabID) { tab in
                    tab.selectedPanelIDs.removeAll()
                }
            }
            workspace.selectedTabID = tabID
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .createWorkspace(let windowID, let title):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }

            let resolvedTitle = title ?? nextWorkspaceTitle(in: state.windows[windowIndex], state: state)
            let workspace = WorkspaceState.bootstrap(
                title: resolvedTitle,
                initialTerminalProfileBinding: state.defaultTerminalProfileBinding
            )

            commitWorkspace(workspace, workspaceID: workspace.id, state: &state)
            state.windows[windowIndex].workspaceIDs.append(workspace.id)
            state.windows[windowIndex].selectedWorkspaceID = workspace.id
            return true

        case .createWorkspaceTab(let workspaceID, let seed):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            let tab = WorkspaceTabState.bootstrap(
                initialTerminalCWD: seed?.terminalCWD,
                initialTerminalProfileBinding: seed?.terminalProfileBinding ?? state.defaultTerminalProfileBinding
            )
            workspace.appendTab(tab, select: true)
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .createWindow(let seed, let initialFrame):
            let workspace = WorkspaceState.bootstrap(
                title: normalizedWorkspaceTitle(seed?.workspaceTitle) ?? "Workspace 1",
                initialTerminalCWD: seed?.terminalCWD,
                initialTerminalProfileBinding: seed?.terminalProfileBinding ?? state.defaultTerminalProfileBinding
            )
            let window = WindowState(
                id: UUID(),
                frame: initialFrame ?? CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
                workspaceIDs: [workspace.id],
                selectedWorkspaceID: workspace.id,
                terminalFontSizePointsOverride: seed?.windowTerminalFontSizePointsOverride
            )

            commitWorkspace(workspace, workspaceID: workspace.id, state: &state)
            state.windows.append(window)
            state.selectedWindowID = window.id
            return true

        case .closeWindow(let windowID):
            return removeWindow(windowID, state: &state)

        case .renameWorkspace(let workspaceID, let title):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedTitle.isEmpty == false else { return false }
            guard workspace.title != trimmedTitle else { return false }
            workspace.title = trimmedTitle
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .setWorkspaceTabCustomTitle(let workspaceID, let tabID, let title):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            let normalizedTitle = normalizedMetadataValue(title)
            guard workspace.tabsByID[tabID] != nil else { return false }
            guard title == nil || normalizedTitle != nil else { return false }
            guard workspace.tab(id: tabID)?.customTitle != normalizedTitle else { return false }
            guard workspace.updateTab(id: tabID, { tab in
                tab.customTitle = normalizedTitle
            }) else {
                return false
            }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .closeWorkspace(let workspaceID):
            guard let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) else { return false }
            return removeWorkspace(
                workspaceID,
                windowID: windowID,
                emptyWindowDisposition: .keepWindow,
                state: &state
            )

        case .closeWorkspaceTab(let workspaceID, let tabID):
            guard let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) else { return false }
            return removeWorkspaceTab(
                tabID,
                workspaceID: workspaceID,
                windowID: windowID,
                emptyWorkspaceDisposition: .removeWorkspace(.keepWindow),
                state: &state
            )

        case .focusPanel(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
            workspace.selectedTabID = tabID
            guard workspace.updateTab(id: tabID, { tab in
                tab.focusedPanelID = panelID
                tab.selectedPanelIDs.removeAll()

                guard tab.focusedPanelModeActive else {
                    return
                }

                let splitTree = WorkspaceSplitTree(root: tab.layoutTree)
                let currentRootNodeID = splitTree.effectiveFocusModeRootNodeID(
                    preferredRootNodeID: tab.focusModeRootNodeID,
                    focusedPanelID: tab.focusedPanelID
                )
                if let currentRootNodeID,
                   let currentSubtree = tab.layoutTree.findSubtree(nodeID: currentRootNodeID),
                   currentSubtree.slotContaining(panelID: panelID) != nil {
                    tab.focusModeRootNodeID = currentRootNodeID
                } else {
                    tab.focusModeRootNodeID = tab.layoutTree.slotContaining(panelID: panelID)?.slotID
                }
            }) else {
                return false
            }
            _ = workspace.unreadPanelIDs.remove(panelID)
            workspace.unreadWorkspaceNotificationCount = 0
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .movePanelToSlot(let panelID, let targetSlotID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard let targetLocation = locateSlot(targetSlotID, in: state) else { return false }
            guard sourceLocation.workspaceID == targetLocation.workspaceID else { return false }
            guard sourceLocation.tabID == targetLocation.tabID else { return false }
            guard var workspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard sourceLocation.slotID != targetSlotID else { return false }

            let removal = workspace.layoutTree.removingPanel(panelID)
            guard removal.removed, var updatedTree = removal.node else { return false }
            guard splitLeaf(
                slotID: targetSlotID,
                in: &updatedTree,
                insertingPanelID: panelID,
                orientation: .horizontal,
                placeInsertedPanelSecond: true
            ) else {
                return false
            }
            workspace.layoutTree = updatedTree
            workspace.focusedPanelID = panelID
            commitWorkspace(workspace, workspaceID: sourceLocation.workspaceID, state: &state)
            return true

        case .movePanelToWorkspace(let panelID, let targetWorkspaceID, let targetSlotID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var sourceWorkspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard var targetWorkspace = state.workspacesByID[targetWorkspaceID] else { return false }
            guard let panelState = sourceWorkspace.panelState(for: panelID) else { return false }

            if sourceLocation.workspaceID == targetWorkspaceID {
                guard let slotDestination = targetSlotID else { return false }
                return reduce(
                    action: .movePanelToSlot(panelID: panelID, targetSlotID: slotDestination),
                    state: &state
                )
            }

            guard let insertionSlotID = targetWorkspace.insertionSlotID(preferred: targetSlotID) else {
                return false
            }

            let sourceRemoval = sourceWorkspace.layoutTree.removingPanel(panelID)
            guard sourceRemoval.removed else { return false }

            var shouldRemoveSourceTab = false
            let didTransferUnreadBadge = sourceWorkspace.unreadPanelIDs.remove(panelID) != nil
            sourceWorkspace.panels.removeValue(forKey: panelID)
            if let updatedSourceTree = sourceRemoval.node {
                sourceWorkspace.layoutTree = updatedSourceTree
                _ = sourceWorkspace.synchronizeFocusedPanelToLayout()
            } else {
                shouldRemoveSourceTab = true
            }

            if let targetSlotID,
               let targetTabID = targetWorkspace.tabID(containingSlotID: targetSlotID) {
                targetWorkspace.selectedTabID = targetTabID
            }

            targetWorkspace.panels[panelID] = panelState
            var targetTree = targetWorkspace.layoutTree
            guard splitLeaf(
                slotID: insertionSlotID,
                in: &targetTree,
                insertingPanelID: panelID,
                orientation: .horizontal,
                placeInsertedPanelSecond: true
            ) else {
                return false
            }
            targetWorkspace.layoutTree = targetTree
            targetWorkspace.focusedPanelID = panelID
            if didTransferUnreadBadge {
                targetWorkspace.unreadPanelIDs.insert(panelID)
            }

            if shouldRemoveSourceTab {
                commitWorkspace(sourceWorkspace, workspaceID: sourceLocation.workspaceID, state: &state)
                guard removeWorkspaceTab(
                    sourceLocation.tabID,
                    workspaceID: sourceLocation.workspaceID,
                    windowID: sourceLocation.windowID,
                    emptyWorkspaceDisposition: .removeWorkspace(.removeWindow),
                    state: &state
                ) else {
                    return false
                }
            } else {
                commitWorkspace(sourceWorkspace, workspaceID: sourceLocation.workspaceID, state: &state)
            }
            commitWorkspace(targetWorkspace, workspaceID: targetWorkspaceID, state: &state)
            return true

        case .detachPanelToNewWindow(let panelID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var sourceWorkspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard let panelState = sourceWorkspace.panelState(for: panelID) else { return false }

            let sourceRemoval = sourceWorkspace.layoutTree.removingPanel(panelID)
            guard sourceRemoval.removed else { return false }

            let didTransferUnreadBadge = sourceWorkspace.unreadPanelIDs.remove(panelID) != nil
            sourceWorkspace.panels.removeValue(forKey: panelID)
            if let updatedSourceTree = sourceRemoval.node {
                sourceWorkspace.layoutTree = updatedSourceTree
                _ = sourceWorkspace.synchronizeFocusedPanelToLayout()
                commitWorkspace(sourceWorkspace, workspaceID: sourceLocation.workspaceID, state: &state)
            } else {
                commitWorkspace(sourceWorkspace, workspaceID: sourceLocation.workspaceID, state: &state)
                removeWorkspaceTab(
                    sourceLocation.tabID,
                    workspaceID: sourceLocation.workspaceID,
                    windowID: sourceLocation.windowID,
                    emptyWorkspaceDisposition: .removeWorkspace(.removeWindow),
                    state: &state
                )
            }

            let detachedWorkspaceID = UUID()
            let detachedSlotID = UUID()
            let detachedWorkspace = WorkspaceState(
                id: detachedWorkspaceID,
                title: "Workspace 1",
                layoutTree: .slot(slotID: detachedSlotID, panelID: panelID),
                panels: [panelID: panelState],
                focusedPanelID: panelID,
                unreadPanelIDs: didTransferUnreadBadge ? [panelID] : []
            )

            let detachedWindowID = UUID()
            let detachedWindow = WindowState(
                id: detachedWindowID,
                frame: CGRectCodable(x: 160, y: 160, width: 1000, height: 680),
                workspaceIDs: [detachedWorkspaceID],
                selectedWorkspaceID: detachedWorkspaceID,
                terminalFontSizePointsOverride: state.normalizedTerminalFontOverride(
                    state.effectiveTerminalFontPoints(for: sourceLocation.windowID)
                )
            )

            commitWorkspace(detachedWorkspace, workspaceID: detachedWorkspaceID, state: &state)
            state.windows.append(detachedWindow)
            state.selectedWindowID = detachedWindowID
            return true

        case .closePanel(let panelID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard let panelState = workspace.panelState(for: panelID) else { return false }
            workspace.selectedTabID = sourceLocation.tabID
            let wasFocusedPanel = workspace.focusedPanelID == panelID
            let previousSlotIDBeforeRemoval = wasFocusedPanel
                ? workspace.focusTargetSlotIDWithinVisibleRoot(from: sourceLocation.slotID, direction: .previous)
                : nil
            let trackedFocusModeRootNodeID = workspace.effectiveFocusModeRootNodeID

            workspace.recentlyClosedPanels.append(
                ClosedPanelRecord(
                    panelState: panelState,
                    closedAt: Date(),
                    sourceSlotID: sourceLocation.slotID
                )
            )
            if workspace.recentlyClosedPanels.count > 10 {
                workspace.recentlyClosedPanels.removeFirst(workspace.recentlyClosedPanels.count - 10)
            }

            let removal = workspace.layoutTree.removingPanel(
                panelID,
                trackingAncestorNodeID: trackedFocusModeRootNodeID
            )
            guard removal.removed else { return false }

            workspace.panels.removeValue(forKey: panelID)
            workspace.unreadPanelIDs.remove(panelID)
            workspace.auxPanelVisibility.remove(panelState.kind)
            _ = workspace.updateTab(id: sourceLocation.tabID) { tab in
                _ = tab.selectedPanelIDs.remove(panelID)
            }

            if let updatedTree = removal.node {
                workspace.layoutTree = updatedTree
                if workspace.focusedPanelModeActive {
                    workspace.focusModeRootNodeID = removal.trackedAncestorReplacementNodeID
                }
                workspace.focusedPanelID = workspace.focusedPanelIDAfterClosing(
                    closedPanelID: panelID,
                    closedPanelWasFocused: wasFocusedPanel,
                    previousSlotIDBeforeRemoval: previousSlotIDBeforeRemoval
                )
                if wasFocusedPanel, workspace.focusedPanelID != nil {
                    workspace.selectedPanelIDs.removeAll()
                }
                commitWorkspace(workspace, workspaceID: sourceLocation.workspaceID, state: &state)
            } else {
                commitWorkspace(workspace, workspaceID: sourceLocation.workspaceID, state: &state)
                removeWorkspaceTab(
                    sourceLocation.tabID,
                    workspaceID: sourceLocation.workspaceID,
                    windowID: sourceLocation.windowID,
                    emptyWorkspaceDisposition: .removeWorkspace(.keepWindow),
                    state: &state
                )
            }
            return true

        case .reopenLastClosedPanel(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let closedRecord = workspace.recentlyClosedPanels.last else { return false }

            if closedRecord.panelState.kind != .terminal,
               let existingAuxPanelID = workspace.panels.first(where: { $0.value.kind == closedRecord.panelState.kind })?.key {
                workspace.focusedPanelID = existingAuxPanelID
                workspace.recentlyClosedPanels.removeLast()
                workspace.selectedPanelIDs.removeAll()
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                return true
            }

            guard let targetSlotID = workspace.reopenSlotID(preferred: closedRecord.sourceSlotID) else {
                return false
            }

            let panelID = UUID()
            workspace.panels[panelID] = closedRecord.panelState

            guard splitLeaf(
                slotID: targetSlotID,
                in: &workspace.layoutTree,
                insertingPanelID: panelID,
                orientation: .horizontal,
                placeInsertedPanelSecond: true
            ) else {
                workspace.panels.removeValue(forKey: panelID)
                return false
            }

            workspace.focusedPanelID = panelID
            if closedRecord.panelState.kind != .terminal {
                workspace.auxPanelVisibility.insert(closedRecord.panelState.kind)
            }
            workspace.recentlyClosedPanels.removeLast()
            workspace.selectedPanelIDs.removeAll()

            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .toggleAuxPanel(let workspaceID, let kind):
            guard kind != .terminal else { return false }
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.focusedPanelModeActive == false else { return false }
            let selectedTabID = workspace.resolvedSelectedTabID

            if let existingPanelID = workspace.panels.first(where: { $0.value.kind == kind })?.key {
                let removal = workspace.layoutTree.removingPanel(existingPanelID)
                guard removal.removed else { return false }

                workspace.panels.removeValue(forKey: existingPanelID)
                workspace.unreadPanelIDs.remove(existingPanelID)
                workspace.auxPanelVisibility.remove(kind)

                if let updatedTree = removal.node {
                    workspace.layoutTree = updatedTree
                    if workspace.focusedPanelID == existingPanelID {
                        _ = workspace.synchronizeFocusedPanelToLayout()
                    }
                    commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                } else if let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) {
                    guard let selectedTabID else { return false }
                    commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                    removeWorkspaceTab(
                        selectedTabID,
                        workspaceID: workspaceID,
                        windowID: windowID,
                        state: &state
                    )
                }
                return true
            }

            guard let auxPanelState = makeAuxPanelState(for: kind) else { return false }
            let existingAuxPanelIDs = auxPanelIDs(in: workspace)
            let panelID = UUID()
            workspace.panels[panelID] = auxPanelState

            if existingAuxPanelIDs.isEmpty {
                // First aux panel always gets a dedicated right column regardless of terminal slot layout.
                let terminalTree = workspace.layoutTree
                let auxLeaf = LayoutNode.slot(
                    slotID: UUID(),
                    panelID: panelID
                )
                workspace.layoutTree = .split(
                    nodeID: UUID(),
                    orientation: .horizontal,
                    ratio: 0.7,
                    first: terminalTree,
                    second: auxLeaf
                )
            } else {
                guard let auxColumnSlotID = workspace.auxiliaryColumnSlotID(for: existingAuxPanelIDs) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }
                guard let existingAuxLeaf = workspace.layoutTree.slotNode(slotID: auxColumnSlotID) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }

                let auxLeaf = LayoutNode.slot(
                    slotID: UUID(),
                    panelID: panelID
                )
                let splitRightColumn = LayoutNode.split(
                    nodeID: UUID(),
                    orientation: .vertical,
                    ratio: 0.5,
                    first: existingAuxLeaf,
                    second: auxLeaf
                )

                guard workspace.layoutTree.replaceSlot(slotID: auxColumnSlotID, with: splitRightColumn) else {
                    workspace.panels.removeValue(forKey: panelID)
                    return false
                }
            }

            workspace.auxPanelVisibility.insert(kind)
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .toggleFocusedPanelMode(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let selectedTabID = workspace.resolvedSelectedTabID,
                  var selectedTab = workspace.tab(id: selectedTabID) else {
                return false
            }

            if selectedTab.focusedPanelModeActive {
                selectedTab.focusedPanelModeActive = false
                selectedTab.focusModeRootNodeID = nil
                selectedTab.selectedPanelIDs.removeAll()
                workspace.tabsByID[selectedTabID] = selectedTab
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                return true
            }

            let splitTree = WorkspaceSplitTree(root: selectedTab.layoutTree)
            let resolvedFocusedPanelID = selectedTab.resolvedFocusedPanelID
            selectedTab.focusedPanelID = resolvedFocusedPanelID

            if selectedTab.selectedPanelIDs.isEmpty == false {
                let slotIDs = Set(selectedTab.selectedPanelIDs.compactMap { selectedTab.layoutTree.slotContaining(panelID: $0)?.slotID })
                let selectionFocusedPanelID = selectedTab.resolvedFocusedPanelID
                    .flatMap { selectedTab.selectedPanelIDs.contains($0) ? $0 : nil }
                    ?? selectedTab.layoutTree.allSlotInfos.first(where: { selectedTab.selectedPanelIDs.contains($0.panelID) })?.panelID
                guard slotIDs.count == selectedTab.selectedPanelIDs.count,
                      let selectionFocusedPanelID,
                      let focusRootNodeID = selectedTab.layoutTree.lowestCommonAncestor(containing: slotIDs),
                      focusRootNodeID != selectedTab.layoutTree.resolvedNodeID else {
                    return false
                }
                selectedTab.focusedPanelID = selectionFocusedPanelID
                selectedTab.focusedPanelModeActive = true
                selectedTab.focusModeRootNodeID = focusRootNodeID
                selectedTab.selectedPanelIDs.removeAll()
            } else {
                guard let focusedPanelID = resolvedFocusedPanelID,
                      let focusedSlot = selectedTab.layoutTree.slotContaining(panelID: focusedPanelID) else {
                    return false
                }
                selectedTab.focusedPanelModeActive = true
                selectedTab.focusModeRootNodeID = splitTree.effectiveFocusModeRootNodeID(
                    preferredRootNodeID: focusedSlot.slotID,
                    focusedPanelID: focusedPanelID
                )
            }

            workspace.tabsByID[selectedTabID] = selectedTab
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .togglePanelSelection(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID),
                  workspace.resolvedSelectedTabID == tabID else {
                return false
            }
            guard workspace.tab(id: tabID)?.focusedPanelModeActive == false else {
                return false
            }
            guard workspace.updateTab(id: tabID, { tab in
                if tab.selectedPanelIDs.contains(panelID) {
                    tab.selectedPanelIDs.remove(panelID)
                } else {
                    tab.selectedPanelIDs.insert(panelID)
                }
            }) else {
                return false
            }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .clearPanelSelection(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let selectedTabID = workspace.resolvedSelectedTabID else { return false }
            guard workspace.updateTab(id: selectedTabID, { tab in
                tab.selectedPanelIDs.removeAll()
            }) else {
                return false
            }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .setConfiguredTerminalFont(let points):
            let clampedConfiguredPoints = points.map(AppState.clampedTerminalFontPoints)
            guard state.configuredTerminalFontPoints != clampedConfiguredPoints else { return false }
            state.configuredTerminalFontPoints = clampedConfiguredPoints
            return true

        case .setDefaultTerminalProfile(let profileID):
            let normalizedProfileID = AppState.normalizedTerminalProfileID(profileID)
            guard state.defaultTerminalProfileID != normalizedProfileID else { return false }
            state.defaultTerminalProfileID = normalizedProfileID
            return true

        case .setWindowTerminalFont(let windowID, let points):
            return setWindowTerminalFont(windowID: windowID, points: points, state: &state)

        case .increaseWindowTerminalFont(let windowID):
            return adjustWindowTerminalFont(windowID: windowID, step: AppState.terminalFontStepPoints, state: &state)

        case .decreaseWindowTerminalFont(let windowID):
            return adjustWindowTerminalFont(windowID: windowID, step: -AppState.terminalFontStepPoints, state: &state)

        case .resetWindowTerminalFont(let windowID):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            guard state.windows[windowIndex].terminalFontSizePointsOverride != nil else { return false }
            state.windows[windowIndex].terminalFontSizePointsOverride = nil
            return true

        case .splitFocusedSlot(let workspaceID, let orientation):
            let direction: SlotSplitDirection = orientation == .horizontal ? .right : .down
            return splitFocusedSlot(workspaceID: workspaceID, direction: direction, state: &state)

        case .splitFocusedSlotInDirection(let workspaceID, let direction):
            return splitFocusedSlot(workspaceID: workspaceID, direction: direction, state: &state)

        case .splitFocusedSlotInDirectionWithTerminalProfile(let workspaceID, let direction, let profileBinding):
            return splitFocusedSlot(
                workspaceID: workspaceID,
                direction: direction,
                profileBinding: profileBinding,
                state: &state
            )

        case .focusSlot(let workspaceID, let direction):
            return focusSlot(workspaceID: workspaceID, direction: direction, state: &state)

        case .resizeFocusedSlotSplit(let workspaceID, let direction, let amount):
            return resizeFocusedSlotSplit(
                workspaceID: workspaceID,
                direction: direction,
                amount: amount,
                state: &state
            )

        case .equalizeLayoutSplits(let workspaceID):
            return equalizeLayoutSplits(workspaceID: workspaceID, state: &state)

        case .createTerminalPanel(let workspaceID, let slotID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }

            let panelID = UUID()
            workspace.panels[panelID] = .terminal(
                TerminalPanelState(
                    title: nextTerminalTitle(in: workspace),
                    shell: "zsh",
                    cwd: NSHomeDirectory(),
                    profileBinding: state.defaultTerminalProfileBinding
                )
            )

            guard splitLeaf(
                slotID: slotID,
                in: &workspace.layoutTree,
                insertingPanelID: panelID,
                orientation: .horizontal,
                placeInsertedPanelSecond: true
            ) else {
                workspace.panels.removeValue(forKey: panelID)
                return false
            }

            workspace.focusedPanelID = panelID
            workspace.selectedPanelIDs.removeAll()
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .updateTerminalPanelMetadata(let panelID, let title, let cwd):
            guard let location = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[location.workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID),
                  case .terminal(var terminalState) = workspace.tab(id: tabID)?.panels[panelID] else { return false }

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
            _ = workspace.updateTab(id: tabID) { tab in
                tab.panels[panelID] = .terminal(terminalState)
            }
            commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
            return true

        case .recordDesktopNotification(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            if let panelID {
                guard let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
                _ = workspace.updateTab(id: tabID) { tab in
                    tab.unreadPanelIDs.insert(panelID)
                }
            } else {
                workspace.unreadWorkspaceNotificationCount += 1
            }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .markPanelNotificationsRead(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
            let didMutate = workspace.updateTab(id: tabID) { tab in
                _ = tab.unreadPanelIDs.remove(panelID)
            }
            if didMutate {
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            }
            return true

        case .toggleSidebar(let windowID):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            state.windows[windowIndex].sidebarVisible.toggle()
            return true
        }
    }

    private static func setWindowTerminalFont(windowID: UUID, points: Double, state: inout AppState) -> Bool {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        let normalizedOverride = state.normalizedTerminalFontOverride(points)
        guard state.windows[windowIndex].terminalFontSizePointsOverride != normalizedOverride else {
            return false
        }
        state.windows[windowIndex].terminalFontSizePointsOverride = normalizedOverride
        return true
    }

    private static func adjustWindowTerminalFont(windowID: UUID, step: Double, state: inout AppState) -> Bool {
        guard state.window(id: windowID) != nil else { return false }
        let previousPoints = state.effectiveTerminalFontPoints(for: windowID)
        let nextPoints = AppState.clampedTerminalFontPoints(previousPoints + step)
        guard abs(nextPoints - previousPoints) >= AppState.terminalFontComparisonEpsilon else {
            return false
        }
        let normalizedOverride = state.normalizedTerminalFontOverride(nextPoints)
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        guard state.windows[windowIndex].terminalFontSizePointsOverride != normalizedOverride else {
            return false
        }
        state.windows[windowIndex].terminalFontSizePointsOverride = normalizedOverride
        return true
    }

    @discardableResult
    private static func splitFocusedSlot(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        profileBinding: TerminalProfileBinding? = nil,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard let focusResolution = workspace.synchronizeFocusedPanelToLayout() else {
            return false
        }

        let inheritedCWD: String
        if case .terminal(let focusedTerminalState) = workspace.panels[focusResolution.panelID] {
            inheritedCWD = focusedTerminalState.workingDirectorySeed
        } else {
            inheritedCWD = NSHomeDirectory()
        }

        let newPanelID = UUID()
        let newSlotID = UUID()
        let resolvedProfileBinding = profileBinding ?? state.defaultTerminalProfileBinding

        workspace.panels[newPanelID] = .terminal(
            TerminalPanelState(
                title: nextTerminalTitle(in: workspace),
                shell: "zsh",
                cwd: inheritedCWD,
                profileBinding: resolvedProfileBinding
            )
        )

        let trackedRootNodeID = workspace.effectiveFocusModeRootNodeID

        guard let splitResult = WorkspaceSplitTree(root: workspace.layoutTree).splitting(
            slotID: focusResolution.slot.slotID,
            direction: direction,
            newPanelID: newPanelID,
            newSlotID: newSlotID
        ) else {
            return false
        }

        workspace.apply(splitTree: splitResult.tree)
        if workspace.focusedPanelModeActive,
           trackedRootNodeID == focusResolution.slot.slotID {
            workspace.focusModeRootNodeID = splitResult.newSplitNodeID
        }
        workspace.focusedPanelID = newPanelID
        workspace.selectedPanelIDs.removeAll()
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true

    }

    @discardableResult
    private static func focusSlot(
        workspaceID: UUID,
        direction: SlotFocusDirection,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard let focusResolution = workspace.synchronizeFocusedPanelToLayout() else {
            return false
        }

        guard let targetSlotID = workspace.focusTargetSlotIDWithinVisibleRoot(
            from: focusResolution.slot.slotID,
            direction: direction
        ) else {
            return false
        }
        guard targetSlotID != focusResolution.slot.slotID else {
            return false
        }
        guard let targetPanelID = workspace.panelID(forSlotID: targetSlotID) else {
            return false
        }
        guard targetPanelID != workspace.focusedPanelID else {
            return false
        }

        workspace.focusedPanelID = targetPanelID
        workspace.selectedPanelIDs.removeAll()
        _ = workspace.unreadPanelIDs.remove(targetPanelID)
        workspace.unreadWorkspaceNotificationCount = 0
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true
    }

    private static func markWorkspaceScopedNotificationsRead(workspaceID: UUID, state: inout AppState) {
        guard var workspace = state.workspacesByID[workspaceID] else { return }
        guard workspace.unreadWorkspaceNotificationCount > 0 else { return }
        workspace.unreadWorkspaceNotificationCount = 0
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
    }

    private static func resizeFocusedSlotSplit(
        workspaceID: UUID,
        direction: SplitResizeDirection,
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
        guard let focusResolution = workspace.synchronizeFocusedPanelToLayout() else {
            ToasttyLog.debug(
                "Resize split rejected: no focused panel",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        let updatedLayoutTree: LayoutNode
        if workspace.focusedPanelModeActive {
            guard let rootNodeID = workspace.effectiveFocusModeRootNodeID,
                  let focusModeSubtree = WorkspaceSplitTree(root: workspace.layoutTree).focusedSubtree(rootNodeID: rootNodeID),
                  let resizedSubtree = focusModeSubtree.resized(
                    focusedSlotID: focusResolution.slot.slotID,
                    direction: direction,
                    amount: amount
                  ) else {
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

            var replacedLayoutTree = workspace.layoutTree
            guard replacedLayoutTree.replaceNode(nodeID: rootNodeID, with: resizedSubtree.root) else {
                return false
            }
            updatedLayoutTree = replacedLayoutTree
        } else if let updatedSplitTree = WorkspaceSplitTree(root: workspace.layoutTree).resized(
            focusedSlotID: focusResolution.slot.slotID,
            direction: direction,
            amount: amount
        ) {
            updatedLayoutTree = updatedSplitTree.root
        } else {
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

        workspace.layoutTree = updatedLayoutTree
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
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

    private static func equalizeLayoutSplits(workspaceID: UUID, state: inout AppState) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else {
            ToasttyLog.debug(
                "Equalize splits rejected: workspace missing",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        let updatedLayoutTree: LayoutNode
        if workspace.focusedPanelModeActive {
            guard let rootNodeID = workspace.effectiveFocusModeRootNodeID,
                  let focusModeSubtree = WorkspaceSplitTree(root: workspace.layoutTree).focusedSubtree(rootNodeID: rootNodeID),
                  let equalizedSubtree = focusModeSubtree.equalized() else {
                ToasttyLog.debug(
                    "Equalize splits rejected: tree already equalized",
                    category: .reducer,
                    metadata: ["workspace_id": workspaceID.uuidString]
                )
                return false
            }

            var replacedLayoutTree = workspace.layoutTree
            guard replacedLayoutTree.replaceNode(nodeID: rootNodeID, with: equalizedSubtree.root) else {
                return false
            }
            updatedLayoutTree = replacedLayoutTree
        } else if let updatedSplitTree = WorkspaceSplitTree(root: workspace.layoutTree).equalized() {
            updatedLayoutTree = updatedSplitTree.root
        } else {
            ToasttyLog.debug(
                "Equalize splits rejected: tree already equalized",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        workspace.layoutTree = updatedLayoutTree
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        ToasttyLog.debug(
            "Equalized layout splits",
            category: .reducer,
            metadata: ["workspace_id": workspaceID.uuidString]
        )
        return true
    }

    private static func locatePanel(_ panelID: UUID, in state: AppState) -> PanelLocation? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID),
              let tabID = selection.workspace.tabID(containingPanelID: panelID),
              let slotID = selection.workspace.slotID(containingPanelID: panelID) else {
            return nil
        }

        return PanelLocation(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            tabID: tabID,
            slotID: slotID
        )
    }

    private static func locateSlot(_ slotID: UUID, in state: AppState) -> SlotLocation? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID],
                      let tabID = workspace.tabID(containingSlotID: slotID) else {
                    continue
                }
                return SlotLocation(workspaceID: workspaceID, tabID: tabID)
            }
        }

        return nil
    }

    private static func locateWorkspaceID(containingSlotID slotID: UUID, in state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.tabID(containingSlotID: slotID) != nil {
                    return workspaceID
                }
            }
        }
        return nil
    }

    private static func locateWindowID(containingWorkspaceID workspaceID: UUID, in state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }

    private static func auxPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        Set(
            workspace.panels.compactMap { panelID, panelState in
                auxiliaryPanelKinds.contains(panelState.kind) ? panelID : nil
            }
        )
    }

    private static func splitLeaf(
        slotID: UUID,
        in layoutTree: inout LayoutNode,
        insertingPanelID: UUID,
        orientation: SplitOrientation,
        placeInsertedPanelSecond: Bool
    ) -> Bool {
        guard let existingSlotNode = layoutTree.slotNode(slotID: slotID),
              case .slot(_, let existingPanelID) = existingSlotNode else {
            return false
        }

        let existingNode = LayoutNode.slot(slotID: slotID, panelID: existingPanelID)
        let insertedNode = LayoutNode.slot(slotID: UUID(), panelID: insertingPanelID)
        let firstNode = placeInsertedPanelSecond ? existingNode : insertedNode
        let secondNode = placeInsertedPanelSecond ? insertedNode : existingNode
        let splitNode = LayoutNode.split(
            nodeID: UUID(),
            orientation: orientation,
            ratio: 0.5,
            first: firstNode,
            second: secondNode
        )
        return layoutTree.replaceSlot(slotID: slotID, with: splitNode)
    }

    private static func commitWorkspace(
        _ workspace: WorkspaceState,
        workspaceID: UUID,
        state: inout AppState
    ) {
        var repairedWorkspace = workspace
        repairedWorkspace.repairTransientTabState()
        state.workspacesByID[workspaceID] = repairedWorkspace
    }

    @discardableResult
    private static func removeWorkspace(
        _ workspaceID: UUID,
        windowID: UUID,
        emptyWindowDisposition: EmptyWindowDisposition = .removeWindow,
        state: inout AppState
    ) -> Bool {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        var window = state.windows[windowIndex]
        guard let workspaceIndex = window.workspaceIDs.firstIndex(of: workspaceID) else { return false }

        state.workspacesByID.removeValue(forKey: workspaceID)
        window.workspaceIDs.remove(at: workspaceIndex)

        if window.workspaceIDs.isEmpty {
            switch emptyWindowDisposition {
            case .keepWindow:
                window.selectedWorkspaceID = nil
                state.windows[windowIndex] = window
                if state.selectedWindowID == nil {
                    state.selectedWindowID = window.id
                }
            case .removeWindow:
                let removedWindowID = window.id
                state.windows.remove(at: windowIndex)
                if state.selectedWindowID == removedWindowID || state.selectedWindowID == nil {
                    state.selectedWindowID = state.windows.first?.id
                }
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

    @discardableResult
    private static func removeWorkspaceTab(
        _ tabID: UUID,
        workspaceID: UUID,
        windowID: UUID,
        emptyWorkspaceDisposition: EmptyWorkspaceTabDisposition = .bootstrapReplacementTab,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard workspace.tabsByID[tabID] != nil else { return false }
        _ = workspace.removeTab(id: tabID)

        if workspace.tabIDs.isEmpty {
            switch emptyWorkspaceDisposition {
            case .bootstrapReplacementTab:
                let replacementTab = WorkspaceTabState.bootstrap(
                    initialTerminalProfileBinding: state.defaultTerminalProfileBinding
                )
                workspace.appendTab(replacementTab, select: true)
            case .removeWorkspace(let emptyWindowDisposition):
                return removeWorkspace(
                    workspaceID,
                    windowID: windowID,
                    emptyWindowDisposition: emptyWindowDisposition,
                    state: &state
                )
            }
        }

        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true
    }

    @discardableResult
    private static func removeWindow(_ windowID: UUID, state: inout AppState) -> Bool {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        let removedWindow = state.windows.remove(at: windowIndex)

        for workspaceID in removedWindow.workspaceIDs {
            state.workspacesByID.removeValue(forKey: workspaceID)
        }

        if state.selectedWindowID == windowID {
            state.selectedWindowID = state.windows.first?.id
        } else if state.selectedWindowID == nil {
            state.selectedWindowID = state.windows.first?.id
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

    private static func normalizedWorkspaceTitle(_ value: String?) -> String? {
        normalizedMetadataValue(value)
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
    let tabID: UUID
    let slotID: UUID
}

private struct SlotLocation {
    let workspaceID: UUID
    let tabID: UUID
}
