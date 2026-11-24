import SwiftUI

/// The line above the first message that the reader has not seen.
struct ToasttyNewMessagesDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(ConversationDesignTokens.newMessagesLine)
                .frame(height: 1)
            Text("New")
                .conversationFont(.caption, weight: .semibold)
                .foregroundStyle(ConversationDesignTokens.newMessagesLine)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New messages")
        .accessibilityIdentifier("toastty-transcript-new-messages")
    }
}
