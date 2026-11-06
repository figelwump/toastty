import CoreState
import Foundation
import RemoteProtocol

/// Decides when a task's phone alert fires: when its stage settles into
/// Needs you for a reason that has an alert.
///
/// It samples the stages the task board works out, about once a second. A
/// new stage counts only after it holds for `settleInterval`, so a stage
/// that flips back quickly, such as a status at a tool boundary, sends
/// nothing. The first sample only records, so tasks that already waited
/// when sampling started, such as after a relaunch, send nothing.
struct TaskAlertDetector {
    static let defaultSettleInterval: TimeInterval = 3

    /// One task's sample.
    struct Observation: Equatable {
        var stage: TaskStage
        /// An accepted merge is under way: the agent checks it, or Toastty
        /// merges or waits for checks.
        var isMerging: Bool
        /// When Toastty's last merge of the pull request stopped without
        /// merging (`TaskRecord.mergeFailure`). It stays until a new merge
        /// starts.
        var mergeFailedAt: Date? = nil
        /// The user cancelled the last accepted merge.
        var isMergeCancelled = false

        /// What a change is measured on. A reason's text, such as a setup
        /// error, is not part of it. A recorded merge failure is, so a merge
        /// that fails at once without changing the stage still counts.
        fileprivate var key: Key {
            var attention: String?
            if case .needsYou(let reason) = stage { attention = reason.name }
            return Key(group: stage.group, attention: attention, isMerging: isMerging, mergeFailedAt: mergeFailedAt)
        }
    }

    fileprivate struct Key: Equatable {
        var group: TaskStage.Group
        var attention: String?
        var isMerging: Bool
        var mergeFailedAt: Date?
    }

    struct Trigger: Equatable {
        var taskID: UUID
        var reason: RemotePushTaskAlertReason
    }

    private var settled: [UUID: Observation]?
    private var candidates: [UUID: (key: Key, since: Date)] = [:]
    /// Tasks seen merging since their last settled stage. A merge that ends
    /// before it settles, such as one that fails at once, still counts.
    private var mergeAttempts: Set<UUID> = []
    /// The recorded merge failure each task last settled into Needs you
    /// with. A failure recorded while the agent still worked is reported
    /// when the task then needs the user, and only once.
    private var reportedMergeFailures: [UUID: Date] = [:]

    var isPrimed: Bool { settled != nil }

    mutating func reset() {
        settled = nil
        candidates = [:]
        mergeAttempts = []
        reportedMergeFailures = [:]
    }

