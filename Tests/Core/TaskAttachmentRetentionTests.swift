import CoreState
import Foundation
import Testing

struct TaskAttachmentRetentionTests {
    private let finished = Date(timeIntervalSince1970: 1_800_000_000)
    private let week = TaskAttachmentRetention.keepAfterFinish

    private func record(_ change: (inout TaskRecord) -> Void = { _ in }) -> TaskRecord {
        var record = TaskRecord(
            createdAt: finished.addingTimeInterval(-3600),
            text: "x",
            attachments: [TaskAttachment(path: "/tmp/a/shot.png", displayName: "shot.png")],
            title: "x",
            slug: "x",
            source: .cli,
            setup: .started
        )
        change(&record)
        return record
    }

    private func removes(
        _ record: TaskRecord,
        after interval: TimeInterval,
        releaseTags: Bool = false,
        taskSpaceOpen: Bool = false
    ) -> Bool {
        TaskAttachmentRetention.shouldRemove(
            record,
            releaseTagsConfigured: releaseTags,
            taskSpaceOpen: taskSpaceOpen,
            now: finished.addingTimeInterval(interval)
        )
    }

    @Test
    func doneOrArchivedTasksLoseTheirFilesAfterAWeek() {
        for finishedRecord in [
            record { $0.doneAt = finished },
            record { $0.archivedAt = finished },
            record { $0.mergedAt = finished; $0.shippedAt = finished },
        ] {
            #expect(removes(finishedRecord, after: week - 1) == false)
            #expect(removes(finishedRecord, after: week))
        }
    }

    @Test
    func aMergeCountsAsFinishedOnlyWithoutReleaseTags() {
        let merged = record { $0.mergedAt = finished }
        #expect(removes(merged, after: week))
        // With release_tags the task waits in To ship, and keeps its files.
        #expect(removes(merged, after: 30 * week, releaseTags: true) == false)
    }

    @Test
    func unfinishedTasksKeepTheirFiles() {
        #expect(removes(record(), after: 30 * week) == false)
        // Work resumed after a done mark: the record's mark is cleared.
        let resumed = record { $0.doneAt = nil; $0.readyForReviewAt = finished }
        #expect(removes(resumed, after: 30 * week) == false)
        // A cleanup that stopped puts the task back in Needs you.
        let stopped = record {
            $0.archivedAt = finished
            $0.cleanup = TaskCleanup(kind: .archive, problem: "The worktree has uncommitted changes.")
        }
        #expect(removes(stopped, after: 30 * week) == false)
    }

    @Test
    func theWeekCountsFromTheFirstFinish() {
        let doneThenShipped = record {
            $0.doneAt = finished
            $0.shippedAt = finished.addingTimeInterval(week)
        }
        #expect(removes(doneThenShipped, after: week))
    }

    @Test
    func anOpenTaskSpaceOrAnEarlierRemovalKeepsTheSweepAway() {
        let done = record { $0.doneAt = finished }
        #expect(removes(done, after: 30 * week, taskSpaceOpen: true) == false)
        let removed = record { $0.doneAt = finished; $0.attachmentsRemovedAt = finished.addingTimeInterval(week) }
        #expect(removes(removed, after: 30 * week) == false)
        let noFiles = record { $0.doneAt = finished; $0.attachments = [] }
        #expect(removes(noFiles, after: 30 * week) == false)
    }
}
