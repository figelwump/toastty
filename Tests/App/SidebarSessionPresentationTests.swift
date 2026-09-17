@testable import ToasttyApp
import CoreState
import SwiftUI
import XCTest

@MainActor
final class SidebarSessionPresentationTests: XCTestCase {
    func testSavedPanelOrderPreservesDefaultAndAppendsUnlistedSessions() {
        let panels = (0..<4).map { _ in UUID() }
        let statuses = panels.enumerated().map { index, panelID in
            WorkspaceSessionStatus(
                sessionID: "session-\(index)", panelID: panelID, agent: .codex,
                status: SessionStatus(kind: .working, summary: "Working"),
                cwd: nil, updatedAt: Date(), isActive: true
            )
        }
        XCTAssertEqual(SidebarSessionPresentation.orderedStatuses(statuses, panelOrder: []), statuses)
        let saved = [panels[2], UUID(), panels[0], panels[2]]
        XCTAssertEqual(
            SidebarSessionPresentation.orderedStatuses(statuses, panelOrder: saved).map(\.panelID),
            [panels[2], panels[0], panels[1], panels[3]]
        )
        var restarted = statuses
        restarted[2].sessionID = "replacement-session"
        restarted[2].status = SessionStatus(kind: .ready, summary: "Ready")
        // A replacement arrives last in registry order but retains its panel's position.
        let replacement = restarted.remove(at: 2)
        restarted.append(replacement)
        XCTAssertEqual(
            SidebarSessionPresentation.orderedStatuses(restarted, panelOrder: saved).first?.sessionID,
            "replacement-session"
        )
        XCTAssertEqual(
            SidebarSessionPresentation.orderedStatuses(statuses.filter { $0.panelID != panels[2] }, panelOrder: saved).map(\.panelID),
            [panels[0], panels[1], panels[3]]
        )
    }

    func testSessionDropTargetsUseExpandedGroupBoundsAndRejectOtherWorkspaces() {
        let rows = makeSidebarSessionRowIDs(count: 3)
        let frames = [
            rows[0]: CGRect(x: 10, y: 20, width: 200, height: 40),
            rows[1]: CGRect(x: 10, y: 64, width: 200, height: 120),
            rows[2]: CGRect(x: 10, y: 188, width: 200, height: 40),
        ]
        func target(_ source: Int, _ x: CGFloat, _ y: CGFloat) -> SidebarSessionPresentation.SessionDropTarget? {
            SidebarSessionPresentation.sessionDropTarget(
                orderedRowIDs: rows, frames: frames, source: rows[source],
                pointer: CGPoint(x: x, y: y), viewportHeight: 240
            )
        }
        XCTAssertEqual(target(2, 100, 20), .init(panelID: rows[0].panelID, placeAfter: false))
        XCTAssertEqual(target(0, 100, 227), .init(panelID: rows[2].panelID, placeAfter: true))
        // Crossing the parent's header alone must not skip its expanded children.
        XCTAssertEqual(target(0, 100, 100), .init(panelID: rows[1].panelID, placeAfter: false))
        XCTAssertEqual(target(0, 100, 170), .init(panelID: rows[2].panelID, placeAfter: false))
        XCTAssertNil(target(0, 100, 10))
        XCTAssertNil(target(0, 100, 240))
        XCTAssertNil(target(0, 220, 150))
        XCTAssertNil(target(0, .nan, 150))
        var missing = frames
        missing.removeValue(forKey: rows[1])
        XCTAssertNil(SidebarSessionPresentation.sessionDropTarget(
            orderedRowIDs: rows, frames: missing, source: rows[0],
            pointer: CGPoint(x: 100, y: 150), viewportHeight: 240
        ))
        let foreign = makeSidebarSessionRowIDs(count: 1)[0]
        XCTAssertNil(SidebarSessionPresentation.sessionDropTarget(
            orderedRowIDs: rows + [foreign], frames: frames, source: rows[0],
            pointer: CGPoint(x: 100, y: 150), viewportHeight: 240
        ))
    }

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

