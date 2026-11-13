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

/// "Policy" in the header of the coordinator's panel: shows `policy.md`,
/// the user's rules for the coordinator, in the right panel.
struct CoordinatorPolicyButton: View {
    let controller: CoordinatorController

    var body: some View {
        Button {
            do {
                try controller.openPolicy()
            } catch {
                TaskActions.presentFailure("Unable to Open the Coordinator's Policy", error.localizedDescription)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 9, weight: .semibold))
                Text("Policy")
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
        .help("Show policy.md, your rules for the coordinator. You can edit it there.")
        .accessibilityLabel("Open Policy")
        .accessibilityIdentifier("coordinator.panel.open-policy")
    }
}

/// "Dock" in the header of the coordinator's panel: leaves the full view
/// for the workspace the user came from, with the chat in the dock.
struct CoordinatorPanelDockButton: View {
    let controller: CoordinatorController

    var body: some View {
        Button {
            controller.showDock(focusComposer: true)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 9, weight: .semibold))
                Text("Dock")
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
        .help(ToasttyKeyboardShortcuts.toggleCoordinatorDock.helpText(
            "Go back to your last workspace, with the coordinator's chat in the dock"
        ))
        .accessibilityLabel("Show in Dock")
        .accessibilityIdentifier("coordinator.panel.dock")
    }
}
