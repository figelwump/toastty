@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class SidebarSubspacePresentationTests: XCTestCase {
    private func row(
        _ name: String,
        status: SidebarSubspacePresentation.RowStatus,
        spawner: String? = "spawner-a",
        index: Int,
        sessions: [SidebarSubspacePresentation.SessionLine] = []
    ) -> SidebarSubspacePresentation.Row {
        SidebarSubspacePresentation.Row(
            id: UUID(),
            title: name,
            status: status,
            annotations: [:],
            summary: nil,
            spawningSessionID: spawner,
            spawnerName: spawner.map { "Agent \($0)" },
            sessions: sessions,
            creationIndex: index
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
                sessions: [],
                creationIndex: 0
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
                spawningSessionID: nil, spawnerName: nil, sessions: sessions, creationIndex: 0
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
            )], creationIndex: 0
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowAccessibilityLabel(row, showsSpawnerTag: false),
            "website-redesign, subspace, waiting, PR #58, Review still running"
        )
        let hover = SidebarSubspacePresentation.hoverTipModel(row) { _ in .named(.green) }
        XCTAssertTrue(hover.sessions[0].isWaiting)
        XCTAssertEqual(hover.annotations[0].text, "PR #58")
    }

    func testSortedRowsRankByStatusAndKeepCreationOrderWithoutActivityTimes() {
        let rows = [
            row("a-working", status: .working, index: 0),
            row("b-ready", status: .ready, index: 1),
            row("c-idle", status: .idle, index: 2),
            row("d-approval", status: .needsApproval, index: 3),
            row("e-ready", status: .ready, index: 4),
            row("f-error", status: .error, index: 5),
        ]
        XCTAssertEqual(
            SidebarSubspacePresentation.sortedRows(rows).map(\.title),
            ["b-ready", "e-ready", "d-approval", "f-error", "a-working", "c-idle"]
        )
    }

    func testEachStatusGroupSortsByNewestSessionActivityBeforeCreationOrder() {
        let statuses: [SidebarSubspacePresentation.RowStatus] = [.ready, .needsApproval, .error, .working, .idle, .done]
        let rows = statuses.enumerated().flatMap { index, status in
            [
                row("old-\(status)", status: status, index: index * 2,
                    sessions: [session(reportedAt: TimeInterval(100 - index))]),
                row("new-\(status)", status: status, index: index * 2 + 1,
                    sessions: [session(reportedAt: TimeInterval(200 + index))]),
            ]
        }
        XCTAssertEqual(
            SidebarSubspacePresentation.sortedRows(rows.reversed()).map(\.title),
            statuses.flatMap { ["new-\($0)", "old-\($0)"] }
        )
    }

    func testEqualAndMissingActivityTimesUseStableCreationOrder() {
        let rows = [
            row("empty", status: .idle, index: 0),
            row("unreported", status: .idle, index: 1, sessions: [session(reportedAt: nil)]),
            row("older", status: .idle, index: 2, sessions: [session(reportedAt: 10)]),
            row("newer", status: .idle, index: 3, sessions: [session(reportedAt: 20)]),
            row("same-time", status: .idle, index: 4, sessions: [session(reportedAt: 20)]),
        ]
        let expected = ["newer", "same-time", "older", "empty", "unreported"]
        XCTAssertEqual(SidebarSubspacePresentation.sortedRows(rows).map(\.title), expected)
        XCTAssertEqual(SidebarSubspacePresentation.sortedRows(rows.reversed()).map(\.title), expected)
    }

    func testSubspaceActivityIncludesEverySessionRegardlessOfDisplayedStatus() {
        let rows = [
            row("recent-approval", status: .needsApproval, index: 0,
                sessions: [session(.needsApproval, reportedAt: 20)]),
            row("active-sibling", status: .needsApproval, index: 1,
                sessions: [session(.needsApproval, reportedAt: 10), session(.working, reportedAt: 30)]),
        ]
        XCTAssertEqual(
            SidebarSubspacePresentation.sortedRows(rows).map(\.title),
            ["active-sibling", "recent-approval"]
        )
    }

    func testRecentlyIdleSubspaceLeadsIdleGroupAndKeepsHoverAndSelectionPosition() {
        typealias Presentation = SidebarSubspacePresentation
        let older = row("older", status: .idle, index: 0, sessions: [session(reportedAt: 10)])
        let selected = row("selected", status: .idle, index: 1, sessions: [session(reportedAt: 20)])
        let newest = row("newest", status: .idle, index: 2, sessions: [session(reportedAt: 30)])
        let before = [older.id, selected.id, newest.id]
        let sorted = Presentation.sortedRows([older, selected, newest])
        XCTAssertEqual(sorted.map(\.id), [newest.id, selected.id, older.id])
        XCTAssertEqual(
            Presentation.orderedRows(sorted, frozenOrder: before).map(\.id), before
        )
        let pin = Presentation.pin(
            previous: nil, selectedRowID: newest.id, displayedOrder: before,
            unpinnedOrder: sorted.map(\.id)
        )
        XCTAssertEqual(Presentation.applyingPin(pin, to: sorted).map(\.id), [selected.id, older.id, newest.id])
        XCTAssertEqual(Presentation.applyingPin(nil, to: sorted).map(\.id), [newest.id, selected.id, older.id])
    }

    func testRuntimeProgressMetadataAndReadTransitionsDriveSubspaceActivityOrder() throws {
        typealias Presentation = SidebarSubspacePresentation
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let runtime = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in },
            isApplicationActive: { false }
        )
        runtime.bind(store: appStore)
        let selection = try XCTUnwrap(appStore.state.selectedWorkspaceSelection())
        let panelID = try XCTUnwrap(selection.workspace.focusedPanelID)
        runtime.startSession(
            sessionID: "activity", agent: .codex, panelID: panelID,
            windowID: selection.windowID, workspaceID: selection.workspaceID,
            cwd: "/repo", repoRoot: "/repo", at: Date(timeIntervalSince1970: 1)
        )
        defer { runtime.stopSession(sessionID: "activity", at: Date()) }

        func runtimeRow() throws -> Presentation.Row {
            let status = try XCTUnwrap(runtime.workspaceStatuses(for: selection.workspaceID).first)
            let unread = appStore.state.workspacesByID[selection.workspaceID]?.unreadPanelIDs.contains(panelID) == true
            return row(
                "active", status: Presentation.rowStatus(sessionStatuses: [(status.status.kind, unread)]),
                index: 1,
                sessions: [.init(
                    title: status.displayTitle, panelID: status.panelID,
                    statusKind: status.status.kind, isWaiting: false,
                    showsUnreadSessionAccent: unread, summary: status.status.summary,
                    statusUpdatedAt: status.statusUpdatedAt
                )]
            )
        }
        func report(_ kind: SessionStatusKind, at seconds: TimeInterval) {
            runtime.updateStatus(
                sessionID: "activity", status: .init(kind: kind, summary: "Progress"),
                at: Date(timeIntervalSince1970: seconds)
            )
        }
        let peer = row("peer", status: .working, index: 0, sessions: [session(.working, reportedAt: 20)])
        report(.working, at: 10)
        XCTAssertEqual(Presentation.sortedRows([peer, try runtimeRow()]).map(\.title), ["peer", "active"])
        report(.working, at: 30)
        XCTAssertEqual(Presentation.sortedRows([peer, try runtimeRow()]).map(\.title), ["active", "peer"])

        runtime.updateFiles(
            sessionID: "activity", files: ["changed.swift"], cwd: "/repo/new",
            repoRoot: "/repo", at: Date(timeIntervalSince1970: 40)
        )
        XCTAssertEqual(try runtimeRow().latestActivityAt, Date(timeIntervalSince1970: 30))
        let newerPeer = row("newer-peer", status: .working, index: 0, sessions: [session(.working, reportedAt: 35)])
        XCTAssertEqual(Presentation.sortedRows([newerPeer, try runtimeRow()]).map(\.title), ["newer-peer", "active"])

        report(.ready, at: 50)
        XCTAssertTrue(appStore.send(.recordDesktopNotification(workspaceID: selection.workspaceID, panelID: panelID)))
        XCTAssertEqual(try runtimeRow().status, .ready)
        let beforeRead = Date()
        XCTAssertTrue(appStore.send(.markPanelNotificationsRead(workspaceID: selection.workspaceID, panelID: panelID)))
        let read = try runtimeRow()
        XCTAssertEqual(read.status, .idle)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(read.latestActivityAt), beforeRead)
        let idlePeer = row("idle-peer", status: .idle, index: 0, sessions: [session(reportedAt: 60)])
        XCTAssertEqual(Presentation.sortedRows([idlePeer, read]).map(\.title), ["active", "idle-peer"])
    }

    func testDoneMarkReplacesQuietStatusesAndSortsLast() {
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

        let rows = [
            row("a-done", status: .done, index: 0),
            row("b-idle", status: .idle, index: 1),
            row("c-ready", status: .ready, index: 2),
        ]
        XCTAssertEqual(SidebarSubspacePresentation.sortedRows(rows).map(\.title), ["c-ready", "b-idle", "a-done"])
        XCTAssertTrue(SidebarSubspacePresentation.tally(rows).ready == 1)
    }

    func testFrozenOrderHoldsExistingRowsAndAppendsNewOnes() {
        let first = row("first", status: .working, index: 0)
        let second = row("second", status: .working, index: 1)
        let frozen = [second.id, first.id]

        var promoted = first
        promoted = SidebarSubspacePresentation.Row(
            id: first.id, title: first.title, status: .ready, annotations: [:], summary: nil,
            spawningSessionID: first.spawningSessionID, spawnerName: first.spawnerName,
            sessions: [], creationIndex: first.creationIndex
        )
        let added = row("added", status: .needsApproval, index: 2)

        XCTAssertEqual(
            SidebarSubspacePresentation.orderedRows([promoted, second, added], frozenOrder: frozen).map(\.title),
            ["second", "first", "added"]
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.orderedRows([promoted, second, added], frozenOrder: nil).map(\.title),
            ["first", "added", "second"]
        )
    }

    func testSelectedRowKeepsTheSlotItWasFoundInUntilTheSelectionMoves() {
        typealias Presentation = SidebarSubspacePresentation
        let a = row("a", status: .ready, index: 2)
        let b = row("b", status: .ready, index: 3)
        let w = row("w", status: .working, index: 0)
        let i = row("i", status: .idle, index: 1)
        let shownBeforeSelection = [a.id, b.id, w.id, i.id]
        func read(_ row: Presentation.Row) -> Presentation.Row {
            Presentation.Row(
                id: row.id, title: row.title, status: .idle, annotations: [:], summary: nil,
                spawningSessionID: row.spawningSessionID, spawnerName: row.spawnerName,
                sessions: [], creationIndex: row.creationIndex
            )
        }
        func order(
            _ rows: [Presentation.Row],
            previous: Presentation.Pin?,
            selected: UUID,
            shown: [UUID]
        ) -> (pin: Presentation.Pin?, titles: [String]) {
            let unpinned = Presentation.sortedRows(rows)
            let pin = Presentation.pin(
                previous: previous,
                selectedRowID: selected,
                displayedOrder: shown,
                unpinnedOrder: unpinned.map(\.id)
            )
            return (pin, Presentation.applyingPin(pin, to: unpinned).map(\.title))
        }

        // Selecting a reads it, but it stays first instead of sorting last.
        let first = order([read(a), b, w, i], previous: nil, selected: a.id, shown: shownBeforeSelection)
        XCTAssertEqual(first.titles, ["a", "b", "w", "i"])

        // Moving to b: b holds its slot and a settles among the idle rows.
        let second = order([read(a), read(b), w, i], previous: first.pin, selected: b.id, shown: shownBeforeSelection)
        XCTAssertEqual(second.pin, Presentation.Pin(rowID: b.id, index: 1))
        XCTAssertEqual(second.titles, ["w", "b", "i", "a"])

        // A filter that hides b keeps its pin for when the filter clears.
        XCTAssertEqual(
            Presentation.pin(previous: second.pin, selectedRowID: b.id, displayedOrder: [w.id, i.id], unpinnedOrder: [w.id, i.id]),
            second.pin
        )

        // Leaving the group releases the pin.
        let left = order([read(a), read(b), w, i], previous: second.pin, selected: UUID(), shown: [])
        XCTAssertNil(left.pin)
        XCTAssertEqual(left.titles, ["w", "i", "a", "b"])
    }

    func testSpawnerChipCountsToneAndFilterState() {
        let rows = [
            row("one", status: .ready, spawner: "a", index: 0),
            row("two", status: .needsApproval, spawner: "a", index: 1),
            row("three", status: .error, spawner: "b", index: 2),
            row("four", status: .working, spawner: nil, index: 3),
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
            creationIndex: 0,
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
            spawningSessionID: nil, spawnerName: nil, sessions: [], creationIndex: 1
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
}
