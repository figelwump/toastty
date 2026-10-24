import SwiftUI

public struct ConversationMarkdownTableView: View {
    @Environment(\.layoutDirection) private var layoutDirection

    let table: ConversationMarkdownTable
    var theme: ConversationTheme = .toastty
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 144

    public init(table: ConversationMarkdownTable, theme: ConversationTheme = .toastty) {
        self.table = table
        self.theme = theme
    }

    public var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(table.rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(table.columns.indices, id: \.self) { column in
                            ConversationSelectableText(row.cells[column],
                                                  weight: row.isHeader ? .semibold : nil,
                                                  alignment: table.columns[column].textAlignment(layoutDirection: layoutDirection), theme: theme)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: table.columns[column].alignment)
                                .padding(10)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    max(minimumColumnWidth, width / CGFloat(table.columns.count))
                                }
                                .accessibilityAddTraits(row.isHeader ? .isHeader : [])
                        }
                    }
                    .background(row.isHeader ? theme.raisedSurface : Color.clear)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.border)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-mobile-markdown-table")
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.background)
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                .stroke(theme.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.controlCornerRadius))
    }
}

private extension ConversationMarkdownTable.ColumnAlignment {
    var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    func textAlignment(layoutDirection: LayoutDirection) -> ConversationTextAlignment {
        switch self {
        case .leading: layoutDirection == .rightToLeft ? .right : .left
        case .center: .center
        case .trailing: layoutDirection == .rightToLeft ? .left : .right
        }
    }
}
