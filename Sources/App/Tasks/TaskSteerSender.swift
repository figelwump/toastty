import CoreState
import Foundation
import RemoteProtocol

/// How `task send --steer` gave a message to a task's agent.
enum TaskSteerDelivery: Equatable {
    /// Typed and submitted at the agent's open prompt.
    case sent
    /// Typed and submitted into the agent's running turn.
    case steered
    /// Held by Toastty until the agent's next open prompt. `position`
    /// counts from 1.
    case queued(position: Int)

    /// The name `task.send` reports.
    var name: String {
        switch self {
        case .sent: "sent"
        case .steered: "steered"
        case .queued: "queued"
        }
    }
}

/// Why `task send --steer` gave the agent nothing, or cannot say that it did.
enum TaskSteerFailure: Error, Equatable {
    /// Toastty could not tell what the agent does now. Nothing was typed.
    case stateUnknown
    /// The terminal did not take the text. Nothing was typed.
    case unavailable
    /// The text was typed, but the terminal did not confirm the Return key.
    case uncertain
    /// Toastty already holds its maximum of waiting messages for the agent.
    /// Nothing was added.
    case queueFull
    /// A person typed in the agent's terminal, and that text can still be
    /// in the agent's prompt. Nothing was typed.
    case typedInTerminal
}

/// What the agent's own hooks and its terminal report about the agent in a
/// panel, apart from the conversation that Toastty reads from its transcript.
struct TaskSteerAgentView: Equatable {
    var sessionID: String
    var state: TaskAgentState
    /// When the agent's latest turn started: the running one, or the last
    /// one that ended. `nil` when it had no turn since Toastty started.
    var latestTurnStartedAt: Date?
    /// When a person last typed, pasted or dropped a file into the terminal.
    var userTypedAt: Date?
}

/// Gives a message to the agent in a terminal panel without typing into a
/// permission prompt or a question, and without waiting for the agent's turn
/// to end where the agent can read it sooner.
///
/// It types through the panel's conversation, the path of a phone send, so
/// the check and the typing are one step: an open prompt takes the message,
/// and a running turn of an agent that can read during a turn takes it as a
/// steer. In every other case this class holds the message and types it at
/// the agent's next open prompt.
///
/// The conversation's view comes from the agent's transcript. It can be
/// behind, and a conversation that nothing followed before first reads its
/// whole transcript, with every earlier turn's open prompt on the way. So
/// nothing is typed, now or later, unless the state that the agent's own
/// hooks report agrees with it. That is also why held messages stay here
/// and not in the conversation's own queue, which types on its view alone.
@MainActor
final class TaskSteerSender {
    /// How long a send waits for the two views of the agent to agree. A
    /// conversation that nothing followed before needs this time to read
    /// its transcript.
    static let settleTimeout: Duration = .seconds(5)
    static let settlePollInterval: Duration = .milliseconds(100)
    /// How often a held message looks for the agent's open prompt.
    static let heldPollInterval: Duration = .milliseconds(500)
    static let maximumHeldMessages = RemoteConversationInputControl.maximumQueuedMessages

    private struct Held {
        var id: String
        var text: String
        /// The agent session the message is for. A later session in the
        /// same panel does not get it.
        var sessionID: String
    }

    private struct Panel {
        var subscription: any LocalConversationSubscription
        var held: [Held] = []
        var delivery: Task<Void, Never>?
    }

    /// What one look at the agent decided.
    private enum Step {
        case typed(TaskSteerDelivery)
        case failed(TaskSteerFailure)
        case hold
        /// Toastty cannot tell yet what the agent does. `holdAtDeadline`
        /// says that holding the message is safe if that does not change.
        case undecided(holdAtDeadline: Bool)
    }

    weak var access: (any LocalConversationAccess)?
    /// What the hooks and the terminal report for a panel's agent now, or
    /// `nil` when no agent runs there.
    private let agent: @MainActor (UUID) -> TaskSteerAgentView?
    /// One entry for each panel that got a message. It stays until
    /// `releasePanels` finds its agent gone.
    private var panels: [UUID: Panel] = [:]
    private let settleTimeout: Duration
    private let now: () -> Date

