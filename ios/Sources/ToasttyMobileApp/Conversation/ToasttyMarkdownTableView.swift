import SwiftUI

struct ToasttyMarkdownTableView: View {
    let table: ToasttyMarkdownTable
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 144

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(table.rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(table.columns.indices, id: \.self) { column in
                            Text(row.cells[column])
                                .font(row.isHeader ? .body.weight(.semibold) : .body)
                                .multilineTextAlignment(table.columns[column].textAlignment)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: table.columns[column].alignment)
                                .padding(10)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    max(minimumColumnWidth, width / CGFloat(table.columns.count))
                                }
                                .accessibilityAddTraits(row.isHeader ? .isHeader : [])
                        }
                    }
                    .background(row.isHeader ? ToasttyDesignTokens.raisedSurface : Color.clear)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(ToasttyDesignTokens.border)
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
        .background(ToasttyDesignTokens.background)
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius)
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius))
    }
}

private extension ToasttyMarkdownTable.ColumnAlignment {
    var alignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
