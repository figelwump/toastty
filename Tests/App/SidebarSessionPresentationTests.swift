@testable import ToasttyApp
import CoreState
import SwiftUI
import XCTest

@MainActor
final class SidebarSessionPresentationTests: XCTestCase {
    private func makeWorkspace(
        title: String,
        hasBeenVisited: Bool = true
    ) -> WorkspaceState {
        let tab = WorkspaceTabState.bootstrap(terminalTitle: "\(title) Terminal")
        return WorkspaceState(
            id: UUID(),
            title: title,
            hasBeenVisited: hasBeenVisited,
            selectedTabID: tab.id,
            tabIDs: [tab.id],
            tabsByID: [tab.id: tab]
        )
    }

    private func makeSidebarSessionRowIDs(
        count: Int,
        workspaceID: UUID = UUID()
    ) -> [SidebarSessionPresentation.SidebarSessionRowID] {
        (0..<count).map { index in
            SidebarSessionPresentation.SidebarSessionRowID(
                workspaceID: workspaceID,
                sessionID: "session-\(index)",
                panelID: UUID()
            )
        }
    }

    private func localDate(hour: Int, minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 9,
            hour: hour,
            minute: minute
        )))
    }

    func testAbbreviatedPathLabelKeepsOnlyLastPathComponent() {
        XCTAssertEqual(SidebarSessionPresentation.abbreviatedPathLabel("/Users/vishal/GiantThings/repos/toastty-session-status"), ".../toastty-session-status")
        XCTAssertEqual(SidebarSessionPresentation.abbreviatedPathLabel("/"), "/")
        XCTAssertEqual(SidebarSessionPresentation.abbreviatedPathLabel("relative"), "relative")
    }

    func testSessionStatusChipKindShowsPersistentUnresolvedAndUnreadReady() {
        XCTAssertNil(
            SidebarSessionPresentation.sessionStatusChipKind(
                for: SessionStatus(kind: .idle, summary: "Idle"),
                showsUnreadSessionAccent: true
            )
        )
        XCTAssertNil(
            SidebarSessionPresentation.sessionStatusChipKind(
                for: SessionStatus(kind: .working, summary: "Working"),
                showsUnreadSessionAccent: true
            )
        )
        XCTAssertNil(
            SidebarSessionPresentation.sessionStatusChipKind(
                for: SessionStatus(kind: .ready, summary: "Ready"),
                showsUnreadSessionAccent: false
            )
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionStatusChipKind(
                for: SessionStatus(kind: .needsApproval, summary: "Needs approval"),
                showsUnreadSessionAccent: false
            ),
            .needsApproval
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionStatusChipKind(
                for: SessionStatus(kind: .ready, summary: "Ready"),
                showsUnreadSessionAccent: true
            ),
            .ready
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionStatusChipKind(
                for: SessionStatus(kind: .error, summary: "Error"),
                showsUnreadSessionAccent: false
            ),
            .error
        )
    }

    func testSessionStatusProjectionChipLabelShowsWaitingOnly() {
        XCTAssertEqual(
            SidebarSessionPresentation.sessionStatusProjectionChipLabel(
                for: .waitingOnChildren(childCount: 2, pendingBackgroundTaskCount: 0)
            ),
            "waiting"
        )
        XCTAssertNil(SidebarSessionPresentation.sessionStatusProjectionChipLabel(for: .resuming))
        XCTAssertNil(SidebarSessionPresentation.sessionStatusProjectionChipLabel(for: .none))
    }

    func testSessionAccessibilityLabelIncludesWaitingProjection() {
        XCTAssertEqual(
            SidebarSessionPresentation.sessionAccessibilityLabel(
                agentName: "Claude Code",
                chipKind: nil,
                projection: .waitingOnChildren(childCount: 1, pendingBackgroundTaskCount: 0),
                childCount: 2,
                detailText: "Reviewing changes",
                cwd: ".../toastty",
                isLaterFlagged: false
            ),
            "Claude Code, waiting, 2 sub-agents, Reviewing changes, .../toastty"
        )
    }

    func testSessionRowCompactHelpTextCarriesHiddenParentAndScopeInfo() {
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowCompactHelpText(
                parentSessionName: "Claude",
                workspaceScopeHelpText: "Scoped to Review."
            ),
            "Parent session: Claude\nScoped to Review."
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowCompactHelpText(
                parentSessionName: "Claude",
                workspaceScopeHelpText: nil
            ),
            "Parent session: Claude"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowCompactHelpText(
                parentSessionName: nil,
                workspaceScopeHelpText: nil,
                droppedWaitingChipLabel: "waiting"
            ),
            "Status: waiting"
        )
        XCTAssertNil(
            SidebarSessionPresentation.sessionRowCompactHelpText(
                parentSessionName: nil,
                workspaceScopeHelpText: nil
            )
        )
        XCTAssertEqual(SidebarSessionPresentation.parentSessionTagLabel(parentName: "Claude"), "↖ Claude")
    }

    func testSessionChildRowsDefaultExpandedAndNeedAttentionForApprovalOrError() {
        XCTAssertTrue(
            SidebarSessionPresentation.sessionChildRowsExpanded(
                sessionID: "parent",
                expandedSessionChildrenBySessionID: [:]
            )
        )
        XCTAssertFalse(
            SidebarSessionPresentation.sessionChildRowsExpanded(
                sessionID: "parent",
                expandedSessionChildrenBySessionID: ["parent": false]
            )
        )
        XCTAssertTrue(
            SidebarSessionPresentation.sessionChildRowsNeedAttention([
                SessionChildRow(
                    id: "child",
                    source: .session,
                    displayName: "Claude Code",
                    startedAt: Date(timeIntervalSince1970: 1),
                    statusKind: .needsApproval
                ),
            ])
        )
        XCTAssertFalse(
            SidebarSessionPresentation.sessionChildRowsNeedAttention([
                SessionChildRow(
                    id: "activity",
                    source: .activity,
                    displayName: "Explore",
                    startedAt: Date(timeIntervalSince1970: 1)
                ),
            ])
        )
    }

    func testSessionChildFocusTargetRoutesSessionsToChildAndActivitiesToParent() {
        let parentWorkspaceID = UUID()
        let parentPanelID = UUID()
        let childWorkspaceID = UUID()
        let childPanelID = UUID()

        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildFocusTarget(
                for: SessionChildRow(
                    id: "activity",
                    source: .activity,
                    displayName: "Explore",
                    startedAt: Date(timeIntervalSince1970: 1)
                ),
                parentWorkspaceID: parentWorkspaceID,
                parentPanelID: parentPanelID
            ),
            SidebarSessionPresentation.SessionChildFocusTarget(workspaceID: parentWorkspaceID, panelID: parentPanelID)
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildFocusTarget(
                for: SessionChildRow(
                    id: "child",
                    source: .session,
                    displayName: "Codex",
                    startedAt: Date(timeIntervalSince1970: 1),
                    panelID: childPanelID,
                    workspaceID: childWorkspaceID,
                    sessionID: "child"
                ),
                parentWorkspaceID: parentWorkspaceID,
                parentPanelID: parentPanelID
            ),
            SidebarSessionPresentation.SessionChildFocusTarget(workspaceID: childWorkspaceID, panelID: childPanelID)
        )
    }

    func testSessionChildWorkspaceTagShowsOnlyForDifferentWorkspace() {
        let parentWorkspaceID = UUID()
        let childWorkspaceID = UUID()
        let child = SessionChildRow(
            id: "child",
            source: .session,
            displayName: "Claude Code",
            startedAt: Date(timeIntervalSince1970: 1),
            panelID: UUID(),
            workspaceID: childWorkspaceID,
            sessionID: "child"
        )

        XCTAssertEqual(
            SidebarSessionPresentation.childWorkspaceTagLabel(
                for: child,
                parentWorkspaceID: parentWorkspaceID,
                workspaceNamesByID: [childWorkspaceID: "wt-sessions"]
            ),
            "wt-sessions"
        )
        XCTAssertNil(
            SidebarSessionPresentation.childWorkspaceTagLabel(
                for: SessionChildRow(
                    id: "same",
                    source: .session,
                    displayName: "Codex",
                    startedAt: Date(timeIntervalSince1970: 1),
                    panelID: UUID(),
                    workspaceID: parentWorkspaceID,
                    sessionID: "same"
                ),
                parentWorkspaceID: parentWorkspaceID,
                workspaceNamesByID: [parentWorkspaceID: "toastty"]
            )
        )
    }

    func testSessionChildHoverTipModelCarriesActivityDescriptionAndMeta() throws {
        let start = try localDate(hour: 12, minute: 4)

        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildHoverTipModel(
                child: SessionChildRow(
                    id: "activity",
                    source: .activity,
                    displayName: "Explore",
                    context: "agent: find session log callers",
                    executionProfile: SessionAgentExecutionProfile(
                        modelIdentifier: "gpt-5.6-luna",
                        reasoningEffort: "xhigh"
                    ),
                    startedAt: start
                ),
                workspaceName: nil,
                elapsedText: "2m 30s",
                now: start.addingTimeInterval(150)
            ),
            SessionChildHoverTipModel(
                name: "Explore",
                typeLabel: "sub-agent",
                statusDotColorKind: .working,
                bodyText: "agent: find session log callers",
                executionProfileText: "gpt-5.6-luna · xhigh",
                metaItems: ["running · 2m 30s", "started 12:04"]
            )
        )
    }

    func testSessionChildHoverTipModelCarriesSessionApprovalAndRemoteWorkspace() throws {
        let start = try localDate(hour: 12, minute: 4)

        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildHoverTipModel(
                child: SessionChildRow(
                    id: "child-session",
                    source: .session,
                    displayName: "Claude Code",
                    context: "Approve Bash: git push",
                    startedAt: start,
                    statusKind: .needsApproval,
                    sessionID: "child-session"
                ),
                workspaceName: "wt-sessions",
                elapsedText: nil,
                now: start
            ),
            SessionChildHoverTipModel(
                name: "Claude Code",
                typeLabel: "session",
                statusDotColorKind: .needsApproval,
                bodyText: "Approve Bash: git push",
                executionProfileText: nil,
                metaItems: ["needs approval", "wt-sessions"]
            )
        )
    }

    func testSessionChildHoverTipModelCarriesBareChild() throws {
        let start = try localDate(hour: 12, minute: 4)

        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildHoverTipModel(
                child: SessionChildRow(
                    id: "bare",
                    source: .activity,
                    displayName: "Codex",
                    context: nil,
                    startedAt: start
                ),
                workspaceName: nil,
                elapsedText: nil,
                now: start
            ),
            SessionChildHoverTipModel(
                name: "Codex",
                typeLabel: "sub-agent",
                statusDotColorKind: .working,
                bodyText: nil,
                executionProfileText: nil,
                metaItems: ["running · 0s", "started 12:04"]
            )
        )
    }

    func testElapsedChildActivityTextFormatsSecondsAndMinutes() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            SidebarSessionPresentation.elapsedChildActivityText(startedAt: start, now: start.addingTimeInterval(52)),
            "52s"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.elapsedChildActivityText(startedAt: start, now: start.addingTimeInterval(242)),
            "4m 02s"
        )
    }

    func testSessionChildAccessibilityLabelIncludesStatusContextWorkspaceAndElapsed() {
        let child = SessionChildRow(
            id: "child",
            source: .session,
            displayName: "Claude Code",
            context: "Approve Bash: git push",
            startedAt: Date(timeIntervalSince1970: 1),
            statusKind: .needsApproval,
            panelID: UUID(),
            workspaceID: UUID(),
            sessionID: "child"
        )

        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildAccessibilityLabel(
                child: child,
                workspaceTag: "wt-sessions",
                elapsedText: nil
            ),
            "session child, Claude Code, needs approval, Approve Bash: git push, wt-sessions"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildAccessibilityLabel(
                child: SessionChildRow(
                    id: "activity",
                    source: .activity,
                    displayName: "Explore",
                    context: "find session callers",
                    executionProfile: SessionAgentExecutionProfile(
                        modelIdentifier: "gpt-5.6-luna",
                        reasoningEffort: "xhigh"
                    ),
                    startedAt: Date(timeIntervalSince1970: 1)
                ),
                workspaceTag: nil,
                elapsedText: "3m"
            ),
            "activity child, Explore, find session callers, model gpt-5.6-luna, reasoning effort xhigh, 3m"
        )
    }

    func testSessionChildExecutionProfileTextShowsAvailableFieldsOnly() {
        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildExecutionProfileText(
                SessionAgentExecutionProfile(modelIdentifier: "gpt-5.6-sol")
            ),
            "gpt-5.6-sol"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionChildExecutionProfileText(
                SessionAgentExecutionProfile(reasoningEffort: "high")
            ),
            "high"
        )
        XCTAssertNil(SidebarSessionPresentation.sessionChildExecutionProfileText(nil))
    }

    func testSessionIndicatorStateShowsSpinnerOnlyForWorking() {
        XCTAssertEqual(SidebarSessionPresentation.sessionIndicatorState(for: .working), .spinner)
        XCTAssertEqual(SidebarSessionPresentation.sessionIndicatorState(for: .idle), .hidden)
        XCTAssertEqual(SidebarSessionPresentation.sessionIndicatorState(for: .needsApproval), .hidden)
        XCTAssertEqual(SidebarSessionPresentation.sessionIndicatorState(for: .ready), .hidden)
        XCTAssertEqual(SidebarSessionPresentation.sessionIndicatorState(for: .error), .hidden)
    }

    func testLaterFlagActionTitleUsesLaterCopy() {
        XCTAssertEqual(SidebarSessionPresentation.laterFlagActionTitle(isFlaggedForLater: false), "Flag for Later")
        XCTAssertEqual(SidebarSessionPresentation.laterFlagActionTitle(isFlaggedForLater: true), "Clear Later Flag")
    }

    func testWorkspaceAccessibilityLabelIncludesAgentSummary() {
        let workspace = makeWorkspace(title: "Build")

        XCTAssertEqual(
            SidebarSessionPresentation.workspaceAccessibilityLabel(
                for: workspace,
                isSelected: true,
                agentSummary: WorkspaceAgentSummary(running: 3, active: 1)
            ),
            "Build, 1 active, 3 running"
        )
    }

    func testWorkspaceAccessibilityLabelKeepsNewBadgeWordingWithAgentSummary() {
        let workspace = makeWorkspace(title: "Draft", hasBeenVisited: false)

        XCTAssertEqual(
            SidebarSessionPresentation.workspaceAccessibilityLabel(
                for: workspace,
                isSelected: false,
                agentSummary: WorkspaceAgentSummary(running: 2, active: 0)
            ),
            "Draft New, 0 active, 2 running"
        )
    }

    func testUnreadSessionTypographyUsesEmphasizedWeights() {
        XCTAssertEqual(SidebarSessionPresentation.sessionAgentFontWeight(showsUnreadSessionAccent: false), .medium)
        XCTAssertEqual(SidebarSessionPresentation.sessionAgentFontWeight(showsUnreadSessionAccent: true), .heavy)
        XCTAssertEqual(SidebarSessionPresentation.sessionBodyFontWeight(showsUnreadSessionAccent: false), .regular)
        XCTAssertEqual(SidebarSessionPresentation.sessionBodyFontWeight(showsUnreadSessionAccent: true), .bold)
    }

    func testWorkingSessionTextUsesItalicOnlyWhileWorking() {
        XCTAssertTrue(SidebarSessionPresentation.sessionTextUsesItalic(for: .working))
        XCTAssertFalse(SidebarSessionPresentation.sessionTextUsesItalic(for: .idle))
        XCTAssertFalse(SidebarSessionPresentation.sessionTextUsesItalic(for: .needsApproval))
        XCTAssertFalse(SidebarSessionPresentation.sessionTextUsesItalic(for: .ready))
        XCTAssertFalse(SidebarSessionPresentation.sessionTextUsesItalic(for: .error))
    }

    func testUnvisitedWorkspaceTitleUsesEmphasizedWeight() {
        XCTAssertEqual(
            SidebarSessionPresentation.workspaceTitleFontWeight(isSelected: false, hasBeenVisited: false),
            .semibold
        )
        XCTAssertEqual(
            SidebarSessionPresentation.workspaceTitleFontWeight(isSelected: false, hasBeenVisited: true),
            .medium
        )
    }

    func testNewWorkspaceBadgeShowsOnlyForInactiveUnvisitedWorkspaces() {
        XCTAssertTrue(
            SidebarSessionPresentation.showsNewWorkspaceBadge(isSelected: false, hasBeenVisited: false)
        )
        XCTAssertFalse(
            SidebarSessionPresentation.showsNewWorkspaceBadge(isSelected: true, hasBeenVisited: false)
        )
        XCTAssertFalse(
            SidebarSessionPresentation.showsNewWorkspaceBadge(isSelected: false, hasBeenVisited: true)
        )
    }

    func testHiddenSessionPillStateReturnsEmptyWhenListFitsViewport() {
        let rows = makeSidebarSessionRowIDs(count: 3)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 40, width: 240, height: 32),
                rows[1]: CGRect(x: 0, y: 76, width: 240, height: 32),
                rows[2]: CGRect(x: 0, y: 112, width: 240, height: 32),
            ],
            unreadSessionRowIDs: [],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertNil(state.above)
        XCTAssertNil(state.below)
    }

    func testHiddenSessionPillStateCountsOnlyBelowAtTopOfList() {
        let rows = makeSidebarSessionRowIDs(count: 4)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 40, width: 240, height: 36),
                rows[1]: CGRect(x: 0, y: 82, width: 240, height: 36),
                rows[2]: CGRect(x: 0, y: 205, width: 240, height: 36),
                rows[3]: CGRect(x: 0, y: 247, width: 240, height: 36),
            ],
            unreadSessionRowIDs: [rows[3]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertNil(state.above)
        XCTAssertEqual(state.below?.direction, .below)
        XCTAssertEqual(state.below?.count, 2)
        XCTAssertEqual(state.below?.unreadCount, 1)
    }

    func testHiddenSessionPillStateCountsBothDirectionsInMiddle() {
        let rows = makeSidebarSessionRowIDs(count: 6)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: -90, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: -20, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 24, width: 240, height: 40),
                rows[3]: CGRect(x: 0, y: 90, width: 240, height: 40),
                rows[4]: CGRect(x: 0, y: 180, width: 240, height: 35),
                rows[5]: CGRect(x: 0, y: 210, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [rows[0]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(state.above?.count, 2)
        XCTAssertEqual(state.above?.unreadCount, 1)
        XCTAssertEqual(state.below?.count, 1)
        XCTAssertEqual(state.below?.unreadCount, 0)
    }

    func testHiddenSessionPillStateCountsOnlyAboveAtBottomOfList() {
        let rows = makeSidebarSessionRowIDs(count: 3)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: -90, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: -45, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 52, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(state.above?.direction, .above)
        XCTAssertEqual(state.above?.count, 2)
        XCTAssertNil(state.below)
    }

    func testHiddenSessionPillStateKeepsBarelyVisibleRowsHidden() {
        let rows = makeSidebarSessionRowIDs(count: 3)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 0, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: 80, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 185, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [rows[0], rows[1]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(state.above?.count, 1)
        XCTAssertEqual(state.above?.unreadCount, 1)
        XCTAssertEqual(state.below?.count, 1)
        XCTAssertEqual(state.below?.unreadCount, 0)
    }

    func testHiddenSessionPillStateTreatsHalfVisibleRowsAsVisible() {
        let rows = makeSidebarSessionRowIDs(count: 2)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 13.5, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: 178.5, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [rows[0], rows[1]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertNil(state.above)
        XCTAssertNil(state.below)
    }

    func testHiddenSessionPillStateKeepsLowerRowsHiddenAfterNearestBelowBecomesVisible() {
        let rows = makeSidebarSessionRowIDs(count: 3)
        let barelyVisibleState = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 80, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: 185, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 230, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [],
            viewportHeight: 200,
            visibleTop: 32
        )
        let nearestVisibleState = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 80, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: 178.5, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 230, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(barelyVisibleState.below?.count, 2)
        XCTAssertEqual(nearestVisibleState.below?.count, 1)
    }

    func testHiddenSessionPillStateUsesVisibleHeightThresholdWithBoundaryEpsilon() {
        let rows = makeSidebarSessionRowIDs(count: 4)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: 13.4, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: 13.5, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 178.5, width: 240, height: 40),
                rows[3]: CGRect(x: 0, y: 178.6, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [],
            viewportHeight: 200,
            visibleTop: 32,
            epsilon: 1.5
        )

        XCTAssertEqual(state.above?.count, 1)
        XCTAssertEqual(state.below?.count, 1)
    }

    func testHiddenSessionPillStateTreatsViewportSpanningTallRowAsVisible() {
        let rows = makeSidebarSessionRowIDs(count: 1)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: -200, width: 240, height: 600),
            ],
            unreadSessionRowIDs: [rows[0]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertNil(state.above)
        XCTAssertNil(state.below)
    }

    func testHiddenSessionPillStateAggregatesUnreadOnlyFromHiddenRows() {
        let rows = makeSidebarSessionRowIDs(count: 4)
        let framesByID: [SidebarSessionPresentation.SidebarSessionRowID: CGRect] = [
            rows[0]: CGRect(x: 0, y: -70, width: 240, height: 40),
            rows[1]: CGRect(x: 0, y: 60, width: 240, height: 40),
            rows[2]: CGRect(x: 0, y: 110, width: 240, height: 40),
            rows[3]: CGRect(x: 0, y: 220, width: 240, height: 40),
        ]
        let visibleUnreadState = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: framesByID,
            unreadSessionRowIDs: [rows[1]],
            viewportHeight: 200,
            visibleTop: 32
        )
        let hiddenUnreadState = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: framesByID,
            unreadSessionRowIDs: [rows[0], rows[3]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(visibleUnreadState.above?.unreadCount, 0)
        XCTAssertEqual(visibleUnreadState.below?.unreadCount, 0)
        XCTAssertEqual(hiddenUnreadState.above?.unreadCount, 1)
        XCTAssertEqual(hiddenUnreadState.below?.unreadCount, 1)
    }

    func testHiddenSessionPillStateAggregatesWorkingOnlyFromHiddenRows() {
        let rows = makeSidebarSessionRowIDs(count: 4)
        let framesByID: [SidebarSessionPresentation.SidebarSessionRowID: CGRect] = [
            rows[0]: CGRect(x: 0, y: -70, width: 240, height: 40),
            rows[1]: CGRect(x: 0, y: 60, width: 240, height: 40),
            rows[2]: CGRect(x: 0, y: 110, width: 240, height: 40),
            rows[3]: CGRect(x: 0, y: 220, width: 240, height: 40),
        ]
        let visibleWorkingState = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: framesByID,
            unreadSessionRowIDs: [],
            workingSessionRowIDs: [rows[1]],
            viewportHeight: 200,
            visibleTop: 32
        )
        let hiddenWorkingState = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: framesByID,
            unreadSessionRowIDs: [],
            workingSessionRowIDs: [rows[0], rows[3]],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(visibleWorkingState.above?.hasWorking, false)
        XCTAssertEqual(visibleWorkingState.below?.hasWorking, false)
        XCTAssertEqual(hiddenWorkingState.above?.hasWorking, true)
        XCTAssertEqual(hiddenWorkingState.below?.hasWorking, true)
    }

    func testHiddenSessionPillStateDefaultsWorkingRowsToEmpty() {
        let rows = makeSidebarSessionRowIDs(count: 4)
        let state = SidebarSessionPresentation.hiddenSessionPillState(
            orderedSessionRowIDs: rows,
            measuredSessionRowFramesByID: [
                rows[0]: CGRect(x: 0, y: -70, width: 240, height: 40),
                rows[1]: CGRect(x: 0, y: 60, width: 240, height: 40),
                rows[2]: CGRect(x: 0, y: 110, width: 240, height: 40),
                rows[3]: CGRect(x: 0, y: 220, width: 240, height: 40),
            ],
            unreadSessionRowIDs: [],
            viewportHeight: 200,
            visibleTop: 32
        )

        XCTAssertEqual(state.above?.hasWorking, false)
        XCTAssertEqual(state.below?.hasWorking, false)
    }

    func testHiddenSessionPillAccessibilityLabelIncludesSignalStates() {
        XCTAssertEqual(
            SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(
                SidebarSessionPresentation.HiddenSessionPill(
                    direction: .above,
                    count: 1,
                    unreadCount: 0,
                    hasWorking: false
                )
            ),
            "1 session hidden above"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(
                SidebarSessionPresentation.HiddenSessionPill(
                    direction: .below,
                    count: 3,
                    unreadCount: 0,
                    hasWorking: false
                )
            ),
            "3 sessions hidden below"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(
                SidebarSessionPresentation.HiddenSessionPill(
                    direction: .below,
                    count: 3,
                    unreadCount: 2,
                    hasWorking: false
                )
            ),
            "3 sessions hidden below, 2 unread"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(
                SidebarSessionPresentation.HiddenSessionPill(
                    direction: .below,
                    count: 3,
                    unreadCount: 0,
                    hasWorking: true
                )
            ),
            "3 sessions hidden below, working"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.hiddenSessionPillAccessibilityLabel(
                SidebarSessionPresentation.HiddenSessionPill(
                    direction: .below,
                    count: 3,
                    unreadCount: 2,
                    hasWorking: true
                )
            ),
            "3 sessions hidden below, 2 unread, working"
        )
    }

    func testHiddenSessionScrollTargetJumpsToListExtremes() {
        let workspaceIDs = [UUID(), UUID(), UUID()]

        let above = SidebarSessionPresentation.hiddenSessionScrollTarget(for: .above, orderedWorkspaceIDs: workspaceIDs)
        let below = SidebarSessionPresentation.hiddenSessionScrollTarget(for: .below, orderedWorkspaceIDs: workspaceIDs)

        XCTAssertEqual(above?.workspaceID, workspaceIDs.first)
        XCTAssertEqual(above?.anchor, .top)
        XCTAssertEqual(below?.workspaceID, workspaceIDs.last)
        XCTAssertEqual(below?.anchor, .bottom)
    }

    func testHiddenSessionScrollTargetIsNilWithoutWorkspaces() {
        XCTAssertNil(SidebarSessionPresentation.hiddenSessionScrollTarget(for: .above, orderedWorkspaceIDs: []))
        XCTAssertNil(SidebarSessionPresentation.hiddenSessionScrollTarget(for: .below, orderedWorkspaceIDs: []))
    }

    func testBackgroundTabSessionPanelRemainsFocusable() throws {
        let backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let panelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )

        XCTAssertTrue(SidebarSessionPresentation.canFocusSessionPanel(panelID, in: workspace))
    }

    func testUnreadSessionAccentUsesPanelTabUnreadStateAcrossTabs() throws {
        var backgroundTab = WorkspaceTabState.bootstrap(terminalTitle: "Background Agent")
        let selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let backgroundPanelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        backgroundTab.unreadPanelIDs = [backgroundPanelID]
        let workspaceID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [backgroundTab.id, selectedTab.id],
            tabsByID: [
                backgroundTab.id: backgroundTab,
                selectedTab.id: selectedTab,
            ]
        )

        XCTAssertTrue(
            SidebarSessionPresentation.showsUnreadSessionAccent(
                for: backgroundPanelID,
                in: workspace,
                selectedWorkspaceID: workspaceID,
                selectedPanelID: selectedPanelID
            )
        )
    }

    func testUnreadSessionAccentSuppressesFocusedPanelInSelectedWorkspace() throws {
        var selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Foreground Terminal")
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        selectedTab.unreadPanelIDs = [selectedPanelID]
        let workspaceID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "One",
            selectedTabID: selectedTab.id,
            tabIDs: [selectedTab.id],
            tabsByID: [selectedTab.id: selectedTab]
        )

        XCTAssertFalse(
            SidebarSessionPresentation.showsUnreadSessionAccent(
                for: selectedPanelID,
                in: workspace,
                selectedWorkspaceID: workspaceID,
                selectedPanelID: selectedPanelID
            )
        )
    }
}