    mutating func observe(
        _ current: [UUID: Observation],
        now: Date,
        settleInterval: TimeInterval = defaultSettleInterval
    ) -> [Trigger] {
        guard var settled else {
            self.settled = current
            candidates = [:]
            reportedMergeFailures = current.compactMapValues(\.mergeFailedAt)
            return []
        }
        var triggers: [Trigger] = []
        for (id, observation) in current.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let previous = settled[id] else {
                // A new task: what it is now counts as a change from nothing.
                settled[id] = observation
                if let reason = settle(id, observation, mergeEnded: false) {
                    triggers.append(Trigger(taskID: id, reason: reason))
                }
                continue
            }
            let key = observation.key
            if observation.isMerging { mergeAttempts.insert(id) }
            // A merge that started and ended between settled samples comes
            // back to the same stage: its outcome is still a change.
            let unsettledMergeEnded = mergeAttempts.contains(id) && observation.isMerging == false
                && previous.isMerging == false
            if previous.key == key, unsettledMergeEnded == false {
                candidates[id] = nil
                settled[id] = observation
                continue
            }
            if let candidate = candidates[id], candidate.key == key {
                guard now.timeIntervalSince(candidate.since) >= settleInterval else { continue }
            } else if settleInterval > 0 {
                candidates[id] = (key, now)
                continue
            }
            candidates[id] = nil
            settled[id] = observation
            let mergeEnded = (previous.isMerging || mergeAttempts.contains(id)) && observation.isMerging == false
            if observation.isMerging == false { mergeAttempts.remove(id) }
            if let reason = settle(id, observation, mergeEnded: mergeEnded) {
                triggers.append(Trigger(taskID: id, reason: reason))
            }
        }
        for id in settled.keys where current[id] == nil {
            settled[id] = nil
            candidates[id] = nil
            mergeAttempts.remove(id)
            reportedMergeFailures[id] = nil
        }
        self.settled = settled
        return triggers
    }

    /// The alert a task that settled into `observation` sends, if any.
    /// `mergeEnded` says an accepted merge was under way just before.
    private mutating func settle(_ id: UUID, _ observation: Observation, mergeEnded: Bool) -> RemotePushTaskAlertReason? {
        guard case .needsYou = observation.stage else { return nil }
        let failure = observation.mergeFailedAt
        let isNewFailure = failure != nil && failure != reportedMergeFailures[id]
        reportedMergeFailures[id] = failure
        let merge: MergeOutcome = if isNewFailure {
            .stopped
        } else if mergeEnded {
            // A merge skill that stopped on a blocker ends its turn without
            // a recorded failure. A merge the user cancelled is their own.
            observation.isMergeCancelled ? .cancelled : .stopped
        } else {
            .none
        }
        return Self.reason(observation.stage, merge: merge)
    }

    enum MergeOutcome {
        case none
        case stopped
        case cancelled
    }

    /// The alert for a task that settled into `stage`. The session's own
    /// alerts cover a finished turn and an approval, and the user is at hand
    /// for the rest of Needs you: a task they just created that waits for a
    /// workspace, a task space they closed, or a merge they cancelled.
    static func reason(_ stage: TaskStage, merge: MergeOutcome) -> RemotePushTaskAlertReason? {
        guard case .needsYou(let attention) = stage else { return nil }
        switch attention {
        case .awaitingReply: return .question
        case .setupFailed: return .setupFailed
        case .moveFailed: return .moveFailed
        case .cleanupStopped: return .cleanupStopped
        case .review, .readyForReview, .agentFinished, .agentError:
            switch (merge, attention) {
            case (.stopped, _): return .mergeStopped
            case (.cancelled, _): return nil
            case (.none, .review), (.none, .readyForReview): return .review
            case (.none, _): return nil
            }
        case .pickWorkspace, .taskSpaceClosed, .agentNeedsInput:
            return nil
        }
    }
}

/// Plans the task alerts a Mac sends to paired phones, and which session
/// alerts they replace.
///
/// A session that finishes a turn in a task space holds its "Ready" alert
/// for `sessionHold`. When its task settles into Needs you for a reason
/// with an alert in that time, the task alert replaces the held alert, so
/// one event sends one alert. Otherwise the held alert goes out as before.
/// A finished turn asks GitHub about the task's pull request, and its answer
/// can turn the task into a review: while that answer is outstanding, and
/// for a settle window after it, the alert stays held, up to `maximumHold`.
@MainActor
final class RemoteTaskAlerts {
    struct Timing {
        /// `nil` turns the automatic pass off, for tests that call `pass`.
        var passInterval: Duration? = .seconds(1)
        /// Lets workspaces and agent sessions restore before the first sample
        /// after sampling starts, so a task space that is still opening does
        /// not count as a change.
        var startupDelay: TimeInterval = 10
        var settleInterval: TimeInterval = TaskAlertDetector.defaultSettleInterval
        var sessionHold: TimeInterval = 8
        /// `gh pr view` can take two 30-second attempts.
        var maximumHold: TimeInterval = 75
    }

    /// A task alert, with the session alerts it replaces. A relay that
    /// predates task alerts refuses it; the replaced alerts then go out.
    struct TaskAlert: Equatable {
        var notification: RemotePushTaskNotification
        var replaced: [RemotePushSessionNotification]
    }

    enum Delivery: Equatable {
        case task(TaskAlert)
        /// A held session alert that no task alert replaced.
        case session(RemotePushSessionNotification)
    }

