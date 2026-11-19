import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit

/// The chips for the tasks the Mac shares: a `toastty://task/<id>` link to
/// a task on its task board, or to one of its recent Done and archived
/// tasks, is drawn with the task's stage color, current title and pull
/// request number, as the Mac's Coordinator chat draws it. A `toastty:`
/// link to anything else is plain text.
struct ToasttyTaskLinkChips {
    let chips: [UUID: ConversationLinkChip]

    init(board: MobileTaskBoard?, finished: ToasttyFinishedTasks = ToasttyFinishedTasks()) {
        // A finished task that the board also lists, while its task space is
        // open, takes the board's chip.
        var chips = finished.chips
        // A task space that Toastty only watches has no task record, and its
        // ID is a workspace's, so it is not a task.
        for task in board?.tasks ?? [] where task.hasRecord {
            chips[task.id] = Self.chip(task)
        }
        self.chips = chips
    }

    var presenter: ConversationLinkPresenter {
        .taskChips(chips)
    }

    /// The task a tap on `url` opens: `nil` for a link that is not a chip.
    func taskID(for url: URL) -> UUID? {
        guard let taskID = CoordinatorTaskLink.taskID(in: url), chips[taskID] != nil else { return nil }
        return taskID
    }

    static func chip(_ task: RemoteTaskSummary) -> ConversationLinkChip {
        ConversationLinkChip(
            markColor: chipColor(ToasttyTaskDetailSheet.stageColor(task)),
            title: ConversationLinkChip.taskTitle(task.title),
            detail: task.pullRequest.map { "#\($0.number)" }
        )
    }

    static func chipColor(_ color: Color) -> ConversationChipColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ConversationChipColor(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

/// The Mac's recent Done and archived tasks, as it last answered: the chips
/// of links to them, and each task as its detail shows it. They are not on
/// the task board, so Home, the Tasks tab, the mention list and the badges
/// never see them. Empty with an older Mac, which shares none, and before
/// the Mac's first answer.
struct ToasttyFinishedTasks: Equatable {
    /// The revision of the Mac's answer, `nil` without one.
    let revision: String?
    let chips: [UUID: ConversationLinkChip]
    private let summaries: [UUID: RemoteTaskSummary]

    init(_ answer: RemoteFinishedTasks? = nil) {
        revision = answer?.revision
        var summaries: [UUID: RemoteTaskSummary] = [:]
        for task in answer?.tasks ?? [] where summaries[task.id] == nil {
            summaries[task.id] = Self.summary(task)
        }
        self.summaries = summaries
        // Made once for each answer, not for each drawing of a chat.
        chips = summaries.mapValues(ToasttyTaskLinkChips.chip)
    }

    /// The task as its detail sheet shows it, `nil` for a task the Mac did
    /// not share.
    func summary(id: UUID) -> RemoteTaskSummary? {
        summaries[id]
    }

    /// A finished task has no task space to open and no action on the
    /// phone: the Mac offers its actions only for the tasks on the board.
    static func summary(_ task: RemoteFinishedTask) -> RemoteTaskSummary {
        RemoteTaskSummary(
            id: task.id,
            title: task.title,
            group: task.group == .archived ? .archived : .done,
            mark: .done,
            statusLine: task.statusLine,
            stageTitle: task.stageTitle,
            stageReason: task.stageReason,
            projectTitle: task.projectTitle,
            pullRequest: task.pullRequest,
            activityAt: .distantPast
        )
    }
}
