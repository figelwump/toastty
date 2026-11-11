import CoreState
import Foundation
import Testing

/// What waits for the coordinator and how it reads: one line for each task,
/// which changes wake it, the timer it sets, and the rule that a typed
/// digest removes that time.
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
        #expect(wake().digest(now: at(10)) == nil)
        #expect(wake().digest(now: at(86_400)) == nil)
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
        let digest = try #require(wake.digest(now: at(70)))
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
        let digest = try #require(wake.digest(now: at(2)))
        #expect(digest.contains("- [Fix the login](toastty://task/\(first.uuidString)): needsYou (awaitingReply) at "))
        #expect(digest.contains("- [Old task](toastty://task/\(second.uuidString)): deleted at "))
    }

    @Test func aTitleCannotBreakTheLineTheLinkOrTheTerminalPaste() throws {
        var wake = wake()
        let hostile = "Fix [urgent]\n\u{1B}[201~rm -rf ~\r](http://evil.example) \\ now"
        for change in changes(from: [first: state("running", title: hostile)], to: [first: state("idle", title: hostile)]) {
            wake.record(change, at: at(1))
        }
        let digest = try #require(wake.digest(now: at(2)))
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
        let longDigest = try #require(long.digest(now: at(2)))
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
        let lines = try #require(wake.digest(now: at(2))).split(separator: "\n")
        #expect(lines.count == 1 + 40 + 1 + 1)
        #expect(lines[41] == "- 5 more tasks changed.")
        #expect(lines.last == "Read `toastty task list` for details.")
    }

    // MARK: - Changes that wake nothing

    @Test func aTaskThatOnlyStartsRunningWakesNothingAndIsListedInTheNextDigest() throws {
        var wake = wake()
        for change in changes(from: [first: state("idle")], to: [first: state("running")]) {
            wake.record(change, at: at(5))
        }
        // It waits, but no digest is typed for it, at any time.
        #expect(wake.changes.map(\.wakes) == [false])
        #expect(wake.digest(now: at(6)) == nil)
        #expect(wake.digest(now: at(7 * 86_400)) == nil)

        // Another task's change wakes the coordinator: the digest lists both.
        for change in changes(from: [second: state("running", title: "Add the API")],
                              to: [second: state("needsYou", "review", title: "Add the API")]) {
            wake.record(change, at: at(65))
        }
        #expect(try #require(wake.digest(now: at(66))) == """
        [Toastty] Wake: this message is from Toastty, not from the user.
        - [Fix the login](toastty://task/11111111-1111-1111-1111-111111111111): running at 2027-01-15T08:00:05Z
        - [Add the API](toastty://task/22222222-2222-2222-2222-222222222222): needsYou (review) at 2027-01-15T08:01:05Z
        Read `toastty task list` for details.
        """)
    }

    @Test func onlyAPlainMoveIntoRunningWakesNothing() {
        // Into Running from any stage, a new task that starts, and a task
        // that a merge or a deletion also changed.
        let running = changes(from: [first: state("needsYou", "agentFinished"), second: state("toShip", merged: true)],
                              to: [first: state("running"), second: state("running", merged: true)])
        let deleted = changes(from: [first: state("running")], to: [:])
        let created = changes(from: [:], to: [first: state("running")])
        var wake = wake()
        for change in running + created + deleted {
            wake.record(change, at: at(1))
            #expect(wake.changes.last?.wakes == (change.state.key.merged || change.events.contains(.deleted)),
                    "\(change.state.key) \(change.events)")
        }
        // A move out of Running into any other stage wakes it.
        for after in [state("needsYou", "review"), state("idle"), state("toShip", merged: true), state("done"), state("archived")] {
            var other = self.wake()
            for change in changes(from: [first: state("running")], to: [first: after]) {
                other.record(change, at: at(1))
            }
            #expect(other.changes.map(\.wakes) == [true], "\(after.key)")
        }
    }

    @Test func aTasksNewestChangeDecidesWhetherItWakes() throws {
        // A task that needed something runs again before the digest is
        // typed: it needs nothing now, and nothing is typed.
        var wake = wake()
        for change in changes(from: [first: state("running")], to: [first: state("needsYou", "agentFinished")]) {
            wake.record(change, at: at(5))
        }
        #expect(wake.digest(now: at(6)) != nil)
        for change in changes(from: [first: state("needsYou", "agentFinished")], to: [first: state("running")]) {
            wake.record(change, at: at(10))
        }
        #expect(wake.changes.count == 1)
        #expect(wake.digest(now: at(11)) == nil)
        // And the other way: a running line that waits is replaced by a
        // change that wakes.
        for change in changes(from: [first: state("running")], to: [first: state("idle")]) {
            wake.record(change, at: at(20))
        }
        #expect(try #require(wake.digest(now: at(21))).contains("): idle at "))
    }

    // MARK: - Timer

    @Test func withNoTimeSetNoTimerRuns() {
        var wake = wake()
        #expect(wake.requestedWakeAt == nil)
        // Days after the last wake, with open tasks or not: nothing.
        #expect(wake.digest(now: at(30 * 86_400)) == nil)
        wake.markDelivered(at: at(60))
        #expect(wake.digest(now: at(30 * 86_400)) == nil)
    }

    @Test func aTimeTheCoordinatorSetFiresAtThatTimeAndClearingRemovesIt() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        #expect(wake.requestedWakeAt == at(1200))
        #expect(wake.digest(now: at(1199)) == nil)
        #expect(try #require(wake.digest(now: at(1200))) == """
        [Toastty] Wake: this message is from Toastty, not from the user.
        - Scheduled check: the time you set, 2027-01-15T08:20:00Z, has come.
        Read `toastty task list` for details.
        """)
        // Clearing it leaves no timer.
        wake.setRequestedWake(nil)
        #expect(wake.digest(now: at(30 * 86_400)) == nil)
    }

    @Test func aTimerThatCameDueTypesTheChangesThatWakeNothingWithIt() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        for change in changes(from: [first: state("idle")], to: [first: state("running")]) {
            wake.record(change, at: at(300))
        }
        #expect(wake.digest(now: at(1199)) == nil)
        let lines = try #require(wake.digest(now: at(1200))).split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[1].hasSuffix("): running at 2027-01-15T08:05:00Z"))
        #expect(lines[2] == "- Scheduled check: the time you set, 2027-01-15T08:20:00Z, has come.")
    }

    @Test func aTypedDigestTellsItsChangesAndRemovesTheTime() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        for change in changes(from: [first: state("running")], to: [first: state("needsYou", "review")]) {
            wake.record(change, at: at(300))
        }
        // A change and a timer that came due go in one digest.
        let both = try #require(wake.digest(now: at(1300))).split(separator: "\n")
        #expect(both.count == 4)
        #expect(both[2].hasPrefix("- Scheduled check: the time you set"))

        // Typed at 300 s, before the time the coordinator set: that time is
        // gone, and no timer runs until the coordinator sets one.
        wake.markDelivered(at: at(300))
        #expect(wake.changes.isEmpty)
        #expect(wake.requestedWakeAt == nil)
        #expect(wake.lastWakeAt == at(300))
        #expect(wake.digest(now: at(1300)) == nil)
        #expect(wake.digest(now: at(30 * 86_400)) == nil)
    }

    @Test func theStateSurvivesASave() throws {
        var wake = wake()
        wake.setRequestedWake(at(1200))
        for change in changes(from: [first: state("running"), second: state("idle")],
                              to: [first: state("done", merged: true), second: state("running")]) {
            wake.record(change, at: at(30))
        }
        let restored = try decoder.decode(CoordinatorWakeState.self, from: encoder.encode(wake))
        #expect(restored == wake)
        #expect(restored.changes.map(\.wakes) == [true, false])
        #expect(restored.digest(now: at(40)) == wake.digest(now: at(40)))
    }

    /// A state as the build before this one saved it: no `wakes`, no time
    /// set, and the last wake two hours before `t0`.
    private func savedByEarlierBuild(changes: String) -> Data {
        Data("""
        {
          "changes" : [\(changes)],
          "isFollowing" : true,
          "lastWakeAt" : "2027-01-15T06:00:00Z",
          "workspaceID" : "\(workspace.uuidString)"
        }
        """.utf8)
    }

    @Test func aStateSavedByTheEarlierBuildDecodesAndItsChangesWake() throws {
        // A running change woke the coordinator then. It still does once.
        let saved = savedByEarlierBuild(changes: """
            {
              "at" : "2027-01-15T08:00:30Z",
              "deleted" : false,
              "group" : "running",
              "merged" : false,
              "taskID" : "11111111-1111-1111-1111-111111111111",
              "title" : "Fix the login"
            },
            {
              "at" : "2027-01-15T08:00:40Z",
              "attention" : "review",
              "deleted" : false,
              "group" : "needsYou",
              "merged" : false,
              "taskID" : "22222222-2222-2222-2222-222222222222",
              "title" : "Add the API"
            }
            """)
        let restored = try decoder.decode(CoordinatorWakeState.self, from: saved)
        #expect(restored.workspaceID == workspace)
        #expect(restored.isFollowing)
        #expect(restored.requestedWakeAt == nil)
        #expect(restored.lastWakeAt == at(-7200))
        #expect(restored.changes.map(\.attention) == [nil, "review"])
        #expect(restored.changes.map(\.wakes) == [true, true])
        #expect(try #require(restored.digest(now: at(60))).contains("- [Fix the login](toastty://task/\(first.uuidString)): running at "))

        // Nothing waits, and the last wake was two hours ago with no time
        // set: the earlier build's default would fire. Now nothing does.
        let idle = try decoder.decode(CoordinatorWakeState.self, from: savedByEarlierBuild(changes: ""))
        #expect(idle.changes.isEmpty)
        #expect(idle.digest(now: at(60)) == nil)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func aChangeWithNoWebhookEventIsToldAndTheFirstLookTellsNothing() throws {
        // A release moves a merged task from To ship to Done. No webhook
        // event fires for that; the coordinator's line still moves.
        let release = changes(from: [first: state("toShip", merged: true)], to: [first: state("done", merged: true)])
        #expect(release.map(\.events) == [[]])
        var wake = wake()
        for change in release { wake.record(change, at: at(5)) }
        #expect(try #require(wake.digest(now: at(6))).contains("): done, merged at "))

        // Until the first look at the tasks is over, nothing is recorded.
        var fresh = CoordinatorWakeState(workspaceID: workspace, startedAt: t0)
        for change in release { fresh.record(change, at: at(5)) }
        #expect(fresh.changes.isEmpty)
        fresh.startFollowing()
        for change in release { fresh.record(change, at: at(5)) }
        #expect(fresh.changes.count == 1)
    }
}
