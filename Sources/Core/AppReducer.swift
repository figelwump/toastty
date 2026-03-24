import Foundation

public struct AppReducer {
    private enum EmptyWorkspaceTabDisposition {
        case bootstrapReplacementTab
        case removeWorkspace
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
            workspace.selectedTabID = tabID
            state.workspacesByID[workspaceID] = workspace
            return true

        case .createWorkspace(let windowID, let title):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }

            let resolvedTitle = title ?? nextWorkspaceTitle(in: state.windows[windowIndex], state: state)
            let workspace = WorkspaceState.bootstrap(
                title: resolvedTitle,
                initialTerminalProfileBinding: state.defaultTerminalProfileBinding
            )

            state.workspacesByID[workspace.id] = workspace
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
            state.workspacesByID[workspaceID] = workspace
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
                selectedWorkspaceID: workspace.id
            )

            state.workspacesByID[workspace.id] = workspace
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
            state.workspacesByID[workspaceID] = workspace
            return true

        case .closeWorkspace(let workspaceID):
            guard let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) else { return false }
            return removeWorkspace(workspaceID, windowID: windowID, state: &state)

        case .closeWorkspaceTab(let workspaceID, let tabID):
            guard let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) else { return false }
            return removeWorkspaceTab(tabID, workspaceID: workspaceID, windowID: windowID, state: &state)

        case .focusPanel(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
            workspace.selectedTabID = tabID
            workspace.focusedPanelID = panelID
            _ = workspace.unreadPanelIDs.remove(panelID)
            workspace.unreadWorkspaceNotificationCount = 0
            state.workspacesByID[workspaceID] = workspace
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
            state.workspacesByID[sourceLocation.workspaceID] = workspace
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
                state.workspacesByID[sourceLocation.workspaceID] = sourceWorkspace
                guard removeWorkspaceTab(
                    sourceLocation.tabID,
                    workspaceID: sourceLocation.workspaceID,
                    windowID: sourceLocation.windowID,
                    emptyWorkspaceDisposition: .removeWorkspace,
                    state: &state
                ) else {
                    return false
                }
            } else {
                state.workspacesByID[sourceLocation.workspaceID] = sourceWorkspace
            }
            state.workspacesByID[targetWorkspaceID] = targetWorkspace
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
                state.workspacesByID[sourceLocation.workspaceID] = sourceWorkspace
            } else {
                state.workspacesByID[sourceLocation.workspaceID] = sourceWorkspace
                removeWorkspaceTab(
                    sourceLocation.tabID,
                    workspaceID: sourceLocation.workspaceID,
                    windowID: sourceLocation.windowID,
                    emptyWorkspaceDisposition: .removeWorkspace,
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
                selectedWorkspaceID: detachedWorkspaceID
            )

            state.workspacesByID[detachedWorkspaceID] = detachedWorkspace
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
                ? workspace.focusTargetSlotID(from: sourceLocation.slotID, direction: .previous)
                : nil

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

            let removal = workspace.layoutTree.removingPanel(panelID)
            guard removal.removed else { return false }

            workspace.panels.removeValue(forKey: panelID)
            workspace.unreadPanelIDs.remove(panelID)
            workspace.auxPanelVisibility.remove(panelState.kind)

            if let updatedTree = removal.node {
                workspace.layoutTree = updatedTree
                workspace.focusedPanelID = workspace.focusedPanelIDAfterClosing(
                    closedPanelID: panelID,
                    closedPanelWasFocused: wasFocusedPanel,
                    previousSlotIDBeforeRemoval: previousSlotIDBeforeRemoval
                )
                state.workspacesByID[sourceLocation.workspaceID] = workspace
            } else {
                state.workspacesByID[sourceLocation.workspaceID] = workspace
                removeWorkspaceTab(
                    sourceLocation.tabID,
                    workspaceID: sourceLocation.workspaceID,
                    windowID: sourceLocation.windowID,
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
                state.workspacesByID[workspaceID] = workspace
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

            state.workspacesByID[workspaceID] = workspace
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
                    state.workspacesByID[workspaceID] = workspace
                } else if let windowID = locateWindowID(containingWorkspaceID: workspaceID, in: state) {
                    guard let selectedTabID else { return false }
                    state.workspacesByID[workspaceID] = workspace
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
            state.workspacesByID[workspaceID] = workspace
            return true

        case .toggleFocusedPanelMode(let workspaceID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard workspace.synchronizeFocusedPanelToLayout() != nil else {
                return false
            }
            workspace.focusedPanelModeActive.toggle()
            state.workspacesByID[workspaceID] = workspace
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
            state.workspacesByID[workspaceID] = workspace
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
            state.workspacesByID[location.workspaceID] = workspace
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
            state.workspacesByID[workspaceID] = workspace
            return true

        case .markPanelNotificationsRead(let workspaceID, let panelID):
            guard var workspace = state.workspacesByID[workspaceID] else { return false }
            guard let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
            let didMutate = workspace.updateTab(id: tabID) { tab in
                _ = tab.unreadPanelIDs.remove(panelID)
            }
            if didMutate {
                state.workspacesByID[workspaceID] = workspace
            }
            return true

        case .toggleSidebar(let windowID):
            guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else { return false }
            state.windows[windowIndex].sidebarVisible.toggle()
            return true
        }
    }

    @discardableResult
    private static func splitFocusedSlot(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        profileBinding: TerminalProfileBinding? = nil,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard workspace.focusedPanelModeActive == false else { return false }
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

        guard let updatedSplitTree = WorkspaceSplitTree(root: workspace.layoutTree).splitting(
            slotID: focusResolution.slot.slotID,
            direction: direction,
            newPanelID: newPanelID,
            newSlotID: newSlotID
        ) else {
            return false
        }

        workspace.apply(splitTree: updatedSplitTree)
        workspace.focusedPanelID = newPanelID
        state.workspacesByID[workspaceID] = workspace
        return true

    }

    @discardableResult
    private static func focusSlot(
        workspaceID: UUID,
        direction: SlotFocusDirection,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard workspace.focusedPanelModeActive == false else { return false }
        guard let focusResolution = workspace.synchronizeFocusedPanelToLayout() else {
            return false
        }

        guard let targetSlotID = workspace.focusTargetSlotID(from: focusResolution.slot.slotID, direction: direction) else {
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
        guard workspace.focusedPanelModeActive == false else {
            ToasttyLog.debug(
                "Resize split rejected: focused panel mode active",
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

        guard let updatedSplitTree = WorkspaceSplitTree(root: workspace.layoutTree).resized(
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

        workspace.apply(splitTree: updatedSplitTree)
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

    private static func equalizeLayoutSplits(workspaceID: UUID, state: inout AppState) -> Bool {
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

        guard let updatedSplitTree = WorkspaceSplitTree(root: workspace.layoutTree).equalized() else {
            ToasttyLog.debug(
                "Equalize splits rejected: tree already equalized",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        workspace.apply(splitTree: updatedSplitTree)
        state.workspacesByID[workspaceID] = workspace
        ToasttyLog.debug(
            "Equalized layout splits",
            category: .reducer,
            metadata: ["workspace_id": workspaceID.uuidString]
        )
        return true
    }

    private static func locatePanel(_ panelID: UUID, in state: AppState) -> PanelLocation? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard let tabID = workspace.tabID(containingPanelID: panelID),
                      let sourceSlot = workspace.tab(id: tabID)?.layoutTree.slotContaining(panelID: panelID) else {
                    continue
                }

                return PanelLocation(
                    windowID: window.id,
                    workspaceID: workspaceID,
                    tabID: tabID,
                    slotID: sourceSlot.slotID
                )
            }
        }

        return nil
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
            case .removeWorkspace:
                return removeWorkspace(workspaceID, windowID: windowID, state: &state)
            }
        }

        state.workspacesByID[workspaceID] = workspace
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
