import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
import UIKit

/// The chips for the tasks in the Mac's task board: a
/// `toastty://task/<id>` link to one of them is drawn with the task's stage
/// color, current title and pull request number, as the Mac's Coordinator
/// chat draws it. A `toastty:` link to anything else is plain text.
struct ToasttyTaskLinkChips {
    let chips: [UUID: ConversationLinkChip]

    init(board: MobileTaskBoard?) {
        var chips: [UUID: ConversationLinkChip] = [:]
        // A task space that Toastty only watches has no task record, and its
        // ID is a workspace's, so it is not a task.
        for task in board?.tasks ?? [] where task.hasRecord {
            chips[task.id] = ConversationLinkChip(
                markColor: Self.chipColor(ToasttyTaskDetailSheet.stageColor(task)),
                title: ConversationLinkChip.taskTitle(task.title),
                detail: task.pullRequest.map { "#\($0.number)" }
            )
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

    private static func chipColor(_ color: Color) -> ConversationChipColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ConversationChipColor(red: Double(red), green: Double(green), blue: Double(blue))
    }
}
