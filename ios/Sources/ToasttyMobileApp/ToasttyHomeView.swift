import SwiftUI
import ToasttyMobileDomain

enum ToasttyHomeListMode: String, CaseIterable {
    case activity
    case workspaces

    var title: String {
        switch self {
        case .activity: "Activity"
        case .workspaces: "Workspaces"
        }
    }
}

struct ToasttyHomeView: View {
    static let listModePreferenceKey = "toastty-mobile-home-list-mode"

    let controller: HomeScreenController
    let refresh: () async -> Void
    let onSettings: () -> Void

    @AppStorage private var storedListMode: String

    init(
        controller: HomeScreenController,
        refresh: @escaping () async -> Void = {},
        onSettings: @escaping () -> Void = {},
        defaults: UserDefaults = .standard
    ) {
        self.controller = controller
        self.refresh = refresh
        self.onSettings = onSettings
        _storedListMode = AppStorage(
            wrappedValue: ToasttyHomeListMode.activity.rawValue,
            Self.listModePreferenceKey,
            store: defaults
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                homeContent
            }
            .id(selectedListMode)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await refresh()
        }
        .scrollIndicators(.hidden)
        // The identifier must precede safeAreaInset: applied after it, it
        // stamps both the scroll view and the inset header, breaking UI-test
        // queries with ambiguous matches.
        .accessibilityIdentifier("toastty-mobile-home")
        .safeAreaInset(edge: .top, spacing: 0) {
            // Connection state and the active list mode stay visible while
            // sessions scroll underneath them.
            VStack(spacing: 10) {
                header
                connectionNotice
                listModePicker
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .background(ToasttyDesignTokens.background)
        }
        .background(ToasttyDesignTokens.background)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.warning, trigger: needsApprovalCount) { old, new in
            new > old
        }
        .onAppear {
            if ToasttyHomeListMode(rawValue: storedListMode) == nil {
                storedListMode = ToasttyHomeListMode.activity.rawValue
            }
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        switch selectedListMode {
        case .activity:
            activityContent
        case .workspaces:
            workspaceContent
        }
    }

    private var selectedListMode: ToasttyHomeListMode {
        ToasttyHomeListMode(rawValue: storedListMode) ?? .activity
    }

    private var listModeSelection: Binding<ToasttyHomeListMode> {
        Binding(
            get: { selectedListMode },
            set: { storedListMode = $0.rawValue }
        )
    }

    private var listModePicker: some View {
        Picker("Session organization", selection: listModeSelection) {
            ForEach(ToasttyHomeListMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("toastty-mobile-home-mode")
    }

    @ViewBuilder
    private var activityContent: some View {
        if controller.snapshot.activitySessions.isEmpty {
            emptyState
        } else {
            ForEach(controller.snapshot.activitySessions) { conversation in
                ToasttySessionCard(
                    conversation: conversation,
                    showsWorkspace: true,
                    accessibilityIdentifier:
                        "toastty-mobile-activity-card-\(conversation.id.uuidString)",
                    onOpen: controller.open
                )
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if controller.snapshot.rankedWorkspaces.isEmpty {
            emptyState
        } else {
            ForEach(controller.snapshot.rankedWorkspaces) { workspace in
                Section {
                    ForEach(workspace.conversations) { conversation in
                        ToasttySessionCard(
                            conversation: conversation,
                            showsWorkspace: false,
                            accessibilityIdentifier:
                                "toastty-mobile-grouped-card-\(conversation.id.uuidString)",
                            onOpen: controller.open
                        )
                    }
                } header: {
                    workspaceHeader(workspace)
                }
            }
        }
    }

    private func workspaceHeader(_ workspace: MobileWorkspace) -> some View {
        NavigationLink(value: ToasttyMobileRoute.workspace(workspace.id)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.title)
                        .font(.headline)
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .lineLimit(1)
                    Text(sessionCountLabel(workspace.conversations.count))
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(workspace.title), \(sessionCountLabel(workspace.conversations.count))"
        )
        .accessibilityHint("Opens the workspace")
        .accessibilityIdentifier("toastty-mobile-workspace-\(workspace.id.uuidString)")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No sessions yet",
            systemImage: "rectangle.stack",
            description: Text("Open a session in Toastty on your Mac and it will appear here.")
        )
        .foregroundStyle(ToasttyDesignTokens.secondaryText)
        .padding(.vertical, 32)
    }

    private var needsApprovalCount: Int {
        controller.snapshot.activitySessions.lazy.filter {
            $0.state.bucket == .needsApproval
        }.count
    }

    private func sessionCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "session" : "sessions")"
    }

