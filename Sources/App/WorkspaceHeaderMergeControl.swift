import CoreState
import SwiftUI

/// The merge control under a subspace's title in the top bar: the Merge
/// button, its in-progress form while the agent works on the merge, or the
/// done label. It takes the subtitle slot, so it has to fit the 16pt the
/// top bar leaves under the title.
struct WorkspaceHeaderMergeControl: View {
    let presentation: WorkspaceMergePresentation
    let merge: () -> Void

    var body: some View {
        switch presentation {
        case .ready:
            Button(action: merge) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 8, weight: .bold))
                    titleText
                }
            }
            .buttonStyle(WorkspaceHeaderMergeButtonStyle())
            .help("Ask this workspace's agent to merge the pull request")
            .accessibilityLabel(presentation.title)
            .accessibilityIdentifier("topbar.workspace.merge")

        case .merging:
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
            .accessibilityIdentifier("topbar.workspace.merge.progress")

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

    // No fixed size: a long pull request label truncates inside the title
    // column instead of widening it.
    private var titleText: some View {
        Text(presentation.title)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct WorkspaceHeaderMergeButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ToastyTheme.fontWorkspaceMergeButton)
            .foregroundStyle(ToastyTheme.accentDark)
            .padding(.horizontal, ToastyTheme.workspaceMergeControlHorizontalPadding)
            .frame(height: ToastyTheme.workspaceMergeControlHeight)
            .background(
                RoundedRectangle(cornerRadius: ToastyTheme.workspaceMergeControlCornerRadius)
                    .fill(ToastyTheme.sidebarSubspaceDoneMark)
            )
            .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
