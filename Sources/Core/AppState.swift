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

public struct PanelNavigationTarget: Equatable, Sendable {
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
    public static let defaultMarkdownTextScale: Double = 1
    public static let minMarkdownTextScale: Double = 0.8
    public static let maxMarkdownTextScale: Double = 1.6
    public static let markdownTextScaleStep: Double = 0.1
    public static let markdownTextScaleComparisonEpsilon: Double = 0.0001

    public var windows: [WindowState]
    public var workspacesByID: [UUID: WorkspaceState]
    public var selectedWindowID: UUID?
    public var configuredTerminalFontPoints: Double?
    public var defaultTerminalProfileID: String?

    private struct ManagedAgentResumeRecordOwner {
        let panelID: UUID
        let record: ManagedAgentResumeRecord
        let traversalIndex: Int
    }

    public init(
        windows: [WindowState],
        workspacesByID: [UUID: WorkspaceState],
        selectedWindowID: UUID?,
        configuredTerminalFontPoints: Double? = nil,
        defaultTerminalProfileID: String? = nil
    ) {
        self.windows = windows
        self.workspacesByID = workspacesByID
        self.selectedWindowID = selectedWindowID
        self.configuredTerminalFontPoints = configuredTerminalFontPoints.map(Self.clampedTerminalFontPoints)
        self.defaultTerminalProfileID = Self.normalizedTerminalProfileID(defaultTerminalProfileID)
        normalizeVisitedWorkspacesForVisibleSelections()
    }

    @discardableResult
    mutating func pruneDuplicateManagedAgentResumeRecords(preferredPanelID: UUID? = nil) -> Bool {
        var ownerByClaimKey: [String: ManagedAgentResumeRecordOwner] = [:]
        var panelIDsToClear = Set<UUID>()
        var traversalIndex = 0

        for workspaceID in orderedWorkspaceIDsForManagedAgentResumeRecords() {
            guard let workspace = workspacesByID[workspaceID] else { continue }
            for tabID in Self.orderedTabIDs(in: workspace) {
                guard let tab = workspace.tabsByID[tabID] else { continue }
                for panelID in Self.orderedPanelIDs(in: tab) {
                    guard case .terminal(let terminalState) = tab.panels[panelID],
                          let record = terminalState.resumeRecord,
                          let claimKey = record.resumeClaimKey else {
                        continue
                    }

                    let owner = ManagedAgentResumeRecordOwner(
                        panelID: panelID,
                        record: record,
                        traversalIndex: traversalIndex
                    )
                    traversalIndex += 1

                    guard let incumbent = ownerByClaimKey[claimKey] else {
                        ownerByClaimKey[claimKey] = owner
                        continue
                    }

                    if Self.shouldPreferManagedAgentResumeRecordOwner(
                        owner,
                        over: incumbent,
                        preferredPanelID: preferredPanelID
                    ) {
                        panelIDsToClear.insert(incumbent.panelID)
                        panelIDsToClear.remove(owner.panelID)
                        ownerByClaimKey[claimKey] = owner
                    } else {
                        panelIDsToClear.insert(owner.panelID)
                    }
                }
            }
        }

        guard panelIDsToClear.isEmpty == false else { return false }
        var didMutate = false

        for workspaceID in orderedWorkspaceIDsForManagedAgentResumeRecords() {
            guard var workspace = workspacesByID[workspaceID] else { continue }
            var workspaceDidMutate = false

            for tabID in Self.orderedTabIDs(in: workspace) {
                guard var tab = workspace.tabsByID[tabID] else { continue }
                var tabDidMutate = false

                for panelID in Self.orderedPanelIDs(in: tab) where panelIDsToClear.contains(panelID) {
                    guard case .terminal(var terminalState) = tab.panels[panelID],
                          terminalState.resumeRecord != nil else {
                        continue
                    }

                    terminalState.resumeRecord = nil
                    tab.panels[panelID] = .terminal(terminalState)
                    tabDidMutate = true
                }

                if tabDidMutate {
                    workspace.tabsByID[tabID] = tab
                    workspaceDidMutate = true
                }
            }

            if workspaceDidMutate {
                workspacesByID[workspaceID] = workspace
                didMutate = true
            }
        }

        return didMutate
    }

