import CoreState
import SwiftUI

/// The merge control under a subspace's title in the top bar: the Merge
/// button with a menu that picks what it does, its in-progress form while
/// the agent works on the merge, the cleanup that follows a Merge and Clean
/// Up, or the done label. It takes the subtitle slot, so it has to fit the
/// 16pt the top bar leaves under the title.
struct WorkspaceHeaderMergeControl: View {
    let presentation: WorkspaceMergePresentation
    var merge: () -> Void = {}
    var setMode: (WorkspaceMergeMode) -> Void = { _ in }
    var retryCleanup: () -> Void = {}
    var cancelCleanup: () -> Void = {}

    private var shortcut: ToasttyKeyboardShortcut { ToasttyKeyboardShortcuts.mergeWorkspacePullRequest }

    var body: some View {
        switch presentation {
        case .ready(_, let mode):
            HStack(spacing: 1) {
                Button(action: merge) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 8, weight: .bold))
                        titleText
                    }
                }
                .buttonStyle(WorkspaceHeaderMergeButtonStyle(corners: .leading))
                .help(shortcut.helpText(helpText(for: mode)))
                .accessibilityLabel(presentation.title)
                .accessibilityIdentifier("topbar.workspace.merge")

                Menu {
                    ForEach(WorkspaceMergeMode.allCases, id: \.self) { option in
                        Toggle(
                            option == mode ? shortcut.menuTitle(option.menuTitle) : option.menuTitle,
                            isOn: Binding(
                                get: { option == mode },
                                set: { isOn in
                                    if isOn { setMode(option) }
                                }
                            )
                        )
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .frame(maxHeight: .infinity)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(WorkspaceHeaderMergeButtonStyle(corners: .trailing, horizontalPadding: 4))
                .fixedSize()
                .help("Choose what the Merge button does")
                .accessibilityLabel("Merge options")
                .accessibilityIdentifier("topbar.workspace.merge.mode")
            }

        case .merging, .cleaningUp:
            progressLabel(showsSpinner: true)
                .accessibilityIdentifier("topbar.workspace.merge.progress")

        case .awaitingMerge:
            cleanupMenu {
                progressLabel(showsSpinner: true)
            }
            .help("Toastty closes this workspace, removes its worktree, and deletes its branches when the pull request merges")
            .accessibilityIdentifier("topbar.workspace.merge.awaiting")

        case .cleanupFailed(_, let reason):
            cleanupMenu {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                    titleText
                    chevron
                }
                .font(ToastyTheme.fontWorkspaceMergeProgress)
                .foregroundStyle(ToastyTheme.sidebarSummaryText)
                .frame(height: ToastyTheme.workspaceMergeControlHeight)
            }
            .help(reason)
            .accessibilityIdentifier("topbar.workspace.merge.cleanup-failed")

        case .done:
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                titleText
            }
            .font(ToastyTheme.fontWorkspaceMergeProgress)
            .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark)
            .frame(height: ToastyTheme.workspaceMergeControlHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.title)
            .accessibilityIdentifier("topbar.workspace.merge.done")
        }
    }

    private func helpText(for mode: WorkspaceMergeMode) -> String {
        switch mode {
        case .mergeAndCleanUp:
            return "Ask this workspace's agent to merge the pull request, then close the workspace and remove its worktree once it merges"
        case .mergeOnly:
            return "Ask this workspace's agent to merge the pull request"
        }
    }

    private func progressLabel(showsSpinner: Bool) -> some View {
        HStack(spacing: 4) {
            if showsSpinner {
                SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.5)
            }
            titleText
            if presentation.canCancelCleanup {
                chevron
            }
        }
        .font(ToastyTheme.fontWorkspaceMergeProgress)
        .foregroundStyle(ToastyTheme.sidebarSummaryText)
        .padding(.horizontal, ToastyTheme.workspaceMergeControlHorizontalPadding)
        .frame(height: ToastyTheme.workspaceMergeControlHeight)
        .overlay(
            RoundedRectangle(cornerRadius: ToastyTheme.workspaceMergeControlCornerRadius)
                .strokeBorder(ToastyTheme.subtleBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
    }

    /// A pending or failed cleanup opens a menu to retry or drop it.
    private func cleanupMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            if case .cleanupFailed = presentation {
                Button("Retry Clean Up", action: retryCleanup)
            }
            Button("Don't Clean Up", action: cancelCleanup)
        } label: {
            label()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        // Vertical only, so a long pull request label still truncates.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
    }

    // No fixed size: a long pull request label truncates inside the title
    // column instead of widening it.
    private var titleText: some View {
        Text(presentation.title)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct WorkspaceHeaderMergeButtonStyle: ButtonStyle {
    enum Corners {
        case leading
        case trailing
    }

    let corners: Corners
    var horizontalPadding: CGFloat = ToastyTheme.workspaceMergeControlHorizontalPadding
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let radius = ToastyTheme.workspaceMergeControlCornerRadius
        configuration.label
            .font(ToastyTheme.fontWorkspaceMergeButton)
            .foregroundStyle(ToastyTheme.accentDark)
            .padding(.horizontal, horizontalPadding)
            .frame(height: ToastyTheme.workspaceMergeControlHeight)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: corners == .leading ? radius : 0,
                    bottomLeadingRadius: corners == .leading ? radius : 0,
                    bottomTrailingRadius: corners == .trailing ? radius : 0,
                    topTrailingRadius: corners == .trailing ? radius : 0
                )
                .fill(ToastyTheme.sidebarSubspaceDoneMark)
            )
            .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
