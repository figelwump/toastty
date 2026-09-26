@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class SidebarSubspacePresentationTests: XCTestCase {
    private func row(
        _ name: String,
        status: SidebarSubspacePresentation.RowStatus,
        spawner: String? = "spawner-a",
        index: Int
    ) -> SidebarSubspacePresentation.Row {
        SidebarSubspacePresentation.Row(
            id: UUID(),
            title: name,
            status: status,
            annotations: [:],
            summary: nil,
            spawningSessionID: spawner,
            spawnerName: spawner.map { "Agent \($0)" },
            sessions: [],
            creationIndex: index
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

    func testSortedRowsRankByStatusAndKeepCreationOrderWithinAStatus() {
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
                .init(title: "Rebase fixture", panelID: UUID(), statusKind: .working, summary: "Rebasing onto main"),
                .init(title: "Screenshot pass", panelID: UUID(), statusKind: .idle, summary: nil),
                .init(title: "Collect logs", panelID: UUID(), statusKind: .ready, showsUnreadSessionAccent: true, summary: "Saved 3 logs"),
                .init(
                    title: "Fix nav drawer focus", panelID: approvalPanelID, agentLabel: "claude",
                    statusKind: .needsApproval, summary: "pnpm db:migrate"
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
