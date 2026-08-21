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
        let sortedConversations = workspace.sortedConversations
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(sessionCountLabel(workspace.conversations.count))
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("toastty-mobile-workspace-context")

                ForEach(sortedConversations) { conversation in
                    ToasttySessionCard(
                        conversation: conversation,
                        showsWorkspace: false,
                        accessibilityIdentifier:
                            "toastty-mobile-workspace-session-\(conversation.id.uuidString)",
                        onOpen: onOpen
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            // Reorders happen only on status-bucket transitions; animate so
            // the moving card stays trackable.
            .animation(.default, value: sortedConversations.map(\.id))
        }
        .scrollIndicators(.hidden)
        .background(ToasttyDesignTokens.background)
    }

    private func onOpen(_ conversation: MobileConversation) {
        controller.open(conversation)
    }

    private func sessionCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "session" : "sessions")"
    }
}
