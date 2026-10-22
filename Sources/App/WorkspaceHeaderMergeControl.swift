import CoreState
import SwiftUI

/// The merge control under a subspace's title in the top bar: the Merge
/// button with a menu that picks what it does, its in-progress form while
/// Toastty merges, the cleanup that follows a Merge and Clean,
/// or the done label. While the pull request is not ready to merge, the
/// button opens it instead, in a neutral color, and its menu merges it.
/// It takes the subtitle slot, so it has to fit the 16pt the top bar
/// leaves under the title.
struct WorkspaceHeaderMergeControl: View {
    let presentation: WorkspaceMergePresentation
    /// `<owner>/<repo>#<number>`, so the tooltip names exactly what merges.
    var pullRequestName: String = ""
    var merge: () -> Void = {}
    /// Merges in the given mode, from the menu of a pull request that is
    /// not ready to merge.
    var mergeInMode: (WorkspaceMergeMode) -> Void = { _ in }
    var openPullRequest: () -> Void = {}
    var setMode: (WorkspaceMergeMode) -> Void = { _ in }
    var retryCleanup: () -> Void = {}
    var cancelCleanup: () -> Void = {}
    var closeWithoutMerging: () -> Void = {}
    /// A task space: Merge goes through the task, which always cleans up,
    /// and its menu offers the task's own choices instead of the modes.
    var isTask = false
    var mergeWithoutChecks: () -> Void = {}
    var archiveTask: () -> Void = {}

    private var shortcut: ToasttyKeyboardShortcut { ToasttyKeyboardShortcuts.mergeWorkspacePullRequest }

    var body: some View {
        switch presentation {
        case .ready(_, let mode, let blocker):
            let tone: WorkspaceHeaderMergeButtonStyle.Tone = blocker == nil ? .merge : .neutral
            HStack(spacing: 1) {
                Button(action: blocker == nil ? merge : openPullRequest) {
                    HStack(spacing: 4) {
                        Image(systemName: blocker == nil ? "arrow.triangle.merge" : "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                        titleText
                    }
                }
                .buttonStyle(WorkspaceHeaderMergeButtonStyle(corners: .leading, tone: tone))
                .help(primaryHelpText(mode: mode, blocker: blocker))
                .accessibilityLabel(presentation.title)
                .accessibilityIdentifier(blocker == nil ? "topbar.workspace.merge" : "topbar.workspace.merge.open")

                Menu {
                    if isTask {
                        if blocker != nil {
                            Button(shortcut.menuTitle("Merge \(presentation.pullRequest)"), action: merge)
                        }
                        Button("Merge Without Checks", action: mergeWithoutChecks)
                        Divider()
                        Button("Archive Task…", action: archiveTask)
                    } else if blocker != nil {
                        mergeActionItems(mode: mode)
                    } else {
                        modeMenuItems(mode: mode)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .frame(maxHeight: .infinity)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(WorkspaceHeaderMergeButtonStyle(corners: .trailing, horizontalPadding: 4, tone: tone))
                .fixedSize()
                .help(menuHelpText(blocker: blocker))
                .accessibilityLabel("Merge options")
                .accessibilityIdentifier("topbar.workspace.merge.mode")
            }

        case .merging, .cleaningUp, .closing:
            progressLabel
                .accessibilityIdentifier("topbar.workspace.merge.progress")

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

    @ViewBuilder
    private func modeMenuItems(mode: WorkspaceMergeMode) -> some View {
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
        // A one-off action, not a mode, so the button and its
        // shortcut never close a pull request.
        Divider()
        Button(WorkspaceMergePresentation.closeWithoutMergingTitle, action: closeWithoutMerging)
    }

    /// The modes as actions, like the sidebar's context menu: the button
    /// opens the pull request, so the menu is where it merges.
    @ViewBuilder
    private func mergeActionItems(mode: WorkspaceMergeMode) -> some View {
        ForEach(WorkspaceMergeMode.allCases, id: \.self) { option in
            let title = WorkspaceMergePresentation.actionTitle(mode: option, pullRequest: presentation.pullRequest)
            Button(option == mode ? shortcut.menuTitle(title) : title) {
                mergeInMode(option)
            }
        }
        Divider()
        Button(WorkspaceMergePresentation.closeWithoutMergingTitle, action: closeWithoutMerging)
    }

    private func primaryHelpText(mode: WorkspaceMergeMode, blocker: PullRequestMergeBlocker?) -> String {
        if let blocker {
            return "\(blocker.label): \(pullRequestName) is not ready to merge. Open it on GitHub, "
                + "or merge it anyway from the menu or with \(shortcut.symbolLabel)"
        }
        return shortcut.helpText(isTask ? taskHelpText : helpText(for: mode))
    }

    private func menuHelpText(blocker: PullRequestMergeBlocker?) -> String {
        if isTask { return "More ways to finish this task" }
        return blocker == nil ? "Choose what the Merge button does" : "Merge anyway, or close the pull request"
    }

    private var taskHelpText: String {
        "Merge \(pullRequestName) the task's way: its agent checks it first unless tasks.toml says merge = \"direct\". "
            + "Toastty then closes the task space and removes its worktree"
    }

    private func helpText(for mode: WorkspaceMergeMode) -> String {
        switch mode {
        case .mergeAndCleanUp:
            return "Merge \(pullRequestName), then close this workspace and remove its worktree once it merges"
        case .mergeOnly:
            return "Merge \(pullRequestName)"
        }
    }

    private var progressLabel: some View {
        HStack(spacing: 4) {
            SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.5)
            titleText
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

    /// A stopped cleanup opens a menu to retry or drop it.
    private func cleanupMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button("Retry Clean Up", action: retryCleanup)
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

    /// Green while the pull request is ready to merge, neutral while the
    /// button only opens it.
    enum Tone {
        case merge
        case neutral
    }

    let corners: Corners
    var horizontalPadding: CGFloat = ToastyTheme.workspaceMergeControlHorizontalPadding
    var tone: Tone = .merge
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let radius = ToastyTheme.workspaceMergeControlCornerRadius
        configuration.label
            .font(ToastyTheme.fontWorkspaceMergeButton)
            .foregroundStyle(tone == .merge ? ToastyTheme.accentDark : ToastyTheme.sidebarDisclosureText)
            .padding(.horizontal, horizontalPadding)
            .frame(height: ToastyTheme.workspaceMergeControlHeight)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: corners == .leading ? radius : 0,
                    bottomLeadingRadius: corners == .leading ? radius : 0,
                    bottomTrailingRadius: corners == .trailing ? radius : 0,
                    topTrailingRadius: corners == .trailing ? radius : 0
                )
                .fill(tone == .merge ? ToastyTheme.sidebarSubspaceDoneMark : ToastyTheme.sidebarDisclosureBackground)
            )
            .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
