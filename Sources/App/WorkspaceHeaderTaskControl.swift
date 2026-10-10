import CoreState
import SwiftUI

/// The task control under a subspace's title in the top bar: Finish Task
/// while the task is ready for review, Clean Up once it is done, a progress
/// label while a script runs, and the result of a script that stopped. The
/// arrow beside the button holds the manual stage moves and Close Task. It
/// takes the subtitle slot, so it has to fit the 16pt the top bar leaves
/// under the title.
struct WorkspaceHeaderTaskControl: View {
    let button: SidebarSubspacePresentation.TaskButton
    let stageActions: [SidebarSubspacePresentation.StageAction]
    /// The close hook, when the task has one.
    var closeHook: WorkspaceTaskHooks.ScriptHook?
    var runButton: () -> Void = {}
    var setStage: (WorkspaceTaskStage) -> Void = { _ in }
    var close: () -> Void = {}
    var retry: (WorkspaceTaskHooks.ScriptKind) -> Void = { _ in }
    var dismiss: () -> Void = {}

    var body: some View {
        switch button {
        case .finish, .cleanUp:
            HStack(spacing: 1) {
                Button(action: runButton) {
                    HStack(spacing: 4) {
                        if let symbolName = button.symbolName {
                            Image(systemName: symbolName)
                                .font(.system(size: 8, weight: .bold))
                        }
                        titleText
                    }
                }
                .buttonStyle(WorkspaceTaskButtonStyle(corners: .leading))
                .help(button.help)
                .accessibilityLabel(button.title)
                .accessibilityHint(button.help)
                .accessibilityIdentifier("topbar.workspace.task")
                Menu {
                    ForEach(stageActions, id: \.self) { action in
                        Button(action.title) { setStage(action.stage) }
                    }
                    if let closeHook {
                        Divider()
                        Button(WorkspaceTaskHookPresentation.title(.close) + "…", action: close)
                            .help(WorkspaceTaskHookPresentation.scriptHelp(closeHook))
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .frame(maxHeight: .infinity)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(WorkspaceTaskButtonStyle(corners: .trailing, horizontalPadding: 4))
                .fixedSize()
                .help("More task actions")
                .accessibilityLabel("Task options")
                .accessibilityIdentifier("topbar.workspace.task.options")
            }
        case .running:
            HStack(spacing: 4) {
                SessionStatusIndicator(state: .spinner, size: 8, lineWidth: 1.5)
                titleText
            }
            .font(ToastyTheme.fontWorkspaceTaskProgress)
            .foregroundStyle(ToastyTheme.sidebarSummaryText)
            .padding(.horizontal, ToastyTheme.workspaceTaskControlHorizontalPadding)
            .frame(height: ToastyTheme.workspaceTaskControlHeight)
            .overlay(
                RoundedRectangle(cornerRadius: ToastyTheme.workspaceTaskControlCornerRadius)
                    .strokeBorder(ToastyTheme.subtleBorder, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(button.title)
            .accessibilityIdentifier("topbar.workspace.task.progress")
        case .skipped(let kind, let detail), .failed(let kind, let detail):
            Menu {
                Button(detail) {}
                    .disabled(true)
                Button("Retry \(WorkspaceTaskHookPresentation.title(kind))…") { retry(kind) }
                Button("Dismiss", action: dismiss)
                Divider()
                ForEach(stageActions, id: \.self) { action in
                    Button(action.title) { setStage(action.stage) }
                }
                if let closeHook, kind != .close {
                    Divider()
                    Button(WorkspaceTaskHookPresentation.title(.close) + "…", action: close)
                        .help(WorkspaceTaskHookPresentation.scriptHelp(closeHook))
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                    titleText
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(ToastyTheme.fontWorkspaceTaskProgress)
                .foregroundStyle(ToastyTheme.sidebarSummaryText)
                .frame(height: ToastyTheme.workspaceTaskControlHeight)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .help(detail)
            .accessibilityIdentifier("topbar.workspace.task.stopped")
        }
    }

    // No fixed size: a long title truncates inside the title column
    // instead of widening it.
    private var titleText: some View {
        Text(button.title)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The green task button, in the top bar and on a hovered subspace row.
struct WorkspaceTaskButtonStyle: ButtonStyle {
    enum Corners {
        case leading
        case trailing
        case all
    }

    var corners: Corners = .all
    var horizontalPadding: CGFloat = ToastyTheme.workspaceTaskControlHorizontalPadding
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let radius = ToastyTheme.workspaceTaskControlCornerRadius
        let leading = corners != .trailing ? radius : 0
        let trailing = corners != .leading ? radius : 0
        configuration.label
            .font(ToastyTheme.fontWorkspaceTaskButton)
            .foregroundStyle(ToastyTheme.accentDark)
            .padding(.horizontal, horizontalPadding)
            .frame(height: ToastyTheme.workspaceTaskControlHeight)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: leading,
                    bottomLeadingRadius: leading,
                    bottomTrailingRadius: trailing,
                    topTrailingRadius: trailing
                )
                .fill(ToastyTheme.sidebarSubspaceDoneMark)
            )
            .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
