import CoreState
import RemoteProtocol
import Foundation

/// The coordinator chat's words and rules that do not depend on the
/// toolkit. `CoordinatorChatView` (macOS) and the GTK chat draw them.
enum CoordinatorChatPresentation {
    static let introductionTitle = "Hi, I'm Toasty."
    static let introductionText = "I follow your tasks, keep them moving, and tell you what needs you. Say hi to get started."
    /// What a question card says that the chat cannot answer.
    static let readOnlyInteractionMessage = "Answer in the terminal"

    /// The field's hint also names the quick entry shortcut, which sends to
    /// the coordinator from any app. It names none when the shortcut is off
    /// or another app holds its keys.
    static func composerPlaceholder(quickEntryShortcut: NewTaskShortcutHint?) -> String {
        let placeholder = "Message Toasty…"
        guard let quickEntryShortcut, quickEntryShortcut.isGlobal else { return placeholder }
        return "\(placeholder)  \(quickEntryShortcut.label) from anywhere"
    }

    static func text(for notice: CoordinatorChatModel.Notice) -> String {
        switch notice {
        case .agentNotRunning(let reason):
            reason ?? "The coordinator's agent is not running. A message you send waits for it."
        case .agentStarting:
            "The agent is starting. If this takes long, it may wait for you in the terminal."
        case .startWaitsInTerminal:
            "The coordinator's agent has not started yet. It may wait for your answer in the terminal, for example to a login or a folder-trust question."
        case .awaitingAnswerInTerminal:
            "The coordinator waits for your answer in the terminal."
        case .terminalDraft:
"You typed in the coordinator's terminal, and that text may still be in its prompt. Messages wait until you send it there. If you only answered a question there, choose Send Anyway."
        case .deliveryNotConfirmed:
            "Toastty typed your message, but the conversation did not show it. Check the terminal before you send it again."
        case .typingInterrupted:
            "Toastty quit while it typed a message, so the coordinator may have it already. Check the conversation. If the message is there, choose Remove on the paused message. If it is not, choose Send next to send it."
        case .instructionsMayBeCut:
            "Codex may read only the first 32 KiB of the coordinator's instructions: Toastty cannot add project_doc_max_bytes to the arguments of your codex profile. "
                + "Use a codex profile in ~/.toastty/agents.toml that runs codex itself, or set project_doc_max_bytes = \(CoordinatorFolder.codexProjectDocMaxBytes) in Codex's config.toml, then restart the coordinator."
        case .failure(let message):
            message
        }
    }

    /// A spinner in place of a task chip's dot while the task's agent works,
    /// as the Tasks view draws it.
    static func chipShowsActivity(for item: TaskBoardItem) -> Bool {
        switch item.stage {
        case .running, .idle: item.agent == .working
        default: false
        }
    }
}

/// What a click on a link in the coordinator's text does.
enum CoordinatorChatLinks {
    enum Action: Equatable {
        case openTaskSpace(workspaceID: UUID)
        /// A task whose space is closed, such as a done or archived one:
        /// the Tasks view, with the task selected.
        case showInTasksView(taskID: UUID)
        /// An `http` or `https` page, in a Toastty browser.
        case openWebPageInToastty
        /// An `http` or `https` page, in the system browser: the click held
        /// Shift, as for a link in a terminal, or the Tasks view covers the
        /// window's workspace, so a Toastty browser could not be seen.
        case openWebPageInSystemBrowser
        case ignore
    }

    /// Where a link to a task that exists leads.
    enum TaskTarget: Equatable {
        /// The task's space is open.
        case taskSpace(workspaceID: UUID)
        /// The task's space is closed or was never made.
        case tasksView
    }

    /// `taskTarget` answers for a task that exists, or `nil` for any other
    /// task ID. `webPagesOpenInSystemBrowser` changes only web links.
    static func action(
        for url: URL,
        webPagesOpenInSystemBrowser: Bool = false,
        taskTarget: (UUID) -> TaskTarget?
    ) -> Action {
        if CoordinatorTaskLink.isToasttyURL(url) {
            guard let taskID = CoordinatorTaskLink.taskID(in: url),
                  let target = taskTarget(taskID) else { return .ignore }
            switch target {
            case .taskSpace(let workspaceID): return .openTaskSpace(workspaceID: workspaceID)
            case .tasksView: return .showInTasksView(taskID: taskID)
            }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return .ignore }
        return webPagesOpenInSystemBrowser ? .openWebPageInSystemBrowser : .openWebPageInToastty
    }
}

