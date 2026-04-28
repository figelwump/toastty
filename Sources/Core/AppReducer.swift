import Foundation

public struct AppReducer {
    private enum FocusGraphTarget: Equatable {
        case mainPanel(UUID)
        case rightAuxPanel(UUID)
    }

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
            markWorkspaceVisited(workspaceID: workspaceID, state: &state)
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

        case .moveWorkspace(let windowID, let fromIndex, let toIndex):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            guard moveElement(in: &state.windows[windowIndex].workspaceIDs, fromIndex: fromIndex, toIndex: toIndex) else {
                return false
            }
            return true

        case .moveWorkspaceTab(let workspaceID, let fromIndex, let toIndex):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard moveElement(in: &workspace.tabIDs, fromIndex: fromIndex, toIndex: toIndex) else { return false }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .createWorkspace(let windowID, let title, let activate):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }

            let resolvedTitle = title ?? nextWorkspaceTitle(in: state.windows[windowIndex], state: state)
            let workspace = WorkspaceState.bootstrap(
                title: resolvedTitle,
                initialTerminalProfileBinding: state.defaultTerminalProfileBinding,
                hasBeenVisited: activate
            )

            commitWorkspace(workspace, workspaceID: workspace.id, state: &state)
            state.windows[windowIndex].workspaceIDs.append(workspace.id)
            if activate {
                state.windows[windowIndex].selectedWorkspaceID = workspace.id
            }
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
                terminalFontSizePointsOverride: seed?.windowTerminalFontSizePointsOverride,
                markdownTextScaleOverride: seed?.windowMarkdownTextScaleOverride
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
            if let rightAuxLocation = workspace.rightAuxPanelTabLocation(containingPanelID: panelID) {
                workspace.selectedTabID = rightAuxLocation.mainTabID
                _ = workspace.updateTab(id: rightAuxLocation.mainTabID) { tab in
                    tab.rightAuxPanel.activeTabID = rightAuxLocation.rightAuxTabID
                    tab.rightAuxPanel.isVisible = true
                    tab.rightAuxPanel.focusedPanelID = panelID
                    tab.unreadPanelIDs.remove(panelID)
                }
                workspace.unreadWorkspaceNotificationCount = 0
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                return true
            }

            guard let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
            workspace.selectedTabID = tabID
            workspace.rightAuxPanel.focusedPanelID = nil
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
                ),
                markdownTextScaleOverride: AppState.normalizedMarkdownTextScaleOverride(
                    state.effectiveMarkdownTextScale(for: sourceLocation.windowID)
                )
            )

            commitWorkspace(detachedWorkspace, workspaceID: detachedWorkspaceID, state: &state)
            state.windows.append(detachedWindow)
            state.selectedWindowID = detachedWindowID
            return true

        case .closePanel(let panelID):
            if let rightAuxLocation = locateRightAuxPanel(panelID, in: state) {
                return closeRightAuxPanelTab(
                    workspaceID: rightAuxLocation.workspaceID,
                    mainTabID: rightAuxLocation.mainTabID,
                    rightAuxTabID: rightAuxLocation.rightAuxTabID,
                    state: &state
                )
            }

            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[sourceLocation.workspaceID] else { return false }
            guard let panelState = workspace.panelState(for: panelID) else { return false }
            let sourceTabIndex = workspace.tabIDs.firstIndex(of: sourceLocation.tabID)
            let sourceTabPredecessorID: UUID?
            if let sourceTabIndex, sourceTabIndex > 0 {
                sourceTabPredecessorID = workspace.tabIDs[sourceTabIndex - 1]
            } else {
                sourceTabPredecessorID = nil
            }
            let sourceTabSuccessorID: UUID?
            if let sourceTabIndex {
                let successorIndex = sourceTabIndex + 1
                if workspace.tabIDs.indices.contains(successorIndex) {
                    sourceTabSuccessorID = workspace.tabIDs[successorIndex]
                } else {
                    sourceTabSuccessorID = nil
                }
            } else {
                sourceTabSuccessorID = nil
            }
            let sourceTabCustomTitle = workspace.tab(id: sourceLocation.tabID)?.customTitle
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
                    sourceSlotID: sourceLocation.slotID,
                    sourceTabID: sourceLocation.tabID,
                    sourceTabIndex: sourceTabIndex,
                    sourceTabPredecessorID: sourceTabPredecessorID,
                    sourceTabSuccessorID: sourceTabSuccessorID,
                    sourceTabCustomTitle: sourceTabCustomTitle
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
            guard let historyTabID = workspace.resolvedSelectedTabID,
                  let historyTab = workspace.tab(id: historyTabID),
                  let closedRecord = historyTab.recentlyClosedPanels.last else { return false }

            let panelID = UUID()

            if let sourceTabID = closedRecord.sourceTabID,
               workspace.tab(id: sourceTabID) == nil {
                var updatedHistoryTab = historyTab
                updatedHistoryTab.recentlyClosedPanels.removeLast()
                workspace.tabsByID[historyTabID] = updatedHistoryTab

                let reopenedTab = WorkspaceTabState(
                    id: sourceTabID,
                    customTitle: closedRecord.sourceTabCustomTitle,
                    layoutTree: .slot(slotID: closedRecord.sourceSlotID, panelID: panelID),
                    panels: [panelID: closedRecord.panelState],
                    focusedPanelID: panelID
                )
                let insertionIndex = Self.reopenedTabInsertionIndex(for: closedRecord, in: workspace)
                workspace.insertTab(reopenedTab, at: insertionIndex, select: true)
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                return true
            }

            let targetTabID: UUID
            if let sourceTabID = closedRecord.sourceTabID,
               workspace.tab(id: sourceTabID) != nil {
                targetTabID = sourceTabID
            } else {
                targetTabID = historyTabID
            }

            guard var targetTab = workspace.tab(id: targetTabID),
                  let targetSlotID = targetTab.reopenSlotID(preferred: closedRecord.sourceSlotID) else {
                return false
            }

            targetTab.panels[panelID] = closedRecord.panelState
            guard splitLeaf(
                slotID: targetSlotID,
                in: &targetTab.layoutTree,
                insertingPanelID: panelID,
                orientation: .horizontal,
                placeInsertedPanelSecond: true
            ) else {
                return false
            }

            targetTab.focusedPanelID = panelID
            targetTab.selectedPanelIDs.removeAll()
            if historyTabID == targetTabID {
                targetTab.recentlyClosedPanels.removeLast()
            } else {
                var updatedHistoryTab = historyTab
                updatedHistoryTab.recentlyClosedPanels.removeLast()
                workspace.tabsByID[historyTabID] = updatedHistoryTab
            }

            workspace.tabsByID[targetTabID] = targetTab
            workspace.selectedTabID = targetTabID
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .createWebPanel(let workspaceID, let panel, let placement):
            return createWebPanel(
                workspaceID: workspaceID,
                panel: panel,
                placement: placement,
                state: &state
            )

        case .setRightAuxPanelVisibility(let workspaceID, let isVisible):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.rightAuxPanel.isVisible != isVisible else { return false }
            workspace.rightAuxPanel.isVisible = isVisible
            if isVisible {
                workspace.rightAuxPanel.focusActiveTab()
            } else {
                workspace.rightAuxPanel.focusedPanelID = nil
            }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .toggleRightAuxPanel(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            workspace.rightAuxPanel.isVisible.toggle()
            if workspace.rightAuxPanel.isVisible {
                workspace.rightAuxPanel.focusActiveTab()
            } else {
                workspace.rightAuxPanel.focusedPanelID = nil
            }
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .setRightAuxPanelWidth(let workspaceID, let width):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            let clampedWidth = RightAuxPanelState.clampedWidth(width)
            guard workspace.rightAuxPanel.width != clampedWidth ||
                workspace.rightAuxPanel.hasCustomWidth == false else {
                return false
            }
            workspace.rightAuxPanel.width = clampedWidth
            workspace.rightAuxPanel.hasCustomWidth = true
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .selectRightAuxPanelTab(let workspaceID, let tabID, let focus):
            guard var workspace = state.workspacesByID[workspaceID],
                  let location = workspace.rightAuxPanelTabLocation(containingRightAuxTabID: tabID),
                  var mainTab = workspace.tab(id: location.mainTabID),
                  let tab = mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID] else {
                return false
            }
            guard workspace.selectedTabID != location.mainTabID ||
                mainTab.rightAuxPanel.activeTabID != location.rightAuxTabID ||
                mainTab.rightAuxPanel.isVisible == false ||
                (focus && mainTab.rightAuxPanel.focusedPanelID != tab.panelID) else {
                return false
            }
            mainTab.rightAuxPanel.activeTabID = location.rightAuxTabID
            mainTab.rightAuxPanel.isVisible = true
            if focus {
                mainTab.rightAuxPanel.focusedPanelID = tab.panelID
                mainTab.unreadPanelIDs.remove(tab.panelID)
                workspace.unreadWorkspaceNotificationCount = 0
            }
            workspace.selectedTabID = location.mainTabID
            workspace.tabsByID[location.mainTabID] = mainTab
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .selectAdjacentRightAuxPanelTab(let workspaceID, let direction):
            return selectAdjacentRightAuxPanelTab(
                workspaceID: workspaceID,
                direction: direction,
                state: &state
            )

        case .closeRightAuxPanelTab(let workspaceID, let tabID):
            return closeRightAuxPanelTab(workspaceID: workspaceID, rightAuxTabID: tabID, state: &state)

        case .focusRightAuxPanel(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID],
                  let location = workspace.rightAuxPanelTabLocation(containingPanelID: panelID) else {
                return false
            }
            workspace.selectedTabID = location.mainTabID
            _ = workspace.updateTab(id: location.mainTabID) { tab in
                tab.rightAuxPanel.activeTabID = location.rightAuxTabID
                tab.rightAuxPanel.isVisible = true
                tab.rightAuxPanel.focusedPanelID = panelID
                tab.unreadPanelIDs.remove(panelID)
            }
            workspace.unreadWorkspaceNotificationCount = 0
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .clearRightAuxPanelFocus(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.rightAuxPanel.focusedPanelID != nil else { return false }
            workspace.rightAuxPanel.focusedPanelID = nil
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
            selectedTab.selectedPanelIDs.removeAll()
            guard let focusedPanelID = resolvedFocusedPanelID,
                  let focusedSlot = selectedTab.layoutTree.slotContaining(panelID: focusedPanelID) else {
                return false
            }
            selectedTab.focusedPanelModeActive = true
            selectedTab.focusModeRootNodeID = splitTree.effectiveFocusModeRootNodeID(
                preferredRootNodeID: focusedSlot.slotID,
                focusedPanelID: focusedPanelID
            )

            workspace.tabsByID[selectedTabID] = selectedTab
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

        case .setWindowMarkdownTextScale(let windowID, let scale):
            return setWindowMarkdownTextScale(windowID: windowID, scale: scale, state: &state)

        case .increaseWindowMarkdownTextScale(let windowID):
            return adjustWindowMarkdownTextScale(
                windowID: windowID,
                step: AppState.markdownTextScaleStep,
                state: &state
            )

        case .decreaseWindowMarkdownTextScale(let windowID):
            return adjustWindowMarkdownTextScale(
                windowID: windowID,
                step: -AppState.markdownTextScaleStep,
                state: &state
            )

        case .resetWindowMarkdownTextScale(let windowID):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            guard state.windows[windowIndex].markdownTextScaleOverride != nil else { return false }
            state.windows[windowIndex].markdownTextScaleOverride = nil
            return true

        case .setBrowserPanelPageZoom(let panelID, let zoom):
            return setBrowserPanelPageZoom(panelID: panelID, zoom: zoom, state: &state)

        case .increaseBrowserPanelPageZoom(let panelID):
            return adjustBrowserPanelPageZoom(
                panelID: panelID,
                direction: .increase,
                state: &state
            )

        case .decreaseBrowserPanelPageZoom(let panelID):
            return adjustBrowserPanelPageZoom(
                panelID: panelID,
                direction: .decrease,
                state: &state
            )

        case .resetBrowserPanelPageZoom(let panelID):
            return setBrowserPanelPageZoom(
                panelID: panelID,
                zoom: WebPanelState.defaultBrowserPageZoom,
                state: &state
            )

        case .splitFocusedSlot(let workspaceID, let orientation):
            let direction: SlotSplitDirection = orientation == .horizontal ? .right : .down
            return splitFocusedSlot(workspaceID: workspaceID, direction: direction, state: &state)

        case .splitFocusedSlotInDirection(let workspaceID, let direction):
            return splitFocusedSlot(workspaceID: workspaceID, direction: direction, state: &state)

        case .splitFocusedSlotInDirectionWithWorkingDirectory(
            let workspaceID,
            let direction,
            let workingDirectory
        ):
            return splitFocusedSlot(
                workspaceID: workspaceID,
                direction: direction,
                workingDirectory: workingDirectory,
                state: &state
            )

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
            workspace.rightAuxPanel.focusedPanelID = nil
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

        case .updateWebPanelMetadata(let panelID, let title, let url):
            if let location = locateRightAuxPanel(panelID, in: state) {
                guard var workspace = state.workspacesByID[location.workspaceID],
                      var mainTab = workspace.tab(id: location.mainTabID),
                      var rightAuxTab = mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID],
                      case .web(var webState) = rightAuxTab.panelState else {
                    return false
                }

                guard updateWebPanelState(&webState, title: title, url: url) else {
                    return false
                }

                rightAuxTab.panelState = .web(webState)
                mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID] = rightAuxTab
                workspace.tabsByID[location.mainTabID] = mainTab
                commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
                return true
            }

            guard let location = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[location.workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID),
                  case .web(var webState) = workspace.tab(id: tabID)?.panels[panelID] else { return false }

            guard updateWebPanelState(&webState, title: title, url: url) else { return false }
            _ = workspace.updateTab(id: tabID) { tab in
                tab.panels[panelID] = .web(webState)
            }
            commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
            return true

        case .updateScratchpadPanelState(let panelID, let scratchpad, let title):
            if let location = locateRightAuxPanel(panelID, in: state) {
                guard var workspace = state.workspacesByID[location.workspaceID],
                      var mainTab = workspace.tab(id: location.mainTabID),
                      var rightAuxTab = mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID],
                      case .web(var webState) = rightAuxTab.panelState,
                      webState.definition == .scratchpad else {
                    return false
                }

                guard updateScratchpadWebPanelState(&webState, scratchpad: scratchpad, title: title) else {
                    return false
                }

                rightAuxTab.panelState = .web(webState)
                mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID] = rightAuxTab
                workspace.tabsByID[location.mainTabID] = mainTab
                commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
                return true
            }

            guard let location = locatePanel(panelID, in: state) else { return false }
            guard var workspace = state.workspacesByID[location.workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID),
                  case .web(var webState) = workspace.tab(id: tabID)?.panels[panelID],
                  webState.definition == .scratchpad else { return false }

            guard updateScratchpadWebPanelState(&webState, scratchpad: scratchpad, title: title) else {
                return false
            }

            _ = workspace.updateTab(id: tabID) { tab in
                tab.panels[panelID] = .web(webState)
            }
            commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
            return true

        case .recordDesktopNotification(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            if let panelID {
                let tabID = workspace.tabID(containingPanelID: panelID)
                    ?? workspace.rightAuxPanelTabLocation(containingPanelID: panelID)?.mainTabID
                guard let tabID else { return false }
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
            let tabID = workspace.tabID(containingPanelID: panelID)
                ?? workspace.rightAuxPanelTabLocation(containingPanelID: panelID)?.mainTabID
            guard let tabID else { return false }
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

    private static func setWindowMarkdownTextScale(
        windowID: UUID,
        scale: Double,
        state: inout AppState
    ) -> Bool {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        let normalizedOverride = AppState.normalizedMarkdownTextScaleOverride(scale)
        guard state.windows[windowIndex].markdownTextScaleOverride != normalizedOverride else {
            return false
        }
        state.windows[windowIndex].markdownTextScaleOverride = normalizedOverride
        return true
    }

    private static func adjustWindowMarkdownTextScale(
        windowID: UUID,
        step: Double,
        state: inout AppState
    ) -> Bool {
        guard state.window(id: windowID) != nil else { return false }
        let previousScale = state.effectiveMarkdownTextScale(for: windowID)
        let nextScale = AppState.clampedMarkdownTextScale(previousScale + step)
        guard abs(nextScale - previousScale) >= AppState.markdownTextScaleComparisonEpsilon else {
            return false
        }
        let normalizedOverride = AppState.normalizedMarkdownTextScaleOverride(nextScale)
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
        guard state.windows[windowIndex].markdownTextScaleOverride != normalizedOverride else {
            return false
        }
        state.windows[windowIndex].markdownTextScaleOverride = normalizedOverride
        return true
    }

    private enum BrowserPageZoomAdjustmentDirection {
        case increase
        case decrease
    }

    private static func setBrowserPanelPageZoom(
        panelID: UUID,
        zoom: Double,
        state: inout AppState
    ) -> Bool {
        mutateBrowserPanelState(panelID: panelID, state: &state) { webState in
            let normalizedZoom = WebPanelState.normalizedBrowserPageZoom(zoom)
            guard webState.browserPageZoom != normalizedZoom else {
                return false
            }
            webState.browserPageZoom = normalizedZoom
            return true
        }
    }

    private static func adjustBrowserPanelPageZoom(
        panelID: UUID,
        direction: BrowserPageZoomAdjustmentDirection,
        state: inout AppState
    ) -> Bool {
        mutateBrowserPanelState(panelID: panelID, state: &state) { webState in
            let currentZoom = webState.effectiveBrowserPageZoom
            let nextZoom: Double
            switch direction {
            case .increase:
                nextZoom = WebPanelState.increasedBrowserPageZoom(from: currentZoom)
            case .decrease:
                nextZoom = WebPanelState.decreasedBrowserPageZoom(from: currentZoom)
            }

            let normalizedZoom = WebPanelState.normalizedBrowserPageZoom(nextZoom)
            guard webState.browserPageZoom != normalizedZoom else {
                return false
            }
            webState.browserPageZoom = normalizedZoom
            return true
        }
    }

    private static func mutateBrowserPanelState(
        panelID: UUID,
        state: inout AppState,
        mutation: (inout WebPanelState) -> Bool
    ) -> Bool {
        if let location = locateRightAuxPanel(panelID, in: state) {
            guard var workspace = state.workspacesByID[location.workspaceID],
                  var mainTab = workspace.tab(id: location.mainTabID),
                  var rightAuxTab = mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID],
                  case .web(var webState) = rightAuxTab.panelState,
                  webState.definition == .browser else {
                return false
            }

            guard mutation(&webState) else {
                return false
            }

            rightAuxTab.panelState = .web(webState)
            mainTab.rightAuxPanel.tabsByID[location.rightAuxTabID] = rightAuxTab
            workspace.tabsByID[location.mainTabID] = mainTab
            commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
            return true
        }

        guard let location = locatePanel(panelID, in: state) else { return false }
        guard var workspace = state.workspacesByID[location.workspaceID] else { return false }
        guard let tabID = workspace.tabID(containingPanelID: panelID),
              case .web(var webState) = workspace.tab(id: tabID)?.panels[panelID],
              webState.definition == .browser else {
            return false
        }

        guard mutation(&webState) else {
            return false
        }

        _ = workspace.updateTab(id: tabID) { tab in
            tab.panels[panelID] = .web(webState)
        }
        commitWorkspace(workspace, workspaceID: location.workspaceID, state: &state)
        return true
    }

    private static func updateWebPanelState(
        _ webState: inout WebPanelState,
        title: String?,
        url: String?
    ) -> Bool {
        var didMutate = false

        let resolvedTitle = WebPanelState.resolvedTitle(
            definition: webState.definition,
            title: title
        )
        if webState.title != resolvedTitle {
            webState.title = resolvedTitle
            didMutate = true
        }

        let normalizedCurrentURL = WebPanelState.normalizedCurrentURL(url)
        if webState.currentURL != normalizedCurrentURL {
            webState.currentURL = normalizedCurrentURL
            didMutate = true
        }

        return didMutate
    }

    private static func updateScratchpadWebPanelState(
        _ webState: inout WebPanelState,
        scratchpad: ScratchpadState,
        title: String?
    ) -> Bool {
        var didMutate = false

        if webState.scratchpad != scratchpad {
            webState.scratchpad = scratchpad
            didMutate = true
        }

        if let normalizedTitle = WebPanelState.normalizedTitle(title),
           webState.title != normalizedTitle {
            webState.title = normalizedTitle
            didMutate = true
        }

        return didMutate
    }

    @discardableResult
    private static func splitFocusedSlot(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        profileBinding: TerminalProfileBinding? = nil,
        workingDirectory: String? = nil,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard let focusResolution = workspace.synchronizeFocusedPanelToLayout() else {
            return false
        }

        let inheritedCWD: String
        if let workingDirectory {
            guard let normalizedWorkingDirectory = normalizedWorkingDirectoryValue(workingDirectory) else {
                return false
            }
            inheritedCWD = normalizedWorkingDirectory
        } else if case .terminal(let focusedTerminalState) = workspace.panels[focusResolution.panelID] {
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
        workspace.rightAuxPanel.focusedPanelID = nil
        workspace.selectedPanelIDs.removeAll()
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true

    }

    private static func normalizedWorkingDirectoryValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalizedPath = (trimmed as NSString).standardizingPath
        guard normalizedPath.isEmpty == false else { return nil }
        return normalizedPath
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

        let rightAuxPanelID = focusableRightAuxPanelID(in: workspace)
        let rightAuxPanelIsFocused = rightAuxPanelID != nil &&
            workspace.rightAuxPanel.focusedPanelID == rightAuxPanelID

        switch direction {
        case .previous, .next:
            let targets = focusGraphTargets(in: workspace, rightAuxPanelID: rightAuxPanelID)
            guard targets.count > 1 else { return false }

            let currentTarget: FocusGraphTarget
            if rightAuxPanelIsFocused, let rightAuxPanelID {
                currentTarget = .rightAuxPanel(rightAuxPanelID)
            } else {
                currentTarget = .mainPanel(focusResolution.panelID)
            }

            guard let currentIndex = targets.firstIndex(of: currentTarget) else {
                return false
            }

            let targetIndex: Int
            switch direction {
            case .previous:
                targetIndex = (currentIndex - 1 + targets.count) % targets.count
            case .next:
                targetIndex = (currentIndex + 1) % targets.count
            case .up, .down, .left, .right:
                return false
            }
            return focus(
                targets[targetIndex],
                workspaceID: workspaceID,
                workspace: &workspace,
                state: &state
            )

        case .left where rightAuxPanelIsFocused:
            return focus(
                .mainPanel(focusResolution.panelID),
                workspaceID: workspaceID,
                workspace: &workspace,
                state: &state
            )

        case .up where rightAuxPanelIsFocused,
            .down where rightAuxPanelIsFocused,
            .right where rightAuxPanelIsFocused:
            return false

        case .up, .down, .left, .right:
            if let targetSlotID = workspace.focusTargetSlotIDWithinVisibleRoot(
                from: focusResolution.slot.slotID,
                direction: direction
            ) {
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
                workspace.rightAuxPanel.focusedPanelID = nil
                workspace.selectedPanelIDs.removeAll()
                _ = workspace.unreadPanelIDs.remove(targetPanelID)
                workspace.unreadWorkspaceNotificationCount = 0
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                return true
            }

            guard direction == .right,
                  let rightAuxPanelID else {
                return false
            }
            return focus(
                .rightAuxPanel(rightAuxPanelID),
                workspaceID: workspaceID,
                workspace: &workspace,
                state: &state
            )
        }
    }

    private static func focusableRightAuxPanelID(in workspace: WorkspaceState) -> UUID? {
        guard workspace.focusedPanelModeActive == false,
              workspace.rightAuxPanel.isVisible,
              let activePanelID = workspace.rightAuxPanel.activePanelID else {
            return nil
        }
        return activePanelID
    }

    private static func focusGraphTargets(
        in workspace: WorkspaceState,
        rightAuxPanelID: UUID?
    ) -> [FocusGraphTarget] {
        let visibleRoot = workspace.focusModeSubtree?.root ?? workspace.layoutTree
        var targets = visibleRoot.allSlotInfos.compactMap { slot -> FocusGraphTarget? in
            guard workspace.panels[slot.panelID] != nil else {
                return nil
            }
            return .mainPanel(slot.panelID)
        }

        if let rightAuxPanelID,
           targets.contains(.rightAuxPanel(rightAuxPanelID)) == false {
            targets.append(.rightAuxPanel(rightAuxPanelID))
        }

        return targets
    }

    @discardableResult
    private static func focus(
        _ target: FocusGraphTarget,
        workspaceID: UUID,
        workspace: inout WorkspaceState,
        state: inout AppState
    ) -> Bool {
        switch target {
        case .mainPanel(let targetPanelID):
            guard targetPanelID != workspace.focusedPanelID ||
                workspace.rightAuxPanel.focusedPanelID != nil else {
                return false
            }
            guard workspace.panels[targetPanelID] != nil,
                  workspace.layoutTree.slotContaining(panelID: targetPanelID) != nil else {
                return false
            }

            workspace.focusedPanelID = targetPanelID
            workspace.rightAuxPanel.focusedPanelID = nil
            workspace.selectedPanelIDs.removeAll()
            _ = workspace.unreadPanelIDs.remove(targetPanelID)
            workspace.unreadWorkspaceNotificationCount = 0

        case .rightAuxPanel(let targetPanelID):
            guard focusableRightAuxPanelID(in: workspace) == targetPanelID else {
                return false
            }
            guard workspace.rightAuxPanel.focusedPanelID != targetPanelID else {
                return false
            }

            workspace.rightAuxPanel.focusedPanelID = targetPanelID
            workspace.selectedPanelIDs.removeAll()
            _ = workspace.unreadPanelIDs.remove(targetPanelID)
            workspace.unreadWorkspaceNotificationCount = 0
        }

        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true
    }

    @discardableResult
    private static func selectAdjacentRightAuxPanelTab(
        workspaceID: UUID,
        direction: PanelTabNavigationDirection,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID],
              let selectedTabID = workspace.resolvedSelectedTabID,
              var selectedTab = workspace.tab(id: selectedTabID) else {
            return false
        }

        let rightAuxTabIDs = selectedTab.rightAuxPanel.tabIDs
        guard selectedTab.rightAuxPanel.isVisible,
              rightAuxTabIDs.count > 1,
              let activeTabID = selectedTab.rightAuxPanel.activeTabID,
              let activeIndex = rightAuxTabIDs.firstIndex(of: activeTabID) else {
            return false
        }

        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = (activeIndex - 1 + rightAuxTabIDs.count) % rightAuxTabIDs.count
        case .next:
            targetIndex = (activeIndex + 1) % rightAuxTabIDs.count
        }

        let targetTabID = rightAuxTabIDs[targetIndex]
        guard let targetTab = selectedTab.rightAuxPanel.tabsByID[targetTabID] else {
            return false
        }

        selectedTab.rightAuxPanel.activeTabID = targetTabID
        selectedTab.rightAuxPanel.focusedPanelID = targetTab.panelID
        selectedTab.unreadPanelIDs.remove(targetTab.panelID)
        workspace.unreadWorkspaceNotificationCount = 0
        workspace.tabsByID[selectedTabID] = selectedTab
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true
    }

    private static func markWorkspaceScopedNotificationsRead(workspaceID: UUID, state: inout AppState) {
        guard var workspace = state.workspacesByID[workspaceID] else { return }
        guard workspace.unreadWorkspaceNotificationCount > 0 else { return }
        workspace.unreadWorkspaceNotificationCount = 0
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
    }

    private static func markWorkspaceVisited(workspaceID: UUID, state: inout AppState) {
        guard var workspace = state.workspacesByID[workspaceID],
              workspace.hasBeenVisited == false else {
            return
        }
        workspace.hasBeenVisited = true
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
    }

    private static func markSelectedWorkspaceVisited(windowID: UUID, state: inout AppState) {
        guard let workspaceID = state.selectedWorkspaceID(in: windowID) else { return }
        markWorkspaceVisited(workspaceID: workspaceID, state: &state)
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

        let splitTree = WorkspaceSplitTree(root: workspace.layoutTree)
        let rightAuxPanelOwnsResize = workspace.focusedPanelModeActive == false &&
            workspace.rightAuxPanel.isVisible &&
            workspace.rightAuxPanel.focusedPanelID != nil
        let focusedSlotTouchesRightPanelBoundary =
            rightAuxPanelResizeDirection(direction) &&
            workspace.focusedPanelModeActive == false &&
            workspace.rightAuxPanel.isVisible &&
            splitTree.slotTouchesRightEdge(slotID: focusResolution.slot.slotID)

        if rightAuxPanelOwnsResize || focusedSlotTouchesRightPanelBoundary {
            guard resizeRightAuxPanel(workspace: &workspace, direction: direction, amount: amount) else {
                ToasttyLog.debug(
                    "Resize right panel rejected",
                    category: .reducer,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "direction": direction.rawValue,
                        "amount": String(amount),
                    ]
                )
                return false
            }

            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            ToasttyLog.debug(
                "Resize right panel applied",
                category: .reducer,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "direction": direction.rawValue,
                    "amount": String(amount),
                    "width": String(workspace.rightAuxPanel.width),
                ]
            )
            return true
        }

        let updatedLayoutTree: LayoutNode
        if workspace.focusedPanelModeActive {
            guard let rootNodeID = workspace.effectiveFocusModeRootNodeID,
                  let focusModeSubtree = splitTree.focusedSubtree(rootNodeID: rootNodeID),
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
        } else if let updatedSplitTree = splitTree.resized(
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

    private static func resizeRightAuxPanel(
        workspace: inout WorkspaceState,
        direction: SplitResizeDirection,
        amount: Int
    ) -> Bool {
        guard rightAuxPanelResizeDirection(direction),
              workspace.focusedPanelModeActive == false,
              workspace.rightAuxPanel.isVisible else {
            return false
        }

        let nextWidth = RightAuxPanelState.clampedWidth(
            workspace.rightAuxPanel.width + rightAuxPanelResizeDelta(direction: direction, amount: amount)
        )
        guard abs(nextWidth - workspace.rightAuxPanel.width) > 0.0001 else {
            return false
        }

        workspace.rightAuxPanel.width = nextWidth
        workspace.rightAuxPanel.hasCustomWidth = true
        return true
    }

    private static func rightAuxPanelResizeDirection(_ direction: SplitResizeDirection) -> Bool {
        switch direction {
        case .left, .right:
            return true
        case .up, .down:
            return false
        }
    }

    private static func rightAuxPanelResizeDelta(direction: SplitResizeDirection, amount: Int) -> Double {
        let clampedAmount = max(1, min(amount, 60))
        // Keep the keyboard step close to split resizing's 0.5%-per-amount feel
        // for a typical 1000 pt workspace while remaining deterministic in state.
        let magnitude = Double(clampedAmount) * 5
        switch direction {
        case .left:
            return magnitude
        case .right:
            return -magnitude
        case .up, .down:
            return 0
        }
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

    private static func locateRightAuxPanel(_ panelID: UUID, in state: AppState) -> RightAuxPanelLocation? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID),
              let location = selection.workspace.rightAuxPanelTabLocation(containingPanelID: panelID) else {
            return nil
        }

        return RightAuxPanelLocation(
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            mainTabID: location.mainTabID,
            rightAuxTabID: location.rightAuxTabID
        )
    }

    @discardableResult
    private static func closeRightAuxPanelTab(
        workspaceID: UUID,
        mainTabID: UUID? = nil,
        rightAuxTabID: UUID,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else {
            return false
        }

        let targetMainTabID = mainTabID ??
            workspace.rightAuxPanelTabLocation(containingRightAuxTabID: rightAuxTabID)?.mainTabID
        guard let targetMainTabID,
              var targetMainTab = workspace.tab(id: targetMainTabID),
              targetMainTab.rightAuxPanel.tabsByID[rightAuxTabID] != nil else {
            return false
        }

        let removedTab = targetMainTab.rightAuxPanel.removeTab(id: rightAuxTabID)
        if let removedPanelID = removedTab?.panelID {
            targetMainTab.unreadPanelIDs.remove(removedPanelID)
        }
        workspace.tabsByID[targetMainTabID] = targetMainTab
        commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
        return true
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
        markSelectedWorkspaceVisited(windowID: window.id, state: &state)
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
        guard let removedTab = workspace.removeTab(id: tabID) else { return false }

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

        if removedTab.recentlyClosedPanels.isEmpty == false,
           let destinationTabID = workspace.resolvedSelectedTabID {
            _ = workspace.updateTab(id: destinationTabID) { tab in
                tab.recentlyClosedPanels = mergeClosedPanelHistory(
                    tab.recentlyClosedPanels,
                    with: removedTab.recentlyClosedPanels
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

    private static func mergeClosedPanelHistory(
        _ existing: [ClosedPanelRecord],
        with incoming: [ClosedPanelRecord]
    ) -> [ClosedPanelRecord] {
        var merged = existing + incoming
        merged.sort { $0.closedAt < $1.closedAt }
        if merged.count > 10 {
            merged.removeFirst(merged.count - 10)
        }
        return merged
    }

    @discardableResult
    private static func moveElement<T>(
        in values: inout [T],
        fromIndex: Int,
        toIndex: Int
    ) -> Bool {
        guard values.indices.contains(fromIndex) else { return false }
        guard values.indices.contains(toIndex) else { return false }
        guard fromIndex != toIndex else { return false }

        let movedValue = values.remove(at: fromIndex)
        values.insert(movedValue, at: toIndex)
        return true
    }

    private static func reopenedTabInsertionIndex(
        for closedRecord: ClosedPanelRecord,
        in workspace: WorkspaceState
    ) -> Int {
        if let successorID = closedRecord.sourceTabSuccessorID,
           let successorIndex = workspace.tabIDs.firstIndex(of: successorID) {
            return successorIndex
        }

        if let predecessorID = closedRecord.sourceTabPredecessorID,
           let predecessorIndex = workspace.tabIDs.firstIndex(of: predecessorID) {
            return predecessorIndex + 1
        }

        if let sourceTabIndex = closedRecord.sourceTabIndex {
            return min(max(0, sourceTabIndex), workspace.tabIDs.count)
        }

        return workspace.tabIDs.count
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

    private static func createWebPanel(
        workspaceID: UUID,
        panel: WebPanelState,
        placement: WebPanelPlacement,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }

        switch placement {
        case .rightPanel:
            let panelID = UUID()
            let identity = RightAuxPanelTabIdentity.identity(for: panel, panelID: panelID)
            if let existingTabID = workspace.rightAuxPanel.tabID(matching: identity),
               var existingTab = workspace.rightAuxPanel.tabsByID[existingTabID] {
                existingTab.panelState = .web(panel)
                workspace.rightAuxPanel.tabsByID[existingTabID] = existingTab
                workspace.rightAuxPanel.activeTabID = existingTabID
                workspace.rightAuxPanel.isVisible = true
                workspace.rightAuxPanel.focusActiveTab()
                commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
                return true
            }

            let tab = RightAuxPanelTabState(
                id: UUID(),
                identity: identity,
                panelID: panelID,
                panelState: .web(panel)
            )
            workspace.rightAuxPanel.appendTab(tab)
            workspace.rightAuxPanel.focusActiveTab()
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .newTab:
            let panelID = UUID()
            let tab = WorkspaceTabState(
                id: UUID(),
                layoutTree: .slot(slotID: UUID(), panelID: panelID),
                panels: [panelID: .web(panel)],
                focusedPanelID: panelID
            )
            workspace.appendTab(tab, select: true)
            workspace.rightAuxPanel.focusedPanelID = nil
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true

        case .splitRight:
            guard let focusResolution = workspace.synchronizeFocusedPanelToLayout() else {
                return false
            }

            let panelID = UUID()
            let newSlotID = UUID()
            let trackedRootNodeID = workspace.effectiveFocusModeRootNodeID
            workspace.panels[panelID] = .web(panel)

            guard let splitResult = WorkspaceSplitTree(root: workspace.layoutTree).splitting(
                slotID: focusResolution.slot.slotID,
                direction: .right,
                newPanelID: panelID,
                newSlotID: newSlotID
            ) else {
                workspace.panels.removeValue(forKey: panelID)
                return false
            }

            workspace.apply(splitTree: splitResult.tree)
            if workspace.focusedPanelModeActive,
               trackedRootNodeID == focusResolution.slot.slotID {
                workspace.focusModeRootNodeID = splitResult.newSplitNodeID
            }
            workspace.focusedPanelID = panelID
            workspace.rightAuxPanel.focusedPanelID = nil
            workspace.selectedPanelIDs.removeAll()
            commitWorkspace(workspace, workspaceID: workspaceID, state: &state)
            return true
        }
    }
}

private struct PanelLocation {
    let windowID: UUID
    let workspaceID: UUID
    let tabID: UUID
    let slotID: UUID
}

private struct RightAuxPanelLocation {
    let windowID: UUID
    let workspaceID: UUID
    let mainTabID: UUID
    let rightAuxTabID: UUID
}

private struct SlotLocation {
    let workspaceID: UUID
    let tabID: UUID
}
