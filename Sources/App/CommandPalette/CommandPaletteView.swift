import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ToastyTheme.subtleText)

                PaletteSearchField(
                    text: $viewModel.query,
                    placeholder: "Type a command...",
                    focusRequestID: viewModel.focusRequestID,
                    accessibilityID: "command-palette.search",
                    onMoveUp: { viewModel.moveSelection(delta: -1) },
                    onMoveDown: { viewModel.moveSelection(delta: 1) },
                    onSubmit: viewModel.submitSelection,
                    onCancel: viewModel.dismiss
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .overlay(ToastyTheme.hairline)

            Group {
                if viewModel.results.isEmpty {
                    VStack(spacing: 10) {
                        Text("No matching commands")
                            .font(ToastyTheme.fontBody)
                            .foregroundStyle(ToastyTheme.inactiveText)

                        Text("Try a broader query.")
                            .font(ToastyTheme.fontSubtext)
                            .foregroundStyle(ToastyTheme.subtleText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                            CommandPaletteResultRow(
                                title: result.title,
                                shortcut: result.command.shortcut?.symbolLabel,
                                isSelected: index == viewModel.selectedIndex
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.select(index: index)
                                viewModel.submitSelection()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .background(ToastyTheme.chromeBackground.opacity(0.96))

            Divider()
                .overlay(ToastyTheme.hairline)

            HStack {
                Text(resultCountText)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(ToastyTheme.subtleText)

                Spacer()

                Text("Return Execute   Esc Cancel")
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(ToastyTheme.subtleText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 580)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.18, green: 0.15, blue: 0.13).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.5), radius: 28, y: 12)
        .padding(1)
    }

    private var resultCountText: String {
        let count = viewModel.results.count
        return count == 1 ? "1 command" : "\(count) commands"
    }
}

private struct CommandPaletteResultRow: View {
    let title: String
    let shortcut: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(isSelected ? ToastyTheme.accent : Color.clear)
                .frame(width: 3, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))

            Text(title)
                .font(ToastyTheme.fontBody)
                .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let shortcut {
                Text(shortcut)
                    .font(ToastyTheme.fontShortcutBadge)
                    .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.subtleText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(isSelected ? 0.08 : 0.04))
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? ToastyTheme.accent.opacity(0.16) : Color.clear)
                .padding(.horizontal, 8)
        )
    }
}
