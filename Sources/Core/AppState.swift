import Foundation

public struct WindowWorkspaceSelection: Equatable, Sendable {
    public let windowID: UUID
    public let window: WindowState
    public let workspaceID: UUID
    public let workspace: WorkspaceState

    public init(
        windowID: UUID,
        window: WindowState,
        workspaceID: UUID,
        workspace: WorkspaceState
    ) {
        self.windowID = windowID
        self.window = window
        self.workspaceID = workspaceID
        self.workspace = workspace
    }
}

public struct UnreadPanelTarget: Equatable, Sendable {
    public let windowID: UUID
    public let workspaceID: UUID
    public let tabID: UUID
    public let panelID: UUID

    public init(windowID: UUID, workspaceID: UUID, tabID: UUID, panelID: UUID) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.panelID = panelID
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let defaultTerminalFontPoints: Double = 12
    public static let minTerminalFontPoints: Double = 6
    public static let maxTerminalFontPoints: Double = 24
    public static let terminalFontStepPoints: Double = 1
    public static let terminalFontComparisonEpsilon: Double = 0.0001

    public var windows: [WindowState]
    public var workspacesByID: [UUID: WorkspaceState]
    public var selectedWindowID: UUID?
    public var configuredTerminalFontPoints: Double?
    public var defaultTerminalProfileID: String?
    public var globalTerminalFontPoints: Double

    public init(
        windows: [WindowState],
        workspacesByID: [UUID: WorkspaceState],
        selectedWindowID: UUID?,
        configuredTerminalFontPoints: Double? = nil,
        defaultTerminalProfileID: String? = nil,
        globalTerminalFontPoints: Double
    ) {
        self.windows = windows
        self.workspacesByID = workspacesByID
        self.selectedWindowID = selectedWindowID
        self.configuredTerminalFontPoints = configuredTerminalFontPoints
        self.defaultTerminalProfileID = Self.normalizedTerminalProfileID(defaultTerminalProfileID)
        self.globalTerminalFontPoints = globalTerminalFontPoints
    }

    public static func clampedTerminalFontPoints(_ points: Double) -> Double {
        min(max(points, minTerminalFontPoints), maxTerminalFontPoints)
    }

    public static func normalizedTerminalProfileID(_ profileID: String?) -> String? {
        guard let profileID else { return nil }
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    public var defaultTerminalProfileBinding: TerminalProfileBinding? {
        guard let defaultTerminalProfileID else { return nil }
        return TerminalProfileBinding(profileID: defaultTerminalProfileID)
    }

    public static func bootstrap(defaultTerminalProfileID: String? = nil) -> AppState {
        let normalizedDefaultTerminalProfileID = normalizedTerminalProfileID(defaultTerminalProfileID)
        let workspace = WorkspaceState.bootstrap(
            initialTerminalProfileBinding: normalizedDefaultTerminalProfileID.map { profileID in
                TerminalProfileBinding(profileID: profileID)
            }
        )
        let window = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
            workspaceIDs: [workspace.id],
            selectedWorkspaceID: workspace.id
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: window.id,
            configuredTerminalFontPoints: nil,
            defaultTerminalProfileID: normalizedDefaultTerminalProfileID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
    }

    public func window(id windowID: UUID) -> WindowState? {
        windows.first(where: { $0.id == windowID })
    }

    public func selectedWorkspaceID(in windowID: UUID) -> UUID? {
        guard let window = window(id: windowID) else { return nil }
        return window.selectedWorkspaceID ?? window.workspaceIDs.first
    }

    public func workspaceSelection(in windowID: UUID) -> WindowWorkspaceSelection? {
        guard let window = window(id: windowID),
              let workspaceID = selectedWorkspaceID(in: windowID),
              let workspace = workspacesByID[workspaceID] else {
            return nil
        }

        return WindowWorkspaceSelection(
            windowID: windowID,
            window: window,
            workspaceID: workspaceID,
            workspace: workspace
        )
    }

    public func workspaceSelection(containingWorkspaceID workspaceID: UUID) -> WindowWorkspaceSelection? {
        guard let window = windows.first(where: { $0.workspaceIDs.contains(workspaceID) }),
              let workspace = workspacesByID[workspaceID] else {
            return nil
        }

        return WindowWorkspaceSelection(
            windowID: window.id,
            window: window,
            workspaceID: workspaceID,
            workspace: workspace
        )
    }

    public func workspaceSelection(containingPanelID panelID: UUID) -> WindowWorkspaceSelection? {
        for window in windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = workspacesByID[workspaceID],
                      workspace.panelState(for: panelID) != nil,
                      workspace.slotID(containingPanelID: panelID) != nil else {
                    continue
                }

                return WindowWorkspaceSelection(
                    windowID: window.id,
                    window: window,
                    workspaceID: workspaceID,
                    workspace: workspace
                )
            }
        }

