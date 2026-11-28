import CoreState
import Foundation
import RemoteProtocol

/// How `task send` gave a message to a task's agent.
enum TaskSteerDelivery: Equatable {
    /// Typed and submitted at the agent's open prompt.
    case sent
    /// Typed and submitted into the agent's running turn.
    case steered
    /// Nothing was typed: the agent cannot take the message now. The
    /// caller saves it on the task for the agent's next open prompt
    /// (`TaskCoordinator.send`).
    case mustWait

    /// The name `task.send` reports for a typed message.
    var name: String {
        switch self {
        case .sent: "sent"
        case .steered: "steered"
        case .mustWait: "queued"
        }
    }

    /// What `task.send` tells its caller about a typed message, who may
    /// pass it on to a person.
    var message: String {
        switch self {
        case .sent: "The agent was at its prompt. Toastty typed the message there."
        case .steered: "The agent was in a turn. Toastty typed the message into that turn."
        case .mustWait: "Nothing was typed."
        }
    }
}

/// What `task send` did with a message.
enum TaskSteerSendOutcome {
    /// Typed now, at the agent's open prompt or into its turn.
    case typed(TaskSteerDelivery, session: TaskSessionInfo)
    /// Saved on the task for the agent's next open prompt. The message's
    /// `outcome` says whether Toastty already typed it. `position` counts
    /// from 1 while it waits. `session` is the agent it was sent to.
    case saved(TaskQueuedMessage, position: Int?, session: TaskSessionInfo)
}

/// Why `task send` gave the agent nothing, or cannot say that it did.
enum TaskSteerFailure: Error, Equatable {
    /// The terminal did not take the text, or the agent ended. Nothing was
    /// typed.
    case unavailable
    /// The text was typed, but the terminal did not confirm the Return key.
    case uncertain
}

/// Where `TaskSteerSender` is about to type a message.
enum TaskSteerTarget: Equatable {
    case openPrompt
    case runningTurn
}

/// What the agent's own hooks and its terminal report about the agent in a
/// panel, apart from the conversation that Toastty reads from its transcript.
struct TaskSteerAgentView: Equatable {
    var sessionID: String
    var state: TaskAgentState
    /// When the agent's latest turn started: the running one, or the last
    /// one that ended (`TaskSessionInfo.latestTurnStartedAt`).
    var latestTurnStartedAt: Date?
    /// When a person last typed, pasted or dropped a file into the agent's
    /// prompt (`SessionRuntimeStore.lastPromptInputAt`).
    var userTypedAt: Date?
    /// Claude Code shows one of its own dialogs, such as the compact offer.
    /// It reports no interaction for them, and Return picks a choice there.
    var showsDialog = false
}

/// Gives a message to the agent in a terminal panel without typing into a
/// permission prompt or a question, and without waiting for the agent's turn
/// to end where the agent can read it sooner.
///
/// It types through the panel's conversation, the path of a phone send, so
/// the check and the typing are one step: an open prompt takes the message,
/// and a running turn of an agent that can read during a turn takes it as a
/// steer. In every other case it types nothing and returns `.mustWait`: the
/// task coordinator saves the message on the task, so that it waits across
/// a relaunch, and types it at the agent's next open prompt. That is also
/// the result when Toastty cannot tell what the agent does, as for an agent
/// whose conversation it does not follow.
///
/// The conversation's view comes from the agent's transcript. It can be
/// behind, and a conversation that nothing followed before first reads its
/// whole transcript, with every earlier turn's open prompt on the way. So
/// nothing is typed unless the state that the agent's own hooks report
/// agrees with it. That is also why a message that must wait does not go to
/// the conversation's own queue, which types on its view alone.
@MainActor
final class TaskSteerSender {
    /// How long a send waits for the two views of the agent to agree. A
    /// conversation that nothing followed before needs this time to read
    /// its transcript.
    static let settleTimeout: Duration = .seconds(5)
    static let settlePollInterval: Duration = .milliseconds(100)

    private struct Message {
        var id: String
        var text: String
        /// The agent session the message is for.
        var sessionID: String
    }

    /// What one look at the agent decided.
    private enum Step {
        case typed(TaskSteerDelivery)
        case failed(TaskSteerFailure)
        /// The agent cannot take the message now, and can later.
        case mustWait
        /// Toastty cannot tell yet what the agent does. If that does not
        /// change before the deadline, the message must wait.
        case undecided
    }

    weak var access: (any LocalConversationAccess)?
    /// What the hooks and the terminal report for a panel's agent now, or
    /// `nil` when no agent runs there.
    private let agent: @MainActor (UUID) -> TaskSteerAgentView?
    /// The conversation of each panel that got a message. It stays until
    /// `releasePanels` finds its agent gone.
    private var subscriptions: [UUID: any LocalConversationSubscription] = [:]
    /// When this class last typed a message into each panel. The hooks can
    /// report the open prompt for a moment after that, so Toastty's other
    /// messages read it to leave the prompt to this one.
    private var typedAt: [UUID: Date] = [:]
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

