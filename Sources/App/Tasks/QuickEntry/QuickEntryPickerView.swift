import SwiftUI

/// An open Workspace or Agent picker, drawn to "Task Keyboard Flow"
/// revision 3, section 2: a search field, the rows in sections, and the
/// keys that work.
struct QuickEntryPickerView: View {
    @ObservedObject var picker: QuickEntryPicker
    /// Called with the content's size whenever it changes, so the window
    /// can fit it.
    let onSizeChange: (CGSize) -> Void

    static let background = Color(hex: 0x1F1F1F)
    static let border = Color(hex: 0x3D3D3D)
    static let divider = Color(hex: 0x2E2E2E)
    static let selectedRow = Color(hex: 0x2A2622)
    static let accent = QuickEntryView.accentText
    /// The list scrolls past this height.
    static let maximumListHeight: CGFloat = 320

    @State private var listHeight: CGFloat = 0

    private var width: CGFloat {
        if picker.columns != nil { return 520 }
        return picker.kind == .workspace ? 360 : 420
    }

    private var placeholder: String {
        if picker.columns != nil { return "Choose agent, model, effort" }
        return picker.kind == .workspace ? "Search workspaces…" : "Search agents, models…"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            QuickEntryPickerSearchField(
                text: $picker.query,
                placeholder: placeholder,
                onMove: { picker.move($0) },
                onArrow: { picker.adjustEffort($0) },
                onTab: { picker.tab($0) },
                onSubmit: { picker.submit() },
                onCancel: { picker.cancel() }
            )
            .frame(height: 17)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)

            Rectangle().fill(Self.divider).frame(height: 1)

            if let columns = picker.columns {
                ColumnsView(picker: picker, columns: columns)
            } else {
                rowList
            }

