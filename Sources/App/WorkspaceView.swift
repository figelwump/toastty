import CoreState
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Divider()

            if let workspace = store.selectedWorkspace {
                PaneNodeView(node: workspace.paneTree, workspace: workspace)
                    .padding(12)
            } else {
                ContentUnavailableView("No workspace selected", systemImage: "rectangle.slash")
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text(store.selectedWorkspace?.title ?? "")
                .font(.title3)
                .fontWeight(.semibold)
                .accessibilityIdentifier("topbar.workspace.title")

            Spacer()

            Button("Split Horizontal") {
                split(orientation: .horizontal)
            }
            .accessibilityIdentifier("workspace.split.horizontal")
            Button("Split Vertical") {
                split(orientation: .vertical)
            }
            .accessibilityIdentifier("workspace.split.vertical")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityIdentifier("topbar.container")
    }

    private func split(orientation: SplitOrientation) {
        guard let workspaceID = store.selectedWorkspace?.id else { return }
        store.send(.splitFocusedPane(workspaceID: workspaceID, orientation: orientation))
    }
}

private struct PaneNodeView: View {
    let node: PaneNode
    let workspace: WorkspaceState

    var body: some View {
        switch node {
        case .leaf(let paneID, let tabPanelIDs, _):
            VStack(alignment: .leading, spacing: 8) {
                Text("Pane \(shortID(paneID))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(tabPanelIDs, id: \.self) { panelID in
                    Text(panelLabel(for: panelID))
                        .font(.body.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.35), lineWidth: 1)
            )

        case .split(_, let orientation, _, let first, let second):
            if orientation == .horizontal {
                HStack(spacing: 10) {
                    PaneNodeView(node: first, workspace: workspace)
                    PaneNodeView(node: second, workspace: workspace)
                }
            } else {
                VStack(spacing: 10) {
                    PaneNodeView(node: first, workspace: workspace)
                    PaneNodeView(node: second, workspace: workspace)
                }
            }
        }
    }

    private func panelLabel(for panelID: UUID) -> String {
        guard let panel = workspace.panels[panelID] else {
            return "Unknown panel"
        }

        switch panel {
        case .terminal(let terminal):
            return "\(terminal.title) · \(terminal.shell)"
        case .diff:
            return "Diff Panel"
        case .markdown:
            return "Markdown Panel"
        case .scratchpad:
            return "Scratchpad Panel"
        }
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(6))
    }
}
