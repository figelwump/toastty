import CoreState
import Foundation
import SwiftUI

@MainActor
enum SidebarSessionPresentation {
    struct SessionChildFocusTarget: Equatable {
        let workspaceID: UUID
        let panelID: UUID
    }

    struct SidebarSessionRowID: Hashable, Equatable {
        let workspaceID: UUID
        let sessionID: String
        let panelID: UUID
    }

    enum HiddenSessionDirection: Equatable {
        case above
        case below

        var iconName: String {
            switch self {
            case .above:
                return "chevron.up"
            case .below:
                return "chevron.down"
            }
        }

        var accessibilityDirection: String {
            switch self {
            case .above:
                return "above"
            case .below:
                return "below"
            }
        }
    }

    struct HiddenSessionPill: Equatable {
        let direction: HiddenSessionDirection
        let count: Int
        let unreadCount: Int
        let hasWorking: Bool
    }

    struct HiddenSessionPillState: Equatable {
        let above: HiddenSessionPill?
        let below: HiddenSessionPill?

        static let empty = HiddenSessionPillState(above: nil, below: nil)
    }

    private static let sessionChildStartedTimeFormat = Date.FormatStyle()
        .hour(.defaultDigits(amPM: .omitted))
        .minute(.twoDigits)

    nonisolated static func hiddenSessionPillState(
        orderedSessionRowIDs: [SidebarSessionRowID],
        measuredSessionRowFramesByID: [SidebarSessionRowID: CGRect],
        unreadSessionRowIDs: Set<SidebarSessionRowID>,
        workingSessionRowIDs: Set<SidebarSessionRowID> = [],
        viewportHeight: CGFloat,
        visibleTop: CGFloat = ToastyTheme.sidebarTopPadding,
        minimumVisibleFraction: CGFloat = 0.5,
        epsilon: CGFloat = 1.5
    ) -> HiddenSessionPillState {
        guard viewportHeight.isFinite,
              viewportHeight > 0,
              visibleTop.isFinite,
              minimumVisibleFraction.isFinite,
              minimumVisibleFraction >= 0,
              minimumVisibleFraction <= 1,
              epsilon.isFinite else {
            return .empty
        }

        let topThreshold = visibleTop + epsilon
        let bottomThreshold = viewportHeight - epsilon
        guard bottomThreshold > topThreshold else { return .empty }

        var hiddenAbove: [SidebarSessionRowID] = []
        var hiddenBelow: [SidebarSessionRowID] = []

        for rowID in orderedSessionRowIDs {
            guard let frame = measuredSessionRowFramesByID[rowID],
                  frame.minY.isFinite,
                  frame.maxY.isFinite,
                  frame.height.isFinite,
                  frame.height > 0 else {
                continue
            }

            let visibleHeight = max(0, min(frame.maxY, bottomThreshold) - max(frame.minY, topThreshold))
            let viewportVisibleHeight = bottomThreshold - topThreshold
            let minimumVisibleHeight = min(frame.height * minimumVisibleFraction, viewportVisibleHeight)

            // A one-pixel intersection is not useful as a scroll affordance; keep
            // a row counted hidden until enough of that row is visible to identify it.
            if frame.maxY <= topThreshold
                || (frame.minY < topThreshold && visibleHeight < minimumVisibleHeight) {
                hiddenAbove.append(rowID)
            } else if frame.minY >= bottomThreshold
                || (frame.maxY > bottomThreshold && visibleHeight < minimumVisibleHeight) {
                hiddenBelow.append(rowID)
            }
        }

        let abovePill = hiddenAbove.isEmpty
            ? nil
            : HiddenSessionPill(
                direction: .above,
                count: hiddenAbove.count,
                unreadCount: hiddenAbove.filter { unreadSessionRowIDs.contains($0) }.count,
                hasWorking: hiddenAbove.contains { workingSessionRowIDs.contains($0) }
            )
        let belowPill = hiddenBelow.isEmpty
            ? nil
            : HiddenSessionPill(
                direction: .below,
                count: hiddenBelow.count,
                unreadCount: hiddenBelow.filter { unreadSessionRowIDs.contains($0) }.count,
                hasWorking: hiddenBelow.contains { workingSessionRowIDs.contains($0) }
            )

        return HiddenSessionPillState(above: abovePill, below: belowPill)
    }

