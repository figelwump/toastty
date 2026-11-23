import CoreState
import SwiftUI

extension SidebarStatusSections {
    /// The To ship header's label. Collapsed, it names each project and its
    /// count, as the header's summary shows them.
    func toShipLabel(isExpanded: Bool) -> String {
        let label = SidebarToShipGroupToggle.label(count: toShip.reduce(0) { $0 + $1.count }, isExpanded: isExpanded)
        guard isExpanded == false else { return label }
        return ([label] + toShip.map { "\($0.projectTitle) \($0.count)" }).joined(separator: ", ")
    }
}

/// A sidebar row for a task with no open task space in the window, such as
/// one whose task space closed before it finished, or one that waits for its
/// workspace to be picked. It opens the task in the Tasks view.
struct SidebarTaskRecordRow: View {
    let item: TaskBoardItem
    /// Names the project on the row: a project card already names it.
    var showsProject = true
    /// The task that started this one, named with a ↖ when the list shows
    /// the row without that task.
    var parentTaskTitle: String? = nil
    /// Drawn on one line, as the Needs you segment lists rows: the status
    /// line moves to the tooltip, and one tag shows.
    var isCompact = false
    let open: () -> Void

    @State private var isHovered = false

    private var label: String {
        var label = TaskBoardPresentation.addingReleaseAfterMerge(to: "\(item.title), \(TaskBoardPresentation.statusLine(item))", item)
        if showsProject, let project = item.projectTitle {
            label += ", in \(project)"
        }
        if let parentTaskTitle {
            label += ", started by \(parentTaskTitle)"
        }
        return label
    }

    private var markColor: Color {
        switch item.stage {
        case .needsYou(.review), .needsYou(.readyForReview): ToastyTheme.sidebarTaskReviewMark
        case .needsYou: ToastyTheme.sessionNeedsApprovalText
        default: ToastyTheme.sidebarSubspaceQuietMark
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if TaskBoardPresentation.restingWait(item) != nil {
                    TaskWaitingGlyph()
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(markColor)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 12, height: 17)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                if isCompact == false {
                    statusLine
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: open)
        .onHover { isHovered = $0 }
        // A one-line row has no status line, so its tooltip carries it. An
        // empty tooltip shows nothing.
        .help(isCompact ? TaskBoardPresentation.statusLine(item) : "")
        .background {
            SidebarSemanticTextBridge(text: label)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            SidebarView.styledSessionNameText(item.title, isEmphasized: false)
                .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                .lineLimit(1)
            if TaskBoardPresentation.releaseAfterMergeRequestedAt(item) != nil {
                TaskReleaseAfterMergeMark()
            }
            if isCompact {
                Spacer(minLength: 0)
                compactTag
            }
        }
        .frame(minHeight: 17, alignment: .leading)
    }

    /// The one tag a one-line row shows: its pull request, else the task
    /// that started it, else its project where several share a list.
    @ViewBuilder
    private var compactTag: some View {
        if let pullRequest = item.pullRequest {
            SidebarView.sidebarTaskTag("#\(pullRequest.number)")
        } else if let parentTaskTitle {
            SidebarView.parentTaskTag(parentTaskTitle, maximumWidth: 90)
        } else if showsProject, let project = item.projectTitle {
            SidebarView.sidebarTaskTag(project)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            SidebarView.styledSessionSummaryText(TaskBoardPresentation.statusLine(item))
                .foregroundStyle(ToastyTheme.sidebarSummaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsProject, let project = item.projectTitle {
                SidebarView.sidebarTaskTag(project)
            }
            if let parentTaskTitle {
                SidebarView.parentTaskTag(parentTaskTitle, maximumWidth: 90)
            }
        }
    }
}

/// A sidebar group's title: "TO SHIP 3".
struct SidebarGroupTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
            Text("\(count)")
                .font(ToastyTheme.fontWorkspaceAgentCount)
                .foregroundStyle(ToastyTheme.sidebarSessionPathText)
        }
    }
}

