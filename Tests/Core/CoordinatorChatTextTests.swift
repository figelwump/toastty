import CoreState
import Foundation
import Testing

/// The two readings the coordinator's chat makes of text it did not write:
/// which links name a task, and which messages are Toastty's digests.
struct CoordinatorChatTextTests {
    private let taskID = UUID(uuidString: "8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F")!

    // MARK: - Task links

    @Test func aTaskLinkNamesItsTask() throws {
        let url = try #require(URL(string: "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F"))
        #expect(CoordinatorTaskLink.taskID(in: url) == taskID)
        #expect(CoordinatorTaskLink.isToasttyURL(url))
        // The link Toastty writes in a digest reads back.
        #expect(CoordinatorTaskLink.taskID(in: CoordinatorTaskLink.url(taskID: taskID)) == taskID)
        // A scheme is not case sensitive, and an ID may be in lower case.
        let lower = try #require(URL(string: "TOASTTY://task/8c2f1d3a-4b5c-4d6e-8f70-1a2b3c4d5e6f"))
        #expect(CoordinatorTaskLink.taskID(in: lower) == taskID)
    }

    @Test(arguments: [
        // Another Toastty page or action.
        "toastty://action/open-settings",
        "toastty://getting-started/",
        "toastty://task",
        "toastty://task/",
        // Not a full task ID.
        "toastty://task/8C2F1D3A",
        "toastty://task/8C2F1D3A4B5C4D6E8F701A2B3C4D5E6F",
        "toastty://task/not-a-task-id-at-all-but-36-chars-long",
        // More than the ID.
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F/",
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F/merge",
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F?action=merge",
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F#merge",
        "toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F%2Fmerge",
        "toastty://task/%38C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://task/..%2F8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        // The ID in another place.
        "toastty://8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://tasks/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://TASK/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://task.evil.example/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://user@task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://user:secret@task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty://task:80/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty:task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "toastty:///task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
    ])
    func aToasttyLinkThatIsNotExactlyATaskLinkNamesNothing(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(CoordinatorTaskLink.taskID(in: url) == nil)
        // It is still Toastty's scheme, so the chat does not hand it on.
        #expect(CoordinatorTaskLink.isToasttyURL(url))
    }

    @Test(arguments: [
        "https://example.com/task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "file:///task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
        "x-toastty://task/8C2F1D3A-4B5C-4D6E-8F70-1A2B3C4D5E6F",
    ])
    func aLinkWithAnotherSchemeIsNotToasttys(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(CoordinatorTaskLink.taskID(in: url) == nil)
        #expect(CoordinatorTaskLink.isToasttyURL(url) == false)
    }

    // MARK: - Digests

    @Test func aDigestCountsItsUpdates() throws {
        // A digest as the real detector and wake state write it: two tasks
        // and the timer.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func state(_ group: String, _ attention: String? = nil, title: String) -> TaskWebhookTaskState {
            TaskWebhookTaskState(
                key: .init(group: group, attention: attention, merged: false),
                title: title,
                projectRoot: "/repo",
                question: nil
            )
        }
        let other = UUID()
        var detector = TaskWebhookEventDetector()
        _ = detector.observe([
            taskID: state("running", title: "Fix the unread dot"),
            other: state("running", title: "Add the export API"),
        ], now: t0)
        var wake = CoordinatorWakeState(workspaceID: UUID(), startedAt: t0)
        wake.startFollowing()
        for change in detector.observe([
            taskID: state("needsYou", "review", title: "Fix the unread dot"),
            other: state("idle", title: "Add the export API"),
        ], now: t0, settleInterval: 0) {
            wake.record(change, at: t0)
        }
        let digest = try #require(wake.digest(
            now: t0.addingTimeInterval(CoordinatorWakeState.defaultInterval + 1),
            hasOpenTasks: true
        ))
        #expect(digest.contains("toastty://task/\(taskID.uuidString)"))
        #expect(CoordinatorDigestFold.updateCount(inMessage: digest) == 3)
        #expect(CoordinatorDigestFold.summary(updateCount: 3, time: "14:05") == "Toastty · 3 updates · 14:05")
        #expect(CoordinatorDigestFold.summary(updateCount: 1, time: "9:00") == "Toastty · 1 update · 9:00")
    }

    @Test func onlyAMessageThatStartsAsADigestFolds() {
        #expect(CoordinatorDigestFold.updateCount(inMessage: "main. and answer base questions yourself") == nil)
        // The prefix must start the message.
        #expect(CoordinatorDigestFold.updateCount(inMessage: "See [Toastty] Wake: above") == nil)
        #expect(CoordinatorDigestFold.updateCount(inMessage: " \(CoordinatorWakeState.digestHeader)") == nil)
        // A digest with the timer line only.
        let timerOnly = [
            CoordinatorWakeState.digestHeader,
            "- Scheduled check: 1 hour has passed since the last wake, and you set no time.",
            CoordinatorWakeState.digestFooter,
        ].joined(separator: "\n")
        #expect(CoordinatorDigestFold.updateCount(inMessage: timerOnly) == 1)
        #expect(CoordinatorDigestFold.updateCount(inMessage: CoordinatorWakeState.digestHeader) == 0)
    }
}