    let timing: Timing
    private let now: () -> Date
    private var detector = TaskAlertDetector()
    private var startedAt: Date?
    private typealias HeldAlert = (notification: RemotePushSessionNotification, at: Date)
    private var held: [UUID: [HeldAlert]] = [:]
    /// When each task with a held alert last waited for a pull request answer.
    private var pullRequestPendingAt: [UUID: Date] = [:]

    init(timing: Timing = Timing(), now: @escaping () -> Date = Date.init) {
        self.timing = timing
        self.now = now
    }

    var hasHeldAlerts: Bool { held.isEmpty == false }

    /// Holds a finished turn's alert for the task whose task space the
    /// session runs in.
    func hold(_ notification: RemotePushSessionNotification, taskID: UUID) {
        held[taskID, default: []].append((notification, now()))
    }

    /// Forgets the baseline and held alerts, as when the last phone grant
    /// goes away. The next pass records again and sends nothing.
    func reset() {
        detector.reset()
        startedAt = nil
        held = [:]
        pullRequestPendingAt = [:]
    }

    /// One sample of the task board. `conversationID` finds the task's own
    /// agent session, which a tap opens; without one, the tap opens the
    /// session whose alert the task alert replaced. `isAwaitingPullRequest`
    /// says whether GitHub's answer about the task's pull request is
    /// outstanding.
    func pass(
        items: [TaskBoardItem],
        isAwaitingPullRequest: (TaskBoardItem) -> Bool = { _ in false },
        conversationID: (TaskBoardItem) -> RemoteConversationID?
    ) -> [Delivery] {
        let at = now()
        let startedAt = self.startedAt ?? at
        self.startedAt = startedAt
        var deliveries: [Delivery] = []
        if at.timeIntervalSince(startedAt) >= timing.startupDelay {
            var observations: [UUID: TaskAlertDetector.Observation] = [:]
            var itemsByID: [UUID: TaskBoardItem] = [:]
            for item in items {
                guard let record = item.record else { continue }
                let id = record.id
                observations[id] = .init(
                    stage: item.stage,
                    isMerging: item.merge != nil,
                    mergeFailedAt: record.mergeFailure?.at,
                    isMergeCancelled: record.mergeCancelledAt != nil
                )
                itemsByID[id] = item
            }
            for trigger in detector.observe(observations, now: at, settleInterval: timing.settleInterval) {
                guard let item = itemsByID[trigger.taskID], let record = item.record else { continue }
                let replaced = (held.removeValue(forKey: trigger.taskID) ?? []).map(\.notification)
                pullRequestPendingAt[trigger.taskID] = nil
                deliveries.append(.task(TaskAlert(
                    notification: RemotePushTaskNotification(
                        eventID: UUID(),
                        taskID: record.id,
                        conversationID: conversationID(item) ?? replaced.last?.conversationID,
                        reason: trigger.reason,
                        taskTitle: item.title,
                        detail: record.replyRequest?.question,
                        pullRequestNumber: item.pullRequest?.number
                    ),
                    replaced: replaced
                )))
            }
        }
        for item in items {
            guard let id = item.record?.id, held[id] != nil, isAwaitingPullRequest(item) else { continue }
            pullRequestPendingAt[id] = at
        }
        for (taskID, alerts) in held {
            // The answer must also settle before the task's stage counts.
            let awaitingAnswer = pullRequestPendingAt[taskID].map {
                at.timeIntervalSince($0) <= timing.settleInterval + 1
            } ?? false
            var waiting: [HeldAlert] = []
            for alert in alerts {
                let elapsed = at.timeIntervalSince(alert.at)
                if elapsed >= timing.maximumHold || (elapsed >= timing.sessionHold && awaitingAnswer == false) {
                    deliveries.append(.session(alert.notification))
                } else {
                    waiting.append(alert)
                }
            }
            held[taskID] = waiting.isEmpty ? nil : waiting
            if waiting.isEmpty { pullRequestPendingAt[taskID] = nil }
        }
        return deliveries
    }
}
