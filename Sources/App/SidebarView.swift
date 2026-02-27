import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspaces")
                .font(.headline)
                .accessibilityIdentifier("sidebar.workspaces.title")

            if let window = store.selectedWindow {
                ForEach(Array(window.workspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                    if let workspace = store.state.workspacesByID[workspaceID] {
                        workspaceButton(
                            workspaceID: workspaceID,
                            title: workspace.title,
                            shortcutLabel: "⌘\(index + 1)",
                            isSelected: window.selectedWorkspaceID == workspaceID,
                            index: index + 1
                        )
                    }
                }
            } else {
                Text("No windows")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                guard let windowID = store.selectedWindow?.id else { return }
                store.send(.createWorkspace(windowID: windowID, title: nil))
            } label: {
                Label("New workspace", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("sidebar.workspaces.new")
        }
        .padding(14)
    }

    private func workspaceButton(workspaceID: UUID, title: String, shortcutLabel: String, isSelected: Bool, index: Int) -> some View {
        Button {
            guard let windowID = store.selectedWindow?.id else { return }
            store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(shortcutLabel)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.workspace.\(index)")
    }
}
