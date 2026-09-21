import CoreState
import Foundation
import Testing

struct NavigationHistoryTests {
    @Test
    func firstVisitPreservesOriginAndTraversalCommitsOnlyAfterSelection() throws {
        let a = UUID(), b = UUID()
        var history = NavigationHistory()
        history.recordVisit(from: a, to: b)

        let back = try #require(history.destination(direction: .back, currentPanelID: b, isLive: { _ in true }))
        #expect(history.entries == [a, b])
        #expect(history.cursor == 1)
        #expect(back == NavigationHistoryDestination(index: 0, panelID: a))
        #expect(history.destination(direction: .forward, currentPanelID: b, isLive: { _ in true }) == nil)

        history.commitTraversal(to: back.index)
        #expect(history.destination(direction: .back, currentPanelID: a, isLive: { _ in true }) == nil)
        #expect(history.destination(direction: .forward, currentPanelID: a, isLive: { _ in true })?.panelID == b)
    }

    @Test
    func branchingDiscardsForwardVisitsButRepeatedSelectionPreservesThem() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var history = NavigationHistory()
        history.recordVisit(from: a, to: b)
        history.recordVisit(from: b, to: c)
        history.commitTraversal(to: 1)

        history.recordVisit(from: b, to: b)
        #expect(history.entries == [a, b, c])
        #expect(history.cursor == 1)

        history.recordVisit(from: b, to: d)
        #expect(history.entries == [a, b, d])
        #expect(history.cursor == 2)
        #expect(history.destination(direction: .forward, currentPanelID: d, isLive: { _ in true }) == nil)
    }

    @Test
    func repeatedNonadjacentVisitRemainsADestination() {
        let a = UUID(), b = UUID()
        var history = NavigationHistory()
        history.recordVisit(from: a, to: b)
        history.recordVisit(from: b, to: a)

        #expect(history.entries == [a, b, a])
        #expect(history.destination(direction: .back, currentPanelID: a, isLive: { _ in true })?.panelID == b)
    }

    @Test
    func closedCurrentPanelRetainsBoundaryAndSkipsDisplayedFallback() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var history = NavigationHistory()
        history.recordVisit(from: a, to: b)
        history.recordVisit(from: b, to: c)
        history.recordVisit(from: c, to: d)
        history.commitTraversal(to: 2)
        let live: Set<UUID> = [a, b, d]

        #expect(history.destination(direction: .back, currentPanelID: b, isLive: live.contains)?.panelID == a)
        #expect(history.destination(direction: .forward, currentPanelID: b, isLive: live.contains)?.panelID == d)
        #expect(history.cursor == 2)
        #expect(history.entries == [a, b, c, d])
    }

    @Test
    func branchAfterAutomaticFallbackPreservesActualOrigin() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        var history = NavigationHistory()
        history.recordVisit(from: a, to: b)
        history.recordVisit(from: b, to: c)
        history.recordVisit(from: c, to: d)
        history.commitTraversal(to: 2)

        history.recordVisit(from: b, to: e)
        #expect(history.entries == [a, b, c, b, e])
        #expect(history.destination(direction: .back, currentPanelID: e, isLive: { $0 != c })?.panelID == b)
        #expect(history.destination(direction: .forward, currentPanelID: e, isLive: { $0 != c }) == nil)
    }

    @Test
    func deadDestinationsAreSkippedAndLivenessIsResolvedOnEveryLookup() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = NavigationHistory()
        history.recordVisit(from: a, to: b)
        history.recordVisit(from: b, to: c)

        #expect(history.destination(direction: .back, currentPanelID: c, isLive: { $0 == a })?.panelID == a)
        #expect(history.destination(direction: .back, currentPanelID: c, isLive: { _ in false }) == nil)
        // A moved panel is still visited by its stable ID; history stores no old workspace or window.
        #expect(history.destination(direction: .back, currentPanelID: c, isLive: { _ in true })?.panelID == b)
    }

    @Test
    func capacityEvictsOldestVisitsAndKeepsCursorAtNewDestination() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        var history = NavigationHistory(capacity: 3)
        history.recordVisit(from: a, to: b)
        history.recordVisit(from: b, to: c)
        history.recordVisit(from: c, to: d)
        #expect(history.entries == [b, c, d])
        #expect(history.cursor == 2)

        history.commitTraversal(to: 1)
        history.recordVisit(from: c, to: e)
        #expect(history.entries == [b, c, e])
        #expect(history.cursor == 2)
    }

    @Test
    func smallestCapacityRetainsOnlyLatestDestination() {
        var history = NavigationHistory(capacity: 1)
        let destination = UUID()
        history.recordVisit(from: UUID(), to: destination)
        #expect(history.entries == [destination])
        #expect(history.cursor == 0)
        #expect(history.destination(direction: .back, currentPanelID: destination, isLive: { _ in true }) == nil)
    }

    @Test
    func emptyOriginAndClearDoNotCreatePhantomDestinations() {
        var history = NavigationHistory()
        let a = UUID(), b = UUID()
        #expect(history.destination(direction: .back, currentPanelID: nil, isLive: { _ in true }) == nil)
        history.recordVisit(from: nil, to: a)
        history.recordVisit(from: a, to: b)
        history.clear()
        #expect(history.entries.isEmpty)
        #expect(history.cursor == nil)
        #expect(history.commitTraversal(to: 0) == false)
        history.recordVisit(from: nil, to: b)
        #expect(history.entries == [b])
        #expect(history.cursor == 0)
    }

    @Test
    func invalidTraversalCommitLeavesCursorUnchanged() {
        var history = NavigationHistory()
        history.recordVisit(from: UUID(), to: UUID())
        #expect(history.commitTraversal(to: -1) == false)
        #expect(history.commitTraversal(to: 2) == false)
        #expect(history.cursor == 1)
    }
}
