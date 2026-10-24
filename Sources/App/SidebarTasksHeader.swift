import CoreState
import SwiftUI

/// The top of the sidebar while the task system is on: the Coordinator row,
/// which opens the review home and counts decisions that need attention, with the
/// ＋ that opens quick entry; and the Projects | Status switcher.
struct SidebarTasksHeader: View {
    let needsYouCount: Int
    let isTasksViewShown: Bool
    let segment: SidebarSegment
    let openTasksView: () -> Void
    let newTask: (() -> Void)?
    let selectSegment: (SidebarSegment) -> Void

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
                    Text("Coordinator")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ToastyTheme.primaryText)
                    if needsYouCount > 0 {
                        Text("\(needsYouCount)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x160F06))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(ToastyTheme.sessionNeedsApprovalText, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.tasksRowAccessibilityLabel(needsYouCount: needsYouCount))
            .accessibilityIdentifier("sidebar.tasks.open")
            .background {
                SidebarSemanticTextBridge(text: Self.tasksRowAccessibilityLabel(needsYouCount: needsYouCount))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
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
                Button {
                    selectSegment(candidate)
                } label: {
                    Text(Self.title(candidate))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.sidebarSessionPathText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            isSelected ? Color(hex: 0x3D3D3D) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group the sidebar by \(Self.title(candidate).lowercased())")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("sidebar.segment.\(candidate.rawValue)")
            }
        }
        .padding(2)
        .background(Color(hex: 0x222222), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 4)
    }

    static func title(_ segment: SidebarSegment) -> String {
        switch segment {
        case .projects: "Projects"
        case .status: "Status"
        }
    }

    static func tasksRowAccessibilityLabel(needsYouCount: Int) -> String {
        switch needsYouCount {
        case 0: "Coordinator"
        case 1: "Coordinator, 1 needs you"
        default: "Coordinator, \(needsYouCount) need you"
        }
    }
}