    init(
        settleTimeout: Duration = TaskSteerSender.settleTimeout,
        now: @escaping () -> Date = Date.init,
        agent: @escaping @MainActor (UUID) -> TaskSteerAgentView?
    ) {
        self.settleTimeout = settleTimeout
        self.now = now
        self.agent = agent
    }

    func send(_ text: String, panelID: UUID) async -> Result<TaskSteerDelivery, TaskSteerFailure> {
        guard let access else { return .failure(.stateUnknown) }
        guard let sessionID = agent(panelID)?.sessionID else { return .failure(.unavailable) }
        if panels[panelID] == nil {
            panels[panelID] = Panel(subscription: access.subscribeToConversation(inPanel: panelID))
        }
        // One ID for every try: a try that types marks it as done, so no
        // later try can type the message again.
        let message = Held(id: UUID().uuidString, text: text, sessionID: sessionID)
        let deadline = ContinuousClock.now + settleTimeout
        while true {
            var step = look(panelID: panelID, message: message, isHeld: false)
            if case .undecided(let holdAtDeadline) = step {
                if ContinuousClock.now < deadline, Task.isCancelled == false {
                    try? await Task.sleep(for: Self.settlePollInterval)
                    continue
                }
                step = holdAtDeadline ? .hold : .failed(.stateUnknown)
            }
            switch step {
            case .typed(let delivery):
                return .success(delivery)
            case .failed(let failure):
                return .failure(failure)
            case .hold:
                return hold(message, panelID: panelID)
            case .undecided:
                return .failure(.stateUnknown)
            }
        }
    }

    /// The messages that wait for the panel's agent, oldest first.
    func heldTexts(panelID: UUID) -> [String] {
        panels[panelID]?.held.map(\.text) ?? []
    }

    /// Forgets the panels that `isGone` names, with the messages that wait
    /// for them: panels with no agent any more.
    func releasePanels(where isGone: (UUID) -> Bool) {
        for (panelID, panel) in panels where isGone(panelID) {
            panel.delivery?.cancel()
            panel.subscription.cancel()
            panels[panelID] = nil
        }
    }

    // MARK: - Held messages

