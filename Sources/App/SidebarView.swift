import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspaces")
                .font(ToastyTheme.fontTitle)
                .foregroundStyle(ToastyTheme.primaryText)
                .accessibilityIdentifier("sidebar.workspaces.title")
                .padding(.top, 2)

            if let window = store.selectedWindow {
                ForEach(Array(window.workspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                    if let workspace = store.state.workspacesByID[workspaceID] {
                        workspaceButton(
                            workspaceID: workspaceID,
                            title: workspace.title,
                            shortcutLabel: "⌘\(index + 1)",
                            isSelected: window.selectedWorkspaceID == workspaceID,
                            unreadCount: workspace.unreadNotificationCount,
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

            Button {
                guard let windowID = store.selectedWindow?.id else { return }
                store.send(.createWorkspace(windowID: windowID, title: nil))
            } label: {
                Label("New workspace", systemImage: "plus")
                    .font(ToastyTheme.fontBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToastyTheme.primaryText)
            .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(ToastyTheme.hairline, lineWidth: 1)
            )
            .accessibilityIdentifier("sidebar.workspaces.new")
        }
        .padding(12)
        .background(ToastyTheme.chromeBackground)
    }

    private func workspaceButton(
        workspaceID: UUID,
        title: String,
        shortcutLabel: String,
        isSelected: Bool,
        unreadCount: Int,
        index: Int
    ) -> some View {
        Button {
            guard let windowID = store.selectedWindow?.id else { return }
            store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ToastyTheme.fontBody)
                    .foregroundStyle(ToastyTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(shortcutLabel)
                        .font(ToastyTheme.fontSubtext)
                        .foregroundStyle(ToastyTheme.mutedTextStrong)

                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(ToastyTheme.fontSubtext)
                            .foregroundStyle(ToastyTheme.primaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ToastyTheme.badgeBlue, in: Capsule())
                    }

                    Spacer()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? ToastyTheme.elevatedBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(ToastyTheme.hairline, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(ToastyTheme.accent)
                        .frame(width: 2)
                        .padding(.vertical, 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.workspace.\(index)")
    }
}