            Rectangle().fill(Self.divider).frame(height: 1)
            footer
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Self.background))
        .overlay(shape.strokeBorder(Self.border, lineWidth: 1))
        .clipShape(shape)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            onSizeChange(size)
        }
    }

    private var rowList: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                        if let section = row.section, index == 0 || picker.rows[index - 1].section != section {
                            SectionHeader(title: section)
                        }
                        PickerRow(
                            row: row,
                            query: picker.query,
                            isHighlighted: row.id == picker.highlightedID,
                            choose: { picker.choose(rowID: row.id) },
                            adjustEffort: { _ = picker.adjustEffort($0) }
                        )
                        .id(row.id)
                    }
                    if picker.rows.isEmpty {
                        Text("No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(QuickEntryView.mutedText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    listHeight = height
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(listHeight, Self.maximumListHeight))
            .onChange(of: picker.highlightedID) {
                if let id = picker.highlightedID {
                    scroller.scrollTo(id)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if picker.columns != nil {
                KeyHint(keys: ["tab"], label: "next column")
                Text("type to filter the focused column")
                Spacer(minLength: 8)
                Button("Choose") { picker.submit() }
                    .buttonStyle(ChooseButtonStyle())
                    .accessibilityIdentifier("quick-entry.picker.choose")
            } else {
                if let last = picker.rows.last(where: { $0.number != nil })?.number {
                    KeyHint(keys: [last > 1 ? "1–\(last)" : "1"], label: "pick")
                }
                if picker.kind == .agent {
                    KeyHint(keys: ["←", "→"], label: "effort")
                }
                KeyHint(keys: ["↩"], label: "choose")
                KeyHint(keys: ["esc"], label: "back")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(QuickEntryView.mutedText)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}

/// The text with the characters the search matched in the accent color.
private func highlighted(_ text: String, query: String) -> AttributedString {
    var result = AttributedString(text)
    let offsets = QuickEntrySearch.matchedOffsets(query, in: text)
    guard offsets.isEmpty == false else { return result }
    var index = result.startIndex
    var offset = 0
    while index < result.endIndex {
        let next = result.characters.index(after: index)
        if offsets.contains(offset) {
            result[index..<next].foregroundColor = QuickEntryPickerView.accent
        }
        index = next
        offset += 1
    }
    return result
}

private struct SectionHeader: View {
    let title: String
    var isFocused = false

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(isFocused ? QuickEntryPickerView.accent : QuickEntryView.mutedText)
            .padding(EdgeInsets(top: 8, leading: 11, bottom: 3, trailing: 11))
            .accessibilityAddTraits(.isHeader)
    }
}

private struct PickerRow: View {
    let row: QuickEntryPicker.Row
    let query: String
    let isHighlighted: Bool
    let choose: () -> Void
    let adjustEffort: (Int) -> Void

    private var isAdjustable: Bool {
        if case .preset = row.action, row.detail != nil { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(row.number.map(String.init) ?? (isHighlighted && query.isEmpty == false ? "↩" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(QuickEntryView.mutedText)
                .frame(width: 16)
            Text(highlighted(row.title, query: query))
                .font(.system(size: 13))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if isHighlighted, isAdjustable, let effort = row.detail {
                EffortStepper(effort: effort, adjust: adjustEffort)
            } else if row.detailIsShortcut, let detail = row.detail {
                KeyHint(keys: [detail], label: "")
            } else if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(QuickEntryView.mutedText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(isHighlighted ? QuickEntryPickerView.selectedRow : Color.clear)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle().fill(QuickEntryPickerView.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose() }
        .accessibilityIdentifier("quick-entry.picker.row")
    }
}

/// "◀ high ▶" on the highlighted Frequent row; ← → or a click change it.
private struct EffortStepper: View {
    let effort: String
    let adjust: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { adjust(-1) } label: { Text("◀") }
                .accessibilityLabel("Lower effort")
            Text(effort)
                .font(.system(size: 12))
                .foregroundStyle(QuickEntryPickerView.accent)
            Button { adjust(1) } label: { Text("▶") }
                .accessibilityLabel("Higher effort")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(QuickEntryView.mutedText)
        .fixedSize()
    }
}

/// The three columns: Agent, Model, Effort.
private struct ColumnsView: View {
    @ObservedObject var picker: QuickEntryPicker
    let columns: QuickEntryPresetColumns

    private static let weights: [QuickEntryPresetColumns.Column: CGFloat] = [.agent: 1, .model: 1.3, .effort: 0.8]

    var body: some View {
        let visible = columns.visibleColumns
        let total = visible.reduce(0) { $0 + (Self.weights[$1] ?? 1) }
        HStack(alignment: .top, spacing: 0) {
            ForEach(visible, id: \.self) { column in
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: column.title, isFocused: column == columns.focused)
                    ForEach(columns.cells(in: column)) { cell in
                        ColumnCell(
                            title: column == columns.focused
                                ? highlighted(cell.title, query: columns.query)
                                : AttributedString(cell.title),
                            isMuted: cell.isMuted,
                            isSelected: columns.isSelected(cell)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { picker.select(cell, in: column) }
                        .accessibilityAction { picker.select(cell, in: column) }
                    }
                }
                .padding(.bottom, 6)
                .frame(width: 520 * (Self.weights[column] ?? 1) / total, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    if column != visible.last {
                        Rectangle().fill(QuickEntryPickerView.divider).frame(width: 1)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(column.title)
                .accessibilityIdentifier("quick-entry.picker.column")
            }
        }
    }
}

private struct ColumnCell: View {
    let title: AttributedString
    let isMuted: Bool
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12.5))
            .foregroundStyle(isMuted ? QuickEntryView.mutedText : ToastyTheme.primaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? QuickEntryPickerView.selectedRow : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(QuickEntryPickerView.accent).frame(width: 2)
                }
            }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Keys and what they do, for the picker's footer.
private struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0x262626)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color(hex: 0x3C3C3C), lineWidth: 1))
            }
            if label.isEmpty == false {
                Text(label)
            }
        }
        .fixedSize()
    }
}

private struct ChooseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(ToastyTheme.accentDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(QuickEntryPickerView.accent.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}