    @ViewBuilder
    private var connectionNotice: some View {
        if let message = controller.connectionNoticeMessage {
            HStack(alignment: .top, spacing: 9) {
                connectionNoticeIndicator
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
            .accessibilityValue(showsProgressIndicator ? "In progress" : "")
            .accessibilityIdentifier("toastty-mobile-connection-notice")
        }
    }

    @ViewBuilder
    private var connectionNoticeIndicator: some View {
        if showsProgressIndicator {
            ProgressView()
                .controlSize(.small)
                .tint(ToasttyDesignTokens.amber)
        } else {
            Image(systemName: controller.freshness == .unreachable
                ? "wifi.slash"
                : "arrow.trianglehead.2.clockwise.rotate.90")
        }
    }

    private var showsProgressIndicator: Bool {
        controller.freshness == .reconnecting || controller.freshness == .connecting
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
        .padding(.bottom, 4)
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
}

struct ToasttySessionCard: View {
    let conversation: MobileConversation
    let showsWorkspace: Bool
    let accessibilityIdentifier: String
    let onOpen: (MobileConversation) -> Void

    var body: some View {
        Button {
            onOpen(conversation)
        } label: {
            VStack(alignment: .leading, spacing: isIdle ? 6 : 8) {
                if isIdle {
                    idleContent
                } else {
                    statusHeader
                    activityBody
                }
                metadata
            }
            .padding(.horizontal, 13)
            .padding(.vertical, isIdle ? 10 : 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(cardBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.accessibilitySummary)
        .accessibilityHint("Opens the conversation")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var isIdle: Bool {
        conversation.state.bucket == .idle
    }

    private var idleContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(conversation.lastActivity)
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            activityDestination
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusLabel
            Spacer(minLength: 8)
            activityDestination
        }
    }

    private var statusLabel: some View {
        ToasttySessionStatusLabel(bucket: conversation.state.bucket)
    }

    private var activityDestination: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .accessibilityHidden(true)
    }

    private var activityBody: some View {
        Text(conversation.lastActivity)
            .font(bodyFont)
            .foregroundStyle(bodyForegroundStyle)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bodyFont: Font {
        conversation.state.bucket == .working ? .subheadline.italic() : .subheadline
    }

    private var bodyForegroundStyle: Color {
        conversation.state.bucket == .working
            ? ToasttyDesignTokens.secondaryText
            : ToasttyDesignTokens.primaryText
    }

    private var metadata: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let workspaceLabel {
                    Text(workspaceLabel)
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !trailingMetadataLabel.isEmpty {
                        Text("·")
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                    }
                }
                if !trailingMetadataLabel.isEmpty {
                    // Wins the width fight so a long workspace name squeezes
                    // before cwd/agent/age disappear.
                    Text(trailingMetadataLabel)
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .font(.caption2.monospaced())
        }
    }

    private var workspaceLabel: String? {
        guard showsWorkspace else { return nil }
        let title = conversation.workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private var trailingMetadataLabel: String {
        [conversation.abbreviatedCWD, conversation.agent.displayName, conversation.displayAge]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private var cardBackground: Color {
        switch conversation.state.bucket {
        case .error, .ready, .needsApproval:
            ToasttyDesignTokens.color(for: conversation.state.bucket).opacity(0.13)
        case .working, .idle:
            ToasttyDesignTokens.raisedSurface
        }
    }

    private var cardBorder: Color {
        switch conversation.state.bucket {
        case .error, .ready, .needsApproval:
            ToasttyDesignTokens.color(for: conversation.state.bucket).opacity(0.38)
        case .working, .idle:
            ToasttyDesignTokens.border
        }
    }
}