    func testSessionCustomTabTitleRequiresExplicitNameEvenInSingleTabWorkspace() throws {
        var workspace = makeWorkspace(title: "Workspace")
        let tabID = try XCTUnwrap(workspace.selectedTabID)
        let session = try makeSession(in: workspace)

        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace))
        workspace.tabsByID[tabID]?.customTitle = "orchestrator"
        XCTAssertEqual(
            SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace),
            "orchestrator"
        )
    }

    func testSessionCustomTabTitleUsesContainingTabInsteadOfSelectedTabOrScope() throws {
        var workspace = makeWorkspace(title: "Workspace")
        let owningTabID = try XCTUnwrap(workspace.selectedTabID)
        workspace.tabsByID[owningTabID]?.customTitle = "orchestrator"
        var session = try makeSession(in: workspace)
        session.scopedWorkspaceIDs = [UUID()]
        var selectedTab = WorkspaceTabState.bootstrap(terminalTitle: "Automatic title")
        selectedTab.customTitle = "review"
        workspace.appendTab(selectedTab, select: true)

        XCTAssertEqual(workspace.selectedTabID, selectedTab.id)
        XCTAssertEqual(
            SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace),
            "orchestrator"
        )
    }

    func testSessionCustomTabTitleRejectsMissingWorkspaceWrongOwnerPanelAndTab() throws {
        var workspace = makeWorkspace(title: "Workspace")
        let tabID = try XCTUnwrap(workspace.selectedTabID)
        workspace.tabsByID[tabID]?.customTitle = "orchestrator"
        let session = try makeSession(in: workspace)
        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: nil))

        var wrongOwner = session
        wrongOwner.workspaceID = UUID()
        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: wrongOwner, in: workspace))

        var missingPanel = workspace
        missingPanel.tabsByID[tabID]?.panels.removeValue(forKey: session.panelID)
        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: missingPanel))

        var orphanedPanel = workspace
        orphanedPanel.tabsByID[tabID]?.layoutTree = .slot(slotID: UUID(), panelID: UUID())
        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: orphanedPanel))

        workspace.tabsByID.removeValue(forKey: tabID)
        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace))
    }

    func testSessionCustomTabTitleReflectsRenameClearAndPanelMovement() throws {
        var workspace = makeWorkspace(title: "Workspace")
        let originalTabID = try XCTUnwrap(workspace.selectedTabID)
        let session = try makeSession(in: workspace)
        workspace.tabsByID[originalTabID]?.customTitle = "orchestrator"
        XCTAssertEqual(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace), "orchestrator")

        workspace.tabsByID[originalTabID]?.customTitle = "renamed"
        XCTAssertEqual(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace), "renamed")
        workspace.tabsByID[originalTabID]?.customTitle = nil
        XCTAssertNil(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace))

        let panel = try XCTUnwrap(workspace.tabsByID[originalTabID]?.panels[session.panelID])
        let replacementTab = WorkspaceTabState.bootstrap()
        workspace.tabsByID[originalTabID]?.customTitle = "renamed"
        workspace.tabsByID[originalTabID]?.layoutTree = replacementTab.layoutTree
        workspace.tabsByID[originalTabID]?.panels = replacementTab.panels
        workspace.tabsByID[originalTabID]?.focusedPanelID = replacementTab.focusedPanelID
        let destinationTab = WorkspaceTabState(
            id: UUID(),
            customTitle: "implementation",
            layoutTree: .slot(slotID: UUID(), panelID: session.panelID),
            panels: [session.panelID: panel],
            focusedPanelID: session.panelID
        )
        workspace.appendTab(destinationTab, select: false)
        XCTAssertEqual(SidebarSessionPresentation.sessionCustomTabTitle(for: session, in: workspace), "implementation")
    }

    func testSessionAccessibilityLabelIncludesFullCustomTabNameWithAndWithoutDirectory() {
        let title = "orchestrator handling a very long implementation name"
        for cwd in [".../toastty", nil] as [String?] {
            let label = SidebarSessionPresentation.sessionAccessibilityLabel(
                agentName: "Codex",
                chipKind: nil,
                detailText: "Reviewing changes",
                cwd: cwd,
                isLaterFlagged: false,
                customTabTitle: title
            )
            XCTAssertEqual(
                label,
                ["Codex", "Reviewing changes", cwd, "Tab: \(title)"].compactMap { $0 }.joined(separator: ", ")
            )
        }
    }

    private func makeSession(in workspace: WorkspaceState) throws -> WorkspaceSessionStatus {
        WorkspaceSessionStatus(
            sessionID: "session-tab-badge",
            panelID: try XCTUnwrap(workspace.focusedPanelID),
            workspaceID: workspace.id,
            agent: .codex,
            status: SessionStatus(kind: .idle, summary: "Idle"),
            cwd: "/repo/sidebar",
            updatedAt: Date(timeIntervalSince1970: 1),
            isActive: true
        )
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

    func testSessionRailStateMapsEachStatusAndSplitsReadyOnUnread() {
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRailState(for: .working, showsUnreadSessionAccent: false),
            .spinner
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRailState(for: .needsApproval, showsUnreadSessionAccent: false),
            .approvalDot
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRailState(for: .error, showsUnreadSessionAccent: false),
            .errorDot
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRailState(for: .ready, showsUnreadSessionAccent: true),
            .unreadDot
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRailState(for: .ready, showsUnreadSessionAccent: false),
            .empty
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRailState(for: .idle, showsUnreadSessionAccent: true),
            .empty
        )
    }

    func testSessionSummaryResolvesInlineMarkdownAndKeepsPlainCharacters() {
        let bold = SidebarSessionPresentation.sessionSummaryAttributedText(
            "**emptyos** — development repo for a personal computer"
        )
        XCTAssertEqual(
            String(bold.characters),
            "emptyos — development repo for a personal computer",
            "Emphasis markers should resolve rather than render literally"
        )
        XCTAssertTrue(
            bold.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
            "The emphasized span should carry a strong presentation intent"
        )

        let code = SidebarSessionPresentation.sessionSummaryAttributedText(
            "The last commit is `77c2f8b` (`Prepare EmptyOS`)"
        )
        XCTAssertEqual(String(code.characters), "The last commit is 77c2f8b (Prepare EmptyOS)")
        XCTAssertTrue(
            code.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true },
            "A backticked span should carry a code presentation intent"
        )

        XCTAssertEqual(
            SidebarSessionPresentation.sessionSummaryPlainText("They are in `/Users/vishal/Giant`"),
            "They are in /Users/vishal/Giant"
        )
    }

    func testSessionSummaryStripsLeadingBlockMarkersAndLeavesOrdinaryTextAlone() {
        for (input, expected) in [
            ("- Fixed the missing profile", "Fixed the missing profile"),
            ("* Fixed the missing profile", "Fixed the missing profile"),
            ("+ Fixed the missing profile", "Fixed the missing profile"),
            ("## Release notes drafted", "Release notes drafted"),
            ("> Waiting on approval", "Waiting on approval"),
            ("1. Ran the gate", "Ran the gate"),
            ("> - Nested marker", "Nested marker"),
            ("Plain summary with no markup", "Plain summary with no markup"),
            // Intraword underscores are not emphasis in CommonMark, so an
            // identifier or path must survive untouched.
            ("Read session_index.jsonl for the thread name", "Read session_index.jsonl for the thread name"),
            ("2026-09-17 15:04 - done", "2026-09-17 15:04 - done"),
        ] {
            XCTAssertEqual(
                SidebarSessionPresentation.sessionSummaryPlainText(input),
                expected,
                "Unexpected summary text for \(input)"
            )
        }
    }

    func testSessionSummaryKeepsLinkTextWithoutTheLink() {
        let linked = SidebarSessionPresentation.sessionSummaryAttributedText(
            "Opened [PR #11](https://example.com/pull/11)"
        )
        XCTAssertEqual(String(linked.characters), "Opened PR #11")
        XCTAssertTrue(
            linked.runs.allSatisfy { $0.link == nil },
            "A sidebar row is not somewhere to click through, so the link is dropped"
        )
    }

    func testSessionSummaryPreservesAPlaceholderAndSurvivesBrokenMarkup() {
        XCTAssertEqual(String(SidebarSessionPresentation.sessionSummaryAttributedText(" ").characters), " ")
        XCTAssertEqual(String(SidebarSessionPresentation.sessionSummaryAttributedText("").characters), "")
        // An unbalanced marker is left as characters rather than dropping the text.
        XCTAssertEqual(
            SidebarSessionPresentation.sessionSummaryPlainText("Working on **the thing"),
            "Working on **the thing"
        )
    }

    func testSessionAccessibilityLabelReadsTheSummaryNotItsMarkup() {
        let label = SidebarSessionPresentation.sessionAccessibilityLabel(
            agentName: "Repository summary",
            chipKind: .ready,
            detailText: "**emptyos** — development repo",
            cwd: nil,
            isLaterFlagged: false
        )
        XCTAssertTrue(label.contains("emptyos — development repo"), label)
        XCTAssertFalse(label.contains("**"), label)
    }

    func testSessionRowShapeLeadsWithNameAndFallsBackThroughSummaryToAgentName() {
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowShape(
                sessionName: "Sidebar row rebuild",
                summary: "Reviewing changes",
                agentFallbackName: "Codex"
            ),
            .named(name: "Sidebar row rebuild", summary: "Reviewing changes")
        )
        // A named session keeps its name on the first line even before the
        // provider reports any summary.
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowShape(
                sessionName: "Sidebar row rebuild",
                summary: nil,
                agentFallbackName: "Codex"
            ),
            .named(name: "Sidebar row rebuild", summary: nil)
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowShape(
                sessionName: nil,
                summary: "Reviewing changes",
                agentFallbackName: "Codex"
            ),
            .summaryFirst(summary: "Reviewing changes")
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowShape(
                sessionName: nil,
                summary: nil,
                agentFallbackName: "Codex"
            ),
            .summaryFirst(summary: "Codex")
        )
        // Whitespace-only provider values count as absent in both slots.
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowShape(
                sessionName: "  \n ",
                summary: "\t",
                agentFallbackName: "Claude Code"
            ),
            .summaryFirst(summary: "Claude Code")
        )
        XCTAssertEqual(
            SidebarSessionPresentation.sessionRowShape(
                sessionName: " Sidebar row rebuild ",
                summary: " Reviewing changes ",
                agentFallbackName: "Codex"
            ),
            .named(name: "Sidebar row rebuild", summary: "Reviewing changes")
        )
    }

    func testShowsSessionAgentLabelDropsOnlyWhenPrimaryLineIsAlreadyTheAgentName() {
        XCTAssertTrue(
            SidebarSessionPresentation.showsSessionAgentLabel(
                shape: .named(name: "Sidebar row rebuild", summary: nil),
                agentFallbackName: "Codex"
            )
        )
        // Even a row named exactly after its agent keeps the label, because a
        // named row's own name line is not the summary fallback.
        XCTAssertTrue(
            SidebarSessionPresentation.showsSessionAgentLabel(
                shape: .named(name: "Codex", summary: nil),
                agentFallbackName: "Codex"
            )
        )
        XCTAssertTrue(
            SidebarSessionPresentation.showsSessionAgentLabel(
                shape: .summaryFirst(summary: "Reviewing changes"),
                agentFallbackName: "Codex"
            )
        )
        XCTAssertFalse(
            SidebarSessionPresentation.showsSessionAgentLabel(
                shape: .summaryFirst(summary: "Codex"),
                agentFallbackName: "Codex"
            )
        )
    }

    func testSessionStatusBadgeLabelShortensApprovalWhileSpokenWordingKeepsIt() {
        XCTAssertEqual(SidebarSessionPresentation.sessionStatusBadgeLabel(for: .needsApproval), "approval")
        XCTAssertEqual(SidebarSessionPresentation.sessionStatusChipLabel(for: .needsApproval), "needs approval")
        // Every other kind reads the same in the badge and in speech.
        for kind in [SessionStatusKind.ready, .error, .idle, .working] {
            XCTAssertEqual(
                SidebarSessionPresentation.sessionStatusBadgeLabel(for: kind),
                SidebarSessionPresentation.sessionStatusChipLabel(for: kind),
                "Only needs-approval should shorten for the row badge, not \(kind.rawValue)"
            )
        }
    }

    func testSessionAccessibilityLabelKeepsSpokenApprovalWordingNotTheShortBadge() {
        let label = SidebarSessionPresentation.sessionAccessibilityLabel(
            agentName: "Codex",
            chipKind: .needsApproval,
            detailText: "Review command",
            cwd: nil,
            isLaterFlagged: false
        )

        XCTAssertEqual(label, "Codex, needs approval, Review command")
    }

    func testDurationTextFormatsSecondsMinutesAndClampsUnusableInput() {
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: 45), "45s")
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: 252), "4m 12s")
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: 0), "0s")
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: 60), "1m 00s")
        // A clock correction can hand the formatter a negative or unusable
        // span; the row must not count backwards or print a placeholder.
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: -30), "0s")
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: .infinity), "0s")
        XCTAssertEqual(SidebarSessionPresentation.durationText(seconds: .nan), "0s")
    }

    func testSessionElapsedTurnTextMeasuresTurnAndIsAbsentWithoutOne() {
        let turnStart = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            SidebarSessionPresentation.sessionElapsedTurnText(
                turnStartedAt: turnStart,
                now: turnStart.addingTimeInterval(252)
            ),
            "4m 12s"
        )
        XCTAssertNil(
            SidebarSessionPresentation.sessionElapsedTurnText(turnStartedAt: nil, now: turnStart)
        )
    }

    func testSessionLastTurnTextFormatsDurationAndRejectsAbsentOrNegative() {
        XCTAssertEqual(SidebarSessionPresentation.sessionLastTurnText(45), "45s")
        XCTAssertEqual(SidebarSessionPresentation.sessionLastTurnText(252), "4m 12s")
        XCTAssertNil(SidebarSessionPresentation.sessionLastTurnText(nil))
        // A row at rest with a nonsense duration shows nothing rather than "0s".
        XCTAssertNil(SidebarSessionPresentation.sessionLastTurnText(-1))
        XCTAssertNil(SidebarSessionPresentation.sessionLastTurnText(.infinity))
    }

    func testSessionRowHoverTipModelCarriesEverythingTheRowStoppedShowing() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var session = try makeSession(in: makeWorkspace(title: "Workspace"))
        session.displayTitleOverride = "Sidebar row rebuild"
        session.cwd = "\(NSHomeDirectory())/GiantThings/repos/toastty"
        session.status = SessionStatus(
            kind: .working,
            summary: "Working",
            detail: "Rebuilding the sidebar session rows so the summary no longer truncates"
        )
        session.updatedAt = now.addingTimeInterval(-90)
        session.lastTurnDuration = 252

        let model = SidebarSessionPresentation.sessionRowHoverTipModel(
            session: session,
            customTabTitle: "orchestrator",
            parentSessionName: "Claude Code",
            workspaceScopeNames: ["Workspace 1", "wt-sessions"],
            isLaterFlagged: true,
            now: now
        )

        XCTAssertEqual(model.name, "Sidebar row rebuild")
        XCTAssertEqual(model.agentLabel, "codex")
        XCTAssertEqual(model.statusDotColorKind, .working)
        // The row truncates the summary to one line; the card keeps all of it.
        XCTAssertEqual(
            model.bodyText,
            "Rebuilding the sidebar session rows so the summary no longer truncates"
        )
        XCTAssertNil(model.turnStartedAt)
        XCTAssertEqual(
            model.metaItems.map(\.label),
            ["path", "scoped", "status", "updated", "last turn", "tab", "parent", "flagged"]
        )
        let valuesByLabel = Dictionary(
            uniqueKeysWithValues: model.metaItems.map { ($0.label, $0.value) }
        )
        XCTAssertEqual(valuesByLabel["path"], "~/GiantThings/repos/toastty")
        XCTAssertEqual(valuesByLabel["scoped"], "Workspace 1, wt-sessions")
        XCTAssertEqual(valuesByLabel["status"], "working")
        XCTAssertEqual(
            valuesByLabel["updated"],
            SidebarSessionPresentation.sessionUpdatedRelativeText(
                updatedAt: session.updatedAt,
                now: now
            )
        )
        XCTAssertEqual(valuesByLabel["last turn"], "4m 12s")
        XCTAssertEqual(valuesByLabel["tab"], "orchestrator")
        XCTAssertEqual(valuesByLabel["parent"], "Claude Code")
        XCTAssertEqual(valuesByLabel["flagged"], "for later")
        // A long scope list is the one value allowed to wrap.
        XCTAssertEqual(
            model.metaItems.filter(\.wraps).map(\.label),
            ["scoped"]
        )
    }

    func testSessionRowHoverTipModelReportsWaitingProjectionAndHidesLastTurnMidTurn() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var session = try makeSession(in: makeWorkspace(title: "Workspace"))
        session.cwd = nil
        session.status = SessionStatus(kind: .working, summary: "Working", detail: nil)
        session.projection = .waitingOnChildren(childCount: 2, pendingBackgroundTaskCount: 0)
        session.children = [
            SessionChildRow(id: "a", source: .activity, displayName: "Explore", startedAt: now),
            SessionChildRow(id: "b", source: .activity, displayName: "Plan", startedAt: now),
        ]
        session.turnStartedAt = now.addingTimeInterval(-45)
        session.lastTurnDuration = 252

        let model = SidebarSessionPresentation.sessionRowHoverTipModel(
            session: session,
            customTabTitle: nil,
            parentSessionName: nil,
            workspaceScopeNames: [],
            isLaterFlagged: false,
            now: now
        )

        XCTAssertNil(model.bodyText)
        XCTAssertEqual(model.turnStartedAt, session.turnStartedAt)
        // `last turn` belongs to a row at rest; a turn in flight shows elapsed
        // instead, and the card never shows both.
        XCTAssertEqual(model.metaItems.map(\.label), ["status", "updated", "sub-agents"])
        let valuesByLabel = Dictionary(
            uniqueKeysWithValues: model.metaItems.map { ($0.label, $0.value) }
        )
        XCTAssertEqual(valuesByLabel["status"], "waiting on 2 sub-agents")
        XCTAssertEqual(valuesByLabel["sub-agents"], "2 · 2 working")

        session.projection = .waitingOnChildren(childCount: 1, pendingBackgroundTaskCount: 0)
        session.children = [session.children[0]]
        let singleChildModel = SidebarSessionPresentation.sessionRowHoverTipModel(
            session: session,
            customTabTitle: nil,
            parentSessionName: nil,
            workspaceScopeNames: [],
            isLaterFlagged: false,
            now: now
        )
        XCTAssertEqual(
            singleChildModel.metaItems.first(where: { $0.label == "status" })?.value,
            "waiting on 1 sub-agent"
        )
        XCTAssertEqual(singleChildModel.metaItems.map(\.label), ["status", "updated", "sub-agent"])
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
