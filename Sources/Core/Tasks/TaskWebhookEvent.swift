import CryptoKit
import Foundation

/// What a webhook event says about a task. The stage fields decide which
/// events fire; the rest goes into the payload, and is kept so a deleted
/// task can still be described.
public struct TaskWebhookTaskState: Codable, Equatable, Sendable {
    public struct Key: Codable, Equatable, Sendable {
        /// `TaskStage.Group`'s name: needsYou, running, idle, toShip, done,
        /// archived.
        public var group: String
        /// Why the task needs the user, inside needsYou.
        public var attention: String?
        public var merged: Bool
        /// The task's alerts for the coordinator, in `TaskAlert.allCases`
        /// order. No webhook event reads them: `events(from:to:)` looks at
        /// the stage only, and the payload does not carry them.
        public var alerts: [TaskAlert]

        public init(group: String, attention: String? = nil, merged: Bool = false, alerts: [TaskAlert] = []) {
            self.group = group
            self.attention = attention
            self.merged = merged
            self.alerts = alerts
        }

        /// The same stage, whatever the alerts.
        func hasSameStage(as other: Key) -> Bool {
            group == other.group && attention == other.attention && merged == other.merged
        }

        /// A stage the record decides, not the live agent: it cannot
        /// flicker, so it skips the settle window.
        var isSettledByRecord: Bool {
            ["done", "toShip", "archived"].contains(group)
        }
    }

    public var key: Key
    public var title: String
    public var projectRoot: String?
    public var externalRef: TaskExternalRef?
    public var question: String?
    public var pullRequestURL: String?
    public var mergedAt: Date?

    public init(
        key: Key,
        title: String,
        projectRoot: String? = nil,
        externalRef: TaskExternalRef? = nil,
        question: String? = nil,
        pullRequestURL: String? = nil,
        mergedAt: Date? = nil
    ) {
        self.key = key
        self.title = title
        self.projectRoot = projectRoot
        self.externalRef = externalRef
        self.question = question
        self.pullRequestURL = pullRequestURL
        self.mergedAt = mergedAt
    }
}

extension TaskWebhookTaskState.Key {
    /// A key saved before Toastty had alerts has none. An alert this build
    /// does not know, saved by a newer one, is left out, so the saved
    /// baseline still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decode(String.self, forKey: .group)
        attention = try container.decodeIfPresent(String.self, forKey: .attention)
        merged = try container.decode(Bool.self, forKey: .merged)
        alerts = try container.decodeIfPresent([String].self, forKey: .alerts)?.compactMap(TaskAlert.init(rawValue:)) ?? []
    }
}

/// Turns task states, sampled about once a second, into webhook events.
///
/// A stage the live agent decides (needs you, running, idle) must hold for
/// `settleInterval` before it counts, so a status that flickers at a tool
/// boundary sends nothing. Stages the record decides (done, to ship,
/// archived), a merge, and a deletion count at once.
///
/// The baseline is saved, so after a relaunch a task that already waited
/// sends nothing new, and a change made while Toastty was quit, such as a
/// merge on GitHub, still fires once.
public struct TaskWebhookEventDetector: Codable, Equatable, Sendable {
    public static let defaultSettleInterval: TimeInterval = 3

    /// A change of a task's stage or alerts that counted. `events` is
    /// empty for a change that fires no webhook event, such as To ship to
    /// Done, or a change of only the alerts.
    public struct Change: Equatable, Sendable {
        public var taskID: UUID
        public var events: [TaskWebhookEventType]
        public var state: TaskWebhookTaskState
        /// The key that counted before; `nil` for a new task.
        public var previous: TaskWebhookTaskState.Key?
    }

    private struct Candidate: Codable, Equatable, Sendable {
        var key: TaskWebhookTaskState.Key
        var since: Date
    }

    /// The last state that counted for each task. `nil` until the first
    /// observation, which only records.
    public private(set) var baseline: [UUID: TaskWebhookTaskState]?
    private var candidates: [UUID: Candidate] = [:]

    public init(baseline: [UUID: TaskWebhookTaskState]? = nil) {
        self.baseline = baseline
    }

    public var isPrimed: Bool { baseline != nil }

    /// Forgets the baseline: the next observation records the current state
    /// and sends nothing. Used when the first webhook is approved, so it
    /// starts from now instead of replaying old changes.
    public mutating func reset() {
        baseline = nil
        candidates = [:]
    }