    /// `mayType` is asked in the same step as the typing, since the send
    /// can wait for the agent's state before it. It says whether the
    /// message may still go to this agent: the agent still works on the
    /// sender's task, and no earlier message waits. For an open prompt it
    /// also says whether the prompt is still free: of text that can be in
    /// it, and of Toastty's other messages, where one that was typed there
    /// took it. While an open prompt is not free, the send waits as for an
    /// undecided state, and then the message must wait.
    func send(
        _ text: String, panelID: UUID, mayType: @escaping @MainActor (TaskSteerTarget) -> Bool = { _ in true }
    ) async -> Result<TaskSteerDelivery, TaskSteerFailure> {
        // Nothing follows conversations: the message waits for the prompt
        // that the agent's hooks report.
        guard let access else { return .success(.mustWait) }
        guard let sessionID = agent(panelID)?.sessionID else { return .failure(.unavailable) }
        if subscriptions[panelID] == nil {
            subscriptions[panelID] = access.subscribeToConversation(inPanel: panelID)
        }
        // One ID for every try: a try that types marks it as done, so no
        // later try can type the message again.
        let message = Message(id: UUID().uuidString, text: text, sessionID: sessionID)
        let deadline = ContinuousClock.now + settleTimeout
        while true {
            switch look(panelID: panelID, message: message, mayType: mayType) {
            case .typed(let delivery):
                typedAt[panelID] = now()
                return .success(delivery)
            case .failed(let failure):
                if failure == .uncertain { typedAt[panelID] = now() }
                return .failure(failure)
            case .mustWait:
                return .success(.mustWait)
            case .undecided:
                guard ContinuousClock.now < deadline, Task.isCancelled == false else { return .success(.mustWait) }
                try? await Task.sleep(for: Self.settlePollInterval)
            }
        }
    }

    /// When this class last typed a message into the panel, also one whose
    /// Return the terminal did not confirm.
    func lastTypedAt(panelID: UUID) -> Date? {
        typedAt[panelID]
    }

    /// Forgets the panels that `isGone` names: panels with no agent any
    /// more.
    func releasePanels(where isGone: (UUID) -> Bool) {
        for (panelID, subscription) in subscriptions where isGone(panelID) {
            subscription.cancel()
            subscriptions[panelID] = nil
            typedAt[panelID] = nil
        }
    }

    // MARK: - One look

    /// One look at the agent, with no suspension between reading the state
    /// and typing.
    private func look(panelID: UUID, message: Message, mayType: (TaskSteerTarget) -> Bool) -> Step {
        // The message is for one agent session. Another one can run in the
        // panel after a wait.
        guard let subscription = subscriptions[panelID], let agent = agent(panelID), agent.state != .notRunning,
              agent.sessionID == message.sessionID else {
            return .failed(.unavailable)
        }
        // The conversation knows of typing in the terminal only from the
        // time Toastty followed the panel. Text typed before that, and
        // after the agent's latest turn started, can still be in the
        // agent's prompt: no later turn took it. A message typed now would
        // be added to it, so it waits for the prompt after that turn.
        if let typedAt = agent.userTypedAt, typedAt < subscription.followedSince ?? now(),
           typedAt > agent.latestTurnStartedAt ?? .distantPast {
            return .mustWait
        }
        guard let summary = subscription.snapshot(at: now())?.summary else {
            return .undecided
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

        if agent.showsDialog {
            return .mustWait
        }
        switch (summary.inputAvailability, agent.state) {
        case (_, .waiting), (.pendingInteraction, _):
            // A permission prompt or a question is on screen, by either
            // view. Typed text could answer it.
            return .mustWait
        case (.openPrompt(let epoch), .idle), (.openPrompt(let epoch), .error):
            // An agent whose turn an error ended waits at its prompt too.
            // The transcript can show the prompt open for a moment after
            // Toastty typed another message there.
            guard mayType(.openPrompt) else { return .undecided }
            switch request(.prompt, epoch) {
            case .accepted, .duplicate: return .typed(.sent)
            case .uncertain: return .failed(.uncertain)
            case .rejected(.surfaceUnavailable), .rejected(.notBound): return .failed(.unavailable)
            case .rejected, .queued: return .undecided
            }
        case (.openPrompt, .busy):
            // The hooks say that the agent works, and its transcript does
            // not show the turn yet.
            return .undecided
        case (.unavailable(reason: .working), .busy):
            guard let control = summary.inputControl else { return .mustWait }
            // The conversation does not show the running turn yet.
            guard let turnEpoch = control.turnEpoch else { return .undecided }
            // The agent cannot read during a turn, or someone typed in
            // this turn's terminal.
            guard control.canSteer, mayType(.runningTurn) else { return .mustWait }
            switch request(.steer, turnEpoch) {
            case .accepted, .duplicate: return .typed(.steered)
            case .uncertain: return .failed(.uncertain)
            case .rejected(.surfaceUnavailable), .rejected(.notBound): return .failed(.unavailable)
            // The turn did not take it. The message waits for its end.
            case .rejected, .queued: return .mustWait
            }
        case (.unavailable(reason: .working), .idle),
             (.unavailable(reason: .interrupted), .idle),
             (.localDraft, .idle):
            // The hooks say that the agent is at its prompt. The
            // conversation is behind, as while it first reads its
            // transcript, and the prompt opens in a moment; or the prompt
            // holds text that someone typed, and stays closed.
            return .undecided
        case (.unavailable(reason: .interrupted), .busy),
             (.localDraft, .busy):
            return .mustWait
        default:
            // The agent starts, ended or failed, or Toastty does not follow
            // its conversation.
            return .undecided
        }
    }
}
