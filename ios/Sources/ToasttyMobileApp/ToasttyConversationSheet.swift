import SwiftUI
import ToasttyMobileDomain

struct ToasttyConversationSheet: View {
    let conversationID: UUID
    let controller: HomeScreenController
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let conversation = controller.conversation(id: conversationID) {
                VStack(spacing: 0) {
                    header(conversation)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(conversation.lastActivity)
                                .font(.body)
                                .foregroundStyle(ToasttyDesignTokens.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if case .pendingInteraction(let preview) = conversation.inputAvailability {
                                pendingInteraction(preview: preview)
                            }

                            Text("Full transcript arrives in the transcript milestone. This view keeps interaction requests read-only.")
                                .font(.footnote)
                                .foregroundStyle(ToasttyDesignTokens.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                    }
                    composerState(conversation)
                }
            } else {
                ContentUnavailableView(
                    "Conversation no longer available",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("It was removed from Toastty on your Mac.")
                )
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
            }
        }
        .background(ToasttyDesignTokens.elevatedSurface)
    }

    private func header(_ conversation: MobileConversation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.headline)
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .accessibilityIdentifier("toastty-mobile-conversation-title")
                    HStack(spacing: 6) {
                        Text(conversation.workspaceTitle)
                        Text("·")
                        Text(conversation.agent.displayName)
                        Text("·")
                        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
                Spacer(minLength: 12)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(ToasttyDesignTokens.border, in: Circle())
                }
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityLabel("Close conversation")
                .accessibilityIdentifier("toastty-mobile-conversation-close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(ToasttyDesignTokens.divider) }
    }

    private func pendingInteraction(preview: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Interaction waiting", systemImage: "exclamationmark.bubble")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amber)
            Text(preview ?? "Waiting for a response on the Mac")
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
            Text("Respond on the desktop")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amberText)
        }
        .padding(14)
        .background(Color(red: 24 / 255, green: 21 / 255, blue: 9 / 255))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(ToasttyDesignTokens.amber.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-mobile-readonly-interaction")
    }

    private func composerState(_ conversation: MobileConversation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: composerIcon(conversation))
            Text(composerMessage(conversation))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption.monospaced())
        .foregroundStyle(composerColor(conversation))
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().overlay(ToasttyDesignTokens.divider) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(composerMessage(conversation))
        .accessibilityIdentifier("toastty-mobile-composer-status")
    }

    private func composerIcon(_ conversation: MobileConversation) -> String {
        switch conversation.inputAvailability {
        case .openPrompt: "desktopcomputer"
        case .localDraft: "pencil.line"
        case .pendingInteraction: "desktopcomputer"
        case .unavailable: "lock"
        }
    }

    private func composerMessage(_ conversation: MobileConversation) -> String {
        switch conversation.inputAvailability {
        case .openPrompt:
            "Read-only on iPhone — respond on your Mac"
        case .localDraft:
            "Paused — a draft is in progress on the desktop"
        case .pendingInteraction:
            "Respond on the desktop"
        case .unavailable(let reason):
            "Input not available: \(reason)"
        }
    }

    private func composerColor(_ conversation: MobileConversation) -> Color {
        conversation.inputAvailability == .localDraft
            ? ToasttyDesignTokens.amberText
            : ToasttyDesignTokens.mutedText
    }
}