    nonisolated static func hiddenSessionScrollTarget(
        for direction: HiddenSessionDirection,
        orderedWorkspaceIDs: [UUID]
    ) -> (workspaceID: UUID, anchor: UnitPoint)? {
        switch direction {
        case .above:
            return orderedWorkspaceIDs.first.map { ($0, .top) }
        case .below:
            return orderedWorkspaceIDs.last.map { ($0, .bottom) }
        }
    }

    static func showsUnreadSessionAccent(
        for panelID: UUID,
        in workspace: WorkspaceState,
        selectedWorkspaceID: UUID?,
        selectedPanelID: UUID?
    ) -> Bool {
        guard let tabID = workspace.tabID(containingPanelID: panelID),
              workspace.tab(id: tabID)?.unreadPanelIDs.contains(panelID) == true else {
            return false
        }

        if selectedWorkspaceID == workspace.id,
           selectedPanelID == panelID {
            return false
        }

        return true
    }

    static func sessionStatusChipKind(
        for status: SessionStatus,
        showsUnreadSessionAccent: Bool
    ) -> SessionStatusKind? {
        switch status.kind {
        case .needsApproval, .error:
            return status.kind
        case .ready:
            return showsUnreadSessionAccent ? .ready : nil
        case .idle, .working:
            return nil
        }
    }

    static func sessionStatusChipLabel(for kind: SessionStatusKind) -> String {
        switch kind {
        case .needsApproval:
            return "needs approval"
        case .ready:
            return "ready"
        case .error:
            return "error"
        case .idle, .working:
            return ""
        }
    }

    static func sessionStatusProjectionChipLabel(for projection: SessionStatusProjection) -> String? {
        switch projection {
        case .waitingOnChildren:
            return "waiting"
        case .none, .resuming:
            return nil
        }
    }

    static func sessionStatusProjectionLogValue(_ projection: SessionStatusProjection) -> String {
        switch projection {
        case .none:
            return "none"
        case .waitingOnChildren(let childCount, let pendingBackgroundTaskCount):
            return "waiting_children_\(childCount)_pending_\(pendingBackgroundTaskCount)"
        case .resuming:
            return "resuming"
        }
    }

    static func laterFlagActionTitle(isFlaggedForLater: Bool) -> String {
        isFlaggedForLater ? "Clear Later Flag" : "Flag for Later"
    }

    static func sessionAccessibilityLabel(
        agentName: String,
        chipKind: SessionStatusKind?,
        projection: SessionStatusProjection = .none,
        childCount: Int = 0,
        detailText: String?,
        cwd: String?,
        isLaterFlagged: Bool,
        workspaceScopeHelpText: String? = nil
    ) -> String {
        var components = [agentName]
        if let chipKind {
            components.append(sessionStatusChipLabel(for: chipKind))
        }
        if let projectionLabel = sessionStatusProjectionChipLabel(for: projection) {
            components.append(projectionLabel)
        }
        if childCount > 0 {
            components.append(childCount == 1 ? "1 sub-agent" : "\(childCount) sub-agents")
        }
        if let workspaceScopeHelpText {
            components.append("workspace-scoped")
            components.append(workspaceScopeHelpText)
        }
        if let detailText {
            components.append(detailText)
        }
        if let cwd {
            components.append(cwd)
        }
        if isLaterFlagged {
            components.append("flagged for later")
        }
        return components.joined(separator: ", ")
    }

    static func sessionChildrenDisclosureAccessibilityLabel(
        childCount: Int,
        isExpanded: Bool,
        showsAttention: Bool
    ) -> String {
        let childLabel = childCount == 1 ? "sub-agent" : "sub-agents"
        let state = isExpanded ? "expanded" : "collapsed"
        let attention = showsAttention ? ", needs attention" : ""
        return "\(childCount) \(childLabel), \(state)\(attention)"
    }

    static func sessionChildRowsExpanded(
        sessionID: String,
        expandedSessionChildrenBySessionID: [String: Bool]
    ) -> Bool {
        expandedSessionChildrenBySessionID[sessionID] ?? true
    }

    static func sessionChildRowsNeedAttention(_ children: [SessionChildRow]) -> Bool {
        children.contains { child in
            child.statusKind == .needsApproval || child.statusKind == .error
        }
    }

