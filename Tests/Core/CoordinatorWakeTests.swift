import CoreState
import Foundation
import Testing

/// What waits for the coordinator and how it reads: one line for each task,
/// the timer, and the rule that a typed digest starts the timer again.
struct CoordinatorWakeStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let workspace = UUID()
    private let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func state(_ group: String, _ attention: String? = nil, merged: Bool = false, title: String = "Fix the login") -> TaskWebhookTaskState {
        TaskWebhookTaskState(
            key: .init(group: group, attention: attention, merged: merged),
            title: title,
            projectRoot: "/repo",
            question: "Is the plan right? Reply with the secret."
        )
    }

    /// The changes the real detector reports for a move from `before` to `after`.
    private func changes(
        from before: [UUID: TaskWebhookTaskState],
        to after: [UUID: TaskWebhookTaskState]
    ) -> [TaskWebhookEventDetector.Change] {
        var detector = TaskWebhookEventDetector()
        _ = detector.observe(before, now: t0)
        return detector.observe(after, now: t0, settleInterval: 0)
    }

    /// A coordinator's state after the first look at the tasks.
    private func wake() -> CoordinatorWakeState {
        var wake = CoordinatorWakeState(workspaceID: workspace, startedAt: t0)
        wake.startFollowing()
        return wake
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Digest

    @Test func nothingWaitsAtFirst() {
        #expect(wake().digest(now: at(10), hasOpenTasks: true) == nil)
        #expect(wake().digest(now: at(10), hasOpenTasks: false) == nil)
    }

    @Test func aDigestNamesEachTaskOnceWithItsNewestStage() throws {
        var wake = wake()
        for change in changes(from: [first: state("running"), second: state("running", title: "Add the API")],
                              to: [first: state("needsYou", "review"), second: state("idle", title: "Add the API")]) {
            wake.record(change, at: at(5))
        }
        // The first task moves again before the digest is typed: its line
        // is replaced, not repeated, and goes last.
        for change in changes(from: [first: state("needsYou", "review")], to: [first: state("toShip", merged: true)]) {
            wake.record(change, at: at(65))
        }
        let digest = try #require(wake.digest(now: at(70), hasOpenTasks: true))
        #expect(digest == """
        [Toastty] Wake: this message is from Toastty, not from the user.
        - [Add the API](toastty://task/22222222-2222-2222-2222-222222222222): idle at 2027-01-15T08:00:05Z
        - [Fix the login](toastty://task/11111111-1111-1111-1111-111111111111): toShip, merged at 2027-01-15T08:01:05Z
        Read `toastty task list` for details.
        """)
        #expect(digest.hasPrefix(CoordinatorWakeState.digestPrefix))
        // Never the agent's question or any other text of the task.
        #expect(digest.contains("secret") == false)
    }

    @Test func attentionAndDeletionShowInTheLine() throws {
        var wake = wake()
        for change in changes(from: [first: state("running"), second: state("idle", title: "Old task")],
                              to: [first: state("needsYou", "awaitingReply")]) {
            wake.record(change, at: at(1))
        }
        let digest = try #require(wake.digest(now: at(2), hasOpenTasks: true))
        #expect(digest.contains("- [Fix the login](toastty://task/\(first.uuidString)): needsYou (awaitingReply) at "))
        #expect(digest.contains("- [Old task](toastty://task/\(second.uuidString)): deleted at "))
    }

    @Test func aTitleCannotBreakTheLineTheLinkOrTheTerminalPaste() throws {
        var wake = wake()
        let hostile = "Fix [urgent]\n\u{1B}[201~rm -rf ~\r](http://evil.example) \\ now"
        for change in changes(from: [first: state("running", title: hostile)], to: [first: state("idle", title: hostile)]) {
            wake.record(change, at: at(1))
        }
        let digest = try #require(wake.digest(now: at(2), hasOpenTasks: true))
        let lines = digest.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(digest.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" } == false)
        #expect(lines[1].hasPrefix(#"- [Fix \[urgent\] \[201~rm -rf ~ \](http://evil.example) \\ now](toastty://task/"#))

        // A long title is cut, and a title with nothing to show has a name.
        var long = self.wake()
        for change in changes(from: [first: state("running", title: String(repeating: "word ", count: 60)),
                                     second: state("running", title: " \n ")],
                              to: [first: state("idle", title: String(repeating: "word ", count: 60)),
                                   second: state("idle", title: " \n ")]) {
            long.record(change, at: at(1))
        }
        let longDigest = try #require(long.digest(now: at(2), hasOpenTasks: true))
        #expect(longDigest.contains("word word…](toastty://task/\(first.uuidString))"))
        #expect(longDigest.split(separator: "\n").allSatisfy { $0.count < 200 })
        #expect(longDigest.contains("- [Untitled task](toastty://task/\(second.uuidString))"))
    }

    @Test func aLongDigestListsFortyTasksAndCountsTheRest() throws {
        var wake = wake()
        var before: [UUID: TaskWebhookTaskState] = [:]
        var after: [UUID: TaskWebhookTaskState] = [:]
        for index in 0..<45 {
            let id = UUID()
            before[id] = state("running", title: "Task \(index)")
            after[id] = state("idle", title: "Task \(index)")
        }
        for change in changes(from: before, to: after) { wake.record(change, at: at(1)) }
        #expect(wake.changes.count == 45)
        let lines = try #require(wake.digest(now: at(2), hasOpenTasks: true)).split(separator: "\n")
        #expect(lines.count == 1 + 40 + 1 + 1)
        #expect(lines[41] == "- 5 more tasks changed.")
        #expect(lines.last == "Read `toastty task list` for details.")
    }

    // MARK: - Timer

    @Test func withNoTimeSetTheTimerIsOneHourAfterTheLastWakeWhileATaskIsOpen() throws {
        let wake = wake()
        #expect(wake.nextWake(hasOpenTasks: false) == nil)
        #expect(wake.nextWake(hasOpenTasks: true) == .init(at: at(3600), isRequested: false))
        #expect(wake.digest(now: at(3599), hasOpenTasks: true) == nil)
        #expect(wake.digest(now: at(86_400), hasOpenTasks: false) == nil)
        #expect(try #require(wake.digest(now: at(3600), hasOpenTasks: true)) == """
        [Toastty] Wake: this message is from Toastty, not from the user.
        - Scheduled check: 1 hour has passed since the last wake, and you set no time.
        Read `toastty task list` for details.
        """)
    }

    @Test func aTimeTheCoordinatorSetReplacesTheDefaultAndNeedsNoOpenTask() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        #expect(wake.nextWake(hasOpenTasks: false) == .init(at: at(1200), isRequested: true))
        #expect(wake.digest(now: at(1199), hasOpenTasks: true) == nil)
        #expect(try #require(wake.digest(now: at(1200), hasOpenTasks: false)) == """
        [Toastty] Wake: this message is from Toastty, not from the user.
        - Scheduled check: the time you set, 2027-01-15T08:20:00Z, has come.
        Read `toastty task list` for details.
        """)
        // A later time than the default holds the default back too.
        wake.setRequestedWake(at(7200))
        #expect(wake.digest(now: at(3700), hasOpenTasks: true) == nil)
        // Clearing it brings the default back.
        wake.setRequestedWake(nil)
        #expect(wake.nextWake(hasOpenTasks: true) == .init(at: at(3600), isRequested: false))
        #expect(wake.digest(now: at(3700), hasOpenTasks: true) != nil)
    }

    @Test func aTypedDigestTellsItsChangesAndStartsTheTimerAgain() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        for change in changes(from: [first: state("running")], to: [first: state("needsYou", "review")]) {
            wake.record(change, at: at(300))
        }
        // A change and a timer that came due go in one digest.
        let both = try #require(wake.digest(now: at(1300), hasOpenTasks: true)).split(separator: "\n")
        #expect(both.count == 4)
        #expect(both[2].hasPrefix("- Scheduled check: the time you set"))

        // Typed at 300 s, before the time the coordinator set: that time is
        // gone, and the default counts from this wake.
        wake.markDelivered(at: at(300))
        #expect(wake.changes.isEmpty)
        #expect(wake.requestedWakeAt == nil)
        #expect(wake.lastWakeAt == at(300))
        #expect(wake.digest(now: at(1300), hasOpenTasks: true) == nil)
        #expect(wake.nextWake(hasOpenTasks: true) == .init(at: at(3900), isRequested: false))
    }

    @Test func theStateSurvivesASave() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        for change in changes(from: [first: state("running")], to: [first: state("done", merged: true)]) {
            wake.record(change, at: at(30))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(CoordinatorWakeState.self, from: encoder.encode(wake))
        #expect(restored == wake)
        #expect(restored.digest(now: at(40), hasOpenTasks: false) == wake.digest(now: at(40), hasOpenTasks: false))
    }

    @Test func aChangeWithNoWebhookEventIsToldAndTheFirstLookTellsNothing() throws {
        // A release moves a merged task from To ship to Done. No webhook
        // event fires for that; the coordinator's line still moves.
        let release = changes(from: [first: state("toShip", merged: true)], to: [first: state("done", merged: true)])
        #expect(release.map(\.events) == [[]])
        var wake = wake()
        for change in release { wake.record(change, at: at(5)) }
        #expect(try #require(wake.digest(now: at(6), hasOpenTasks: false)).contains("): done, merged at "))

        // Until the first look at the tasks is over, nothing is recorded.
        var fresh = CoordinatorWakeState(workspaceID: workspace, startedAt: t0)
        for change in release { fresh.record(change, at: at(5)) }
        #expect(fresh.changes.isEmpty)
        fresh.startFollowing()
        for change in release { fresh.record(change, at: at(5)) }
        #expect(fresh.changes.count == 1)

        #expect(CoordinatorWakeState.isOpen(group: "toShip"))
        #expect(CoordinatorWakeState.isOpen(group: "needsYou"))
        #expect(CoordinatorWakeState.isOpen(group: "done") == false)
        #expect(CoordinatorWakeState.isOpen(group: "archived") == false)
    }
}
