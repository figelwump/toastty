import CoreState
import Foundation
import RemoteProtocol
import SwiftUI

@MainActor
enum SidebarSessionPresentation {
    /// Applies a workspace's display preference without changing runtime session order.
    static func orderedStatuses(
        _ statuses: [WorkspaceSessionStatus],
        panelOrder: [UUID]
    ) -> [WorkspaceSessionStatus] {
        guard panelOrder.isEmpty == false else { return statuses }
        var rank: [UUID: Int] = [:]
        for panelID in panelOrder where rank[panelID] == nil {
            rank[panelID] = rank.count
        }
        return statuses.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.panelID] ?? Int.max
            let right = rank[rhs.element.panelID] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    struct SessionDropTarget: Equatable {
        let panelID: UUID
        let placeAfter: Bool
    }

    /// Frames include expanded children and use the scroll viewport's coordinates.
    nonisolated static func sessionDropTarget(
        orderedRowIDs: [SidebarSessionRowID],
        frames: [SidebarSessionRowID: CGRect],
        source: SidebarSessionRowID,
        pointer: CGPoint,
        viewportHeight: CGFloat
    ) -> SessionDropTarget? {
        guard pointer.x.isFinite, pointer.y.isFinite,
              pointer.y >= 0, pointer.y < viewportHeight,
              orderedRowIDs.contains(source),
              orderedRowIDs.allSatisfy({ $0.workspaceID == source.workspaceID }),
              orderedRowIDs.count > 1 else { return nil }
        let measured = orderedRowIDs.compactMap { frames[$0] }
        guard measured.count == orderedRowIDs.count,
              measured.allSatisfy({ !$0.isEmpty && !$0.isInfinite && !$0.isNull }) else { return nil }
        let bounds = measured.reduce(CGRect.null) { $0.union($1) }
        guard bounds.contains(pointer) else { return nil }
        let candidates = orderedRowIDs.filter { $0 != source }
        for row in candidates {
            if let frame = frames[row], pointer.y < frame.midY {
                return SessionDropTarget(panelID: row.panelID, placeAfter: false)
            }
        }
        return candidates.last.map { SessionDropTarget(panelID: $0.panelID, placeAfter: true) }
    }

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

    /// Spelled-out status wording. Accessibility labels and hover cards use
    /// this; the row badge uses the shortened `sessionStatusBadgeLabel`.
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

    /// Row badges sit at the trailing edge of a narrow row, so "needs
    /// approval" shortens to "approval" there.
    static func sessionStatusBadgeLabel(for kind: SessionStatusKind) -> String {
        switch kind {
        case .needsApproval:
            return "approval"
        case .ready, .error, .idle, .working:
            return sessionStatusChipLabel(for: kind)
        }
    }

    /// The left gutter every session row reserves, so states line up down the
    /// list instead of shifting with the row's text.
    enum SessionRailState: Hashable {
        case empty
        case spinner
        case approvalDot
        case unreadDot
        case errorDot
    }

