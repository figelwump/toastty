import CoreState
import Foundation
import RemoteProtocol

/// Whether the coordinator's agent runs as a process of Toastty's own, with
/// no terminal between them (`AgentDirectSession`). Each agent that can run
/// so has a setting of its own. Each is off unless the user turns it on: a
/// prototype for the user's own use.
///
/// Turn one on with
/// `defaults write com.GiantThings.toastty toastty.coordinator.claudeDirectSession -bool YES`
/// (or `…codexDirectSession`), or for one run with
/// `TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION=1` (or
/// `TOASTTY_COORDINATOR_CODEX_DIRECT_SESSION=1`). The next start of the
/// coordinator uses it.
enum CoordinatorDirectSessionSetting {
    /// The settings of an agent, or `nil` for an agent that runs in a
    /// terminal only.
    static func keys(for agent: AgentKind) -> (defaultsKey: String, environmentKey: String)? {
        switch agent {
        case .claude:
            ("toastty.coordinator.claudeDirectSession", "TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION")
        case .codex:
            ("toastty.coordinator.codexDirectSession", "TOASTTY_COORDINATOR_CODEX_DIRECT_SESSION")
        default:
            nil
        }
    }

    static func isOn(
        for agent: AgentKind,
        defaults: UserDefaults?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let keys = keys(for: agent) else { return false }
        if let value = environment[keys.environmentKey] {
            return value == "1"
        }
        return defaults?.bool(forKey: keys.defaultsKey) ?? false
    }
}

/// What takes a direct session's observations and gives it input:
/// `RemoteAccessService`.
@MainActor
protocol DirectConversationSessionHost: AnyObject {
    func attachDirectSession(_ session: any DirectConversationSession)
    func detachDirectSession(_ session: any DirectConversationSession)
    func ingestDirectSessionObservations(
        _ observations: [ProviderTranscriptObservation],
        from session: any DirectConversationSession
    )
}

extension RemoteAccessService: DirectConversationSessionHost {}

/// One agent process that Toastty runs for a conversation and exchanges
/// lines of JSON with: Claude Code in stream-json mode, or the Codex
/// app-server. A `DirectSessionDriver` holds the conversation's state and
/// makes the lines (`ClaudeStreamSession`, `CodexAppServerSession`).
/// `AgentLineProcess` runs the process. This class joins them to the app:
/// observations go to `host`, and the owner hears of each turn's start and
/// end and of the session's end.
@MainActor
final class AgentDirectSession: DirectConversationSession {
    let panelID: UUID
    /// Toastty's ID of the managed session, as in the session registry.
    let sessionID: String
    let agent: AgentKind

    private var model: any DirectSessionDriver
    private var process: AgentLineProcess?
    private weak var host: (any DirectConversationSessionHost)?
    /// Called when the agent's process names its conversation. Claude Code
    /// reports its conversation through its hooks, and not here.
    private let onConversation: @MainActor (DirectSessionConversation) -> Void
    /// Called when a turn begins, by a driver that reports it. Claude
    /// Code's hooks report its turns.
    private let onTurnStart: @MainActor () -> Void
    private let onTurnEnd: @MainActor (DirectSessionTurnEnd) -> Void
    /// Called when the request that waits for the user's answer changes:
    /// with the request when one starts to wait, and with `nil` when the
    /// last one has its answer or the agent withdrew it.
    private let onWaitingRequestChange: @MainActor (DirectSessionWaitingRequest?) -> Void
    private var reportedWaitingRequest: DirectSessionWaitingRequest?
    /// Called once when the session ends by itself, with the reason. Not
    /// called after `stop`.
    private let onEnd: @MainActor (String) -> Void
    private let now: () -> Date
    private var isStopped = false
    private var didEnd = false
    /// The owner checked the start and let the session into the
    /// conversation; see `admit`.
    private var isAdmitted = false
    /// Why the session ended by itself, once it did.
    private(set) var endReason: String?
    /// What the agent's process reported about itself when its start
    /// checks passed, such as its plan.
    private(set) var startDetails: [String: String] = [:]

    init(
        panelID: UUID,
        sessionID: String,
        agent: AgentKind,
        driver: any DirectSessionDriver,
        host: (any DirectConversationSessionHost)?,
        now: @escaping () -> Date = Date.init,
        onConversation: @escaping @MainActor (DirectSessionConversation) -> Void = { _ in },
        onTurnStart: @escaping @MainActor () -> Void = {},
        onTurnEnd: @escaping @MainActor (DirectSessionTurnEnd) -> Void,
        onWaitingRequestChange: @escaping @MainActor (DirectSessionWaitingRequest?) -> Void = { _ in },
        onEnd: @escaping @MainActor (String) -> Void
    ) {
        self.panelID = panelID
        self.sessionID = sessionID
        self.agent = agent
        self.model = driver
        self.host = host
        self.now = now
        self.onConversation = onConversation
        self.onTurnStart = onTurnStart
        self.onTurnEnd = onTurnEnd
        self.onWaitingRequestChange = onWaitingRequestChange
        self.onEnd = onEnd
    }

    /// The processes that run, so that quitting the app can end them.
    private static var runningProcesses: [ObjectIdentifier: AgentLineProcess] = [:]

    /// Ends every direct session's process, for app quit. A process that
    /// outlived the app would go on with its turn with nobody to read it.
    /// The conversation is saved; the next launch goes on with it.
    static func stopAllForAppTermination() {
        for process in runningProcesses.values {
            process.terminateNow()
        }
        runningProcesses.removeAll()
    }

