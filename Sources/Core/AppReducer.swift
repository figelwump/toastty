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

        case .movePanelToSlot(let panelID, let targetSlotID):
            guard let sourceLocation = locatePanel(panelID, in: state) else { return false }
            guard let targetWorkspaceID = locateWorkspaceID(containingSlotID: targetSlotID, in: state) else { return false }
            guard sourceLocation.workspaceID == targetWorkspaceID else { return false }
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
            guard let panelState = sourceWorkspace.panels[panelID] else { return false }

            if sourceLocation.workspaceID == targetWorkspaceID {
                guard let slotDestination = targetSlotID else { return false }
                return reduce(
                    action: .movePanelToSlot(panelID: panelID, targetSlotID: slotDestination),
                    state: &state
                )
            }

            guard let insertionSlotID = resolveInsertionSlotID(in: targetWorkspace, preferredSlotID: targetSlotID) else {
                return false
            }

            let sourceRemoval = sourceWorkspace.layoutTree.removingPanel(panelID)
            guard sourceRemoval.removed else { return false }

            var updatedSourceWorkspace: WorkspaceState?
            let didTransferUnreadBadge = sourceWorkspace.unreadPanelIDs.remove(panelID) != nil
            sourceWorkspace.panels.removeValue(forKey: panelID)
            if let updatedSourceTree = sourceRemoval.node {
                sourceWorkspace.layoutTree = updatedSourceTree
                sourceWorkspace.focusedPanelID = resolveFocusedPanel(in: sourceWorkspace)?.panelID
                updatedSourceWorkspace = sourceWorkspace
            } else {
                updatedSourceWorkspace = nil
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

            let sourceRemoval = sourceWorkspace.layoutTree.removingPanel(panelID)
            guard sourceRemoval.removed else { return false }

            let didTransferUnreadBadge = sourceWorkspace.unreadPanelIDs.remove(panelID) != nil
            sourceWorkspace.panels.removeValue(forKey: panelID)
            if let updatedSourceTree = sourceRemoval.node {
                sourceWorkspace.layoutTree = updatedSourceTree
                sourceWorkspace.focusedPanelID = resolveFocusedPanel(in: sourceWorkspace)?.panelID
                state.workspacesByID[sourceLocation.workspaceID] = sourceWorkspace
            } else {
                removeWorkspace(sourceLocation.workspaceID, windowID: sourceLocation.windowID, state: &state)
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
            guard let panelState = workspace.panels[panelID] else { return false }
            let wasFocusedPanel = workspace.focusedPanelID == panelID
            let previousSlotIDBeforeRemoval = wasFocusedPanel
                ? targetSlotID(from: sourceLocation.slotID, direction: .previous, layoutTree: workspace.layoutTree)
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
                workspace.focusedPanelID = resolveFocusedPanelAfterClose(
                    in: workspace,
                    closedPanelID: panelID,
                    closedPanelWasFocused: wasFocusedPanel,
                    sourceSlotID: sourceLocation.slotID,
                    previousSlotIDBeforeRemoval: previousSlotIDBeforeRemoval
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

            guard let targetSlotID = resolveReopenSlotID(
                in: workspace,
                preferredSlotID: closedRecord.sourceSlotID
            ) else {
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

            if let existingPanelID = workspace.panels.first(where: { $0.value.kind == kind })?.key {
                let removal = workspace.layoutTree.removingPanel(existingPanelID)
                guard removal.removed else { return false }

                workspace.panels.removeValue(forKey: existingPanelID)
                workspace.unreadPanelIDs.remove(existingPanelID)
                workspace.auxPanelVisibility.remove(kind)

                if let updatedTree = removal.node {
                    workspace.layoutTree = updatedTree
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
                guard let auxColumnSlotID = resolveAuxColumnSlotID(in: workspace, auxPanelIDs: existingAuxPanelIDs) else {
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

        case .splitFocusedSlot(let workspaceID, let orientation):
            let direction: SlotSplitDirection = orientation == .horizontal ? .right : .down
            return splitFocusedSlot(workspaceID: workspaceID, direction: direction, state: &state)

        case .splitFocusedSlotInDirection(let workspaceID, let direction):
            return splitFocusedSlot(workspaceID: workspaceID, direction: direction, state: &state)

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
                    cwd: NSHomeDirectory()
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
    private static func splitFocusedSlot(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        state: inout AppState
    ) -> Bool {
        guard var workspace = state.workspacesByID[workspaceID] else { return false }
        guard workspace.focusedPanelModeActive == false else { return false }
        guard let focusResolution = resolveFocusedPanel(in: workspace) else {
            return false
        }
        workspace.focusedPanelID = focusResolution.panelID

        let sourceLeaf = focusResolution.slot
        let inheritedCWD: String
        if case .terminal(let focusedTerminalState) = workspace.panels[focusResolution.panelID] {
            inheritedCWD = focusedTerminalState.cwd
        } else {
            inheritedCWD = NSHomeDirectory()
        }

        let newPanelID = UUID()
        let newSlotID = UUID()

        workspace.panels[newPanelID] = .terminal(
            TerminalPanelState(
                title: nextTerminalTitle(in: workspace),
                shell: "zsh",
                cwd: inheritedCWD
            )
        )

        let newLeaf = LayoutNode.slot(slotID: newSlotID, panelID: newPanelID)
        let originalLeaf = LayoutNode.slot(
            slotID: sourceLeaf.slotID,
            panelID: sourceLeaf.panelID
        )

        let orientation: SplitOrientation = switch direction {
        case .left, .right:
            .horizontal
        case .up, .down:
            .vertical
        }

        let firstNode: LayoutNode
        let secondNode: LayoutNode
        switch direction {
        case .right, .down:
            firstNode = originalLeaf
            secondNode = newLeaf
        case .left, .up:
            firstNode = newLeaf
            secondNode = originalLeaf
        }

        let split = LayoutNode.split(
            nodeID: UUID(),
            orientation: orientation,
            ratio: 0.5,
            first: firstNode,
            second: secondNode
        )

        guard workspace.layoutTree.replaceSlot(slotID: sourceLeaf.slotID, with: split) else {
            return false
        }

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
        guard let focusResolution = resolveFocusedPanel(in: workspace) else {
            return false
        }

        let sourceSlotID = focusResolution.slot.slotID
        guard let targetSlotID = targetSlotID(
            from: sourceSlotID,
            direction: direction,
            layoutTree: workspace.layoutTree
        ) else {
            return false
        }
        guard targetSlotID != sourceSlotID else {
            return false
        }
        guard let targetLeaf = workspace.layoutTree.slotNode(slotID: targetSlotID) else {
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
            in: workspace.layoutTree,
            focusedSlotID: focusResolution.slot.slotID,
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

        workspace.layoutTree = result.node
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

        let result = equalizeSplitRatios(in: workspace.layoutTree)
        guard result.didMutate else {
            ToasttyLog.debug(
                "Equalize splits rejected: tree already equalized",
                category: .reducer,
                metadata: ["workspace_id": workspaceID.uuidString]
            )
            return false
        }

        workspace.layoutTree = result.node
        state.workspacesByID[workspaceID] = workspace
        ToasttyLog.debug(
            "Equalized layout splits",
            category: .reducer,
            metadata: ["workspace_id": workspaceID.uuidString]
        )
        return true
    }

    private struct SplitResizeResult {
        let node: LayoutNode
        let containsFocusedSlot: Bool
        let didResize: Bool
    }

    private struct SplitEqualizeResult {
        let node: LayoutNode
        let didMutate: Bool
    }

    // Suppresses floating-point noise near clamp bounds; this must stay well below the
    // minimum intentional resize step (0.005) so real resizes always apply.
    private static let splitRatioChangeEpsilon: Double = 0.0001

    private static func splitResizeDelta(direction: SplitResizeDirection, amount: Int) -> Double {
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
        in node: LayoutNode,
        focusedSlotID: UUID,
        direction: SplitResizeDirection,
        delta: Double
    ) -> SplitResizeResult {
        switch node {
        case .slot(let slotID, _):
            return SplitResizeResult(node: node, containsFocusedSlot: slotID == focusedSlotID, didResize: false)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = resizeNearestMatchingSplit(
                in: first,
                focusedSlotID: focusedSlotID,
                direction: direction,
                delta: delta
            )
            if firstResult.containsFocusedSlot {
                if firstResult.didResize {
                    return SplitResizeResult(
                        node: .split(
                            nodeID: nodeID,
                            orientation: orientation,
                            ratio: ratio,
                            first: firstResult.node,
                            second: second
                        ),
                        containsFocusedSlot: true,
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
                            containsFocusedSlot: true,
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
                    containsFocusedSlot: true,
                    didResize: false
                )
            }

            let secondResult = resizeNearestMatchingSplit(
                in: second,
                focusedSlotID: focusedSlotID,
                direction: direction,
                delta: delta
            )
            if secondResult.containsFocusedSlot {
                if secondResult.didResize {
                    return SplitResizeResult(
                        node: .split(
                            nodeID: nodeID,
                            orientation: orientation,
                            ratio: ratio,
                            first: first,
                            second: secondResult.node
                        ),
                        containsFocusedSlot: true,
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
                            containsFocusedSlot: true,
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
                    containsFocusedSlot: true,
                    didResize: false
                )
            }

            return SplitResizeResult(node: node, containsFocusedSlot: false, didResize: false)
        }
    }

    private static func equalizeSplitRatios(in node: LayoutNode) -> SplitEqualizeResult {
        switch node {
        case .slot:
            return SplitEqualizeResult(node: node, didMutate: false)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = equalizeSplitRatios(in: first)
            let secondResult = equalizeSplitRatios(in: second)
            let firstWeight = equalizeWeight(in: firstResult.node, orientation: orientation)
            let secondWeight = equalizeWeight(in: secondResult.node, orientation: orientation)
            let totalWeight = firstWeight + secondWeight
            let targetRatio = Double(firstWeight) / Double(totalWeight)
            let didMutate = firstResult.didMutate
                || secondResult.didMutate
                || ratio != targetRatio
            guard didMutate else {
                return SplitEqualizeResult(node: node, didMutate: false)
            }

            return SplitEqualizeResult(
                node: .split(
                    nodeID: nodeID,
                    orientation: orientation,
                    ratio: targetRatio,
                    first: firstResult.node,
                    second: secondResult.node
                ),
                didMutate: didMutate
            )
        }
    }

    /// Match Ghostty equalization semantics:
    /// only descendants with the same split orientation contribute recursive weight.
    /// Opposite-orientation subtrees count as a single unit.
    private static func equalizeWeight(in node: LayoutNode, orientation: SplitOrientation) -> Int {
        switch node {
        case .slot:
            return 1
        case .split(_, let nodeOrientation, _, let first, let second):
            guard nodeOrientation == orientation else { return 1 }
            return equalizeWeight(in: first, orientation: orientation)
                + equalizeWeight(in: second, orientation: orientation)
        }
    }

    private static func splitOrientation(contains direction: SplitResizeDirection, orientation: SplitOrientation) -> Bool {
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

    private static func targetSlotID(
        from sourceSlotID: UUID,
        direction: SlotFocusDirection,
        layoutTree: LayoutNode
    ) -> UUID? {
        let leaves = layoutTree.allSlotInfos
        guard let sourceLeafIndex = leaves.firstIndex(where: { $0.slotID == sourceSlotID }) else {
            return nil
        }

        switch direction {
        case .previous:
            guard leaves.count > 1 else { return nil }
            let previousIndex = (sourceLeafIndex - 1 + leaves.count) % leaves.count
            return leaves[previousIndex].slotID
        case .next:
            guard leaves.count > 1 else { return nil }
            let nextIndex = (sourceLeafIndex + 1) % leaves.count
            return leaves[nextIndex].slotID
        case .up, .down, .left, .right:
            let frames = slotFrames(for: layoutTree)
            guard let sourceFrame = frames.first(where: { $0.slotID == sourceSlotID }) else {
                return nil
            }
            return closestSlotID(to: sourceFrame, direction: direction, frames: frames)
        }
    }

    private static func selectedPanelID(in slotNode: LayoutNode, workspace: WorkspaceState) -> UUID? {
        guard case .slot(_, let panelID) = slotNode else {
            return nil
        }
        guard workspace.panels[panelID] != nil else {
            return nil
        }
        return panelID
    }

    private struct SlotFrame {
        let slotID: UUID
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
        let centerX: Double
        let centerY: Double
    }

    private static func slotFrames(for layoutTree: LayoutNode) -> [SlotFrame] {
        layoutTree.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 1, height: 1),
            dividerThickness: 0
        )
        .slots
        .map { placement in
            let frame = placement.frame
            return SlotFrame(
                slotID: placement.slotID,
                minX: frame.minX,
                minY: frame.minY,
                maxX: frame.maxX,
                maxY: frame.maxY,
                centerX: frame.midX,
                centerY: frame.midY
            )
        }
    }

    private static func closestSlotID(
        to source: SlotFrame,
        direction: SlotFocusDirection,
        frames: [SlotFrame]
    ) -> UUID? {
        let directionalCandidates: [(frame: SlotFrame, primaryDistance: Double, secondaryDistance: Double)] = frames.compactMap { candidate in
            guard candidate.slotID != source.slotID else {
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
            return lhs.frame.slotID.uuidString < rhs.frame.slotID.uuidString
        }
        return sorted.first?.frame.slotID
    }

    private static func resolveFocusedPanel(in workspace: WorkspaceState) -> (panelID: UUID, slot: SlotInfo)? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panels[focusedPanelID] != nil,
           let focusedSlot = workspace.layoutTree.slotContaining(panelID: focusedPanelID) {
            return (focusedPanelID, focusedSlot)
        }

        for slot in workspace.layoutTree.allSlotInfos {
            if workspace.panels[slot.panelID] != nil {
                return (slot.panelID, slot)
            }
        }

        return nil
    }

    private static func resolveFocusedPanelAfterClose(
        in workspace: WorkspaceState,
        closedPanelID: UUID,
        closedPanelWasFocused: Bool,
        sourceSlotID: UUID,
        previousSlotIDBeforeRemoval: UUID?
    ) -> UUID? {
        guard closedPanelWasFocused else {
            return resolveFocusedPanel(in: workspace)?.panelID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           focusedPanelID != closedPanelID,
           workspace.panels[focusedPanelID] != nil,
           workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        if let previousSlotIDBeforeRemoval,
           let previousSlot = workspace.layoutTree.slotNode(slotID: previousSlotIDBeforeRemoval),
           let selectedPreviousPanelID = selectedPanelID(in: previousSlot, workspace: workspace) {
            return selectedPreviousPanelID
        }

        return resolveFocusedPanel(in: workspace)?.panelID
    }

    private static func locatePanel(_ panelID: UUID, in state: AppState) -> PanelLocation? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                guard let sourceSlot = workspace.layoutTree.slotContaining(panelID: panelID) else { continue }

                return PanelLocation(
                    windowID: window.id,
                    workspaceID: workspaceID,
                    slotID: sourceSlot.slotID
                )
            }
        }

        return nil
    }

    private static func locateWorkspaceID(containingSlotID slotID: UUID, in state: AppState) -> UUID? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.layoutTree.allSlotInfos.contains(where: { $0.slotID == slotID }) {
                    return workspaceID
                }
            }
        }
        return nil
    }

    private static func locateWindowID(containingWorkspaceID workspaceID: UUID, in state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }

    private static func resolveInsertionSlotID(in workspace: WorkspaceState, preferredSlotID: UUID?) -> UUID? {
        if let preferredSlotID {
            guard workspace.layoutTree.allSlotInfos.contains(where: { $0.slotID == preferredSlotID }) else {
                return nil
            }
            return preferredSlotID
        }

        if let focusedPanelID = workspace.focusedPanelID,
           let focusedSlot = workspace.layoutTree.slotContaining(panelID: focusedPanelID) {
            return focusedSlot.slotID
        }

        return workspace.layoutTree.allSlotInfos.first?.slotID
    }

    private static func resolveReopenSlotID(in workspace: WorkspaceState, preferredSlotID: UUID) -> UUID? {
        if workspace.layoutTree.allSlotInfos.contains(where: { $0.slotID == preferredSlotID }) {
            return preferredSlotID
        }
        if let focusedPanelID = workspace.focusedPanelID,
           let focusedSlot = workspace.layoutTree.slotContaining(panelID: focusedPanelID) {
            return focusedSlot.slotID
        }
        return workspace.layoutTree.allSlotInfos.first?.slotID
    }

    private static func auxPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        Set(
            workspace.panels.compactMap { panelID, panelState in
                auxiliaryPanelKinds.contains(panelState.kind) ? panelID : nil
            }
        )
    }

    private static func resolveAuxColumnSlotID(in workspace: WorkspaceState, auxPanelIDs: Set<UUID>) -> UUID? {
        guard auxPanelIDs.isEmpty == false else { return nil }
        return workspace.layoutTree.allSlotInfos.last(where: { slot in
            auxPanelIDs.contains(slot.panelID)
        })?.slotID
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
    let slotID: UUID
}
