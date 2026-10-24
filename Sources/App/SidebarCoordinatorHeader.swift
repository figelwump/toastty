import CoreState
import SwiftUI

/// The top of the sidebar while the task system is on: the Coordinator row,
/// which opens the coordinator and counts the tasks waiting for the user,
/// with the ＋ that opens quick entry.
struct SidebarCoordinatorHeader: View {
    let needsYouCount: Int
    let isSelected: Bool
    let openCoordinator: () -> Void
    let newTask: (() -> Void)?

    @State private var isRowHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openCoordinator) {
                HStack(spacing: 8) {
                    Text("C")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x1A1A1C))
                        .frame(width: 18, height: 18)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: 0xE4A944), Color(hex: 0xC76D2A)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .accessibilityHidden(true)
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
            .accessibilityLabel(Self.accessibilityLabel(needsYouCount: needsYouCount))
            .accessibilityIdentifier("sidebar.coordinator.open")
            .background {
                SidebarSemanticTextBridge(text: Self.accessibilityLabel(needsYouCount: needsYouCount))
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
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(
            isSelected
                ? ToastyTheme.sidebarSessionActiveBackground
                : (isRowHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { isRowHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(ToastyTheme.chromeBackground)
    }

    static func accessibilityLabel(needsYouCount: Int) -> String {
        switch needsYouCount {
        case 0: "Coordinator"
        case 1: "Coordinator, 1 needs you"
        default: "Coordinator, \(needsYouCount) need you"
        }
    }
}
