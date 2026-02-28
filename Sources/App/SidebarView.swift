import CoreState
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Logo header: orange icon + "Toastty"
            HStack(spacing: 8) {
                Text("T")
                    .font(.system(size: 11, weight: .heavy, design: .default))
                    .foregroundStyle(ToastyTheme.accentDark)
                    .frame(width: 20, height: 20)
                    .background(ToastyTheme.accent, in: RoundedRectangle(cornerRadius: 5))

                Text("Toastty")
                    .font(ToastyTheme.fontLogoTitle)
                    .foregroundStyle(ToastyTheme.primaryText)
                    .tracking(-0.26) // -0.02em at 13px
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .padding(.bottom, 6)
            .accessibilityIdentifier("sidebar.workspaces.title")

            if let window = store.selectedWindow {
                ForEach(Array(window.workspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                    if let workspace = store.state.workspacesByID[workspaceID] {
                        workspaceButton(
                            workspaceID: workspaceID,
                            workspace: workspace,
                            shortcutLabel: "⌘\(index + 1)",
                            isSelected: window.selectedWorkspaceID == workspaceID,
                            index: index + 1
                        )
                    }
                }
            } else {
                Text("No windows")
                    .font(ToastyTheme.fontBody)
                    .foregroundStyle(ToastyTheme.mutedText)
            }

            Spacer(minLength: 0)

            // New workspace button — full-width, matches workspace item sizing
            Button {
                guard let windowID = store.selectedWindow?.id else { return }
                store.send(.createWorkspace(windowID: windowID, title: nil))
            } label: {
                HStack(spacing: 6) {
                    // Plus icon matching 11×11 stroke icon language
                    Canvas { context, _ in
                        var plus = Path()
                        plus.move(to: CGPoint(x: 5.5, y: 2))
                        plus.addLine(to: CGPoint(x: 5.5, y: 9))
                        plus.move(to: CGPoint(x: 2, y: 5.5))
                        plus.addLine(to: CGPoint(x: 9, y: 5.5))
                        context.stroke(
                            plus,
                            with: .color(ToastyTheme.mutedTextStrong),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                        )
                    }
                    .frame(width: 11, height: 11)

                    Text("New workspace")
                        .font(ToastyTheme.fontWorkspaceNameInactive)
                        .foregroundStyle(ToastyTheme.mutedTextStrong)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    shortcutBadge("⌘⇧N")
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.workspaces.new")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(ToastyTheme.chromeBackground)
    }

    private func workspaceButton(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String,
        isSelected: Bool,
        index: Int
    ) -> some View {
        let paneCount = workspace.paneTree.allLeafInfos.count
        let subtitle = workspaceSubtitle(workspace: workspace, paneCount: paneCount)

        return Button {
            guard let windowID = store.selectedWindow?.id else { return }
            store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                // Top row: workspace name + spacer + shortcut badge
                HStack(spacing: 6) {
                    Text(workspace.title)
                        .font(isSelected ? ToastyTheme.fontWorkspaceName : ToastyTheme.fontWorkspaceNameInactive)
                        .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Blue activity dot (when workspace has unread notifications)
                    if workspace.unreadNotificationCount > 0 {
                        Circle()
                            .fill(ToastyTheme.badgeBlue)
                            .frame(width: 7, height: 7)
                            .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)
                    }

                    Spacer(minLength: 0)

                    // Keyboard shortcut badge pill
                    shortcutBadge(shortcutLabel)
                }

                // Subtitle: pane count + context info
                Text(subtitle)
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(isSelected ? ToastyTheme.mutedText : Color(hex: 0x4A4A4A))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ToastyTheme.elevatedBackground : Color.clear)
            // Left accent border: orange for selected, transparent for others
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? ToastyTheme.accent : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.workspace.\(index)")
    }

    /// Build a subtitle string like "3 panes · dev server running" or "1 pane"
    private func workspaceSubtitle(workspace: WorkspaceState, paneCount: Int) -> String {
        let paneLabel = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
        return paneLabel
    }

    /// Reusable keyboard shortcut badge pill (e.g. "⌘1", "⌘⇧N").
    private func shortcutBadge(_ label: String) -> some View {
        Text(label)
            .font(ToastyTheme.fontShortcutBadge)
            .foregroundStyle(ToastyTheme.shortcutBadgeText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(ToastyTheme.hairline, in: RoundedRectangle(cornerRadius: 3))
    }
}
