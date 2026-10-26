import AppKit
import CoreState
import Foundation

/// What happens to a task when the person closes its task space.
enum TaskSpaceCloseChoice: Equatable {
    case markDone
    case archive
    /// The task stays in Needs you, as "task space closed".
    case keep
}

/// The question Toastty asks when the person closes the task space of a
/// task without a worktree or a pull request. Such a close usually means
/// the task is finished, so the person picks the task's stage in the same
/// dialog. Tasks with a worktree or a pull request do not ask, because
/// closing them by mistake loses more; nor do closes that Toastty or an
/// agent starts.
struct TaskSpaceCloseQuestion: Equatable {
    var taskID: UUID
    var taskTitle: String
    var taskSpaceWorkspaceID: UUID
    /// The warning of the close confirmation this question replaces, such
    /// as a running agent that closing stops.
    var warning: String?

    /// The question for closing `item`'s open task space, or `nil` when the
    /// close keeps its usual behavior: the task has a worktree (or is making
    /// one) or a pull request, its setup or move is still running, or it is
    /// already finished or cleaning up.
    static func make(for item: TaskBoardItem) -> Self? {
        guard let record = item.record,
              let taskSpaceWorkspaceID = item.taskSpaceWorkspaceID,
              record.operation.worktree == nil,
              item.pullRequest == nil,
              record.archivedAt == nil, record.doneAt == nil,
              record.mergedAt == nil, record.shippedAt == nil else { return nil }
        if item.stage == .running, TaskBoardPresentation.showsSetup(item) { return nil }
        switch item.stage {
        case .running, .needsYou:
            if case .needsYou(.cleanupStopped) = item.stage { return nil }
        case .toShip, .done, .archived:
            return nil
        }
        return Self(taskID: record.id, taskTitle: record.title, taskSpaceWorkspaceID: taskSpaceWorkspaceID)
    }

    var messageText: String {
        "Close the task space of \u{201C}\(taskTitle)\u{201D}?"
    }

    var informativeText: String {
        [
            "Choose what happens to the task. Mark Done moves it to Done. Archive moves it to Archived. Keep leaves it in Needs you.",
            warning,
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    static func present(_ question: TaskSpaceCloseQuestion) -> TaskSpaceCloseChoice? {
        let alert = NSAlert()
        alert.messageText = question.messageText
        alert.informativeText = question.informativeText
        alert.alertStyle = question.warning == nil ? .informational : .warning
        alert.addConfiguredButton(withTitle: "Mark Done", behavior: .defaultAction)
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Keep")
        alert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .markDone
        case .alertSecondButtonReturn: return .archive
        case .alertThirdButtonReturn: return .keep
        default: return nil
        }
    }
}

/// Asks the task space close question for the closes a person starts:
/// Close Pane, closing a tab, Close Workspace and Close Session. Each of
/// those asks it in place of its own close confirmation, closes, and then
/// applies the choice.
@MainActor
struct TaskSpaceCloseAsker {
    /// The person's answer. A `nil` choice is Cancel: nothing closes.
    struct Answer: Equatable {
        var question: TaskSpaceCloseQuestion
        var choice: TaskSpaceCloseChoice?
    }

    var question: (_ workspaceID: UUID) -> TaskSpaceCloseQuestion?
    var present: (TaskSpaceCloseQuestion) -> TaskSpaceCloseChoice?
    var apply: (TaskSpaceCloseChoice, TaskSpaceCloseQuestion) -> Void

    /// Never asks: for tests and for windows without the task system.
    static let never = TaskSpaceCloseAsker(question: { _ in nil }, present: { _ in nil }, apply: { _, _ in })

    /// Asks when closing `workspaceID` closes a task space that asks, with
    /// `warning` from the confirmation the question replaces. `nil` means no
    /// question applies, so the caller keeps its usual confirmation.
    func ask(closingWorkspaceID workspaceID: UUID, warning: () -> String?) -> Answer? {
        guard var question = question(workspaceID) else { return nil }
        question.warning = warning()
        return Answer(question: question, choice: present(question))
    }

    /// Applies the person's choice after the task space closed.
    func taskSpaceClosed(_ answer: Answer) {
        guard let choice = answer.choice else { return }
        apply(choice, answer.question)
    }

    static func live(sessionRuntimeStore: SessionRuntimeStore) -> Self {
        Self(
            question: { [weak sessionRuntimeStore] workspaceID in
                sessionRuntimeStore?.taskSpaceCloseQuestion(workspaceID: workspaceID)
            },
            present: TaskSpaceCloseQuestion.present,
            apply: { [weak sessionRuntimeStore] choice, question in
                guard let coordinator = sessionRuntimeStore?.taskCoordinator else { return }
                TaskActions.applyTaskSpaceCloseChoice(choice, question: question, coordinator: coordinator)
            }
        )
    }
}

extension SessionRuntimeStore {
    /// The close question for the task space `workspaceID`, when its task
    /// asks one.
    func taskSpaceCloseQuestion(workspaceID: UUID) -> TaskSpaceCloseQuestion? {
        guard let board = taskCoordinator?.board,
              let workspace = taskCoordinator?.store.state.workspacesByID[workspaceID],
              workspace.taskID != nil,
              let item = board.item(taskSpace: workspace, statuses: workspaceStatuses(for: workspaceID)),
              item.taskSpaceWorkspaceID == workspaceID else { return nil }
        return TaskSpaceCloseQuestion.make(for: item)
    }
}

extension TaskActions {
    /// Marks the task done or archives it through the same coordinator
    /// paths as the sidebar, after its task space closed. A task space
    /// that is still open, because a tab opened in it while the question
    /// was up, leaves the task as it is.
    static func applyTaskSpaceCloseChoice(
        _ choice: TaskSpaceCloseChoice,
        question: TaskSpaceCloseQuestion,
        coordinator: TaskCoordinator
    ) {
        let taskSpaceClosed = coordinator.store.state.workspacesByID[question.taskSpaceWorkspaceID] == nil
        ToasttyLog.info("Task space closed by the user", category: .tasks, metadata: [
            "task_id": question.taskID.uuidString,
            "choice": "\(choice)",
            "task_space_closed": String(taskSpaceClosed),
        ])
        guard taskSpaceClosed else { return }
        switch choice {
        case .keep:
            break
        case .markDone:
            perform("Unable to Mark \(question.taskTitle) Done") {
                _ = try coordinator.markDone(taskID: question.taskID)
            }
        case .archive:
            // Without a worktree or a pull request, and with the task space
            // already closed, the archive has nothing to ask about.
            Task { @MainActor in
                do {
                    _ = try await coordinator.archive(taskID: question.taskID, options: TaskArchiveOptions())
                } catch {
                    presentFailure("Unable to Archive \(question.taskTitle)", error.localizedDescription)
                }
            }
        }
    }
}
