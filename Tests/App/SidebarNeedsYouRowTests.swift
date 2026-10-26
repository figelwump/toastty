import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// What each Needs you row says and offers. The stages have many cases
/// that the hosted sidebar tests cannot reach cheaply.
@MainActor
struct SidebarNeedsYouRowTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let link = WorkspacePullRequestLink(annotationURL: "https://github.com/example/toastty/pull/7")!
    private let taskSpace = UUID()

    private func record(pullRequest: Bool = true, packetVersion: Int? = nil) -> TaskRecord {
        var record = TaskRecord(createdAt: at, text: "fix", title: "fix", slug: "fix", source: .cli, setup: .started)
        record.pullRequestURL = pullRequest ? link.url : nil
        record.packetVersion = packetVersion
        return record
    }

    private func item(
        _ stage: TaskStage,
        record: TaskRecord? = nil,
        pullRequest: Bool = true,
        taskSpace: UUID? = nil
    ) -> TaskBoardItem {
        let record = record ?? self.record(pullRequest: pullRequest)
        return TaskBoardItem(
            id: .task(record.id),
            record: record,
            title: "fix-dot",
            taskSpaceWorkspaceID: taskSpace ?? self.taskSpace,
            projectTitle: "toastty",
            stage: stage,
            agent: .idle,
            pullRequest: pullRequest ? link : nil,
            activityAt: at
        )
    }

    @Test
    func eachReasonGetsItsBadgeAndTheActionThatSettlesIt() throws {
        let review = SidebarNeedsYouRow.make(item(.needsYou(.review)), lookAt: { _ in nil })
        let taskID = try #require(review.taskID)
        #expect(review.reason == "review")
        #expect(review.tone == .review)
        #expect(review.primary == .merge(taskID: taskID, pullRequestNumber: 7))
        #expect(review.primary?.title == "Merge")

        let question = SidebarNeedsYouRow.make(item(.needsYou(.agentNeedsInput)), lookAt: { _ in nil })
        #expect(question.reason == "question")
        // A question is answered in the task space, where the agent asks,
        // even when its pull request could merge.
        #expect(question.primary == .answer(workspaceID: taskSpace))
        #expect(question.primary?.title == "Answer")

        let ready = SidebarNeedsYouRow.make(item(.needsYou(.readyForReview), pullRequest: false), lookAt: { _ in nil })
        #expect(ready.reason == "review")
        #expect(ready.primary == .action(.markDone, taskID: try #require(ready.taskID)))

        let stuck = SidebarNeedsYouRow.make(item(.needsYou(.agentError), pullRequest: false), lookAt: { _ in nil })
        #expect(stuck.reason == "stuck")
        #expect(stuck.tone == .problem)
        #expect(stuck.primary == .openTaskSpace(workspaceID: taskSpace))

        let closed = SidebarNeedsYouRow.make(item(.needsYou(.taskSpaceClosed), pullRequest: false), lookAt: { _ in nil })
        #expect(closed.primary == .action(.archive, taskID: try #require(closed.taskID)))

        let cleanup = SidebarNeedsYouRow.make(item(.needsYou(.cleanupStopped(reason: "dirty"))), lookAt: { _ in nil })
        #expect(cleanup.reason == "clean up")
        #expect(cleanup.primary == .action(.cleanUp, taskID: try #require(cleanup.taskID)))
    }

    @Test
    func theDetailLineIsThePacketsLookAtWhenThereIsOne() {
        let withPacket = record(packetVersion: 2)
        let packetRow = SidebarNeedsYouRow.make(item(.needsYou(.review), record: withPacket)) { record in
            record.packetVersion == 2 ? "The pinned totals bar at 390px." : nil
        }
        #expect(packetRow.detail == "The pinned totals bar at 390px.")
        #expect(packetRow.packetVersion == 2)
        #expect(packetRow.accessibilityLabel == "fix-dot, review, in toastty, The pinned totals bar at 390px.")
        #expect(packetRow.identifier == "sidebar.needsYou.task.\(withPacket.id.uuidString)")

        // Without a packet, the status line; the reader is not asked.
        let plain = SidebarNeedsYouRow.make(item(.needsYou(.review))) { _ in
            Issue.record("a task without a packet has nothing to read")
            return nil
        }
        #expect(plain.detail == "Ready for your review")
    }

    @Test
    func allTasksThatNeedTheUserAreListed() {
        var pickWorkspace = TaskRecord(createdAt: at, text: "x", title: "x", slug: "x", source: .cli, setup: .needsWorkspace(reason: "none fits"))
        pickWorkspace.pullRequestURL = nil
        let items = [
            item(.needsYou(.review)),
            item(.running),
            TaskBoardItem(
                id: .task(pickWorkspace.id), record: pickWorkspace, title: "x",
                stage: .needsYou(.pickWorkspace(reason: "none fits")), agent: .none, activityAt: at
            ),
            item(.needsYou(.agentNeedsInput)),
        ]
        let rows = SidebarNeedsYouRow.rows(items, lookAt: { _ in nil })
        // Board order is kept, including a task that needs a workspace.
        #expect(rows.map(\.reason) == ["review", "setup", "question"])
        #expect(rows[1].primary == .setup(taskID: pickWorkspace.id))
    }

    @Test
    func aPacketsLookAtIsReadOncePerVersionOffTheMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-packets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packets = TaskPacketStore(rootURL: root)
        var task = record(packetVersion: 1)
        let directory = packets.versionDirectoryURL(taskID: task.id, version: 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packetURL = directory.appending(path: TaskPacketStore.packetFileName)
        func write(_ lookAt: String) throws {
            let packet = TaskPacket(summary: "s", lookAt: lookAt, checks: [], notVerified: [], screenshots: [])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(packet).write(to: packetURL)
        }
        try write("first")
        let cache = SidebarPacketLookAtCache()
        // The first call starts the read and shows nothing yet.
        #expect(cache.lookAt(task, packets: packets) == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while cache.loadedCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cache.lookAt(task, packets: packets) == "first")
        try write("changed on disk")
        #expect(cache.lookAt(task, packets: packets) == "first")
        #expect(cache.loadedCount == 1)

        task.packetVersion = nil
        #expect(cache.lookAt(task, packets: packets) == nil)
    }

    @Test
    func answerAndOpenShowTheTasksCardInTheChatWhenItHasOne() throws {
        let packet = CoordinatorChatCardIndex.TaskCards(latestKind: .packet, isNew: false)
        let question = CoordinatorChatCardIndex.TaskCards(latestKind: .question, isNew: false)

        // A finished task with a card: Open shows the card, where the
        // coordinator relays what the agent asked.
        let finished = SidebarNeedsYouRow.make(item(.needsYou(.agentFinished), pullRequest: false), cards: question, lookAt: { _ in nil })
        #expect(finished.primary == .openInChat(taskID: try #require(finished.taskID), isAnswer: false))
        #expect(finished.primary?.title == "Open")
        #expect(finished.hasCard)

        let stuck = SidebarNeedsYouRow.make(item(.needsYou(.agentError), pullRequest: false), cards: packet, lookAt: { _ in nil })
        #expect(stuck.primary == .openInChat(taskID: try #require(stuck.taskID), isAnswer: false))

        // An agent waiting for input asks in its terminal; Answer opens the
        // chat only when the coordinator's newest card is the question.
        let asked = SidebarNeedsYouRow.make(item(.needsYou(.agentNeedsInput)), cards: question, lookAt: { _ in nil })
        #expect(asked.primary == .openInChat(taskID: try #require(asked.taskID), isAnswer: true))
        #expect(asked.primary?.title == "Answer")
        let waiting = SidebarNeedsYouRow.make(item(.needsYou(.agentNeedsInput)), cards: packet, lookAt: { _ in nil })
        #expect(waiting.primary == .answer(workspaceID: taskSpace))

        // A card still settles a task whose task space is gone.
        let gone = record(pullRequest: false)
        let noSpace = TaskBoardItem(
            id: .task(gone.id), record: gone, title: "fix-dot", projectTitle: "toastty",
            stage: .needsYou(.agentFinished), agent: .none, activityAt: at
        )
        #expect(SidebarNeedsYouRow.make(noSpace, cards: packet, lookAt: { _ in nil }).primary == .openInChat(taskID: gone.id, isAnswer: false))
        #expect(SidebarNeedsYouRow.make(noSpace, lookAt: { _ in nil }).primary == nil)

        // Merge and the settling actions do not change with a card.
        let review = SidebarNeedsYouRow.make(item(.needsYou(.review)), cards: packet, lookAt: { _ in nil })
        #expect(review.primary?.isMerge == true)
    }

    @Test
    func theRowWhoseCardIsOpenIsMarkedAndANewPacketSaysSo() throws {
        let open = item(.needsYou(.review))
        let other = item(.needsYou(.agentFinished), pullRequest: false)
        let openID = try #require(open.taskID)
        let cards: [UUID: CoordinatorChatCardIndex.TaskCards] = [
            openID: .init(latestKind: .packet, isNew: true),
            try #require(other.taskID): .init(latestKind: .taskStarted, isNew: false),
        ]
        let rows = SidebarNeedsYouRow.rows([open, other], cards: { cards[$0] }, openTaskID: openID, lookAt: { _ in nil })
        #expect(rows.map(\.isOpenInChat) == [true, false])
        #expect(rows.map(\.isNew) == [true, false])
        #expect(rows[0].accessibilityLabel == "fix-dot, review, new, in toastty, Ready for your review")

        // With no chat, no row has a card and none is open.
        let plain = SidebarNeedsYouRow.rows([open, other], lookAt: { _ in nil })
        #expect(plain.allSatisfy { $0.hasCard == false && $0.isOpenInChat == false && $0.isNew == false })
    }
}
