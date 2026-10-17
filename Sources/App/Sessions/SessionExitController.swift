import CoreState
import Foundation
import RemoteProtocol

/// A managed session's turn ended or its agent stopped. The session store
/// reports these from inside its transitions, before it publishes the new
/// registry, so a handler only records the event and schedules any work.
enum ManagedSessionLifecycleEvent: Equatable, Sendable {
    /// A new turn began working.
    case turnStarted(sessionID: String)
    /// The turn finished ready, after any hold for child work.
    case turnCompleted(sessionID: String)
    /// The turn ended without finishing: interrupted to idle, or an error.
    case turnAbandoned(sessionID: String)
    case stopped(sessionID: String, panelID: UUID, reason: ManagedSessionStopReason)
}

/// Remote Access input for a panel, which bypasses local-input tracking.
@MainActor
protocol SessionRemoteInputProbe: AnyObject {
    /// Whether a phone message reached the panel after `date`, or is still
    /// queued or awaiting confirmation for it.
    func hasRemoteInput(panelID: UUID, since date: Date) -> Bool
}

/// Two exits that clean up after an agent:
///
/// - An agent asks to exit after its current turn. When that turn completes,
///   Toastty types the provider's native exit command. An agent cannot do this
///   itself as its last action, because Codex ends the turn with its final
///   answer, before any later tool call could run.
/// - A session started from the phone gets its own tab. When its agent exits
///   cleanly, Toastty closes that pane, and the tab with it.
///
/// Both skip whenever someone may still be using the session, so they never
/// type over a draft or close a pane in use.
@MainActor
final class SessionExitController {
    enum ArmError: Error, Equatable {
        case sessionNotInPanel
        case unsupportedAgent(AgentKind)
        case noRunningTurn
        /// A task space is marked done when its work is finished, so its
        /// sessions do not exit on request.
        case sessionInTaskSpace
    }

    struct ArmedExit: Equatable {
        let sessionID: String
        let panelID: UUID
        let exitCommand: String
        /// Input after this moment may have left a draft or queued message.
        let turnStartedAt: Date
        let token: UUID
        /// Set when the turn completed and delivery is scheduled.
        var completedAt: Date?
    }

    /// Why an armed exit was not sent. Logged, and returned for tests.
    enum ExitSkipReason: String, Equatable {
        case sessionGone = "session_gone"
        case newTurnStarted = "new_turn_started"
        case localInput = "local_input"
        case remoteInput = "remote_input"
        case deliveryFailed = "delivery_failed"
    }

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let sessionCloseController: SessionCloseController
    private let sendText: @MainActor (_ text: String, _ panelID: UUID) -> Bool
    /// Claude's completion hook precedes its composer reset, so text typed at
    /// once can be cleared. Remote Access waits the same time before it opens
    /// the phone's compose bar.
    private let promptSettleDelay: Duration
    private let now: () -> Date
    weak var remoteInputProbe: SessionRemoteInputProbe?

