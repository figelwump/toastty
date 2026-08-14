import SwiftUI
import ToasttyMobileDomain

struct ToasttyWorkspaceView: View {
    let workspaceID: UUID
    let controller: HomeScreenController

    var body: some View {
        Group {
            if let workspace = controller.workspace(id: workspaceID) {
                workspaceList(workspace)
            } else {
                ContentUnavailableView(
                    "Workspace no longer available",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("It was removed from Toastty on your Mac.")
                )
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityIdentifier("toastty-mobile-workspace-removed")
            }
        }
        .background(ToasttyDesignTokens.background)
        .navigationTitle(controller.workspace(id: workspaceID)?.title ?? "Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("toastty-mobile-workspace-detail")
    }

    private func workspaceList(_ workspace: MobileWorkspace) -> some View {
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
                Text(sessionCountLabel(workspace.conversations.count))
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .textCase(nil)
                    .accessibilityIdentifier("toastty-mobile-workspace-context")
            }
        }
        .scrollContentBackground(.hidden)
        .background(ToasttyDesignTokens.background)
    }

    private func onOpen(_ conversation: MobileConversation) {
        controller.open(conversation)
    }

    @ViewBuilder
    private func metadata(for conversation: MobileConversation) -> some View {
        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
        Text(conversation.agent.displayName)
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
        if let cwd = conversation.cwd {
            Text("·")
                .foregroundStyle(ToasttyDesignTokens.mutedText)
            Text(cwd)
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func title(for conversation: MobileConversation) -> some View {
        Text(conversation.title)
            .font(.headline)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
    }

    private func age(for conversation: MobileConversation) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(conversation.displayAge)
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
    }

    private func sessionCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "session" : "sessions")"
    }
}
