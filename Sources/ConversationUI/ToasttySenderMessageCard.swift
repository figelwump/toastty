import SwiftUI

/// Third-party messages keep their sender and opening text visible. Their
/// disclosure changes only the message body, never the turn's answer.
struct ToasttySenderMessageCard: View {
    let sender: String
    let timeText: String
    let text: String
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    let accessibilitySuffix: String

    /// A bounded opening for long messages, without generating a summary.
    /// Short messages show in full and offer no disclosure control.
    static func preview(of text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
        let opening = String(lines.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        return opening.count < text.count ? opening + "…" : nil
    }

    var body: some View {
        let preview = Self.preview(of: text)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("From")
                    .foregroundStyle(ConversationDesignTokens.mutedText)
                Text(sender)
                    .fontWeight(.semibold)
                    .foregroundStyle(ConversationDesignTokens.primaryText)
                Spacer(minLength: 8)
                Text(timeText)
                    .foregroundStyle(ConversationDesignTokens.mutedText)
            }
            .conversationFont(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ConversationDesignTokens.codeHeaderSurface)

            Divider().overlay(ConversationDesignTokens.border)

            ToasttyMarkdownText(text: isExpanded ? text : preview ?? text)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

            if preview != nil {
                Divider().overlay(ConversationDesignTokens.border)
                Button(action: toggleExpansion) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        Text(isExpanded ? "Show less" : "Show full message")
                    }
                    .conversationFont(.caption)
                    .foregroundStyle(ConversationDesignTokens.amberText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("toastty-transcript-sender-expand-\(accessibilitySuffix)")
            }
        }
        .background(ConversationDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: ConversationDesignTokens.controlCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ConversationDesignTokens.controlCornerRadius)
                .stroke(ConversationDesignTokens.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
