import CoreState
import Foundation
import Testing

struct TaskAttachmentRetentionTests {
    private let seen = Date(timeIntervalSince1970: 1_800_000_000)
    private let week = TaskAttachmentRetention.keepAfterFinish

    private func record(_ change: (inout TaskRecord) -> Void = { _ in }) -> TaskRecord {
        var record = TaskRecord(
            createdAt: seen.addingTimeInterval(-3600),
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

    private func step(
        _ record: TaskRecord,
        after interval: TimeInterval = 0,
        hasFiles: Bool = true,
        releaseTags: Bool = false,
        taskSpaceOpen: Bool = false
    ) -> TaskAttachmentRetention.Step {
        TaskAttachmentRetention.step(
            record,
            hasFiles: hasFiles,
            releaseTagsConfigured: releaseTags,
            taskSpaceOpen: taskSpaceOpen,
            now: seen.addingTimeInterval(interval)
        )
    }

    @Test
    func doneOrArchivedTasksLoseTheirFilesAWeekAfterTheSweepSawThem() {
        for finished in [
            record { $0.doneAt = seen },
            record { $0.archivedAt = seen },
            record { $0.mergedAt = seen; $0.shippedAt = seen },
            record { $0.mergedAt = seen },
        ] {
            #expect(step(finished) == .startClock)
            var counting = finished
            counting.attachmentsFinishedSeenAt = seen
            #expect(step(counting, after: week - 1) == .none)
            #expect(step(counting, after: week) == .remove)
        }
    }

    @Test
    func theWeekStartsWhenTheTaskBecomesDoneNotWhenItMerged() {
        // Merged three weeks ago and waited in To ship; release_tags was
        // removed, so it is Done only now.
        let merged = record { $0.mergedAt = seen.addingTimeInterval(-3 * week) }
        #expect(step(merged, releaseTags: true) == .none)
        #expect(step(merged, releaseTags: false) == .startClock)
    }

    @Test
    func leavingDoneResetsTheWeek() {
        let resumed = record { $0.attachmentsFinishedSeenAt = seen }
        #expect(step(resumed, after: 2 * week) == .resetClock)
        // Back in To ship when release_tags returns.
        let toShip = record { $0.mergedAt = seen; $0.attachmentsFinishedSeenAt = seen }
        #expect(step(toShip, after: 2 * week, releaseTags: true) == .resetClock)
        // A task space that opens again keeps the files.
        let reopened = record { $0.doneAt = seen; $0.attachmentsFinishedSeenAt = seen }
        #expect(step(reopened, after: 2 * week, taskSpaceOpen: true) == .resetClock)
    }

    @Test
    func unfinishedOrBusyTasksKeepTheirFiles() {
        #expect(step(record()) == .none)
        // A cleanup that stopped puts the task back in Needs you.
        let stopped = record {
            $0.archivedAt = seen
            $0.cleanup = TaskCleanup(kind: .archive, problem: "The worktree has uncommitted changes.")
        }
        #expect(step(stopped) == .none)
        // A retry runs setup or the move into a worktree again.
        let retrying = record { $0.archivedAt = seen; $0.setup = .settingUp }
        #expect(step(retrying) == .none)
        let moving = record {
            $0.doneAt = seen
            $0.startWork = TaskStartWork(
                branchPrefix: "fix",
                source: .init(sessionID: "s1", panelID: UUID(), agent: "claude"),
                requestedAt: seen,
                state: .running
            )
        }
        #expect(step(moving) == .none)
    }

    @Test
    func noFolderOrAnEarlierRemovalKeepsTheSweepAway() {
        let done = record { $0.doneAt = seen; $0.attachmentsFinishedSeenAt = seen }
        #expect(step(done, after: 2 * week, hasFiles: false) == .none)
        var removed = done
        removed.attachmentsRemovedAt = seen
        #expect(step(removed, after: 2 * week) == .none)
        // A record rebuilt from its task space has no file list, but its
        // folder still counts.
        var recovered = done
        recovered.attachments = []
        #expect(step(recovered, after: week) == .remove)
    }
}
