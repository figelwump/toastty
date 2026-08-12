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
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
                                Text(conversation.agent.displayName)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(ToasttyDesignTokens.color(for: conversation.agent))
                                Text(conversation.title)
                                    .font(.headline)
                                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(conversation.age)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                            }
                            Text(conversation.lastActivity)
                                .font(.subheadline)
                                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                                .lineLimit(2)
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
                    .textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ToasttyDesignTokens.background)
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("toastty-mobile-workspace-detail")
    }
}