    private func hold(_ message: Held, panelID: UUID) -> Result<TaskSteerDelivery, TaskSteerFailure> {
        guard var panel = panels[panelID] else { return .failure(.unavailable) }
        guard panel.held.count < Self.maximumHeldMessages else { return .failure(.queueFull) }
        panel.held.append(message)
        if panel.delivery == nil {
            panel.delivery = Task { [weak self] in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: Self.heldPollInterval)
                    guard Task.isCancelled == false, let self, self.deliverHeld(panelID: panelID) else { return }
                }
            }
        }
        panels[panelID] = panel
        return .success(.queued(position: panel.held.count))
    }

    /// Types the oldest held message if the agent is at its open prompt.
    /// Returns whether messages still wait.
    private func deliverHeld(panelID: UUID) -> Bool {
        guard let message = panels[panelID]?.held.first else {
            panels[panelID]?.delivery = nil
            return false
        }
        guard let current = agent(panelID), current.sessionID == message.sessionID else {
            // The message's agent ended. Another one can run in the panel
            // now, with messages of its own behind this one.
            let sessionID = agent(panelID)?.sessionID
            let before = panels[panelID]?.held.count ?? 0
            panels[panelID]?.held.removeAll { $0.sessionID != sessionID }
            let kept = panels[panelID]?.held.count ?? 0
            ToasttyLog.info("Dropped the messages held for a task's agent that ended", category: .tasks, metadata: [
                "panel_id": panelID.uuidString,
                "count": String(before - kept),
            ])
            if kept > 0 { return true }
            panels[panelID]?.delivery = nil
            return false
        }
        switch look(panelID: panelID, message: message, isHeld: true) {
        case .typed, .failed(.uncertain):
            // Typed, or typed without a confirmed Return: not typed again.
            panels[panelID]?.held.removeFirst()
            ToasttyLog.info("Typed a message held for a task's agent", category: .tasks, metadata: [
                "panel_id": panelID.uuidString,
                "session_id": message.sessionID,
            ])
        case .failed, .hold, .undecided:
            break
        }
        if panels[panelID]?.held.isEmpty == false { return true }
        panels[panelID]?.delivery = nil
        return false
    }

    // MARK: - One look

    /// One look at the agent, with no suspension between reading the state
    /// and typing. A held message is typed only at an open prompt.
    private func look(panelID: UUID, message: Held, isHeld: Bool) -> Step {
        // The message is for one agent session. Another one can run in the
        // panel after a wait.
        guard let panel = panels[panelID], let agent = agent(panelID), agent.state != .notRunning,
              agent.sessionID == message.sessionID else {
            return .failed(.unavailable)
        }
        let subscription = panel.subscription
        // The conversation knows of typing in the terminal only from the
        // time Toastty followed the panel. Text typed before that, and
        // after the agent's latest turn started, can still be in the
        // agent's prompt: no later turn took it. A message typed now would
        // be added to it, and a message that waits would be typed into it
        // when the turn ends.
        if let typedAt = agent.userTypedAt, typedAt < subscription.followedSince ?? now(),
           typedAt > agent.latestTurnStartedAt ?? .distantPast {
            return .failed(.typedInTerminal)
        }
        guard let summary = subscription.snapshot(at: now())?.summary else {
            return .undecided(holdAtDeadline: false)
        }

        func request(_ mode: RemoteMessageDeliveryMode, _ epoch: RemoteInputEpoch) -> RemoteMessageSendResult {
            subscription.send(RemoteMessageSendRequest(
                conversationID: summary.conversationID,
                clientRequestID: message.id,
                expectedInputEpoch: epoch,
                text: message.text,
                deliveryMode: mode
            ), byUser: false)
        }

        switch (summary.inputAvailability, agent.state) {
        case (_, .waiting), (.pendingInteraction, _):
            // A permission prompt or a question is on screen, by either
            // view. Typed text could answer it.
            return .hold
        case (.openPrompt(let epoch), .idle):
            // Messages that wait go first.
            guard isHeld || panel.held.isEmpty else { return .hold }
            switch request(.prompt, epoch) {
            case .accepted, .duplicate: return .typed(.sent)
            case .uncertain: return .failed(.uncertain)
            case .rejected(.surfaceUnavailable), .rejected(.notBound): return .failed(.unavailable)
            case .rejected, .queued: return .undecided(holdAtDeadline: true)
            }
        case (.openPrompt, .busy):
            // The hooks say that the agent works, and its transcript does
            // not show the turn yet.
            return .undecided(holdAtDeadline: true)
        case (.unavailable(reason: .working), .busy):
            guard isHeld == false, let control = summary.inputControl else { return .hold }
            // The conversation does not show the running turn yet.
            guard let turnEpoch = control.turnEpoch else { return .undecided(holdAtDeadline: true) }
            // The agent cannot read during a turn, or someone typed in
            // this turn's terminal.
            guard control.canSteer else { return .hold }
            switch request(.steer, turnEpoch) {
            case .accepted, .duplicate: return .typed(.steered)
            case .uncertain: return .failed(.uncertain)
            case .rejected(.surfaceUnavailable), .rejected(.notBound): return .failed(.unavailable)
            // The turn did not take it. The message waits for its end.
            case .rejected, .queued: return .hold
            }
        case (.unavailable(reason: .working), .idle),
             (.unavailable(reason: .interrupted), .idle),
             (.localDraft, .idle):
            // The hooks say that the agent is at its prompt. The
            // conversation is behind, as while it first reads its
            // transcript, and the prompt opens in a moment; or the prompt
            // holds text that someone typed, and stays closed.
            return .undecided(holdAtDeadline: true)
        case (.unavailable(reason: .interrupted), .busy),
             (.localDraft, .busy):
            return .hold
        default:
            // The agent starts, ended or failed, or Toastty does not follow
            // its conversation.
            return .undecided(holdAtDeadline: false)
        }
    }
}
