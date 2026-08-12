import SwiftUI
import ToasttyMobileDomain

struct ToasttyWorkspaceView: View {
    let workspace: MobileWorkspace
    let onOpen: (MobileConversation) -> Void

    var body: some View {
        List {
            Section {
                ForEach(workspace.sortedConversations) { conversation in
                    Button { onOpen(conversation) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    metadata(for: conversation)
                                    title(for: conversation)
                                    Spacer(minLength: 4)
                                    age(for: conversation)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            metadata(for: conversation)
                                            Spacer(minLength: 8)
                                            age(for: conversation)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            metadata(for: conversation)
                                            age(for: conversation)
                                        }
                                    }
                                    title(for: conversation)
                                }
                            }
                            Text(conversation.lastActivity)
                                .font(.subheadline)
                                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(ToasttyDesignTokens.background)
                    .accessibilityLabel(conversation.accessibilitySummary)
                    .accessibilityIdentifier("toastty-mobile-workspace-session-\(conversation.id.uuidString)")
                }
            } header: {
                Text("\(workspace.conversations.count) sessions · \(workspace.path)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .textCase(nil)
                    .accessibilityIdentifier("toastty-mobile-workspace-context")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ToasttyDesignTokens.background)
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("toastty-mobile-workspace-detail")
    }

    @ViewBuilder
    private func metadata(for conversation: MobileConversation) -> some View {
        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
        Text(conversation.agent.displayName)
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(ToasttyDesignTokens.color(for: conversation.agent))
    }

    private func title(for conversation: MobileConversation) -> some View {
        Text(conversation.title)
            .font(.headline)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
    }

    private func age(for conversation: MobileConversation) -> some View {
        Text(conversation.age)
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
    }
}
