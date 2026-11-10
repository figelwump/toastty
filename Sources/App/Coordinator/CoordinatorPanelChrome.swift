import CoreState
import SwiftUI

/// The switch in the header of the coordinator's panel: the chat, or the
/// terminal the agent runs in.
struct CoordinatorPanelModeToggle: View {
    /// Observed: it publishes which one shows.
    @ObservedObject var store: AppStore
    let controller: CoordinatorController

    var body: some View {
        let showsTerminal = store.coordinatorShowsTerminal
        Button {
            controller.showsTerminal = showsTerminal == false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsTerminal ? "bubble.left.and.text.bubble.right" : "terminal")
                    .font(.system(size: 9, weight: .semibold))
                Text(showsTerminal ? "Chat" : "Terminal")
                    .font(ToastyTheme.fontWorkspaceMergeButton)
            }
            .foregroundStyle(ToastyTheme.sidebarDisclosureText)
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ToastyTheme.sidebarDisclosureBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsTerminal
            ? "Show the coordinator's conversation as a chat"
            : "Show the coordinator's terminal, for a login, a folder-trust or a permission prompt")
        .accessibilityLabel(showsTerminal ? "Show Chat" : "Show Terminal")
        .accessibilityIdentifier("coordinator.panel.mode-toggle")
    }
}

/// "← Coordinator" in the header of a task space that a chip in the
/// coordinator's chat opened. The header shows it only for that space.
struct WorkspaceHeaderCoordinatorReturnButton: View {
    let location: CoordinatorLocation
    let store: AppStore
    let sessionRuntimeStore: SessionRuntimeStore

    var body: some View {
        Button {
            _ = store.selectWorkspace(
                windowID: location.windowID,
                workspaceID: location.workspaceID,
                preferringUnreadSessionPanelIn: sessionRuntimeStore
            )
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 9, weight: .semibold))
                Text(AppState.coordinatorWorkspaceTitle)
                    .font(ToastyTheme.fontWorkspaceMergeButton)
            }
            .foregroundStyle(ToastyTheme.sidebarDisclosureText)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ToastyTheme.sidebarDisclosureBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Go back to the coordinator")
        .accessibilityLabel("Back to Coordinator")
        .accessibilityIdentifier("topbar.workspace.back-to-coordinator")
    }
}