    static func sessionChildFocusTarget(
        for child: SessionChildRow,
        parentWorkspaceID: UUID,
        parentPanelID: UUID
    ) -> SessionChildFocusTarget {
        guard child.source == .session,
              let workspaceID = child.workspaceID,
              let panelID = child.panelID else {
            return SessionChildFocusTarget(workspaceID: parentWorkspaceID, panelID: parentPanelID)
        }
        return SessionChildFocusTarget(workspaceID: workspaceID, panelID: panelID)
    }

    static func parentSessionTagLabel(parentName: String) -> String {
        "↖ \(parentName)"
    }

    /// Tooltip text for a session row whose parent or scope tag was dropped
    /// because the header did not fit.
    static func sessionRowCompactHelpText(
        parentSessionName: String?,
        workspaceScopeHelpText: String?
    ) -> String? {
        var lines: [String] = []
        if let parentSessionName {
            lines.append("Parent session: \(parentSessionName)")
        }
        if let workspaceScopeHelpText {
            lines.append(workspaceScopeHelpText)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func childWorkspaceTagLabel(
        for child: SessionChildRow,
        parentWorkspaceID: UUID,
        workspaceNamesByID: [UUID: String]
    ) -> String? {
        guard child.source == .session,
              let workspaceID = child.workspaceID,
              workspaceID != parentWorkspaceID else {
            return nil
        }
        if let name = normalizedSidebarHelperText(workspaceNamesByID[workspaceID]) {
            return name
        }
        return "Workspace \(workspaceID.uuidString.prefix(8))"
    }

    static func elapsedChildActivityText(startedAt: Date, now: Date) -> String {
        let elapsedSeconds = Int(max(0, now.timeIntervalSince(startedAt)))
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        guard minutes > 0 else { return "\(seconds)s" }
        return String(format: "%dm %02ds", minutes, seconds)
    }

    static func sessionChildAccessibilityLabel(
        child: SessionChildRow,
        workspaceTag: String?,
        elapsedText: String?
    ) -> String {
        var components: [String] = []
        components.append(child.source == .session ? "session child" : "activity child")
        components.append(child.displayName)
        if let statusKind = child.statusKind,
           let statusLabel = normalizedSidebarHelperText(sessionStatusChipLabel(for: statusKind)) {
            components.append(statusLabel)
        }
        if let context = normalizedSidebarHelperText(child.context) {
            components.append(context)
        }
        if let modelIdentifier = normalizedSidebarHelperText(child.executionProfile?.modelIdentifier) {
            components.append("model \(modelIdentifier)")
        }
        if let reasoningEffort = normalizedSidebarHelperText(child.executionProfile?.reasoningEffort) {
            components.append("reasoning effort \(reasoningEffort)")
        }
        if let workspaceTag {
            components.append(workspaceTag)
        }
        if let elapsedText {
            components.append(elapsedText)
        }
        return components.joined(separator: ", ")
    }

    static func normalizedSidebarHelperText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    static func hiddenSessionPillAccessibilityLabel(_ pill: HiddenSessionPill) -> String {
        let sessionLabel = pill.count == 1 ? "session" : "sessions"
        var label = "\(pill.count) \(sessionLabel) hidden \(pill.direction.accessibilityDirection)"
        if pill.unreadCount > 0 {
            label += ", \(pill.unreadCount) unread"
        }
        if pill.hasWorking {
            label += ", working"
        }
        return label
    }

    static func canFocusSessionPanel(_ panelID: UUID, in workspace: WorkspaceState) -> Bool {
        workspace.panelState(for: panelID) != nil && workspace.slotID(containingPanelID: panelID) != nil
    }

    static func sessionIndicatorState(for kind: SessionStatusKind) -> SessionStatusIndicatorState {
        switch kind {
        case .working:
            return .spinner
        case .needsApproval, .ready, .error, .idle:
            return .hidden
        }
    }

    static func sessionIndicatorLogValue(_ state: SessionStatusIndicatorState) -> String {
        switch state {
        case .hidden:
            return "hidden"
        case .spinner:
            return "spinner"
        case .dot:
            return "dot"
        }
    }

    static func sessionAgentFontWeight(showsUnreadSessionAccent: Bool) -> Font.Weight {
        showsUnreadSessionAccent ? .heavy : .medium
    }

    static func sessionBodyFontWeight(showsUnreadSessionAccent: Bool) -> Font.Weight {
        showsUnreadSessionAccent ? .bold : .regular
    }

    static func sessionTextUsesItalic(for kind: SessionStatusKind) -> Bool {
        kind == .working
    }

    static let workspaceNewBadgeLabel = "New"

    static func workspaceAccessibilityLabel(
        for workspace: WorkspaceState,
        isSelected: Bool,
        agentSummary: WorkspaceAgentSummary? = nil
    ) -> String {
        let baseLabel = if showsNewWorkspaceBadge(isSelected: isSelected, hasBeenVisited: workspace.hasBeenVisited) {
            "\(workspace.title) \(workspaceNewBadgeLabel)"
        } else {
            workspace.title
        }
        var components = [baseLabel]
        if let agentSummary, agentSummary.hasRunning {
            components.append(workspaceAgentSummaryAccessibilityLabel(agentSummary))
        }
        // Text-only annotation chips fold into this summary; chips with URLs
        // remain independently actionable link buttons and are excluded here.
        components.append(contentsOf: workspace.annotations
            .filter { $0.value.url == nil }
            .sorted { $0.key < $1.key }
            .map { key, annotation in "\(key): \(annotation.text)" })
        return components.joined(separator: ", ")
    }

    static func workspaceAgentSummaryAccessibilityLabel(_ summary: WorkspaceAgentSummary) -> String {
        "\(summary.active) active, \(summary.running) running"
    }

    static func showsNewWorkspaceBadge(isSelected: Bool, hasBeenVisited: Bool) -> Bool {
        isSelected == false && hasBeenVisited == false
    }

    static func workspaceTitleFontWeight(isSelected: Bool, hasBeenVisited: Bool) -> Font.Weight {
        if isSelected || hasBeenVisited == false {
            return .semibold
        }
        return .medium
    }

    static func sessionChildHoverTipModel(
        child: SessionChildRow,
        workspaceName: String?,
        elapsedText: String?,
        now: Date
    ) -> SessionChildHoverTipModel {
        let bodyText = normalizedSidebarHelperText(child.context)
        let typeLabel: String
        let statusDotColorKind: SessionChildHoverTipModel.StatusDotColorKind
        var metaItems: [String]

        switch child.source {
        case .activity:
            typeLabel = "sub-agent"
            statusDotColorKind = .working
            let resolvedElapsedText = normalizedSidebarHelperText(elapsedText)
                ?? elapsedChildActivityText(startedAt: child.startedAt, now: now)
            metaItems = [
                "running · \(resolvedElapsedText)",
                "started \(child.startedAt.formatted(sessionChildStartedTimeFormat))",
            ]
        case .session:
            typeLabel = "session"
            statusDotColorKind = SessionChildHoverTipModel.StatusDotColorKind(statusKind: child.statusKind)
            metaItems = [sessionChildHoverTipStatusLabel(for: child.statusKind)]
            if let workspaceName = normalizedSidebarHelperText(workspaceName) {
                metaItems.append(workspaceName)
            }
        }

        return SessionChildHoverTipModel(
            name: child.displayName,
            typeLabel: typeLabel,
            statusDotColorKind: statusDotColorKind,
            bodyText: bodyText,
            executionProfileText: sessionChildExecutionProfileText(child.executionProfile),
            metaItems: metaItems
        )
    }

    static func sessionChildExecutionProfileText(
        _ profile: SessionAgentExecutionProfile?
    ) -> String? {
        guard let profile else { return nil }
        let components = [profile.modelIdentifier, profile.reasoningEffort]
            .compactMap(normalizedSidebarHelperText)
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    static func sessionChildHoverTipStatusLabel(for kind: SessionStatusKind?) -> String {
        switch kind ?? .idle {
        case .idle:
            return "idle"
        case .working:
            return "working"
        case .needsApproval:
            return "needs approval"
        case .ready:
            return "ready"
        case .error:
            return "error"
        }
    }

    static func abbreviatedPathLabel(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalizedPath = (trimmed as NSString).standardizingPath
        let pathString = normalizedPath as NSString
        let lastComponent = pathString.lastPathComponent
        if lastComponent.isEmpty == false, lastComponent != "/", pathString.pathComponents.count > 1 {
            return ".../\(lastComponent)"
        }
        return pathString.abbreviatingWithTildeInPath
    }
}
