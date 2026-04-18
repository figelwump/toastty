import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @State private var resultFramesByID: [String: CGRect] = [:]

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: CommandPalettePanel.cornerRadius,
            style: .continuous
        )

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
                .overlay(ToastyTheme.hairline)

            resultsSection
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            width: CommandPalettePanel.defaultFrame.width,
            height: CommandPalettePanel.defaultFrame.height
        )
        .background(
            shape.fill(Color(red: 0.18, green: 0.15, blue: 0.13).opacity(0.98))
        )
        .overlay(
            shape.stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.5), radius: 28, y: 12)
    }

    private var resultCountText: String {
        let count = viewModel.results.count
        return count == 1 ? "1 command" : "\(count) commands"
    }

    private var resultsSection: some View {
        VStack(spacing: 0) {
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
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    GeometryReader { geometry in
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                                        CommandPaletteResultRow(
                                            title: result.title,
                                            shortcut: result.command.shortcut?.symbolLabel,
                                            isSelected: index == viewModel.selectedIndex
                                        )
                                        .id(result.id)
                                        .background(
                                            GeometryReader { rowGeometry in
                                                Color.clear.preference(
                                                    key: CommandPaletteResultFramePreferenceKey.self,
                                                    value: [
                                                        result.id: rowGeometry.frame(
                                                            in: .named(CommandPaletteResultsScrollSpace.name)
                                                        )
                                                    ]
                                                )
                                            }
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.select(index: index)
                                            viewModel.submitSelection()
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            }
                            .coordinateSpace(name: CommandPaletteResultsScrollSpace.name)
                            .onChange(of: viewModel.selectedIndex) { _, _ in
                                scrollSelectionIfNeeded(using: proxy, viewportHeight: geometry.size.height)
                            }
                            .onPreferenceChange(CommandPaletteResultFramePreferenceKey.self) { frames in
                                resultFramesByID = frames
                                scrollSelectionIfNeeded(using: proxy, viewportHeight: geometry.size.height)
                            }
                            .onChange(of: geometry.size.height) { _, newHeight in
                                scrollSelectionIfNeeded(using: proxy, viewportHeight: newHeight)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scrollSelectionIfNeeded(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard let selectedResultID = viewModel.selectedResult?.id else {
            return
        }

        guard let scrollTarget = CommandPaletteScrollVisibility.scrollTarget(
            for: resultFramesByID[selectedResultID],
            viewportHeight: viewportHeight
        ) else {
            return
        }

        proxy.scrollTo(selectedResultID, anchor: scrollTarget.anchor)
    }
}

enum CommandPaletteScrollTarget: Equatable {
    case top
    case bottom

    var anchor: UnitPoint {
        switch self {
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }
}

struct CommandPaletteScrollVisibility {
    private static let viewportTolerance: CGFloat = 1

    static func scrollTarget(
        for resultFrame: CGRect?,
        viewportHeight: CGFloat
    ) -> CommandPaletteScrollTarget? {
        guard let resultFrame, viewportHeight > 0 else {
            return nil
        }

        if resultFrame.minY < -viewportTolerance {
            return .top
        }

        if resultFrame.maxY > viewportHeight + viewportTolerance {
            return .bottom
        }

        return nil
    }
}

private enum CommandPaletteResultsScrollSpace {
    static let name = "command-palette.results.scroll"
}

private struct CommandPaletteResultFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
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