    nonisolated static func sessionRailState(
        for kind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> SessionRailState {
        switch kind {
        case .working:
            return .spinner
        case .needsApproval:
            return .approvalDot
        case .error:
            return .errorDot
        case .ready:
            return showsUnreadSessionAccent ? .unreadDot : .empty
        case .idle:
            return .empty
        }
    }

    nonisolated static func sessionRailLogValue(_ state: SessionRailState) -> String {
        switch state {
        case .empty:
            return "empty"
        case .spinner:
            return "spinner"
        case .approvalDot:
            return "approval_dot"
        case .unreadDot:
            return "unread_dot"
        case .errorDot:
            return "error_dot"
        }
    }

    /// Named sessions lead with their own name and push the summary to a second
    /// line; sessions the provider has not named yet lead with the summary.
    enum SessionRowShape: Equatable {
        case named(name: String, summary: String?)
        case summaryFirst(summary: String)
    }

    static func sessionRowShape(
        sessionName: String?,
        summary: String?,
        agentFallbackName: String
    ) -> SessionRowShape {
        let normalizedSummary = normalizedSidebarHelperText(summary)
        if let name = normalizedSidebarHelperText(sessionName) {
            return .named(name: name, summary: normalizedSummary)
        }
        return .summaryFirst(summary: normalizedSummary ?? agentFallbackName)
    }

    /// Lowercase provider identity, as the row's third line shows it.
    static func sessionAgentLabel(for agent: AgentKind) -> String {
        agent.rawValue
    }

    /// The summary-first shape falls back to the agent's display name when
    /// there is no summary yet; repeating the agent on the next line adds
    /// nothing, so the label drops out in that case.
    static func showsSessionAgentLabel(
        shape: SessionRowShape,
        agentFallbackName: String
    ) -> Bool {
        switch shape {
        case .named:
            return true
        case .summaryFirst(let summary):
            return summary != agentFallbackName
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

    /// Full terminal-session rows refer to main workspace tabs, not auxiliary panel tabs.
    static func sessionCustomTabTitle(
        for session: WorkspaceSessionStatus,
        in workspace: WorkspaceState?
    ) -> String? {
        guard let workspace,
              workspace.id == session.workspaceID,
              let tabID = workspace.tabID(containingPanelID: session.panelID),
              let tab = workspace.tab(id: tabID),
              tab.panels[session.panelID] != nil else { return nil }
        return tab.customTitle
    }

    static func sessionAccessibilityLabel(
        agentName: String,
        chipKind: SessionStatusKind?,
        projection: SessionStatusProjection = .none,
        childCount: Int = 0,
        detailText: String?,
        cwd: String?,
        isLaterFlagged: Bool,
        workspaceScopeHelpText: String? = nil,
        customTabTitle: String? = nil,
        agentLabel: String? = nil
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
            components.append(sessionSummaryPlainText(detailText))
        }
        if let cwd {
            components.append(cwd)
        }
        if let customTabTitle {
            components.append("Tab: \(customTabTitle)")
        }
        if let agentLabel = normalizedSidebarHelperText(agentLabel) {
            components.append(agentLabel)
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

    /// Tooltip text for a session row whose parent tag, scope tag, or
    /// waiting chip was dropped because the header did not fit.
    static func sessionRowCompactHelpText(
        parentSessionName: String?,
        workspaceScopeHelpText: String?,
        droppedWaitingChipLabel: String? = nil
    ) -> String? {
        var lines: [String] = []
        if let droppedWaitingChipLabel {
            lines.append("Status: \(droppedWaitingChipLabel)")
        }
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
        durationText(seconds: now.timeIntervalSince(startedAt))
    }

    static func durationText(seconds: TimeInterval) -> String {
        let clampedSeconds = Int(seconds.isFinite ? max(0, seconds) : 0)
        let minutes = clampedSeconds / 60
        let remainingSeconds = clampedSeconds % 60
        guard minutes > 0 else { return "\(remainingSeconds)s" }
        return String(format: "%dm %02ds", minutes, remainingSeconds)
    }

    /// Elapsed time for the turn a working row is in the middle of. Shares the
    /// sub-agent formatter so both read the same (`45s`, `4m 12s`).
    static func sessionElapsedTurnText(turnStartedAt: Date?, now: Date) -> String? {
        guard let turnStartedAt else { return nil }
        return elapsedChildActivityText(startedAt: turnStartedAt, now: now)
    }

    static func sessionLastTurnText(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return durationText(seconds: duration)
    }

    private static let relativeUpdatedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func sessionUpdatedRelativeText(updatedAt: Date, now: Date) -> String {
        relativeUpdatedFormatter.localizedString(for: min(updatedAt, now), relativeTo: now)
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

    /// Provider summaries arrive as Markdown. SwiftUI parses Markdown only
    /// from `LocalizedStringKey` literals, so a runtime `String` renders
    /// `**bold**` and backticks verbatim.
    ///
    /// Only inline syntax is interpreted: a sidebar row is one truncated line,
    /// so block structure cannot survive there anyway, and a leading bullet or
    /// heading marker is stripped rather than shown. Links keep their text and
    /// lose the link itself, because a row is not somewhere to click through.
    static func sessionSummaryAttributedText(_ text: String) -> AttributedString {
        let stripped = strippedLeadingBlockMarkers(text)
        guard stripped.isEmpty == false else { return AttributedString(text) }
        guard var attributed = try? AttributedString(
            markdown: stripped,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return AttributedString(stripped)
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].link = nil
        }
        return attributed
    }

    /// The same text with its Markdown resolved away, for accessibility labels
    /// and anywhere else that needs characters rather than styling.
    static func sessionSummaryPlainText(_ text: String) -> String {
        String(sessionSummaryAttributedText(text).characters)
    }

    /// Agents open a summary with a bullet, a heading, or a quote often enough
    /// that the marker is worth removing; nested markers are stripped too.
    private static func strippedLeadingBlockMarkers(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bounded so a line of nothing but markers cannot spin here.
        for _ in 0 ..< 4 {
            guard let shortened = droppingLeadingBlockMarker(result) else { break }
            result = shortened
        }
        return result
    }

    private static func droppingLeadingBlockMarker(_ text: String) -> String? {
        for marker in ["- ", "* ", "+ ", "> "] where text.hasPrefix(marker) {
            return String(text.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespaces)
        }

        let headingHashes = text.prefix { $0 == "#" }
        if headingHashes.isEmpty == false,
           text.dropFirst(headingHashes.count).hasPrefix(" ") {
            return String(text.dropFirst(headingHashes.count))
                .trimmingCharacters(in: .whitespaces)
        }

        let orderedDigits = text.prefix(while: \.isNumber)
        if orderedDigits.isEmpty == false,
           text.dropFirst(orderedDigits.count).hasPrefix(". ") {
            return String(text.dropFirst(orderedDigits.count + 2))
                .trimmingCharacters(in: .whitespaces)
        }

        return nil
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

    /// Everything the row stopped showing — the full path, the workspace
    /// scopes, the tab title, times — plus the untruncated summary.
    static func sessionRowHoverTipModel(
        session: WorkspaceSessionStatus,
        customTabTitle: String?,
        parentSessionName: String?,
        workspaceScopeNames: [String],
        isLaterFlagged: Bool,
        now: Date
    ) -> SessionRowHoverTipModel {
        let statusKind = session.status.kind
        var metaItems: [SessionRowHoverTipModel.MetaItem] = []

        if let path = normalizedSidebarHelperText(session.cwd) {
            metaItems.append(.init(label: "path", value: abbreviatedHomePathLabel(path), wraps: false))
        }

        if workspaceScopeNames.isEmpty == false {
            metaItems.append(.init(
                label: "scoped",
                value: workspaceScopeNames.joined(separator: ", "),
                wraps: true
            ))
        }
        metaItems.append(.init(
            label: "status",
            value: sessionHoverTipStatusValue(kind: statusKind, projection: session.projection),
            wraps: false
        ))
        metaItems.append(.init(
            label: "updated",
            value: sessionUpdatedRelativeText(updatedAt: session.updatedAt, now: now),
            wraps: false
        ))
        if session.turnStartedAt == nil,
           let lastTurn = sessionLastTurnText(session.lastTurnDuration) {
            metaItems.append(.init(label: "last turn", value: lastTurn, wraps: false))
        }
        if session.children.isEmpty == false {
            metaItems.append(.init(
                label: session.children.count == 1 ? "sub-agent" : "sub-agents",
                value: sessionChildSummaryValue(session.children),
                wraps: false
            ))
        }
        if let customTabTitle = normalizedSidebarHelperText(customTabTitle) {
            metaItems.append(.init(label: "tab", value: customTabTitle, wraps: false))
        }
        if let parentSessionName = normalizedSidebarHelperText(parentSessionName) {
            metaItems.append(.init(label: "parent", value: parentSessionName, wraps: false))
        }
        if isLaterFlagged {
            metaItems.append(.init(label: "flagged", value: "for later", wraps: false))
        }

        return SessionRowHoverTipModel(
            name: session.displayTitle,
            agentLabel: sessionAgentLabel(for: session.agent),
            statusDotColorKind: SessionChildHoverTipModel.StatusDotColorKind(statusKind: statusKind),
            bodyText: normalizedSidebarHelperText(session.status.detail),
            turnStartedAt: session.turnStartedAt,
            metaItems: metaItems
        )
    }

    static func sessionHoverTipStatusValue(
        kind: SessionStatusKind,
        projection: SessionStatusProjection
    ) -> String {
        if case .waitingOnChildren(let childCount, _) = projection {
            return childCount == 1
                ? "waiting on 1 sub-agent"
                : "waiting on \(childCount) sub-agents"
        }
        if case .resuming = projection {
            return "resuming"
        }
        return sessionChildHoverTipStatusLabel(for: kind)
    }

    private static func sessionChildSummaryValue(_ children: [SessionChildRow]) -> String {
        let workingCount = children.filter { $0.statusKind == .working || $0.source == .activity }.count
        guard workingCount > 0 else { return "\(children.count)" }
        return "\(children.count) · \(workingCount) working"
    }

    /// The card has room for the whole path, so it keeps every component and
    /// only shortens the home directory to `~`, rather than collapsing to the
    /// last component the way a row does.
    static func abbreviatedHomePathLabel(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).abbreviatingWithTildeInPath
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
