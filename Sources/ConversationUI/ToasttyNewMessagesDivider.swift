import SwiftUI

/// Where the messages that the reader has not seen start. The host decides
/// what the reader has seen; the transcript draws a line above the first of
/// these rows and names their count on Jump to latest.
public struct ToasttyNewMessagesMarker: Equatable, Sendable {
    /// The first row that the reader has not seen. The line goes above the
    /// first shown item at or after it.
    public let firstRowID: ToasttyTranscriptRowID
    /// The messages below the line.
    public let count: Int

    public init(firstRowID: ToasttyTranscriptRowID, count: Int) {
        self.firstRowID = firstRowID
        self.count = count
    }

    /// The shown item that the line goes above: the first one at or after
    /// `firstRowID`. A folded turn's hidden work has no item, so the line
    /// goes above the next item that shows.
    func itemID(in items: [ToasttyTranscriptDisplayItem]) -> ToasttyConversationScrollTarget? {
        items.first { item in
            guard let rowID = item.firstRowID,
                  rowID.projectionRunID == firstRowID.projectionRunID,
                  rowID.projectionGeneration == firstRowID.projectionGeneration
            else { return false }
            return rowID.sequence >= firstRowID.sequence
        }?.id
    }
}

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
