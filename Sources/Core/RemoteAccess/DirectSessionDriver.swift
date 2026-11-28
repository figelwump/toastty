import Foundation
import RemoteProtocol

/// The protocol state of one agent process that the host runs itself and
/// exchanges one JSON object for each line with: `ClaudeStreamSession` for
/// Claude Code's stream-json mode, `CodexAppServerSession` for
/// `codex app-server`.
///
/// A driver makes each line that the host writes, and turns each line that
/// the process writes into conversation observations and a known state:
/// whether a turn runs, which requests wait for an answer, and which of the
/// host's messages the agent took. It does no input or output, so a test can
/// drive it with recorded lines.
public protocol DirectSessionDriver: Sendable {
    var phase: DirectSessionPhase { get }
    /// The oldest request that waits for the user's answer, or `nil` when
    /// none waits. The driver knows the moment a request starts to wait and
    /// the moment it has its answer; no hook reports the second.
    var waitingRequest: DirectSessionWaitingRequest? { get }

    /// The first lines the host writes. The process answers with what the
    /// driver checks before the agent gets any message.
    mutating func startLines() -> [String]

    /// The line for one message of the host, or `nil` while the session
    /// takes none. `clientRequestID` comes back on the transcript's user
    /// message when the agent takes this message. A `steer` goes into the
    /// running turn.
    mutating func messageLine(
        text: String,
        clientRequestID: String,
        deliveryMode: RemoteMessageDeliveryMode
    ) -> String?

    /// The line that asks the agent to stop the running turn, or `nil` when
    /// no turn runs. The turn ends when the agent says so.
    mutating func interruptLine() -> String?

    /// Answers the request that waits under `responseID`. A request takes
    /// one answer: after `submitted`, the same ID gives `notPending`.
    mutating func answer(
        responseID: String,
        answers: [RemoteInteractionAnswer],
        at date: Date
    ) -> DirectSessionAnswerOutcome

    /// The turn state and the waiting requests as observations, for a
    /// projection that starts to read this session after it began. Empty
    /// until the session is ready.
    mutating func currentStateObservations(at date: Date) -> [ProviderTranscriptObservation]

    /// Takes one line that the process wrote.
    mutating func receive(line: String, at date: Date) -> [DirectSessionOutput]
}

public enum DirectSessionPhase: Equatable, Sendable {
    /// The process runs. The start checks have not passed yet.
    case starting
    /// It takes messages.
    case ready
    /// It must get no message. The host stops the process.
    case failed(String)
}

/// The end of one turn, as the agent's process reported it.
public struct DirectSessionTurnEnd: Equatable, Sendable {
    /// The host's IDs of the messages that this turn answered.
    public var clientRequestIDs: [String]
    /// The turn ended with an error, and no interrupt caused it.
    public var failed: Bool
    /// An interrupt or a denied request ended the turn.
    public var interrupted: Bool
    /// Messages that the agent already holds for turns that follow. Each
    /// starts its turn without a new message from the host.
    public var queuedTurnCount: Int
    /// The agent's own text for the error of a failed turn.
    public var errorMessage: String?
    /// The agent's last message of the turn, from a driver that keeps it.
    public var lastMessage: String?

    public init(
        clientRequestIDs: [String],
        failed: Bool,
        interrupted: Bool,
        queuedTurnCount: Int = 0,
        errorMessage: String? = nil,
        lastMessage: String? = nil
    ) {
        self.clientRequestIDs = clientRequestIDs
        self.failed = failed
        self.interrupted = interrupted
        self.queuedTurnCount = queuedTurnCount
        self.errorMessage = errorMessage
        self.lastMessage = lastMessage
    }
}

/// The agent's own conversation, as its process named it: the ID to go on
/// with it later, and the file that holds its history.
public struct DirectSessionConversation: Equatable, Sendable {
    public var nativeSessionID: String
    public var transcriptPath: String

    public init(nativeSessionID: String, transcriptPath: String) {
        self.nativeSessionID = nativeSessionID
        self.transcriptPath = transcriptPath
    }
}

public enum DirectSessionOutput: Equatable, Sendable {
    case observations([ProviderTranscriptObservation])
    /// The start checks passed. `details` says what the process reported
    /// about itself, for the log.
    case ready(details: [String: String])
    /// The process named its conversation. A driver whose agent reports its
    /// conversation through a hook before the first message does not give
    /// this.
    case conversation(DirectSessionConversation)
    /// A turn began. A driver whose agent reports its turns through a hook
    /// does not give this.
    case turnStarted
    case turnEnded(DirectSessionTurnEnd)
    /// A line that the host must write to the process now.
    case write(String)
    /// The session must stop; see `DirectSessionPhase.failed`.
    case failed(String)
}

public enum DirectSessionAnswerOutcome: Equatable, Sendable {
    /// Write `line`, then ingest `observations`.
    case submitted(line: String, observations: [ProviderTranscriptObservation])
    /// No request with this ID waits: it was answered or withdrawn.
    case notPending
    /// The answers do not fit the request.
    case invalid
}

/// A request that waits for the user's answer, as the session's status
/// names it.
public struct DirectSessionWaitingRequest: Equatable, Sendable {
    public var requestID: String
    /// What a permission request asks for. `nil` for a question.
    public var permissionSummary: String?

    public init(requestID: String, permissionSummary: String?) {
        self.requestID = requestID
        self.permissionSummary = permissionSummary
    }
}

extension DirectSessionDriver {
    /// One JSON object on one line. Sorted keys keep the bytes the same for
    /// the same message.
    static func jsonLine(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("a line for the agent's process is made of JSON values only")
        }
        return text
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
