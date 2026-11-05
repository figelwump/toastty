@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class SidebarSubspacePresentationTests: XCTestCase {
    private func row(
        _ name: String,
        id: UUID = UUID(),
        status: SidebarSubspacePresentation.RowStatus,
        spawner: String? = "spawner-a",
        sessions: [SidebarSubspacePresentation.SessionLine] = [],
        doneAt: Date? = nil
    ) -> SidebarSubspacePresentation.Row {
        SidebarSubspacePresentation.Row(
            id: id,
            title: name,
            status: status,
            doneAt: doneAt,
            annotations: [:],
            summary: nil,
            spawningSessionID: spawner,
            spawnerName: spawner.map { "Agent \($0)" },
            sessions: sessions
        )
    }

    private func session(
        _ kind: SessionStatusKind = .idle,
        reportedAt seconds: TimeInterval?,
        unread: Bool = false
    ) -> SidebarSubspacePresentation.SessionLine {
        .init(
            title: "Agent", panelID: UUID(), statusKind: kind,
            isWaiting: false, showsUnreadSessionAccent: unread, summary: nil,
            statusUpdatedAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func testRowChipPrefersPrimaryAnnotationAndFallsBackToPullRequest() {
        let pullRequest = WorkspaceAnnotation(text: "#12")
        let ticket = WorkspaceAnnotation(text: "ENG-5")
        func chipKey(_ annotations: [String: WorkspaceAnnotation], primary: String?) -> String? {
            SidebarSubspacePresentation.Row(
                id: UUID(),
                title: "task",
                status: .idle,
                annotations: annotations,
                primaryAnnotationKey: primary,
                summary: nil,
                spawningSessionID: nil,
                spawnerName: nil,
                sessions: []
            ).rowAnnotation?.key
        }

        XCTAssertEqual(chipKey(["github-pr": pullRequest, "linear": ticket], primary: "linear"), "linear")
        XCTAssertEqual(chipKey(["github-pr": pullRequest, "linear": ticket], primary: nil), "github-pr")
        XCTAssertNil(chipKey(["linear": ticket], primary: nil))
    }

    func testRowStatusUsesSessionAttentionAndUnreadReadyState() {
        typealias Session = (kind: SessionStatusKind, showsUnreadSessionAccent: Bool)
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.working, false), Session(.needsApproval, false)]
            ),
            .needsApproval
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.ready, true), Session(.error, false)]
            ),
            .error
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.error, false), Session(.needsApproval, false), Session(.ready, true)]
            ),
            .needsApproval
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(sessionStatuses: [Session(.working, false)]),
            .working
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(sessionStatuses: [Session(.ready, false)]),
            .idle
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(sessionStatuses: []),
            .idle
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(sessionStatuses: [Session(.ready, true)]),
            .ready
        )
    }

    func testRowSummaryFollowsTheStatusSessionThenTheLatestReport() {
        func line(
            _ summary: String?,
            _ kind: SessionStatusKind,
            unread: Bool = false,
            reportedAt seconds: TimeInterval?
        ) -> SidebarSubspacePresentation.SessionLine {
            SidebarSubspacePresentation.SessionLine(
                title: "Agent",
                panelID: UUID(),
                statusKind: kind,
                isWaiting: false,
                showsUnreadSessionAccent: unread,
                summary: summary,
                statusUpdatedAt: seconds.map { Date(timeIntervalSince1970: $0) }
            )
        }

        // The approval sets the row's status, so its text wins over a newer working report.
        XCTAssertEqual(
            SidebarSubspacePresentation.rowSummary(sessions: [
                line("Running tests", .working, reportedAt: 20),
                line("Approve rm -rf build", .needsApproval, reportedAt: 10),
            ]),
            "Approve rm -rf build"
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowSummary(sessions: [
                line("First agent's old step", .working, reportedAt: 10),
                line("Second agent's new step", .working, reportedAt: 20),
            ]),
            "Second agent's new step"
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowSummary(sessions: [
                line("Editing", .working, reportedAt: 30),
                line("Finished", .ready, unread: true, reportedAt: 10),
            ]),
            "Finished"
        )
        // A read ready session ranks as idle, below one still working.
        XCTAssertEqual(
            SidebarSubspacePresentation.rowSummary(sessions: [
                line("Finished", .ready, reportedAt: 30),
                line("Editing", .working, reportedAt: 10),
            ]),
            "Editing"
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowSummary(sessions: [
                line(nil, .needsApproval, reportedAt: 30),
                line("Editing", .working, reportedAt: 10),
            ]),
            "Editing"
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowSummary(sessions: [
                line("First", .idle, reportedAt: nil),
                line("Second", .idle, reportedAt: nil),
            ]),
            "First"
        )
    }

    func testWaitingRequiresAllWorkingSessionsToWaitAndPreservesAttentionPrecedence() {
        typealias Presentation = SidebarSubspacePresentation
        func line(_ kind: SessionStatusKind, projection: SessionStatusProjection = .none) -> Presentation.SessionLine {
            .init(
                title: "Agent", panelID: UUID(), statusKind: kind,
                isWaiting: SidebarSessionPresentation.sessionStatusProjectionChipLabel(for: projection) != nil,
                summary: nil
            )
        }
        let waiting = line(.working, projection: .waitingOnChildren(childCount: 0, pendingBackgroundTaskCount: 1))
        func isWaiting(_ sessions: [Presentation.SessionLine]) -> Bool {
            let status = Presentation.rowStatus(sessionStatuses: sessions.map {
                (kind: $0.statusKind, showsUnreadSessionAccent: $0.showsUnreadSessionAccent)
            })
            return Presentation.Row(
                id: UUID(), title: "task", status: status, annotations: [:], summary: nil,
                spawningSessionID: nil, spawnerName: nil, sessions: sessions
            ).isWaiting
        }

        XCTAssertTrue(isWaiting([waiting]))
        XCTAssertTrue(isWaiting([waiting, line(.working, projection: .waitingOnChildren(childCount: 2, pendingBackgroundTaskCount: 0))]))
        XCTAssertTrue(isWaiting([waiting, line(.idle), line(.ready)]))
        XCTAssertFalse(isWaiting([]))
        XCTAssertFalse(isWaiting([waiting, line(.working)]))
        XCTAssertFalse(isWaiting([waiting, line(.working, projection: .resuming)]))
        XCTAssertFalse(isWaiting([waiting, line(.needsApproval)]))
        XCTAssertFalse(isWaiting([waiting, line(.error)]))
        var unread = line(.ready)
        unread.showsUnreadSessionAccent = true
        XCTAssertFalse(isWaiting([waiting, unread]))
    }

    func testWaitingRemainsAvailableInAccessibilityAndHoverDetails() {
        let row = SidebarSubspacePresentation.Row(
            id: UUID(), title: "website-redesign", status: .working,
            annotations: ["github-pr": WorkspaceAnnotation(text: "PR #58")],
            summary: "Review still running", spawningSessionID: nil, spawnerName: nil,
            sessions: [.init(
                title: "Claude", panelID: UUID(), statusKind: .working,
                isWaiting: true,
                summary: "Review still running"
            )]
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowAccessibilityLabel(row, showsSpawnerTag: false),
            "website-redesign, task space, waiting, PR #58, Review still running"
        )
        let hover = SidebarSubspacePresentation.hoverTipModel(row) { _ in .named(.green) }
        XCTAssertTrue(hover.sessions[0].isWaiting)
        XCTAssertEqual(hover.annotations[0].text, "PR #58")
    }

    func testDoneMarkReplacesQuietStatuses() {
        func shown(_ status: SidebarSubspacePresentation.RowStatus) -> SidebarSubspacePresentation.RowStatus {
            SidebarSubspacePresentation.rowStatus(sessionStatus: status, isDone: true)
        }
        // The turn that marked the task done ends ready; the check still shows.
        XCTAssertEqual(shown(.idle), .done)
        XCTAssertEqual(shown(.ready), .done)
        // Anything the user may need to act on stays visible.
        XCTAssertEqual(shown(.working), .working)
        XCTAssertEqual(shown(.needsApproval), .needsApproval)
        XCTAssertEqual(shown(.error), .error)
        XCTAssertEqual(SidebarSubspacePresentation.rowStatus(sessionStatus: .ready, isDone: false), .ready)

        let rows = [row("a-done", status: .done), row("b-idle", status: .idle), row("c-ready", status: .ready)]
        XCTAssertTrue(SidebarSubspacePresentation.tally(rows).ready == 1)
    }

    func testSpawnerChipCountsToneAndFilterState() {
        let rows = [
            row("one", status: .ready, spawner: "a"),
            row("two", status: .needsApproval, spawner: "a"),
            row("three", status: .error, spawner: "b"),
            row("four", status: .working, spawner: nil),
        ]
        XCTAssertEqual(
            SidebarSubspacePresentation.spawnerChip(sessionID: "a", rows: rows, activeFilterSessionID: "a"),
            .init(count: 2, tone: .needsApproval, isFilterActive: true)
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.spawnerChip(sessionID: "b", rows: rows, activeFilterSessionID: nil),
            .init(count: 1, tone: .error, isFilterActive: false)
        )
        XCTAssertNil(SidebarSubspacePresentation.spawnerChip(sessionID: "c", rows: rows, activeFilterSessionID: nil))

        XCTAssertTrue(SidebarSubspacePresentation.showsSpawnerTags(rows))
        XCTAssertFalse(SidebarSubspacePresentation.showsSpawnerTags(Array(rows[0...1])))
        // A single-spawner group still tags a row whose spawner lives in
        // another workspace, since no chip in this card points to it.
        let parentID = UUID()
        var externallySpawned = rows[0]
        externallySpawned.spawnerWorkspaceID = UUID()
        var locallySpawned = rows[1]
        locallySpawned.spawnerWorkspaceID = parentID
        XCTAssertTrue(SidebarSubspacePresentation.showsSpawnerTag(
            externallySpawned, parentWorkspaceID: parentID, groupShowsSpawnerTags: false
        ))
        XCTAssertFalse(SidebarSubspacePresentation.showsSpawnerTag(
            locallySpawned, parentWorkspaceID: parentID, groupShowsSpawnerTags: false
        ))
        XCTAssertEqual(
            SidebarSubspacePresentation.filteredRows(rows, spawningSessionID: "a").map(\.title),
            ["one", "two"]
        )
        // Filtering to "a" would hide "three", which has an error; filtering
        // to "b" would hide "two", which needs approval.
        XCTAssertTrue(SidebarSubspacePresentation.filterHidesAttention(rows, spawningSessionID: "a"))
        XCTAssertTrue(SidebarSubspacePresentation.filterHidesAttention(rows, spawningSessionID: "b"))
        XCTAssertFalse(SidebarSubspacePresentation.filterHidesAttention(
            [rows[0], rows[1], rows[3]],
            spawningSessionID: "a"
        ))
        XCTAssertFalse(SidebarSubspacePresentation.filterHidesAttention(rows, spawningSessionID: nil))
        XCTAssertEqual(SidebarSubspacePresentation.tally(rows), .init(ready: 1, needsApproval: 1, error: 1))
        XCTAssertEqual(SidebarSubspacePresentation.headerCountLabel(shownCount: 2, totalCount: 4), "2/4")
        XCTAssertEqual(SidebarSubspacePresentation.headerCountLabel(shownCount: 4, totalCount: 4), "4")
    }

    func testHoverTipModelListsSessionsAnnotationsAndWhereTheSubspaceLives() {
        let approvalPanelID = UUID()
        let row = SidebarSubspacePresentation.Row(
            id: UUID(), title: "qa-mobile-navigation", status: .needsApproval,
            annotations: [
                "task-status": WorkspaceAnnotation(text: "Ready for your testing"),
                "github-pr": WorkspaceAnnotation(text: "PR #132", url: "https://github.com/example/repo/pull/132"),
            ],
            summary: "Rebasing onto main",
            spawningSessionID: "a", spawnerName: "Test EmptyOS beta experience",
            sessions: [
                .init(title: "Rebase fixture", panelID: UUID(), statusKind: .working, isWaiting: false, summary: "Rebasing onto main"),
                .init(title: "Screenshot pass", panelID: UUID(), statusKind: .idle, isWaiting: false, summary: nil),
                .init(title: "Collect logs", panelID: UUID(), statusKind: .ready, isWaiting: false, showsUnreadSessionAccent: true, summary: "Saved 3 logs"),
                .init(
                    title: "Fix nav drawer focus", panelID: approvalPanelID, agentLabel: "claude",
                    statusKind: .needsApproval, isWaiting: false, summary: "pnpm db:migrate"
                ),
            ],
            path: NSHomeDirectory() + "/worktrees/qa-mobile-navigation"
        )
        let model = SidebarSubspacePresentation.hoverTipModel(row) { key in
            key == "github-pr" ? .named(.green) : .named(.blue)
        }
        XCTAssertEqual(model.name, "qa-mobile-navigation")

        // Attention first, then unread, then working; the idle session is past
        // the three-row cap.
        XCTAssertEqual(model.sessions.map(\.title), ["Fix nav drawer focus", "Collect logs", "Rebase fixture"])
        XCTAssertEqual(model.hiddenSessionCount, 1)
        XCTAssertEqual(model.sessions.map(\.railState), [.approvalDot, .unreadDot, .spinner])
        XCTAssertEqual(model.sessions.map(\.badgeKind), [.needsApproval, nil, nil])
        XCTAssertEqual(model.sessions.map(\.isUnread), [false, true, false])
        // Clicking a row jumps to its panel.
        XCTAssertEqual(model.sessions.first?.panelID, approvalPanelID)

        XCTAssertEqual(model.annotations, [
            .init(key: "github-pr", text: "PR #132", colorToken: .named(.green)),
            .init(key: "task-status", text: "Ready for your testing", colorToken: .named(.blue)),
        ])
        // Shown with `~`, copied in full.
        XCTAssertEqual(model.path, "~/worktrees/qa-mobile-navigation")
        XCTAssertEqual(model.absolutePath, NSHomeDirectory() + "/worktrees/qa-mobile-navigation")
        XCTAssertEqual(model.spawnerName, "Test EmptyOS beta experience")

        let empty = SidebarSubspacePresentation.hoverTipModel(SidebarSubspacePresentation.Row(
            id: UUID(), title: "idle-space", status: .idle, annotations: [:], summary: nil,
            spawningSessionID: nil, spawnerName: nil, sessions: []
        )) { _ in .named(.neutral) }
        XCTAssertTrue(empty.sessions.isEmpty)
        XCTAssertEqual(empty.hiddenSessionCount, 0)
        XCTAssertTrue(empty.annotations.isEmpty)
        XCTAssertNil(empty.path)
    }

    func testPathPrefersTheFirstAgentsDirectoryThenTheFirstTerminal() {
        let panelID = UUID()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "qa-www-docs",
            layoutTree: .slot(slotID: UUID(), panelID: panelID),
            panels: [panelID: .terminal(TerminalPanelState(title: "zsh", shell: "zsh", cwd: "/repo/www-docs"))],
            focusedPanelID: panelID
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.path(sessionCWDs: [nil, "/repo/worktree", "/repo/other"], workspace: workspace),
            "/repo/worktree"
        )
        XCTAssertEqual(SidebarSubspacePresentation.path(sessionCWDs: [], workspace: workspace), "/repo/www-docs")
    }

    func testWorkspaceMoveIndicesSkipSubspacesInTheWindowOrder() {
        let a = UUID(), b = UUID(), c = UUID(), subA = UUID(), subB = UUID()
        // Window order interleaves subspaces; the sidebar drags cards only.
        let windowOrder = [a, subA, b, subB, c]
        let cards = [a, b, c]

        // Drop "a" after "b" (target index 1 among the remaining cards b, c).
        let afterB = SidebarView.windowWorkspaceMoveIndices(
            draggedWorkspaceID: a, targetIndex: 1, topLevelWorkspaceIDs: cards, windowWorkspaceIDs: windowOrder
        )
        XCTAssertEqual(afterB?.fromIndex, 0)
        XCTAssertEqual(afterB?.toIndex, 3)
        var moved = windowOrder
        moved.insert(moved.remove(at: afterB!.fromIndex), at: afterB!.toIndex)
        XCTAssertEqual(moved.filter(cards.contains), [b, a, c])

        // Drop "c" at the top.
        let toTop = SidebarView.windowWorkspaceMoveIndices(
            draggedWorkspaceID: c, targetIndex: 0, topLevelWorkspaceIDs: cards, windowWorkspaceIDs: windowOrder
        )
        XCTAssertEqual(toTop?.fromIndex, 4)
        XCTAssertEqual(toTop?.toIndex, 0)

        // Drop "a" at the end.
        let toEnd = SidebarView.windowWorkspaceMoveIndices(
            draggedWorkspaceID: a, targetIndex: 2, topLevelWorkspaceIDs: cards, windowWorkspaceIDs: windowOrder
        )
        XCTAssertEqual(toEnd?.toIndex, 4)
        XCTAssertNil(SidebarView.windowWorkspaceMoveIndices(
            draggedWorkspaceID: a, targetIndex: 3, topLevelWorkspaceIDs: cards, windowWorkspaceIDs: windowOrder
        ))
    }

    func testTaskStageSetsAQuietRowsMarkButAnAgentStillComesFirst() {
        typealias P = SidebarSubspacePresentation
        XCTAssertEqual(P.rowStatus(sessionStatus: .idle, isDone: false, stage: .needsYou(.review)), .review)
        XCTAssertEqual(P.rowStatus(sessionStatus: .ready, isDone: false, stage: .needsYou(.readyForReview)), .review)
        XCTAssertEqual(P.rowStatus(sessionStatus: .idle, isDone: false, stage: .toShip), .toShip)
        XCTAssertEqual(P.rowStatus(sessionStatus: .ready, isDone: false, stage: .done), .done)
        XCTAssertEqual(P.rowStatus(sessionStatus: .ready, isDone: false, stage: .running), .ready)
        // Setup runs before any agent reports, so a starting task shows work.
        XCTAssertEqual(P.rowStatus(sessionStatus: .idle, isDone: false, stage: .starting), .working)
        XCTAssertEqual(P.rowStatus(sessionStatus: .idle, isDone: true, stage: nil), .done)
        // A merge waiting for checks sets the done mark as the user's
        // acceptance; the task is still running, not done.
        XCTAssertEqual(P.rowStatus(sessionStatus: .idle, isDone: true, stage: .running), .idle)
        for agent in [P.RowStatus.working, .needsApproval, .error] {
            XCTAssertEqual(P.rowStatus(sessionStatus: agent, isDone: true, stage: .toShip), agent)
        }

        // Finished rows leave a project card only while nothing in them runs
        // or waits for the user.
        XCTAssertTrue(P.isHiddenAsFinished(row("merged", status: .toShip)))
        XCTAssertTrue(P.isHiddenAsFinished(row("done", status: .done)))
        XCTAssertFalse(P.isHiddenAsFinished(row("review", status: .review)))
        XCTAssertFalse(P.isHiddenAsFinished(row("working", status: .working)))
        // An unread finished turn sets the status, but another agent still works.
        let mixed = row("mixed", status: .done, sessions: [
            session(.ready, reportedAt: 2, unread: true),
            session(.working, reportedAt: 1),
        ])
        XCTAssertFalse(P.isHiddenAsFinished(mixed))

        XCTAssertEqual(P.tally([row("a", status: .review), row("b", status: .review)]).review, 2)
        XCTAssertTrue(P.showsDoneToggle(row("review", status: .review)))
        XCTAssertFalse(P.showsDoneToggle(row("merged", status: .toShip)))
    }

    func testLinkedChildrenDrawUnderTheTaskThatStartedThemOneLevelDeep() {
        var parent = row("task-inbox", status: .working)
        var child = row("hotkey-capture", status: .review)
        var grandchild = row("hotkey-docs", status: .working)
        let other = row("pricing-page", status: .idle)
        var orphan = row("ios-outbox", status: .idle)
        child.linkedParentID = parent.id
        grandchild.linkedParentID = child.id
        orphan.linkedParentID = UUID()
        parent.childProgressLabel = SidebarSubspacePresentation.childProgressLabel(merged: 0, total: 2)

        let grouped = SidebarSubspacePresentation.groupingLinkedChildren([child, other, grandchild, parent, orphan])
        // A grandchild and a child whose parent is not listed keep their places.
        XCTAssertEqual(grouped.map(\.title), ["pricing-page", "hotkey-docs", "task-inbox", "hotkey-capture", "ios-outbox"])
        XCTAssertEqual(grouped.map(\.isLinkedChild), [false, false, false, true, false])
        XCTAssertEqual(parent.childProgressLabel, "0/2 merged")
    }
}