/// "› TO SHIP 3", which expands and collapses a To ship group in place: the
/// one under each project card. While
/// collapsed, `summary` shows on the right. A project card's "› DONE 91"
/// uses it too, with `group` `.done`.
struct SidebarToShipGroupToggle: View {
    let count: Int
    @Binding var isExpanded: Bool
    var summary: Text?
    /// Shows the group's mark before the title: purple To ship, or the
    /// green Done check. A project card uses it because its line has no
    /// purple project summary.
    var showsMark = false
    /// `.toShip` or `.done`.
    var group: TaskStage.Group = .toShip
    /// What the toggle says; starts with `label(count:isExpanded:)`.
    let accessibilityText: String

    nonisolated static func label(count: Int, isExpanded: Bool) -> String {
        "To ship, \(count) \(count == 1 ? "task" : "tasks"), \(isExpanded ? "expanded" : "collapsed")"
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 9)
                if showsMark {
                    // The same mark as the card's "To ship N" and "Done N"
                    // counts.
                    Image(systemName: group == .done ? "checkmark.square" : "arrow.up.square")
                        .font(ToastyTheme.fontWorkspaceSessionChip)
                        .foregroundStyle(
                            group == .done ? ToastyTheme.sidebarSubspaceDoneMark.opacity(0.85) : ToastyTheme.sidebarTaskToShipMark
                        )
                }
                SidebarGroupTitle(title: group == .done ? "Done" : "To ship", count: count)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isExpanded == false, let summary {
                    summary
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(ToastyTheme.sidebarChildContextText)
            .frame(minHeight: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group == .done
            ? (isExpanded ? "Hide the done tasks" : "Show the done tasks whose task spaces are still open")
            : (isExpanded ? "Hide the tasks to ship" : "Show the tasks to ship"))
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
        .background {
            SidebarSemanticTextBridge(text: accessibilityText)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

/// "› ☑ 13/15 merged" under a parent task's open child tasks: its merged
/// children whose task spaces Toastty still holds open, folded into one
/// line. It starts collapsed.
struct SidebarFinishedChildrenToggle: View {
    /// The parent's "N/M merged".
    let title: String
    let rowCount: Int
    @Binding var isExpanded: Bool

    nonisolated static func label(title: String, rowCount: Int, isExpanded: Bool) -> String {
        "\(title), \(rowCount) finished \(rowCount == 1 ? "task" : "tasks"), \(isExpanded ? "expanded" : "collapsed")"
    }

    var body: some View {
        let accessibilityText = Self.label(title: title, rowCount: rowCount, isExpanded: isExpanded)
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 9)
                Image(systemName: "checkmark.square")
                    .font(ToastyTheme.fontWorkspaceSessionChip)
                    .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark.opacity(0.85))
                Text(title)
                    .font(ToastyTheme.fontWorkspaceSessionChip)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ToastyTheme.sidebarChildContextText)
            .frame(minHeight: 18)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the finished tasks" : "Show the finished tasks")
        .accessibilityLabel(accessibilityText)
        .background {
            SidebarSemanticTextBridge(text: accessibilityText)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

/// "Show N more →" under a project's latest To ship tasks, or under a
/// parent task's merged children.
struct SidebarShowMoreToShipButton: View {
    let count: Int
    var help = "Show the other tasks to ship in the Tasks view"
    /// What VoiceOver reads; a To ship list's text by default.
    var accessibilityText: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(SidebarRecentToShip.showMoreTitle(count))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(isHovered ? ToastyTheme.sidebarSessionAgentText : ToastyTheme.sidebarSessionPathText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(accessibilityText ?? SidebarRecentToShip.showMoreLabel(count))
        .background {
            SidebarSemanticTextBridge(text: accessibilityText ?? SidebarRecentToShip.showMoreLabel(count))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}