    public mutating func observe(
        _ current: [UUID: TaskWebhookTaskState],
        now: Date,
        settleInterval: TimeInterval = defaultSettleInterval
    ) -> [Change] {
        guard var settled = baseline else {
            baseline = current
            candidates = [:]
            return []
        }
        var changes: [Change] = []
        for (id, state) in current.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let previous = settled[id] else {
                // A new task: what it is now counts as a change from nothing.
                settled[id] = state
                changes.append(Change(taskID: id, events: Self.events(from: nil, to: state.key), state: state, previous: nil))
                continue
            }
            if previous.key == state.key {
                candidates[id] = nil
                // Keep the payload fields current, such as a new title.
                settled[id] = state
                continue
            }
            let mergeChanged = previous.key.merged != state.key.merged
            if state.key.isSettledByRecord || mergeChanged {
                candidates[id] = nil
            } else if let candidate = candidates[id], candidate.key == state.key {
                guard now.timeIntervalSince(candidate.since) >= settleInterval else { continue }
                candidates[id] = nil
            } else {
                candidates[id] = Candidate(key: state.key, since: now)
                guard settleInterval <= 0 else { continue }
                candidates[id] = nil
            }
            settled[id] = state
            changes.append(Change(
                taskID: id,
                events: Self.events(from: previous.key, to: state.key),
                state: state,
                previous: previous.key
            ))
        }
        for (id, previous) in settled where current[id] == nil {
            settled[id] = nil
            candidates[id] = nil
            changes.append(Change(taskID: id, events: [.deleted], state: previous, previous: previous.key))
        }
        baseline = settled
        return changes
    }

    /// The events a move from `previous` to `current` fires. `previous` is
    /// `nil` for a task that did not exist. Only the stage counts: a change
    /// of only the alerts fires none.
    static func events(from previous: TaskWebhookTaskState.Key?, to current: TaskWebhookTaskState.Key) -> [TaskWebhookEventType] {
        var events: [TaskWebhookEventType] = []
        if current.merged, previous?.merged != true {
            events.append(.merged)
        }
        let previousGroup = previous?.group
        switch current.group {
        case "needsYou":
            if previousGroup != "needsYou" || previous?.attention != current.attention {
                events.append(.needsYou)
            }
        case "running":
            if previousGroup != "running" { events.append(.running) }
        case "idle":
            if previousGroup != "idle" { events.append(.idle) }
        case "done", "toShip":
            if previousGroup != "done", previousGroup != "toShip" { events.append(.done) }
        case "archived":
            if previousGroup != "archived" { events.append(.archived) }
        default:
            break
        }
        return events
    }
}

/// The JSON body Toastty POSTs. It names the task and where it stands;
/// the receiver reads the rest with `toastty task get`. The agent's reply,
/// the task's prompt and its attachments are never in it.
public struct TaskWebhookPayload: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public struct Stage: Codable, Equatable, Sendable {
            public var group: String
            public var attention: String?
        }

        public var id: UUID
        public var title: String
        public var projectRoot: String?
        public var externalRef: TaskExternalRef?
        public var stage: Stage
        public var question: String?
        public var pullRequestURL: String?
        public var mergedAt: Date?

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            // Keys stay present as null, so receivers can rely on them.
            try container.encode(projectRoot, forKey: .projectRoot)
            try container.encode(externalRef, forKey: .externalRef)
            try container.encode(stage, forKey: .stage)
            try container.encode(question, forKey: .question)
            try container.encode(pullRequestURL, forKey: .pullRequestURL)
            try container.encode(mergedAt, forKey: .mergedAt)
        }
    }

    public var version: Int
    public var eventID: UUID
    public var type: String
    public var occurredAt: Date
    public var webhook: String
    public var task: Task?

    public init(eventID: UUID, type: TaskWebhookEventType, occurredAt: Date, webhook: String, taskID: UUID, state: TaskWebhookTaskState) {
        self.version = 1
        self.eventID = eventID
        self.type = type.payloadType
        self.occurredAt = occurredAt
        self.webhook = webhook
        self.task = Task(
            id: taskID,
            title: state.title,
            projectRoot: state.projectRoot,
            externalRef: state.externalRef,
            stage: .init(group: state.key.group, attention: state.key.attention),
            question: state.question,
            pullRequestURL: state.pullRequestURL,
            mergedAt: state.mergedAt
        )
    }

    /// The event `webhook test` sends: no task.
    public static func test(eventID: UUID, occurredAt: Date, webhook: String) -> TaskWebhookPayload {
        TaskWebhookPayload(version: 1, eventID: eventID, type: "task.test", occurredAt: occurredAt, webhook: webhook, task: nil)
    }

    private init(version: Int, eventID: UUID, type: String, occurredAt: Date, webhook: String, task: Task?) {
        self.version = version
        self.eventID = eventID
        self.type = type
        self.occurredAt = occurredAt
        self.webhook = webhook
        self.task = task
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public enum TaskWebhookSignature {
    /// `t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`.
    public static func header(secret: String, timestamp: Int, body: Data) -> String {
        var message = Data("\(timestamp).".utf8)
        message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return "t=\(timestamp),v1=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// What happens after a delivery attempt.
public enum TaskWebhookRetryPolicy {
    public enum Outcome: Equatable, Sendable {
        case delivered
        case retry
        /// The receiver refused the webhook itself: stop sending.
        case disable(reason: String)
        /// The receiver refused this event: drop it.
        case drop
    }

    /// Events older than this are dropped unsent.
    public static let maximumAge: TimeInterval = 24 * 3600
    public static let maximumDelay: TimeInterval = 600

    /// `statusCode` is `nil` when no response came: a timeout or a network
    /// error.
    public static func outcome(statusCode: Int?) -> Outcome {
        guard let statusCode else { return .retry }
        switch statusCode {
        case 200...299: return .delivered
        case 401, 403, 410: return .disable(reason: "HTTP \(statusCode)")
        case 408, 429, 500...599: return .retry
        default: return .drop
        }
    }

    /// The wait after `attempts` failed attempts: 5 s, 15 s, 45 s… up to
    /// 10 minutes.
    public static func delay(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = max(0, min(attempts - 1, 10))
        return min(maximumDelay, 5 * pow(3, Double(exponent)))
    }
}