    private(set) var armedExitsBySessionID: [String: ArmedExit] = [:]
    private(set) var closesPaneOnCleanExitSessionIDs: Set<String> = []

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        sessionCloseController: SessionCloseController,
        sendText: @escaping @MainActor (String, UUID) -> Bool,
        promptSettleDelay: Duration = .milliseconds(500),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.sessionCloseController = sessionCloseController
        self.sendText = sendText
        self.promptSettleDelay = promptSettleDelay
        self.now = now
    }

    static func nativeExitCommand(for agent: AgentKind) -> String? {
        switch agent {
        case .claude, .codex:
            return "/exit"
        default:
            // Other providers need a verified native exit; none is guessed.
            return nil
        }
    }

    // MARK: - Exit after the turn

    /// Arms an exit for the running turn of the session in `panelID`. Arming
    /// the same turn again keeps the first request.
    @discardableResult
    func armExitAfterTurn(panelID: UUID, expectedSessionID: String) throws -> ArmedExit {
        guard let record = sessionRuntimeStore?.sessionRegistry.activeSession(for: panelID),
              record.sessionID == expectedSessionID else {
            throw ArmError.sessionNotInPanel
        }
        guard let exitCommand = Self.nativeExitCommand(for: record.agent) else {
            throw ArmError.unsupportedAgent(record.agent)
        }
        guard store?.state.workspaceSelection(containingPanelID: panelID)?.workspace.parentWorkspaceID == nil else {
            throw ArmError.sessionInTaskSpace
        }
        guard let turnStartedAt = record.turnStartedAt,
              [.working, .needsApproval].contains(record.status?.kind) else {
            throw ArmError.noRunningTurn
        }
        if let existing = armedExitsBySessionID[record.sessionID], existing.turnStartedAt == turnStartedAt {
            return existing
        }
        let armed = ArmedExit(
            sessionID: record.sessionID,
            panelID: panelID,
            exitCommand: exitCommand,
            turnStartedAt: turnStartedAt,
            token: UUID()
        )
        armedExitsBySessionID[record.sessionID] = armed
        ToasttyLog.info(
            "Armed exit after the current turn",
            category: .automation,
            metadata: ["session_id": record.sessionID, "panel_id": panelID.uuidString, "agent": record.agent.rawValue]
        )
        return armed
    }

    // MARK: - Clean exit closes the pane

    /// The session runs in a tab made for it, so its pane closes once its
    /// agent exits cleanly. Kept in memory only: after a relaunch, a restored
    /// session keeps its tab.
    func markClosesPaneOnCleanExit(sessionID: String) {
        closesPaneOnCleanExitSessionIDs.insert(sessionID)
    }

    // MARK: - Lifecycle

    func handle(_ event: ManagedSessionLifecycleEvent) {
        switch event {
        case .turnStarted(let sessionID):
            // Arming needs a running turn, so any turn that starts later is
            // another one; the request covered only its own.
            guard let armed = armedExitsBySessionID.removeValue(forKey: sessionID) else { return }
            logSkippedExit(armed, reason: ExitSkipReason.newTurnStarted.rawValue)

        case .turnCompleted(let sessionID):
            guard var armed = armedExitsBySessionID[sessionID], armed.completedAt == nil else { return }
            armed.completedAt = now()
            armedExitsBySessionID[sessionID] = armed
            let token = armed.token
            Task { @MainActor [weak self, promptSettleDelay] in
                try? await Task.sleep(for: promptSettleDelay)
                self?.deliverArmedExit(sessionID: sessionID, token: token)
            }

        case .turnAbandoned(let sessionID):
            // Also while delivery waits: an error or interruption after the
            // completion means the session is not where the agent left it.
            guard let armed = armedExitsBySessionID.removeValue(forKey: sessionID) else { return }
            logSkippedExit(armed, reason: "turn_abandoned")

        case .stopped(let sessionID, let panelID, let reason):
            armedExitsBySessionID.removeValue(forKey: sessionID)
            guard closesPaneOnCleanExitSessionIDs.remove(sessionID) != nil,
                  reason == .ghosttyCommandFinished(exitCode: 0) else { return }
            let stoppedAt = now()
            // The stop runs inside the store's teardown; close afterwards.
            Task { @MainActor [weak self] in
                self?.closeExitedPane(sessionID: sessionID, panelID: panelID, stoppedAt: stoppedAt)
            }
        }
    }

    /// Sends the exit if nothing could be using the session. Returns why it
    /// did not, or nil when it sent the exit.
    @discardableResult
    func deliverArmedExit(sessionID: String, token: UUID) -> ExitSkipReason? {
        guard let armed = armedExitsBySessionID[sessionID], armed.token == token else { return .sessionGone }
        armedExitsBySessionID.removeValue(forKey: sessionID)
        let reason = exitSkipReason(for: armed)
        if let reason {
            logSkippedExit(armed, reason: reason.rawValue)
            return reason
        }
        guard sendText(armed.exitCommand, armed.panelID) else {
            logSkippedExit(armed, reason: ExitSkipReason.deliveryFailed.rawValue)
            return .deliveryFailed
        }
        ToasttyLog.info(
            "Sent the native exit after the turn",
            category: .automation,
            metadata: ["session_id": sessionID, "panel_id": armed.panelID.uuidString]
        )
        return nil
    }

    private func exitSkipReason(for armed: ArmedExit) -> ExitSkipReason? {
        guard let sessionRuntimeStore,
              let record = sessionRuntimeStore.sessionRegistry.activeSession(for: armed.panelID),
              record.sessionID == armed.sessionID else {
            return .sessionGone
        }
        if record.turnStartedAt != nil || [.working, .needsApproval].contains(record.status?.kind) {
            return .newTurnStarted
        }
        // The prompt that started the turn was submitted before the turn's
        // working status arrived; anything typed after could be a draft or a
        // queued message that the exit would join.
        if let typedAt = sessionRuntimeStore.lastLocalInputAt(panelID: armed.panelID), typedAt > armed.turnStartedAt {
            return .localInput
        }
        if remoteInputProbe?.hasRemoteInput(panelID: armed.panelID, since: armed.turnStartedAt) == true {
            return .remoteInput
        }
        return nil
    }

    private func logSkippedExit(_ armed: ArmedExit, reason: String) {
        ToasttyLog.info(
            "Skipped the exit after the turn",
            category: .automation,
            metadata: ["session_id": armed.sessionID, "panel_id": armed.panelID.uuidString, "reason": reason]
        )
    }

    /// Closes the pane of a session whose agent exited cleanly, unless the
    /// pane is in use again or visible, or closing it would lose something.
    @discardableResult
    func closeExitedPane(sessionID: String, panelID: UUID, stoppedAt: Date) -> SessionCloseController.CloseResult? {
        let skip: String?
        if let store, let sessionRuntimeStore {
            let latestSession = sessionRuntimeStore.sessionRegistry.sessionsByID.values
                .filter { $0.panelID == panelID }
                .max { $0.startedAt < $1.startedAt }
            if latestSession?.sessionID != sessionID || latestSession?.isActive == true {
                skip = "new_session"
            } else if let typedAt = sessionRuntimeStore.lastLocalInputAt(panelID: panelID), typedAt > stoppedAt {
                skip = "local_input"
            } else if Self.isVisible(panelID: panelID, in: store.state) {
                skip = "visible"
            } else {
                skip = nil
            }
        } else {
            skip = "store_gone"
        }
        if let skip {
            logPaneClose(sessionID: sessionID, panelID: panelID, outcome: "skipped_\(skip)")
            return nil
        }
        let result = sessionCloseController.closeExitedSessionPane(panelID: panelID)
        logPaneClose(sessionID: sessionID, panelID: panelID, outcome: String(describing: result))
        return result
    }

    /// Whether the pane's tab is the one showing in its window. Closing it
    /// would change what the person is looking at.
    static func isVisible(panelID: UUID, in state: AppState) -> Bool {
        guard let selection = state.workspaceSelection(containingPanelID: panelID),
              state.selectedWorkspaceID(in: selection.windowID) == selection.workspaceID,
              let tabID = selection.workspace.tabID(containingPanelID: panelID) else {
            return false
        }
        return selection.workspace.resolvedSelectedTabID == tabID
    }

    private func logPaneClose(sessionID: String, panelID: UUID, outcome: String) {
        ToasttyLog.info(
            "Clean agent exit pane close evaluated",
            category: .automation,
            metadata: ["session_id": sessionID, "panel_id": panelID.uuidString, "outcome": outcome]
        )
    }
}
