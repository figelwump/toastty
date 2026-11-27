import CoreState
import Foundation
import RemoteProtocol

/// Whether the coordinator's Claude Code agent runs as a process of
/// Toastty's own, with no terminal between them (`ClaudeDirectSession`).
/// Off unless the user turns it on: a prototype for the user's own use.
///
/// Turn it on with
/// `defaults write com.GiantThings.toastty toastty.coordinator.claudeDirectSession -bool YES`,
/// or for one run with `TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION=1`. The
/// next start of the coordinator uses it.
enum CoordinatorDirectSessionSetting {
    static let defaultsKey = "toastty.coordinator.claudeDirectSession"
    static let environmentKey = "TOASTTY_COORDINATOR_CLAUDE_DIRECT_SESSION"

    static func isOn(
        defaults: UserDefaults?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let value = environment[environmentKey] {
            return value == "1"
        }
        return defaults?.bool(forKey: defaultsKey) ?? false
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

/// One Claude Code process that Toastty runs for a conversation and talks to
/// in stream-json. `ClaudeStreamSession` holds the conversation's state and
/// makes the lines. `ClaudeStreamProcess` runs the process. This class
/// joins them to the app: observations go to `host`, and the owner hears of
/// each turn's end and of the session's end.
@MainActor
final class ClaudeDirectSession: DirectConversationSession {
    let panelID: UUID
    /// Toastty's ID of the managed session, as in the session registry.
    let sessionID: String

    private var model: ClaudeStreamSession
    private var process: ClaudeStreamProcess?
    private weak var host: (any DirectConversationSessionHost)?
    private let onTurnEnd: @MainActor (ClaudeStreamSession.TurnEnd) -> Void
    /// Called once when the session ends by itself, with the reason. Not
    /// called after `stop`.
    private let onEnd: @MainActor (String) -> Void
    private let now: () -> Date
    private var isStopped = false
    private var didEnd = false
    /// Why the session ended by itself, once it did.
    private(set) var endReason: String?

    init(
        panelID: UUID,
        sessionID: String,
        requirements: ClaudeStreamSession.Requirements,
        host: (any DirectConversationSessionHost)?,
        now: @escaping () -> Date = Date.init,
        onTurnEnd: @escaping @MainActor (ClaudeStreamSession.TurnEnd) -> Void,
        onEnd: @escaping @MainActor (String) -> Void
    ) {
        self.panelID = panelID
        self.sessionID = sessionID
        self.model = ClaudeStreamSession(requirements: requirements, at: now())
        self.host = host
        self.now = now
        self.onTurnEnd = onTurnEnd
        self.onEnd = onEnd
    }

    /// The processes that run, so that quitting the app can end them.
    private static var runningProcesses: [ObjectIdentifier: ClaudeStreamProcess] = [:]

    /// Ends every direct session's process, for app quit. A process that
    /// outlived the app would go on with its turn with nobody to read it.
    /// The conversation is saved; the next launch goes on with it.
    static func stopAllForAppTermination() {
        for process in runningProcesses.values {
            process.terminateNow()
        }
        runningProcesses.removeAll()
    }

    var phase: ClaudeStreamSession.Phase { model.phase }
    var account: ClaudeStreamSession.Account? { model.account }

    var acceptsInput: Bool {
        isStopped == false && didEnd == false && model.phase == .ready
    }

    /// Starts the process and asks it for its account and commands. The
    /// session takes messages once `phase` is `ready`.
    func start(launch: ClaudeStreamLaunch) throws {
        let process = ClaudeStreamProcess(launch: launch) { [weak self] event in
            // In the order of the output: the main queue keeps it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(event) }
            }
        }
        try process.start()
        self.process = process
        Self.runningProcesses[ObjectIdentifier(self)] = process
        process.write(line: model.startRequestLine())
        ToasttyLog.info("Started a Claude Code process for a direct session", category: .tasks, metadata: [
            "session_id": sessionID,
            "panel_id": panelID.uuidString,
            "pid": process.processIdentifier.map(String.init) ?? "none",
            "resumes": launch.arguments.contains("--resume") ? "true" : "false",
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
              let line = model.userMessageLine(text: text, clientRequestID: clientRequestID, deliveryMode: deliveryMode) else {
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
            return .submitted
        }
    }

    func currentStateObservations() -> [ProviderTranscriptObservation] {
        guard acceptsInput else { return [] }
        return model.currentStateObservations(at: now())
    }

    // MARK: - The process

    private func receive(_ event: ClaudeStreamProcess.Event) {
        guard didEnd == false else { return }
        switch event {
        case .line(let line):
            guard isStopped == false else { return }
            for output in model.receive(line: line, at: now()) {
                switch output {
                case .observations(let observations):
                    host?.ingestDirectSessionObservations(observations, from: self)
                case .ready(let account):
                    ToasttyLog.info("A direct session takes messages", category: .tasks, metadata: [
                        "session_id": sessionID,
                        "plan": account.subscriptionType ?? "none",
                        "claude_code_version": account.claudeCodeVersion ?? "unknown",
                        "permission_mode": account.permissionMode ?? "unknown",
                    ])
                case .turnEnded(let end):
                    onTurnEnd(end)
                case .write(let line):
                    process?.write(line: line)
                case .failed(let reason):
                    fail(reason)
                    return
                }
            }
        case .exited(let status, let errorOutput):
            Self.runningProcesses.removeValue(forKey: ObjectIdentifier(self))
            guard isStopped == false else { return }
            didEnd = true
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(3).joined(separator: " ")
            let reason = "Claude Code ended (status \(status))" + (detail.isEmpty ? "." : ": \(detail)")
            endReason = reason
            ToasttyLog.warning("A direct session's process ended", category: .tasks, metadata: [
                "session_id": sessionID,
                "status": String(status),
            ])
            onEnd(reason)
        }
    }
}