    @discardableResult
    mutating func pruneManagedAgentResumeRecordScopes(validWorkspaceIDs: Set<UUID>) -> Bool {
        var didMutate = false

        for workspaceID in orderedWorkspaceIDsForManagedAgentResumeRecords() {
            guard var workspace = workspacesByID[workspaceID] else { continue }
            var workspaceDidMutate = false

            for tabID in Self.orderedTabIDs(in: workspace) {
                guard var tab = workspace.tabsByID[tabID] else { continue }
                var tabDidMutate = false

                for panelID in Self.orderedPanelIDs(in: tab) {
                    guard case .terminal(var terminalState) = tab.panels[panelID],
                          var record = terminalState.resumeRecord,
                          let scopedWorkspaceIDs = record.scopedWorkspaceIDs else {
                        continue
                    }

                    let prunedScope = scopedWorkspaceIDs.intersection(validWorkspaceIDs)
                    guard prunedScope != scopedWorkspaceIDs else { continue }

                    record.scopedWorkspaceIDs = prunedScope
                    terminalState.resumeRecord = record
                    tab.panels[panelID] = .terminal(terminalState)
                    tabDidMutate = true
                }

                if tabDidMutate {
                    workspace.tabsByID[tabID] = tab
                    workspaceDidMutate = true
                }
            }

            if workspaceDidMutate {
                workspacesByID[workspaceID] = workspace
                didMutate = true
            }
        }

        return didMutate
    }

    private func orderedWorkspaceIDsForManagedAgentResumeRecords() -> [UUID] {
        var orderedWorkspaceIDs: [UUID] = []
        var seenWorkspaceIDs = Set<UUID>()

        for window in windows {
            for workspaceID in window.workspaceIDs where workspacesByID[workspaceID] != nil {
                guard seenWorkspaceIDs.insert(workspaceID).inserted else { continue }
                orderedWorkspaceIDs.append(workspaceID)
            }
        }

        for workspaceID in workspacesByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard seenWorkspaceIDs.insert(workspaceID).inserted else { continue }
            orderedWorkspaceIDs.append(workspaceID)
        }

