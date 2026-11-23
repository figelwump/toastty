import AppKit
import CoreState
import Foundation

/// Whether a terminal panel's agent can be closed without asking.
enum AgentCloseReadiness: Equatable {
    /// No managed agent session is active in the panel. The terminal's own
    /// running-process check decides instead.
    case noAgent
    /// The agent shows positive evidence that it waits for the user.
    case finished
    /// The agent works, waits on approval or child work, or has not finished
    /// a turn yet.
    case busy(agentName: String)

    /// Only positive evidence counts as finished. A launch reports `.idle`
    /// before its first prompt is dispatched, so `.idle` counts only after the
    /// session has finished a turn in this app run. Restored sessions start
    /// without turn history and ask once.
    static func evaluate(record: SessionRecord?, projection: SessionStatusProjection) -> Self {
        guard let record, record.isActive, record.agent != .processWatch else {
            return .noAgent
        }
        let busy = Self.busy(agentName: record.agent.displayName)
        // Waiting on children and resuming both project working over a
        // stale raw status.
        guard projection == .none else { return busy }
        switch record.status?.kind {
        case .ready, .error:
            return .finished
        case .idle:
            return record.lastTurnDuration == nil ? busy : .finished
        case .working, .needsApproval, nil:
            return busy
        }
    }

    /// The close assessment for a terminal panel: the agent's state when one
    /// runs there, otherwise the terminal's running-process check.
    func terminalCloseAssessment(
        fallback: () -> TerminalCloseConfirmationAssessment?
    ) -> TerminalCloseConfirmationAssessment? {
        switch self {
        case .noAgent:
            return fallback()
        case .finished:
            return TerminalCloseConfirmationAssessment(requiresConfirmation: false)
        case .busy(let agentName):
            return TerminalCloseConfirmationAssessment(requiresConfirmation: true, runningCommand: agentName)
        }
    }
}

extension SessionRuntimeStore {
    func agentCloseReadiness(panelID: UUID) -> AgentCloseReadiness {
        AgentCloseReadiness.evaluate(
            record: sessionRegistry.activeSession(for: panelID),
            projection: panelStatus(for: panelID)?.projection ?? .none
        )
    }
}

/// Closes one agent session's pane, and its tab when that pane was the tab's
/// last, and its workspace when that tab was the workspace's only one. The
/// sidebar's Close Session item and the remote close endpoint share it, so
/// both apply the same confirmation rules.
@MainActor
final class SessionCloseController {
    enum CloseResult: Equatable {
        case closed
        /// Something is still running. The caller asks the user, then calls
        /// again with `stopIfBusy`.
        case confirmationRequired(detail: String?)
        /// The pane's tab is its workspace's only tab, so closing it also
        /// closes the workspace. The caller asks the user, then calls again
        /// with `confirmedWorkspaceCloseID` and `stopIfBusy`.
        case workspaceCloseConfirmationRequired(WorkspaceClose)
        /// Closing would remove the pane's tab with a right-panel document
        /// that has unsaved changes or is saving.
        case unsavedDocument(displayName: String?)
        case notFound
        case failed
    }

