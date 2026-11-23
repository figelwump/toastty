import CoreState
import SwiftUI

/// The question mark inside the tinted box of a task that waits for the
/// user's reply, in the sidebar and the Tasks view.
struct TaskQuestionGlyph: View {
    var body: some View {
        Image(systemName: "questionmark")
            .font(.system(size: 6.5, weight: .black))
            .foregroundStyle(ToastyTheme.sidebarTaskQuestionMark)
    }
}

/// The clock mark of a task that rests in Idle while it waits on
/// something outside Toastty (`task waiting`), in the sidebar and the
/// Tasks view. It is still, unlike the spinner of work under way: the wait
/// can last months.
struct TaskWaitingGlyph: View {
    var body: some View {
        Image(systemName: "clock")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ToastyTheme.sidebarSubspaceQuietMark)
            .accessibilityHidden(true)
    }
}

/// The small mark on the rows of a task the user asked to release right
/// after it merges, in the To ship color. It is not a control: the request
/// is set by asking an agent, or with `toastty task set-release`.
struct TaskReleaseAfterMergeMark: View {
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(ToastyTheme.sidebarTaskToShipMark.opacity(0.85))
            .help("Release right after merge")
            .accessibilityHidden(true)
    }
}

/// The ↳ mark to the left of a task's status mark when the task is drawn
/// under the task that started it, in the sidebar and in the Tasks view.
struct TaskChildArrowMark: View {
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(ToastyTheme.sidebarChildContextText.opacity(0.8))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A task's square mark: the same family as the sidebar's task space marks.
struct TaskStageMark: View {
    let item: TaskBoardItem

    var body: some View {
        Group {
            switch item.stage {
            case .starting:
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(ToastyTheme.sidebarTaskStartingMark, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .frame(width: 9, height: 9)
            case .needsYou(let attention):
                switch attention {
                case .review, .readyForReview:
                    tinted(ToastyTheme.sidebarTaskReviewMarkBackground) {
                        Circle().fill(ToastyTheme.sidebarTaskReviewMark).frame(width: 4.5, height: 4.5)
                    }
                case .awaitingReply:
                    tinted(ToastyTheme.sidebarTaskQuestionMarkBackground) {
                        TaskQuestionGlyph()
                    }
                case .pickWorkspace, .setupFailed, .moveFailed:
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sessionNeedsApprovalText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 9, height: 9)
                case .agentError:
                    RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionErrorText).frame(width: 7, height: 7)
                case .agentFinished:
                    readySquare
                case .agentNeedsInput, .startWaitsInTerminal, .taskSpaceClosed, .cleanupStopped:
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ToastyTheme.sessionNeedsApprovalText)
                        .frame(width: 7, height: 7)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5).stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                        }
                }
            case .running, .idle:
                if TaskBoardPresentation.showsUnreadTurnOverStage(item) {
                    readySquare
                } else if item.agent == .working {
                    SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
                } else if TaskBoardPresentation.restingWait(item) != nil {
                    TaskWaitingGlyph()
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sidebarSubspaceQuietMark, lineWidth: 1.2)
                        .frame(width: 7, height: 7)
                }
            case .toShip:
                tinted(ToastyTheme.sidebarTaskToShipMarkBackground) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                }
            case .done:
                tinted(ToastyTheme.sidebarSubspaceDoneMarkBackground) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark)
                }
            case .archived:
                tinted(ToastyTheme.sidebarWorkspaceTagBackground) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarSubspaceQuietMark)
                }
            }
        }
        .frame(width: 12, height: 16)
        .accessibilityHidden(true)
    }

    /// The sidebar's ready square for an unread turn.
    private var readySquare: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionReadyText).frame(width: 7, height: 7)
    }

    private func tinted(_ background: Color, @ViewBuilder content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(background)
            .frame(width: 10, height: 10)
            .overlay(content: content)
    }
}
