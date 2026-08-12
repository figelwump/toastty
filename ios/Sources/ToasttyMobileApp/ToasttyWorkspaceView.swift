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
        .accessibilityIdentifier("toastty-mobile-workspace-detail")
    }

    private func workspaceList(_ workspace: MobileWorkspace) -> some View {
        List {
            Section {
                ForEach(stablySortedConversations(in: workspace)) { conversation in
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
    }

    private func onOpen(_ conversation: MobileConversation) {
        controller.open(conversation)
    }

    private func stablySortedConversations(in workspace: MobileWorkspace) -> [MobileConversation] {
        workspace.sortedConversations.sorted {
            if $0.state.bucket.sortOrder != $1.state.bucket.sortOrder {
                return $0.state.bucket.sortOrder < $1.state.bucket.sortOrder
            }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
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
