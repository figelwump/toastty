import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ToasttyMarkdownTableView: View {
    @Environment(\.layoutDirection) private var layoutDirection

    let table: ToasttyMarkdownTable
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 144

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(table.rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(table.columns.indices, id: \.self) { column in
                            ToasttySelectableText(row.cells[column],
                                                  weight: row.isHeader ? .semibold : nil,
                                                  alignment: table.columns[column].textAlignment(layoutDirection: layoutDirection))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: table.columns[column].alignment)
                                .padding(10)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    max(minimumColumnWidth, width / CGFloat(table.columns.count))
                                }
                                .accessibilityAddTraits(row.isHeader ? .isHeader : [])
                        }
                    }
                    .background(row.isHeader ? ConversationDesignTokens.raisedSurface : Color.clear)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(ConversationDesignTokens.border)
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
        .background(ConversationDesignTokens.background)
        .overlay {
            RoundedRectangle(cornerRadius: ConversationDesignTokens.controlCornerRadius)
                .stroke(ConversationDesignTokens.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: ConversationDesignTokens.controlCornerRadius))
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

    func textAlignment(layoutDirection: LayoutDirection) -> NSTextAlignment {
        switch self {
        case .leading: layoutDirection == .rightToLeft ? .right : .left
        case .center: .center
        case .trailing: layoutDirection == .rightToLeft ? .left : .right
        }
    }
}