    var phase: DirectSessionPhase { model.phase }

    var acceptsInput: Bool {
        isAdmitted && isStopped == false && didEnd == false && model.phase == .ready
    }

    /// Lets the session into the conversation: from now on it takes
    /// messages, and the conversation gets its state. The owner calls this
    /// after every check of the start passed. Until then no sender can
    /// reach an agent whose start may still fail.
    func admit() {
        guard isAdmitted == false, isStopped == false, didEnd == false, model.phase == .ready else { return }
        isAdmitted = true
        // The host asks for the session's state now.
        host?.attachDirectSession(self)
    }

    /// Starts the process and writes the driver's start requests. The
    /// session takes messages once `phase` is `ready`.
    func start(launch: AgentProcessLaunch) throws {
        let process = AgentLineProcess(launch: launch) { [weak self] event in
            // In the order of the output: the main queue keeps it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(event) }
            }
        }
        try process.start()
        self.process = process
        Self.runningProcesses[ObjectIdentifier(self)] = process
        for line in model.startLines() {
            process.write(line: line)
        }
        ToasttyLog.info("Started an agent process for a direct session", category: .tasks, metadata: [
            "session_id": sessionID,
            "agent": agent.rawValue,
            "panel_id": panelID.uuidString,
            "pid": process.processIdentifier.map(String.init) ?? "none",
        ])
    }

    /// Ends the process. The owner asked for it, so `onEnd` stays silent.
    func stop() {
        guard isStopped == false else { return }
        isStopped = true
        Self.runningProcesses.removeValue(forKey: ObjectIdentifier(self))
        process?.terminate()
    }

    /// Ends the session for a reason that the owner must show.
    func fail(_ reason: String) {
        guard isStopped == false, didEnd == false else { return }
        didEnd = true
        endReason = reason
        Self.runningProcesses.removeValue(forKey: ObjectIdentifier(self))
        process?.terminate()
        ToasttyLog.warning("A direct session ended", category: .tasks, metadata: [
            "session_id": sessionID,
            "reason": reason,
        ])
        onEnd(reason)
    }

    // MARK: - DirectConversationSession

    func send(text: String, clientRequestID: String, deliveryMode: RemoteMessageDeliveryMode) -> TerminalInputDeliveryResult {
        guard acceptsInput, let process,
              let line = model.messageLine(text: text, clientRequestID: clientRequestID, deliveryMode: deliveryMode) else {
            return .unavailable
        }
        return process.write(line: line) ? .delivered : .unavailable
    }

    func interrupt() -> TerminalInputDeliveryResult {
        guard acceptsInput, let process, let line = model.interruptLine() else { return .unavailable }
        return process.write(line: line) ? .delivered : .unavailable
    }

    func answer(responseID: String, answers: [RemoteInteractionAnswer]) -> RemoteQuestionAnswerResult {
        guard acceptsInput, let process else { return .rejected(reason: .notBound) }
        switch model.answer(responseID: responseID, answers: answers, at: now()) {
        case .notPending:
            return .rejected(reason: .notPending)
        case .invalid:
            return .rejected(reason: .invalidAnswers)
        case .submitted(let line, let observations):
            guard process.write(line: line) else { return .rejected(reason: .notBound) }
            host?.ingestDirectSessionObservations(observations, from: self)
            reportWaitingRequest()
            return .submitted
        }
    }

    func currentStateObservations() -> [ProviderTranscriptObservation] {
        guard acceptsInput else { return [] }
        return model.currentStateObservations(at: now())
    }

    private func reportWaitingRequest() {
        let waiting = model.waitingRequest
        guard waiting != reportedWaitingRequest else { return }
        reportedWaitingRequest = waiting
        onWaitingRequestChange(waiting)
    }

    // MARK: - The process

    private func receive(_ event: AgentLineProcess.Event) {
        guard didEnd == false else { return }
        switch event {
        case .line(let line):
            guard isStopped == false else { return }
            for output in model.receive(line: line, at: now()) {
                switch output {
                case .observations(let observations):
                    // Before the owner admits the session there is only its
                    // open prompt to report, and `admit` gives that.
                    if isAdmitted {
                        host?.ingestDirectSessionObservations(observations, from: self)
                    }
                case .ready(let details):
                    startDetails = details
                    ToasttyLog.info(
                        "A direct session takes messages",
                        category: .tasks,
                        metadata: details.merging(["session_id": sessionID, "agent": agent.rawValue]) { _, new in new }
                    )
                case .conversation(let conversation):
                    onConversation(conversation)
                case .turnStarted:
                    onTurnStart()
                case .turnEnded(let end):
                    onTurnEnd(end)
                case .write(let line):
                    process?.write(line: line)
                case .failed(let reason):
                    fail(reason)
                    return
                }
            }
            reportWaitingRequest()
        case .exited(let status, let errorOutput):
            Self.runningProcesses.removeValue(forKey: ObjectIdentifier(self))
            guard isStopped == false else { return }
            didEnd = true
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(3).joined(separator: " ")
            let reason = "\(agent.displayName) ended (status \(status))" + (detail.isEmpty ? "." : ": \(detail)")
            endReason = reason
            ToasttyLog.warning("A direct session's process ended", category: .tasks, metadata: [
                "session_id": sessionID,
                "status": String(status),
            ])
            onEnd(reason)
        }
    }
}