        return orderedWorkspaceIDs
    }

    private static func orderedTabIDs(in workspace: WorkspaceState) -> [UUID] {
        var orderedTabIDs: [UUID] = []
        var seenTabIDs = Set<UUID>()

        for tabID in workspace.tabIDs where workspace.tabsByID[tabID] != nil {
            guard seenTabIDs.insert(tabID).inserted else { continue }
            orderedTabIDs.append(tabID)
        }

        for tabID in workspace.tabsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard seenTabIDs.insert(tabID).inserted else { continue }
            orderedTabIDs.append(tabID)
        }

        return orderedTabIDs
    }

    private static func orderedPanelIDs(in tab: WorkspaceTabState) -> [UUID] {
        var orderedPanelIDs: [UUID] = []
        var seenPanelIDs = Set<UUID>()

        for slotInfo in tab.layoutTree.allSlotInfos where tab.panels[slotInfo.panelID] != nil {
            guard seenPanelIDs.insert(slotInfo.panelID).inserted else { continue }
            orderedPanelIDs.append(slotInfo.panelID)
        }

        for panelID in tab.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard seenPanelIDs.insert(panelID).inserted else { continue }
            orderedPanelIDs.append(panelID)
        }

        return orderedPanelIDs
    }

    private static func shouldPreferManagedAgentResumeRecordOwner(
        _ candidate: ManagedAgentResumeRecordOwner,
        over incumbent: ManagedAgentResumeRecordOwner,
        preferredPanelID: UUID?
    ) -> Bool {
        if candidate.panelID == preferredPanelID {
            return true
        }
        if incumbent.panelID == preferredPanelID {
            return false
        }
        if candidate.record.capturedAt != incumbent.record.capturedAt {
            return candidate.record.capturedAt > incumbent.record.capturedAt
        }
        return candidate.traversalIndex < incumbent.traversalIndex
    }

    public static func clampedTerminalFontPoints(_ points: Double) -> Double {
        min(max(points, minTerminalFontPoints), maxTerminalFontPoints)
    }

    public static func clampedMarkdownTextScale(_ scale: Double) -> Double {
        min(max(scale, minMarkdownTextScale), maxMarkdownTextScale)
    }

    public static func normalizedMarkdownTextScaleOverride(_ scale: Double?) -> Double? {
        guard let scale else { return nil }
        let clampedScale = clampedMarkdownTextScale(scale)
        guard abs(clampedScale - defaultMarkdownTextScale) >= markdownTextScaleComparisonEpsilon else {
            return nil
        }
        return clampedScale
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

    public var configuredTerminalFontBaselinePoints: Double {
        configuredTerminalFontPoints ?? Self.defaultTerminalFontPoints
    }

    public func normalizedTerminalFontOverride(_ points: Double?) -> Double? {
        guard let points else { return nil }
        let clampedPoints = Self.clampedTerminalFontPoints(points)
        guard abs(clampedPoints - configuredTerminalFontBaselinePoints) >= Self.terminalFontComparisonEpsilon else {
            return nil
        }
        return clampedPoints
    }

    public func effectiveTerminalFontPoints(for windowID: UUID) -> Double {
        guard let window = window(id: windowID) else {
            return configuredTerminalFontBaselinePoints
        }
        return effectiveTerminalFontPoints(for: window)
    }

    public func effectiveMarkdownTextScale(for windowID: UUID) -> Double {
        guard let window = window(id: windowID) else {
            return Self.defaultMarkdownTextScale
        }
        return effectiveMarkdownTextScale(for: window)
    }

    private mutating func normalizeVisitedWorkspacesForVisibleSelections() {
        for window in windows {
            guard let workspaceID = selectedWorkspaceID(in: window.id),
                  var workspace = workspacesByID[workspaceID],
                  workspace.hasBeenVisited == false else {
                continue
            }

            workspace.hasBeenVisited = true
            workspacesByID[workspaceID] = workspace
        }
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
            defaultTerminalProfileID: normalizedDefaultTerminalProfileID
        )
    }

    public func window(id windowID: UUID) -> WindowState? {
        windows.first(where: { $0.id == windowID })
    }

    public func windowHasAnyUnreadNotifications(windowID: UUID) -> Bool {
        guard let window = window(id: windowID) else { return false }
        return window.workspaceIDs.contains { workspaceID in
            (workspacesByID[workspaceID]?.unreadNotificationCount ?? 0) > 0
        }
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
                      workspace.panelState(for: panelID) != nil else {
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

    public var allTerminalPanelIDs: Set<UUID> {
        workspacesByID.values.reduce(into: Set<UUID>()) { result, workspace in
            result.formUnion(workspace.allTerminalPanelIDs)
        }
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
    ) -> PanelNavigationTarget? {
        guard let currentWindow = window(id: fromWindowID),
              currentWindow.workspaceIDs.contains(workspaceID),
              let currentWorkspace = workspacesByID[workspaceID],
              currentWorkspace.tabsByID[tabID] != nil,
              currentWorkspace.tabIDs.contains(tabID) else {
            return nil
        }

        if let target = nextUnreadPanelWrappingCurrentWorkspace(
            in: currentWorkspace,
            windowID: fromWindowID,
            startingTabID: tabID,
            focusedPanelID: focusedPanelID,
            matches: { tab, panelID in
                tab.unreadPanelIDs.contains(panelID)
            }
        ) {
            return target
        }

        for otherWorkspaceID in orderedIDs(after: workspaceID, in: currentWindow.workspaceIDs) {
            guard let workspace = workspacesByID[otherWorkspaceID] else { continue }
            if let target = nextMatchingPanel(
                in: workspace,
                windowID: fromWindowID,
                matches: { tab, panelID in
                    tab.unreadPanelIDs.contains(panelID)
                }
            ) {
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
                if let target = nextMatchingPanel(
                    in: workspace,
                    windowID: windowID,
                    matches: { tab, panelID in
                        tab.unreadPanelIDs.contains(panelID)
                    }
                ) {
                    return target
                }
            }
        }

        return nil
    }

    public func nextMatchingPanel(
        fromWindowID: UUID,
        workspaceID: UUID,
        tabID: UUID,
        focusedPanelID: UUID?,
        includeCurrentWorkspaceWrap: Bool = true,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> PanelNavigationTarget? {
        guard let currentWindow = window(id: fromWindowID),
              currentWindow.workspaceIDs.contains(workspaceID),
              let currentWorkspace = workspacesByID[workspaceID],
              currentWorkspace.tabsByID[tabID] != nil,
              currentWorkspace.tabIDs.contains(tabID) else {
            return nil
        }

        if let target = nextMatchingPanel(
            in: currentWorkspace,
            windowID: fromWindowID,
            startingTabID: tabID,
            focusedPanelID: focusedPanelID,
            matches: matches
        ) {
            return target
        }

        for otherWorkspaceID in orderedIDs(after: workspaceID, in: currentWindow.workspaceIDs) {
            guard let workspace = workspacesByID[otherWorkspaceID] else { continue }
            if let target = nextMatchingPanel(
                in: workspace,
                windowID: fromWindowID,
                matches: matches
            ) {
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
                if let target = nextMatchingPanel(
                    in: workspace,
                    windowID: windowID,
                    matches: matches
                ) {
                    return target
                }
            }
        }

        // Keep the current workspace non-wrapping on the first pass so sibling
        // workspaces and windows are considered before we loop back locally.
        guard includeCurrentWorkspaceWrap else {
            return nil
        }

        if let target = nextMatchingPanel(
            in: currentWorkspace,
            windowID: fromWindowID,
            wrappingBeforeTabID: tabID,
            focusedPanelID: focusedPanelID,
            matches: matches
        ) {
            return target
        }

        return nil
    }

    private func effectiveTerminalFontPoints(for window: WindowState) -> Double {
        window.terminalFontSizePointsOverride ?? configuredTerminalFontBaselinePoints
    }

    private func effectiveMarkdownTextScale(for window: WindowState) -> Double {
        window.markdownTextScaleOverride ?? Self.defaultMarkdownTextScale
    }

    private func nextMatchingPanel(
        in workspace: WorkspaceState,
        windowID: UUID,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> PanelNavigationTarget? {
        guard let startingTabID = workspace.resolvedSelectedTabID,
              let startingTab = workspace.tabsByID[startingTabID] else {
            return nil
        }

        let focusedPanelID = startingTab.resolvedFocusedPanelID
        if let panelID = nextMatchingPanel(
            in: startingTab,
            startingAfterPanelID: focusedPanelID,
            wrap: false,
            matches: matches
        ) {
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: startingTabID,
                panelID: panelID
            )
        }

        for tabID in orderedIDs(after: startingTabID, in: workspace.tabIDs) {
            guard let tab = workspace.tabsByID[tabID],
                  let panelID = nextMatchingPanel(
                      in: tab,
                      startingAfterPanelID: nil,
                      wrap: true,
                      matches: matches
                  ) else {
                continue
            }
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: tabID,
                panelID: panelID
            )
        }

        if let panelID = nextMatchingPanel(
            in: startingTab,
            endingAtOrIncludingPanelID: focusedPanelID,
            matches: matches
        ) {
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: startingTabID,
                panelID: panelID
            )
        }

        return nil
    }

    private func nextMatchingPanel(
        in workspace: WorkspaceState,
        windowID: UUID,
        startingTabID: UUID,
        focusedPanelID: UUID?,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> PanelNavigationTarget? {
        guard let startingTab = workspace.tabsByID[startingTabID] else {
            return nil
        }

        if let panelID = nextMatchingPanel(
            in: startingTab,
            startingAfterPanelID: focusedPanelID,
            wrap: false,
            matches: matches
        ) {
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: startingTabID,
                panelID: panelID
            )
        }

        for otherTabID in idsAfter(startingTabID, in: workspace.tabIDs) {
            guard let tab = workspace.tabsByID[otherTabID],
                  let panelID = nextMatchingPanel(
                      in: tab,
                      startingAfterPanelID: nil,
                      wrap: true,
                      matches: matches
                  ) else {
                continue
            }
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: otherTabID,
                panelID: panelID
            )
        }

        return nil
    }

    private func nextUnreadPanelWrappingCurrentWorkspace(
        in workspace: WorkspaceState,
        windowID: UUID,
        startingTabID: UUID,
        focusedPanelID: UUID?,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> PanelNavigationTarget? {
        guard let startingTab = workspace.tabsByID[startingTabID] else {
            return nil
        }

        if let panelID = nextMatchingPanel(
            in: startingTab,
            startingAfterPanelID: focusedPanelID,
            wrap: true,
            matches: matches
        ) {
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: startingTabID,
                panelID: panelID
            )
        }

        for otherTabID in orderedIDs(after: startingTabID, in: workspace.tabIDs) {
            guard let tab = workspace.tabsByID[otherTabID],
                  let panelID = nextMatchingPanel(
                      in: tab,
                      startingAfterPanelID: nil,
                      wrap: true,
                      matches: matches
                  ) else {
                continue
            }
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: otherTabID,
                panelID: panelID
            )
        }

        return nil
    }

    private func nextMatchingPanel(
        in tab: WorkspaceTabState,
        startingAfterPanelID: UUID?,
        wrap: Bool,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> UUID? {
        let panelOrder = tab.layoutTree.allSlotInfos.map(\.panelID)
        guard panelOrder.isEmpty == false else { return nil }

        if let startingAfterPanelID,
           let startIndex = panelOrder.firstIndex(of: startingAfterPanelID) {
            for panelID in panelOrder[panelOrder.index(after: startIndex)...] where matches(tab, panelID) {
                return panelID
            }

            guard wrap, panelOrder.count > 1 else { return nil }
            for panelID in panelOrder[..<startIndex] where matches(tab, panelID) {
                return panelID
            }
            return nil
        }

        for panelID in panelOrder where matches(tab, panelID) {
            return panelID
        }
        return nil
    }

    private func nextMatchingPanel(
        in workspace: WorkspaceState,
        windowID: UUID,
        wrappingBeforeTabID: UUID,
        focusedPanelID: UUID?,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> PanelNavigationTarget? {
        for earlierTabID in idsBefore(wrappingBeforeTabID, in: workspace.tabIDs) {
            guard let tab = workspace.tabsByID[earlierTabID],
                  let panelID = nextMatchingPanel(
                      in: tab,
                      startingAfterPanelID: nil,
                      wrap: true,
                      matches: matches
                  ) else {
                continue
            }
            return PanelNavigationTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                tabID: earlierTabID,
                panelID: panelID
            )
        }

        guard let wrappingTab = workspace.tabsByID[wrappingBeforeTabID],
              let panelID = nextMatchingPanel(
                  in: wrappingTab,
                  endingBeforePanelID: focusedPanelID,
                  matches: matches
              ) else {
            return nil
        }
        return PanelNavigationTarget(
            windowID: windowID,
            workspaceID: workspace.id,
            tabID: wrappingBeforeTabID,
            panelID: panelID
        )
    }

    private func nextMatchingPanel(
        in tab: WorkspaceTabState,
        endingBeforePanelID: UUID?,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> UUID? {
        let panelOrder = tab.layoutTree.allSlotInfos.map(\.panelID)
        guard panelOrder.isEmpty == false else { return nil }

        if let endingBeforePanelID,
           let endIndex = panelOrder.firstIndex(of: endingBeforePanelID) {
            for panelID in panelOrder[..<endIndex] where matches(tab, panelID) {
                return panelID
            }
            return nil
        }

        for panelID in panelOrder where matches(tab, panelID) {
            return panelID
        }
        return nil
    }

    private func nextMatchingPanel(
        in tab: WorkspaceTabState,
        endingAtOrIncludingPanelID: UUID?,
        matches: (_ tab: WorkspaceTabState, _ panelID: UUID) -> Bool
    ) -> UUID? {
        let panelOrder = tab.layoutTree.allSlotInfos.map(\.panelID)
        guard panelOrder.isEmpty == false else { return nil }

        if let endingAtOrIncludingPanelID,
           let endIndex = panelOrder.firstIndex(of: endingAtOrIncludingPanelID) {
            for panelID in panelOrder[...endIndex] where matches(tab, panelID) {
                return panelID
            }
            return nil
        }

        for panelID in panelOrder where matches(tab, panelID) {
            return panelID
        }
        return nil
    }

    private func idsAfter(_ startID: UUID, in ids: [UUID]) -> [UUID] {
        guard let startIndex = ids.firstIndex(of: startID) else {
            return ids
        }
        let nextIndex = ids.index(after: startIndex)
        guard nextIndex < ids.endIndex else {
            return []
        }
        return Array(ids[nextIndex...])
    }

    private func idsBefore(_ endID: UUID, in ids: [UUID]) -> [UUID] {
        guard let endIndex = ids.firstIndex(of: endID) else {
            return []
        }
        return Array(ids[..<endIndex])
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

extension AppState {
    private enum CodingKeys: String, CodingKey {
        case windows
        case workspacesByID
        case selectedWindowID
        case configuredTerminalFontPoints
        case defaultTerminalProfileID
        case globalTerminalFontPoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuredTerminalFontPoints = try container.decodeIfPresent(
            Double.self,
            forKey: .configuredTerminalFontPoints
        )

        self.init(
            windows: try container.decode([WindowState].self, forKey: .windows),
            workspacesByID: try container.decode([UUID: WorkspaceState].self, forKey: .workspacesByID),
            selectedWindowID: try container.decodeIfPresent(UUID.self, forKey: .selectedWindowID),
            configuredTerminalFontPoints: configuredTerminalFontPoints,
            defaultTerminalProfileID: try container.decodeIfPresent(String.self, forKey: .defaultTerminalProfileID)
        )

        if let legacyGlobalTerminalFontPoints = try container.decodeIfPresent(Double.self, forKey: .globalTerminalFontPoints) {
            let migratedOverride = normalizedTerminalFontOverride(legacyGlobalTerminalFontPoints)
            if let migratedOverride {
                windows = windows.map { window in
                    guard window.terminalFontSizePointsOverride == nil else { return window }
                    var window = window
                    window.terminalFontSizePointsOverride = migratedOverride
                    return window
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
        try container.encode(workspacesByID, forKey: .workspacesByID)
        try container.encodeIfPresent(selectedWindowID, forKey: .selectedWindowID)
        try container.encodeIfPresent(configuredTerminalFontPoints, forKey: .configuredTerminalFontPoints)
        try container.encodeIfPresent(defaultTerminalProfileID, forKey: .defaultTerminalProfileID)
    }
}
