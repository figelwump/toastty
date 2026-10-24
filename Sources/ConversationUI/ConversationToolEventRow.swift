import SwiftUI

public struct ConversationToolEventRow: View {
    let summary: String
    let detail: String?
    let systemImage: String
    let tint: Color
    let theme: ConversationTheme

    public init(summary: String, detail: String? = nil,
                systemImage: String = "wrench", tint: Color? = nil,
                theme: ConversationTheme = .toastty) {
        self.summary = summary
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint ?? theme.mutedText
        self.theme = theme
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(summary)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                if let detail = detail, detail.isEmpty == false {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(theme.raisedSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: theme.controlCornerRadius,
                style: .continuous
            )
            .stroke(theme.border)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: theme.controlCornerRadius,
            style: .continuous
        ))
        .accessibilityElement(children: .combine)
    }
}

