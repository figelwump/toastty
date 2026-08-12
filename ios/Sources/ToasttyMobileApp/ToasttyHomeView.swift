import SwiftUI
import ToasttyMobileDomain

struct ToasttyHomeView: View {
    let controller: HomeScreenController
    let refresh: () async -> Void
    let onSettings: () -> Void

    init(
        controller: HomeScreenController,
        refresh: @escaping () async -> Void = {},
        onSettings: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.refresh = refresh
        self.onSettings = onSettings
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                header
                connectionNotice
                readySection
                needsApprovalSection
                workspaceSection
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 40)
        }
        .refreshable {
            await refresh()
        }
        .scrollIndicators(.hidden)
        .background(ToasttyDesignTokens.background)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("toastty-mobile-home")
    }

    @ViewBuilder
    private var connectionNotice: some View {
        if let message = controller.connectionNoticeMessage {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: controller.freshness == .unreachable
                    ? "wifi.slash"
                    : "arrow.trianglehead.2.clockwise.rotate.90")
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(controller.freshness == .unreachable
                ? ToasttyDesignTokens.red
                : ToasttyDesignTokens.amberText)
            .toasttyCard()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(controller.freshness.accessibilityLabel). \(message)")
            .accessibilityIdentifier("toastty-mobile-connection-notice")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                brand
                Spacer(minLength: 12)
                connection
                settingsButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    brand
                    Spacer(minLength: 12)
                    settingsButton
                }
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

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(ToasttyDesignTokens.raisedSurface, in: Circle())
                .overlay {
                    Circle().stroke(ToasttyDesignTokens.border)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ToasttyDesignTokens.amberText)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("toastty-mobile-settings-button")
    }

    private var readySection: some View {
        VStack(spacing: 10) {
            ToasttySectionTitle(title: "Ready · \(readyConversations.count)")
                .padding(.top, 6)
                .accessibilityIdentifier("toastty-mobile-ready-section")

            if readyConversations.isEmpty {
                Text("no conversations are ready")
                    .font(.caption.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
            } else {
                ForEach(readyConversations) { conversation in
                    ToasttyActionCard(
                        conversation: conversation,
                        accessibilityIdentifier: "toastty-mobile-ready-card-\(conversation.id.uuidString)",
                        onOpen: controller.open
                    )
                }
            }
        }
    }

    private var readyConversations: [MobileConversation] {
        stablySorted(controller.snapshot.ready)
    }

    private var needsApprovalSection: some View {
        VStack(spacing: 10) {
            ToasttySectionTitle(title: "Needs approval · \(needsApprovalConversations.count)")
                .padding(.top, 6)
                .accessibilityIdentifier("toastty-mobile-needs-approval-section")

            ForEach(needsApprovalConversations) { conversation in
                ToasttyActionCard(
                    conversation: conversation,
                    accessibilityIdentifier: "toastty-mobile-needs-approval-card-\(conversation.id.uuidString)",
                    onOpen: controller.open
                )
            }
        }
    }

    private var needsApprovalConversations: [MobileConversation] {
        stablySorted(controller.snapshot.needsApproval)
    }

    private func stablySorted(_ conversations: [MobileConversation]) -> [MobileConversation] {
        conversations.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
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

private struct ToasttyActionCard: View {
    let conversation: MobileConversation
    let accessibilityIdentifier: String
    let onOpen: (MobileConversation) -> Void

    var body: some View {
        Button {
            onOpen(conversation)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) { metadata }
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)

                Text(conversation.title)
                    .font(.headline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)

                Text(conversation.inputAvailability.inputReason)
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .toasttyCard()
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(ToasttyDesignTokens.color(for: conversation.state.bucket))
                    .frame(width: 3)
                    .padding(.vertical, 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(conversation.accessibilitySummary), \(conversation.inputAvailability.inputReason)"
        )
        .accessibilityHint("Opens the conversation")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var metadata: some View {
        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
        Text(conversation.workspaceTitle)
        Text("·")
        Text(conversation.agent.displayName)
            .fontWeight(.bold)
            .foregroundStyle(ToasttyDesignTokens.color(for: conversation.agent))
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text("· \(conversation.age)")
        }
    }

}

private struct ToasttyWorkspaceCard: View {
    let workspace: MobileWorkspace
    let onOpen: (MobileConversation) -> Void
    @State private var showsAllConversations = false

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

            ForEach(visibleConversations) { conversation in
                Button { onOpen(conversation) } label: {
                    ToasttyConversationMiniRow(conversation: conversation)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(conversation.accessibilitySummary)
                .accessibilityIdentifier("toastty-mobile-session-\(conversation.id.uuidString)")

                if conversation.id != visibleConversations.last?.id {
                    Divider().overlay(ToasttyDesignTokens.divider)
                }
            }

            if workspace.conversations.count > 3 {
                Button {
                    showsAllConversations.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(showsAllConversations
                            ? "Show less"
                            : "+\(workspace.conversations.count - 3) more…")
                        .font(.caption.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        Spacer(minLength: 8)
                        Image(systemName: showsAllConversations ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsAllConversations
                    ? "Show fewer sessions in \(workspace.title)"
                    : "Show all sessions in \(workspace.title)")
                .accessibilityValue(showsAllConversations ? "Expanded" : "Collapsed")
                .accessibilityHint("Expands or collapses this workspace card")
                .accessibilityIdentifier(
                    "toastty-mobile-workspace-more-toggle-\(workspace.id.uuidString)"
                )
            }
        }
        .toasttyCard()
    }

    private var visibleConversations: [MobileConversation] {
        if showsAllConversations {
            stablySortedConversations
        } else {
            Array(stablySortedConversations.prefix(3))
        }
    }

    private var stablySortedConversations: [MobileConversation] {
        workspace.sortedConversations.sorted {
            if $0.state.bucket.sortOrder != $1.state.bucket.sortOrder {
                return $0.state.bucket.sortOrder < $1.state.bucket.sortOrder
            }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
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
        if workspace.readyCount > 0 { return ToasttyDesignTokens.color(for: .ready) }
        if workspace.needsApprovalCount > 0 { return ToasttyDesignTokens.color(for: .needsApproval) }
        if workspace.workingCount > 0 { return ToasttyDesignTokens.color(for: .working) }
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
            .foregroundStyle(conversation.state.bucket == .idle
                ? ToasttyDesignTokens.mutedText
                : ToasttyDesignTokens.primaryText)
            .lineLimit(1)
        if conversation.inputAvailability == .localDraft {
            Text("✎ desktop draft")
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.amberText)
        }
        Spacer(minLength: 2)
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(conversation.age)
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
    }
}
