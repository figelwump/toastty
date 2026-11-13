import CoreState
import SwiftUI

/// The top of the sidebar while the task system is on: the Tasks row, which
/// opens the Tasks view, with the ＋ that opens quick entry; and the
/// All | Needs you switcher, which counts the rows that need the user.
struct SidebarTasksHeader: View {
    /// Sessions, task spaces and tasks that need the user, as the Needs you
    /// segment lists them: what blocks an agent, and what waits for review.
    let needsYouCount: Int
    var readyToReviewCount = 0
    let isTasksViewShown: Bool
    let segment: SidebarSegment
    let openTasksView: () -> Void
    let newTask: (() -> Void)?
    let selectSegment: (SidebarSegment) -> Void
    /// Shows how many webhooks wait for approval.
    var webhooks: TaskWebhookService? = nil

    @State private var isRowHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tasksRow
            segmentSwitcher
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(ToastyTheme.chromeBackground)
    }

    private var tasksRow: some View {
        HStack(spacing: 8) {
            Button(action: openTasksView) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                        .frame(width: 14)
                    Text("Tasks")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ToastyTheme.primaryText)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.tasksRowAccessibilityLabel)
            .accessibilityIdentifier("sidebar.tasks.open")
            .background {
                SidebarSemanticTextBridge(text: Self.tasksRowAccessibilityLabel)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }

            if let webhooks {
                TaskWebhookPendingPill(webhooks: webhooks, open: openTasksView)
            }

            if let newTask {
                Button(action: newTask) {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                        .frame(width: 20, height: 20)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(ToastyTheme.sidebarDisclosureBorder, lineWidth: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Task")
                .accessibilityLabel("New Task")
                .accessibilityIdentifier("sidebar.tasks.new")
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(
            isTasksViewShown
                ? ToastyTheme.sidebarSessionActiveBackground
                : (isRowHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { isRowHovered = $0 }
    }

    private var segmentSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(SidebarSegment.allCases, id: \.self) { candidate in
                let isSelected = candidate == segment
                let count = candidate == .needsYou ? needsYouCount : 0
                let reviewCount = candidate == .needsYou ? readyToReviewCount : 0
                let label = Self.segmentAccessibilityLabel(candidate, needsYouCount: count, readyToReviewCount: reviewCount)
                Button {
                    selectSegment(candidate)
                } label: {
                    HStack(spacing: 5) {
                        Text(Self.title(candidate))
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.sidebarSessionPathText)
                        // Yellow for what blocks an agent, blue for what
                        // waits for review.
                        if count > 0 {
                            Self.countCapsule(count, fill: ToastyTheme.sessionNeedsApprovalText)
                        }
                        if reviewCount > 0 {
                            Self.countCapsule(reviewCount, fill: ToastyTheme.sidebarTaskReviewMark)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(
                        isSelected ? Color(hex: 0x3D3D3D) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("sidebar.segment.\(candidate.rawValue)")
                .background {
                    SidebarSemanticTextBridge(text: label)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(2)
        .background(Color(hex: 0x222222), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 4)
    }

    private static func countCapsule(_ count: Int, fill: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(hex: 0x160F06))
            .padding(.horizontal, 5)
            .background(fill, in: Capsule())
    }

    static func title(_ segment: SidebarSegment) -> String {
        switch segment {
        case .all: "All"
        case .needsYou: "Needs you"
        }
    }

    static let tasksRowAccessibilityLabel = "Tasks"

    /// "Only what needs you, 4, 3 ready for review", leaving out a zero.
    static func segmentAccessibilityLabel(_ segment: SidebarSegment, needsYouCount: Int, readyToReviewCount: Int = 0) -> String {
        switch segment {
        case .all:
            return "All projects"
        case .needsYou:
            var parts: [String] = []
            if needsYouCount > 0 { parts.append("\(needsYouCount)") }
            if readyToReviewCount > 0 { parts.append("\(readyToReviewCount) ready for review") }
            return (["Only what needs you"] + parts).joined(separator: ", ")
        }
    }
}
