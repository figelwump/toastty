import CoreState
import Foundation
import Testing

struct TaskWatchTests {
    private let made = Date(timeIntervalSince1970: 1_000)

    @Test
    func idleCountsOnlyATurnThatEndedAfterTheWatch() {
        let later = made.addingTimeInterval(5)
        let before = TaskWatchFacts(activity: .idle, activityChangedAt: later, turnEndedAt: made.addingTimeInterval(-5))
        let after = TaskWatchFacts(activity: .idle, activityChangedAt: later, turnEndedAt: later)
        // A session restored after a relaunch reports a fresh status but has
        // not finished a turn.
        let restored = TaskWatchFacts(activity: .idle, activityChangedAt: later, turnEndedAt: nil)
        let busyAgain = TaskWatchFacts(activity: .busy, activityChangedAt: later, turnEndedAt: later)
        #expect(TaskWatchEvaluation.holds(.idle, createdAt: made, facts: before) == false)
        #expect(TaskWatchEvaluation.holds(.idle, createdAt: made, facts: restored) == false)
        #expect(TaskWatchEvaluation.holds(.idle, createdAt: made, facts: busyAgain) == false)
        #expect(TaskWatchEvaluation.holds(.idle, createdAt: made, facts: after))
    }

    @Test
    func waitingHoldsWhileTheAgentWaits() {
        // An approval that was already waiting is still actionable.
        let waiting = TaskWatchFacts(activity: .waiting, activityChangedAt: made.addingTimeInterval(-60))
        #expect(TaskWatchEvaluation.holds(.waiting, createdAt: made, facts: waiting))
        #expect(TaskWatchEvaluation.holds(.waiting, createdAt: made, facts: TaskWatchFacts(activity: .idle, activityChangedAt: nil)) == false)
    }

    @Test
    func stageConditionsReadTheStagesAndArchiveEndsOtherWatches() {
        let merged = TaskWatchFacts(activity: .notRunning, activityChangedAt: nil, stages: [.merged, .toShip])
        #expect(TaskWatchEvaluation.holds(.merged, createdAt: made, facts: merged))
        #expect(TaskWatchEvaluation.holds(.done, createdAt: made, facts: merged) == false)
        #expect(TaskWatchEvaluation.impossibility(.done, facts: merged) == nil)

        let archived = TaskWatchFacts(activity: .notRunning, activityChangedAt: nil, stages: [.archived])
        #expect(TaskWatchEvaluation.impossibility(.done, facts: archived) == "was archived")
        #expect(TaskWatchEvaluation.impossibility(.archived, facts: archived) == nil)
        #expect(TaskWatchEvaluation.holds(.archived, createdAt: made, facts: archived))
    }

    @Test
    func recordsSavedBeforeWatchesExistedStillLoad() throws {
        let record = TaskRecord(createdAt: made, text: "Fix the dot", title: "Fix the dot", slug: "fix-the-dot", source: .cli)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["watches"] = nil
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.watches == nil)
        #expect(decoded.activeWatches.isEmpty)
    }

    @Test
    func watchStatesRoundTrip() throws {
        let watches = [
            TaskWatch(targetTaskID: UUID(), condition: .idle, createdAt: made),
            TaskWatch(
                targetTaskID: UUID(),
                condition: .merged,
                createdAt: made,
                state: .fired(at: made.addingTimeInterval(9), reason: "was deleted", impossible: true, delivered: false)
            ),
        ]
        let decoded = try JSONDecoder().decode([TaskWatch].self, from: JSONEncoder().encode(watches))
        #expect(decoded == watches)
    }

    @Test
    func pruningKeepsUndeliveredAndRecentWatches() {
        var record = TaskRecord(createdAt: made, text: "t", title: "t", slug: "t", source: .cli)
        let now = made.addingTimeInterval(48 * 3600)
        let pending = TaskWatch(targetTaskID: UUID(), condition: .idle, createdAt: made)
        let undeliveredOld = TaskWatch(
            targetTaskID: UUID(), condition: .idle, createdAt: made,
            state: .fired(at: made, reason: "is idle", impossible: false, delivered: false)
        )
        let deliveredOld = TaskWatch(
            targetTaskID: UUID(), condition: .idle, createdAt: made,
            state: .fired(at: made, reason: "is idle", impossible: false, delivered: true)
        )
        let deliveredRecent = (0..<3).map { index in
            TaskWatch(
                targetTaskID: UUID(), condition: .idle, createdAt: made,
                state: .fired(at: now.addingTimeInterval(Double(-index)), reason: "is idle", impossible: false, delivered: true)
            )
        }
        record.watches = [pending, undeliveredOld, deliveredOld] + deliveredRecent
        record.pruneFiredWatches(now: now, keep: 2)
        #expect(record.watches?.map(\.id) == [pending.id, undeliveredOld.id] + deliveredRecent.prefix(2).map(\.id))
        #expect(record.activeWatches.map(\.id) == [pending.id, undeliveredOld.id])
    }
}