    /// What closing a workspace's only tab would end, for the confirmation.
    struct WorkspaceClose: Equatable {
        var workspaceID: UUID
        var workspaceTitle: String
        /// Whether the agent or another process still runs in the tab.
        var isRunning: Bool
        /// The running agent's or command's name, when known.
        var runningDetail: String?
    }

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let terminalCloseAssessment: @MainActor (UUID) -> TerminalCloseConfirmationAssessment?
    private let localDocumentCloseConfirmationState: @MainActor (UUID) -> LocalDocumentCloseConfirmationState?
    private let shouldBypassConfirmation: Bool
    private let confirmStopAndClose: @MainActor (_ sessionTitle: String, _ detail: String?) -> Bool
    private let confirmWorkspaceClose: @MainActor (_ sessionTitle: String, _ close: WorkspaceClose) -> Bool
    private let presentRefusal: @MainActor (_ sessionTitle: String, _ reason: String) -> Void

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        terminalCloseAssessment: @escaping @MainActor (UUID) -> TerminalCloseConfirmationAssessment?,
        localDocumentCloseConfirmationState: @escaping @MainActor (UUID) -> LocalDocumentCloseConfirmationState?,
        shouldBypassConfirmation: Bool? = nil,
        confirmStopAndClose: (@MainActor (String, String?) -> Bool)? = nil,
        confirmWorkspaceClose: (@MainActor (String, WorkspaceClose) -> Bool)? = nil,
        presentRefusal: (@MainActor (String, String) -> Void)? = nil
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.focusedPanelCommandController = focusedPanelCommandController
        self.terminalCloseAssessment = terminalCloseAssessment
        self.localDocumentCloseConfirmationState = localDocumentCloseConfirmationState
        let processInfo = ProcessInfo.processInfo
        self.shouldBypassConfirmation = shouldBypassConfirmation ?? AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        self.confirmStopAndClose = confirmStopAndClose ?? Self.presentStopAndCloseConfirmation
        self.confirmWorkspaceClose = confirmWorkspaceClose ?? Self.presentWorkspaceCloseConfirmation
        self.presentRefusal = presentRefusal ?? Self.presentRefusalAlert
    }

    /// Who asked for a close, which decides what it may end without asking.
    private enum Requester {
        /// A person, who answers confirmations or bypasses them.
        case person(confirmedWorkspaceCloseID: UUID?)
        /// Nobody: the agent exited on its own. Such a close never stops a
        /// process or removes a workspace, even when prompts are bypassed.
        case agentExit
    }

    /// Closes the session in `panelID` without UI. A remote client shows its
    /// own confirmation when this returns a confirmation result.
    func closeSession(
        panelID: UUID,
        stopIfBusy: Bool,
        confirmedWorkspaceCloseID: UUID? = nil,
        source: AppActionSource
    ) -> CloseResult {
        close(
            panelID: panelID,
            stopIfBusy: stopIfBusy,
            requester: .person(confirmedWorkspaceCloseID: confirmedWorkspaceCloseID),
            source: source
        )
    }

    /// Closes the pane of a session whose agent exited cleanly, and its tab
    /// when it was the tab's last. Anything that would need a confirmation
    /// leaves the pane open instead.
    func closeExitedSessionPane(panelID: UUID) -> CloseResult {
        close(
            panelID: panelID,
            stopIfBusy: false,
            requester: .agentExit,
            source: AppActionSource("session_exit", detail: "clean_agent_exit")
        )
    }

    private func close(
        panelID: UUID,
        stopIfBusy: Bool,
        requester: Requester,
        source: AppActionSource
    ) -> CloseResult {
        let asks: Bool
        let confirmedWorkspaceCloseID: UUID?
        switch requester {
        case .person(let confirmedID):
            asks = shouldBypassConfirmation == false
            confirmedWorkspaceCloseID = confirmedID
        case .agentExit:
            asks = true
            confirmedWorkspaceCloseID = nil
        }
        guard let store, let sessionRuntimeStore,
              let selection = store.state.workspaceSelection(containingPanelID: panelID),
              case .terminal = selection.workspace.panelState(for: panelID) else {
            return .notFound
        }
        let workspace = selection.workspace
        // A right-panel pane closes alone; a main pane that is its tab's last
        // takes the whole tab, right panel included.
        let closingTab = workspace.rightAuxPanelTabLocation(containingPanelID: panelID) == nil
            ? workspace.tabID(containingPanelID: panelID).flatMap { workspace.tab(id: $0) }
                .flatMap { $0.panels.count <= 1 ? $0 : nil }
            : nil
        let closesWorkspace = closingTab != nil && workspace.tabIDs.count <= 1

        let agentAssessment: @MainActor (UUID) -> TerminalCloseConfirmationAssessment? = { [terminalCloseAssessment] id in
            sessionRuntimeStore.agentCloseReadiness(panelID: id).terminalCloseAssessment { terminalCloseAssessment(id) }
        }
        let tabAssessment = closingTab.map { closingTab in
            WorkspaceTabCloseConfirmation.assess(
                tab: closingTab,
                shouldBypassConfirmation: false,
                terminalAssessment: agentAssessment,
                localDocumentCloseConfirmationState: localDocumentCloseConfirmationState
            )
        }
        // Stopping the agent and closing the workspace are the user's call;
        // discarding a document draft or a save in progress is not part of
        // closing a session, even when prompts are bypassed.
        if let tabAssessment,
           tabAssessment.unsavedLocalDocumentDraftCount > 0 || tabAssessment.localDocumentSaveInProgressCount > 0 {
            return .unsavedDocument(
                displayName: tabAssessment.firstUnsavedLocalDocumentDisplayName
                    ?? tabAssessment.firstLocalDocumentSaveInProgressDisplayName
            )
        }
        // One confirmation covers both the workspace and a running agent. It
        // names a workspace, so a session that moved since then asks again.
        if closesWorkspace, confirmedWorkspaceCloseID != workspace.id, asks {
            return .workspaceCloseConfirmationRequired(WorkspaceClose(
                workspaceID: workspace.id,
                workspaceTitle: workspace.title,
                isRunning: tabAssessment?.requiresConfirmation ?? false,
                runningDetail: tabAssessment?.detectedRunningCommand
            ))
        }
        if let tabAssessment {
            if stopIfBusy == false, asks, tabAssessment.requiresConfirmation {
                return .confirmationRequired(detail: tabAssessment.detectedRunningCommand)
            }
        } else if stopIfBusy == false, asks {
            // A missing assessment means the terminal state is unknown, so it
            // asks rather than risk ending a running process silently.
            guard let assessment = agentAssessment(panelID) else { return .confirmationRequired(detail: nil) }
            if assessment.requiresConfirmation {
                return .confirmationRequired(detail: assessment.runningCommand)
            }
        }

        switch focusedPanelCommandController.closePanel(
            panelID: panelID,
            source: source,
            confirmationPolicy: .nonInteractive(terminateRunningProcess: true),
            preservesTabSelection: true
        ) {
        case .closed:
            return .closed
        case .notHandled:
            return .notFound
        case .canceled, .confirmationRequired, .blocked:
            return .failed
        }
    }

    /// The sidebar's Close Session item: asks before stopping a busy agent or
    /// closing the workspace, and explains a refusal.
    func closeSessionInteractively(panelID: UUID, sessionTitle: String) {
        let source = AppActionSource.ui("sidebar_session_close")
        switch closeSession(panelID: panelID, stopIfBusy: false, source: source) {
        case .confirmationRequired(let detail):
            guard confirmStopAndClose(sessionTitle, detail) else { return }
            _ = closeSession(panelID: panelID, stopIfBusy: true, source: source)
        case .workspaceCloseConfirmationRequired(let workspaceClose):
            guard confirmWorkspaceClose(sessionTitle, workspaceClose) else { return }
            _ = closeSession(
                panelID: panelID, stopIfBusy: true, confirmedWorkspaceCloseID: workspaceClose.workspaceID, source: source
            )
        case .unsavedDocument(let displayName):
            presentRefusal(
                sessionTitle,
                "\(displayName.map { "\u{201C}\($0)\u{201D}" } ?? "A document") in this session's tab has unsaved changes. Save or close it first."
            )
        case .closed, .notFound, .failed:
            break
        }
    }

    private static func presentStopAndCloseConfirmation(sessionTitle: String, detail: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \u{201C}\(sessionTitle)\u{201D}?"
        if let detail {
            alert.informativeText = "\(detail) is still running. Closing stops it and closes its pane."
        } else {
            alert.informativeText = "A process is still running in this session's terminal. Closing stops it and closes its pane."
        }
        alert.alertStyle = .warning
        alert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        alert.addConfiguredButton(withTitle: "Stop and Close", behavior: .defaultAction)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func presentWorkspaceCloseConfirmation(sessionTitle: String, close: WorkspaceClose) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close \u{201C}\(sessionTitle)\u{201D} and its workspace?"
        alert.informativeText = workspaceCloseMessage(close)
        alert.alertStyle = .warning
        alert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        alert.addConfiguredButton(withTitle: "Close Workspace", behavior: .defaultAction)
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func workspaceCloseMessage(_ close: WorkspaceClose) -> String {
        var sentences = [
            "This is the only tab in \u{201C}\(close.workspaceTitle)\u{201D}, so closing the session also closes the workspace."
        ]
        if close.isRunning {
            sentences.append("\(close.runningDetail ?? "A process") is still running and will be stopped.")
        }
        sentences.append("Any associated git worktree is not cleaned up automatically.")
        return sentences.joined(separator: " ")
    }

    private static func presentRefusalAlert(sessionTitle: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = "Can't close \u{201C}\(sessionTitle)\u{201D}"
        alert.informativeText = reason
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
