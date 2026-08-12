import SwiftUI
import ToasttyMobileDomain

struct ToasttyHomeView: View {
    let controller: HomeScreenController

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                header
                needsYouSection
                workspaceSection
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(ToasttyDesignTokens.background)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("toastty-mobile-home")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                brand
                Spacer(minLength: 12)
                connection
            }
            VStack(alignment: .leading, spacing: 8) {
                brand
                connection
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var brand: some View {
        Text("TOASTTY")
            .font(.headline.monospaced())
            .fontWeight(.bold)
            .tracking(3.2)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private var connection: some View {
        ToasttyConnectionPill(
            state: controller.connectionState,
            hostName: controller.snapshot.hostName
        )
    }

    private var needsYouSection: some View {
        VStack(spacing: 10) {
            ToasttySectionTitle(title: "Needs you · \(controller.snapshot.needsYou.count)")
                .padding(.top, 6)
                .accessibilityIdentifier("toastty-mobile-needs-you-section")

            if controller.snapshot.needsYou.isEmpty {
                Text("queue clear — all agents running or idle")
                    .font(.caption.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
            } else {
                ForEach(controller.snapshot.needsYou) { conversation in
                    ToasttyNeedsYouCard(conversation: conversation, onOpen: controller.open)
                }
            }
        }
    }

    private var workspaceSection: some View {
        VStack(spacing: 10) {
            ToasttySectionTitle(title: "Workspaces")
                .padding(.top, 12)
                .accessibilityIdentifier("toastty-mobile-workspaces-section")

            if controller.snapshot.workspaces.isEmpty {
                ContentUnavailableView(
                    "No workspaces yet",
                    systemImage: "rectangle.stack",
                    description: Text("Pair this device with Toastty on your Mac to get started.")
                )
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .padding(.vertical, 32)
            } else {
                ForEach(controller.snapshot.workspaces) { workspace in
                    ToasttyWorkspaceCard(workspace: workspace, onOpen: controller.open)
                }
            }
        }
    }
}

private struct ToasttyNeedsYouCard: View {
    let conversation: MobileConversation
    let onOpen: (MobileConversation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { metadata }
                VStack(alignment: .leading, spacing: 4) { metadata }
            }

            Text(conversation.title)
                .font(.headline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)

            Text(conversation.inputAvailability.needsYouReason)
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if conversation.inputAvailability.allowsReply {
                    Button("Reply") { onOpen(conversation) }
                        .buttonStyle(ToasttyPrimaryButtonStyle())
                        .accessibilityIdentifier("toastty-mobile-reply-\(conversation.id.uuidString)")
                }

                Spacer(minLength: 4)

                Button("Open", systemImage: "chevron.right") { onOpen(conversation) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .accessibilityIdentifier("toastty-mobile-open-\(conversation.id.uuidString)")
            }
            .padding(.top, 3)
        }
        .toasttyCard()
        .overlay(alignment: .leading) {
            Capsule()
                .fill(ToasttyDesignTokens.amber)
                .frame(width: 3)
                .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(conversation.accessibilitySummary)
        .accessibilityIdentifier("toastty-mobile-needs-you-card-\(conversation.id.uuidString)")
    }

    @ViewBuilder
    private var metadata: some View {
        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
        Text(conversation.workspaceTitle)
        Text("·")
        Text(conversation.agent.displayName)
            .fontWeight(.bold)
            .foregroundStyle(ToasttyDesignTokens.color(for: conversation.agent))
        Text("· \(conversation.age)")
    }
}

private struct ToasttyWorkspaceCard: View {
    let workspace: MobileWorkspace
    let onOpen: (MobileConversation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: workspace.id) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        workspaceIdentity
                        Spacer(minLength: 8)
                        rollupPill
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        workspaceIdentity
                        rollupPill
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("toastty-mobile-workspace-\(workspace.id.uuidString)")

            Divider()
                .overlay(ToasttyDesignTokens.divider)
                .padding(.top, 10)

            ForEach(workspace.sortedConversations.prefix(3)) { conversation in
                Button { onOpen(conversation) } label: {
                    ToasttyConversationMiniRow(conversation: conversation)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(conversation.accessibilitySummary)
                .accessibilityIdentifier("toastty-mobile-session-\(conversation.id.uuidString)")

                if conversation.id != workspace.sortedConversations.prefix(3).last?.id {
                    Divider().overlay(ToasttyDesignTokens.divider)
                }
            }

            if workspace.conversations.count > 3 {
                NavigationLink(value: workspace.id) {
                    Text("+\(workspace.conversations.count - 3) more…")
                        .font(.caption.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
        .toasttyCard()
    }

    private var workspaceIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(workspace.title)
                .font(.headline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
            Text(workspace.path)
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .lineLimit(1)
        }
    }

    private var rollupPill: some View {
        Text(workspace.rollupLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(rollupColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(rollupColor.opacity(0.14), in: Capsule())
    }

    private var rollupColor: Color {
        if workspace.needsYouCount > 0 { return ToasttyDesignTokens.amberText }
        if workspace.workingCount > 0 { return ToasttyDesignTokens.green }
        return ToasttyDesignTokens.mutedText
    }
}

private struct ToasttyConversationMiniRow: View {
    let conversation: MobileConversation

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { rowContents }
            VStack(alignment: .leading, spacing: 5) { rowContents }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var rowContents: some View {
        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
        Text(conversation.title)
            .font(.subheadline)
            .foregroundStyle(conversation.state.bucket == .offline
                ? ToasttyDesignTokens.mutedText
                : ToasttyDesignTokens.primaryText)
            .lineLimit(1)
        if conversation.inputAvailability == .localDraft {
            Text("✎ desktop draft")
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.amberText)
        }
        Spacer(minLength: 2)
        Text(conversation.age)
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
    }
}

private struct ToasttyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ToasttyDesignTokens.amber.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