        return nil
    }

    public func selectedWorkspaceSelection() -> WindowWorkspaceSelection? {
        guard let selectedWindowID else { return nil }
        return workspaceSelection(in: selectedWindowID)
    }

    public func soleWorkspaceSelection() -> WindowWorkspaceSelection? {
        guard windows.count == 1,
              let windowID = windows.first?.id else {
            return nil
        }
        return workspaceSelection(in: windowID)
    }

    public func nextUnreadPanel(
        fromWindowID: UUID,
        workspaceID: UUID,
        tabID: UUID,
        focusedPanelID: UUID?
    ) -> UnreadPanelTarget? {
        guard let currentWindow = window(id: fromWindowID),
              currentWindow.workspaceIDs.contains(workspaceID),
              let currentWorkspace = workspacesByID[workspaceID],
              currentWorkspace.tabsByID[tabID] != nil,
              currentWorkspace.tabIDs.contains(tabID) else {
            return nil
        }

        if let target = nextUnreadPanel(
            in: currentWorkspace,
            windowID: fromWindowID,
            startingTabID: tabID,
            focusedPanelID: focusedPanelID
        ) {
            return target
        }

        for otherWorkspaceID in orderedIDs(after: workspaceID, in: currentWindow.workspaceIDs) {
            guard let workspace = workspacesByID[otherWorkspaceID] else { continue }
            if let target = nextUnreadPanel(in: workspace, windowID: fromWindowID) {
                return target
            }
        }

        let orderedWindowIDs = orderedIDs(after: fromWindowID, in: windows.map(\.id))
        for windowID in orderedWindowIDs {
            guard let window = window(id: windowID) else { continue }
            let orderedWorkspaceIDs = orderedIDs(
                startingAt: window.selectedWorkspaceID ?? window.workspaceIDs.first,
                in: window.workspaceIDs
            )
            for workspaceID in orderedWorkspaceIDs {
                guard let workspace = workspacesByID[workspaceID] else { continue }
                if let target = nextUnreadPanel(in: workspace, windowID: windowID) {
                    return target
                }
            }
        }

        return nil
    }

    private func nextUnreadPanel(in workspace: WorkspaceState, windowID: UUID) -> UnreadPanelTarget? {
        let orderedTabIDs = orderedIDs(startingAt: workspace.resolvedSelectedTabID, in: workspace.tabIDs)
        for tabID in orderedTabIDs {
            guard let tab = workspace.tabsByID[tabID],
                  let panelID = nextUnreadPanel(in: tab, skippingPanelID: nil) else {
                continue
            }
            return UnreadPanelTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: tabID,
                panelID: panelID
            )
        }
        return nil
    }

    private func nextUnreadPanel(
        in workspace: WorkspaceState,
        windowID: UUID,
        startingTabID: UUID,
        focusedPanelID: UUID?
    ) -> UnreadPanelTarget? {
        guard let startingTab = workspace.tabsByID[startingTabID] else {
            return nil
        }

        if let panelID = nextUnreadPanel(in: startingTab, skippingPanelID: focusedPanelID) {
            return UnreadPanelTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: startingTabID,
                panelID: panelID
            )
        }

        for otherTabID in orderedIDs(after: startingTabID, in: workspace.tabIDs) {
            guard let tab = workspace.tabsByID[otherTabID],
                  let panelID = nextUnreadPanel(in: tab, skippingPanelID: nil) else {
                continue
            }
            return UnreadPanelTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: otherTabID,
                panelID: panelID
            )
        }

        return nil
    }

    private func nextUnreadPanel(in tab: WorkspaceTabState, skippingPanelID: UUID?) -> UUID? {
        let panelOrder = tab.layoutTree.allSlotInfos.map(\.panelID)
        guard panelOrder.isEmpty == false else { return nil }

        if let skippingPanelID,
           let startIndex = panelOrder.firstIndex(of: skippingPanelID) {
            guard panelOrder.count > 1 else { return nil }
            for offset in 1 ..< panelOrder.count {
                let panelID = panelOrder[(startIndex + offset) % panelOrder.count]
                if tab.unreadPanelIDs.contains(panelID) {
                    return panelID
                }
            }
            return nil
        }

        for panelID in panelOrder where tab.unreadPanelIDs.contains(panelID) {
            return panelID
        }
        return nil
    }

    private func orderedIDs(startingAt startID: UUID?, in ids: [UUID]) -> [UUID] {
        guard let startID,
              let startIndex = ids.firstIndex(of: startID) else {
            return ids
        }
        return Array(ids[startIndex...]) + Array(ids[..<startIndex])
    }

    private func orderedIDs(after startID: UUID, in ids: [UUID]) -> [UUID] {
        guard let startIndex = ids.firstIndex(of: startID),
              ids.count > 1 else {
            return ids.contains(startID) ? [] : ids
        }
        let nextIndex = ids.index(after: startIndex)
        return Array(ids[nextIndex...]) + Array(ids[..<startIndex])
    }
}
