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
            pullRequest: nil,
            summary: nil,
            spawningSessionID: spawner,
            spawnerName: spawner.map { "Agent \($0)" },
            sessions: [],
            creationIndex: index
        )
    }

    func testRowStatusLetsAgentAttentionWinAndTaskStatusLiftIdleRows() {
        typealias Session = (kind: SessionStatusKind, showsUnreadSessionAccent: Bool)
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.working, false), Session(.needsApproval, false)],
                taskStatusText: "Ready for your testing"
            ),
            .needsApproval
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.ready, true), Session(.error, false)],
                taskStatusText: nil
            ),
            .error
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.error, false), Session(.needsApproval, false), Session(.ready, true)],
                taskStatusText: nil
            ),
            .needsApproval
        )
        // A running agent outranks a stale "Ready" annotation.
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.working, false)],
                taskStatusText: "Ready"
            ),
            .working
        )
        // A finished turn the user has already looked at is quiet; the
        // annotation says the task is ready, so the row does too.
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(
                sessionStatuses: [Session(.ready, false)],
                taskStatusText: " ready for your testing "
            ),
            .ready
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(sessionStatuses: [], taskStatusText: "Working"),
            .idle
        )
        XCTAssertEqual(
            SidebarSubspacePresentation.rowStatus(sessionStatuses: [Session(.ready, true)], taskStatusText: nil),
            .ready
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
            id: first.id, title: first.title, status: .ready, pullRequest: nil, summary: nil,
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

    func testHoverTipModelListsEverySessionAndTheSpawner() {
        let row = SidebarSubspacePresentation.Row(
            id: UUID(), title: "qa-mobile-navigation", status: .needsApproval,
            pullRequest: WorkspaceAnnotation(text: "PR #132"), summary: "pnpm db:migrate",
            spawningSessionID: "a", spawnerName: "Test EmptyOS beta experience",
            sessions: [
                .init(title: "Fix nav drawer focus", statusKind: .needsApproval, summary: "pnpm db:migrate"),
                .init(title: "Review nav tests", statusKind: .idle, summary: nil),
            ],
            creationIndex: 0
        )
        let model = SidebarSubspacePresentation.hoverTipModel(row)
        XCTAssertEqual(model.name, "qa-mobile-navigation")
        XCTAssertEqual(model.typeLabel, "subspace")
        XCTAssertEqual(model.statusDotColorKind, .needsApproval)
        XCTAssertEqual(model.bodyText, "Fix nav drawer focus — needs approval: pnpm db:migrate\nReview nav tests — idle")
        XCTAssertEqual(model.metaItems, ["needs approval", "PR #132", "spawned by Test EmptyOS beta experience"])

        let empty = SidebarSubspacePresentation.hoverTipModel(SidebarSubspacePresentation.Row(
            id: UUID(), title: "idle-space", status: .idle, pullRequest: nil, summary: "Ready",
            spawningSessionID: nil, spawnerName: nil, sessions: [], creationIndex: 1
        ))
        XCTAssertEqual(empty.bodyText, "No agent · Ready")
        XCTAssertEqual(empty.metaItems, ["idle"])
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
