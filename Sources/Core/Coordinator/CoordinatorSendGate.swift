import Foundation

/// Why text for the coordinator waits instead of being typed now.
public enum CoordinatorSendHold: String, Equatable, Sendable {
    /// No agent runs in the coordinator's terminal.
    case noSession
    /// The terminal cannot take input.
    case terminalUnavailable
    /// The agent's process has not reported that it started.
    case agentStarting
    /// The agent works on a turn or waits for an approval.
    case busy
    /// The entry typed last has not started its turn yet.
    case awaitingTurn
    /// The turn just ended, and the agent's composer may not have reset.
    case settling
    /// The user typed in the coordinator's terminal since the last turn
    /// started, so the composer may hold their draft.
    case userDraft
    /// The agent's conversation does not show an open prompt: the turn was
    /// stopped or failed, or Toastty has not read the conversation yet.
    case promptNotOpen
}

/// What Toastty knows about the coordinator's prompt at one moment.
public struct CoordinatorPromptFacts: Equatable, Sendable {
    public struct Session: Equatable, Sendable {
        public var sessionID: String
        public var statusKind: SessionStatusKind?
        public var startedAt: Date
        public var lastTurnEndedAt: Date?
        public var lastTurnDuration: TimeInterval?
        /// The agent's process reported its start. Always `true` for an
        /// agent that reports none.
        public var hasReportedStart: Bool

        public init(
            sessionID: String,
            statusKind: SessionStatusKind?,
            startedAt: Date,
            lastTurnEndedAt: Date? = nil,
            lastTurnDuration: TimeInterval? = nil,
            hasReportedStart: Bool
        ) {
            self.sessionID = sessionID
            self.statusKind = statusKind
            self.startedAt = startedAt
            self.lastTurnEndedAt = lastTurnEndedAt
            self.lastTurnDuration = lastTurnDuration
            self.hasReportedStart = hasReportedStart
        }
    }

    /// The entry typed last.
    public struct Delivery: Equatable, Sendable {
        public var sessionID: String
        public var at: Date
        /// The terminal confirmed the Return key. Without that, the text may
        /// still be in the agent's composer.
        public var submitConfirmed: Bool

        public init(sessionID: String, at: Date, submitConfirmed: Bool = true) {
            self.sessionID = sessionID
            self.at = at
            self.submitConfirmed = submitConfirmed
        }
    }

    /// The agent session in the coordinator's terminal, if one runs.
    public var session: Session?
    public var isTerminalReady: Bool
    /// When a person last typed, pasted or dropped a file into the
    /// coordinator's terminal. Text Toastty types does not count.
    public var lastUserInputAt: Date?
    public var lastDelivery: Delivery?

    public init(
        session: Session?,
        isTerminalReady: Bool,
        lastUserInputAt: Date? = nil,
        lastDelivery: Delivery? = nil
    ) {
        self.session = session
        self.isTerminalReady = isTerminalReady
        self.lastUserInputAt = lastUserInputAt
        self.lastDelivery = lastDelivery
    }
}

/// Decides whether the coordinator's agent is at an open prompt, so one
/// queued entry can be typed. It uses the facts the iPhone's queue delivery
/// rests on: the managed session's reported status, the agent's confirmed
/// start, the settle time after a turn, and local input. It does not read
/// the provider transcript, which Toastty follows only while Remote Access
/// is on.
public enum CoordinatorSendGate {
    /// Claude reports the end of a turn before its composer resets.
    /// `RemoteAccessService` waits the same time before it opens a prompt.
    public static let promptSettleInterval: TimeInterval = 0.5
    /// How long a submitted entry may take to start its turn. After that
    /// the prompt counts as open again, so one lost entry cannot stop the
    /// queue. An entry whose Return key was not confirmed has no such
    /// limit: the next entry would be typed after its text.
    public static let turnStartTimeout: TimeInterval = 10
    /// How soon to look again at a hold that no session change announces.
    public static let pollInterval: TimeInterval = 0.5

    public enum Decision: Equatable, Sendable {
        case open
        /// `recheckAt` is set when the hold can lift without a change to
        /// the session.
        case hold(CoordinatorSendHold, recheckAt: Date?)
    }

    public static func decide(_ facts: CoordinatorPromptFacts, now: Date) -> Decision {
        guard let session = facts.session else {
            return .hold(.noSession, recheckAt: nil)
        }
        guard facts.isTerminalReady else {
            return .hold(.terminalUnavailable, recheckAt: now.addingTimeInterval(pollInterval))
        }
        guard session.hasReportedStart else {
            return .hold(.agentStarting, recheckAt: now.addingTimeInterval(pollInterval))
        }
        switch session.statusKind {
        case .working, .needsApproval:
            return .hold(.busy, recheckAt: nil)
        case .idle, .ready, .error, nil:
            break
        }
        // One entry for each prompt: the entry typed last must have run its
        // turn before the next one goes in. At rest, a turn that ended
        // after the delivery is that turn.
        if let delivery = facts.lastDelivery, delivery.sessionID == session.sessionID,
           (session.lastTurnEndedAt ?? .distantPast) < delivery.at {
            guard delivery.submitConfirmed else {
                return .hold(.awaitingTurn, recheckAt: nil)
            }
            let deadline = delivery.at.addingTimeInterval(turnStartTimeout)
            if now < deadline {
                return .hold(.awaitingTurn, recheckAt: deadline)
            }
        }
        if let endedAt = session.lastTurnEndedAt {
            let settledAt = endedAt.addingTimeInterval(promptSettleInterval)
            if now < settledAt {
                return .hold(.settling, recheckAt: settledAt)
            }
        }
        // The user's text is in the composer from the first key until they
        // send it, and sending it starts a turn.
        let lastTurnStartedAt = session.lastTurnEndedAt.map { endedAt in
            endedAt.addingTimeInterval(-(session.lastTurnDuration ?? 0))
        } ?? session.startedAt
        if let lastUserInputAt = facts.lastUserInputAt, lastUserInputAt > lastTurnStartedAt {
            return .hold(.userDraft, recheckAt: nil)
        }
        return .open
    }
}
